"""Verify the Russian stress checkpoint and convert it with mlx-audio, without replacing the old Base."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parent if (PROJECT.parent / ".venv-mlx").is_dir() else PROJECT
SOURCE = ROOT / "models/Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-source"
TARGET = ROOT / "models/Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-8bit"
SPEC = json.loads((PROJECT / "stress_model_files.json").read_text(encoding="utf-8"))


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def verify_source():
    for f in SPEC["files"]:
        path = SOURCE / f["path"]
        if not path.is_file() or path.stat().st_size != f["size"]:
            raise ValueError(f"Неполная загрузка: {path}")
        if f["sha256"] and digest(path) != f["sha256"]:
            raise ValueError(f"Не совпадает SHA256: {path}")
    print("Исходные веса Ru-Stress-CF: размеры и SHA256 проверены", flush=True)


def download():
    for f in SPEC["files"]:
        path = SOURCE / f["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_file() and path.stat().st_size == f["size"]:
            continue
        if path.is_file() and path.stat().st_size > f["size"]:
            raise ValueError(f"Отказываюсь перезаписывать файл неожиданного размера: {path}")
        url = f"https://huggingface.co/{SPEC['repo']}/resolve/{SPEC['revision']}/{f['path']}"
        subprocess.run(["curl", "-fL", "--retry", "3", "-C", "-", url, "-o", str(path)], check=True)


def ready():
    marker = TARGET / "stress-source.json"
    if not marker.exists():
        return False
    info = json.loads(marker.read_text(encoding="utf-8"))
    config = json.loads((TARGET / "config.json").read_text(encoding="utf-8"))
    weights = list(TARGET.glob("*.safetensors"))
    return (info.get("repo") == SPEC["repo"] and info.get("revision") == SPEC["revision"]
            and config.get("quantization", {}).get("bits") == 8
            and config.get("model_type") == "qwen3_tts"
            and bool(weights) and all(w.stat().st_size > 1024 for w in weights)
            and (TARGET / "speech_tokenizer/model.safetensors").is_file())


def setup():
    if ready():
        print(f"Ru-Stress-CF / MLX 8-bit уже готова: {TARGET}", flush=True)
        return
    download()
    verify_source()
    if TARGET.exists():
        raise ValueError(f"Целевая папка уже существует, но не прошла проверку: {TARGET}; не перезаписываю")
    staging = Path(tempfile.mkdtemp(prefix="ru-stress-cf-conversion-", dir=TARGET.parent))
    print("Конвертация в MLX 8-bit. После завершения процесс конвертера освобождает память.", flush=True)
    # Separate process: all full-precision conversion allocations disappear before synthesis.
    subprocess.run([sys.executable, "-m", "mlx_audio.convert", "--hf-path", str(SOURCE),
                    "--mlx-path", str(staging), "--quantize", "--q-bits", "8",
                    "--q-group-size", "64", "--dtype", "bfloat16"], check=True)
    # Preserve the official in-context speech tokenizer, not a tokenizer from a different voice model.
    if not (staging / "speech_tokenizer/model.safetensors").is_file():
        shutil.copytree(SOURCE / "speech_tokenizer", staging / "speech_tokenizer", dirs_exist_ok=True)
    info = {"repo": SPEC["repo"], "revision": SPEC["revision"], "quantization_bits": 8,
            "source_sha256": next(f["sha256"] for f in SPEC["files"] if f["path"] == "model.safetensors")}
    (staging / "stress-source.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    staging.rename(TARGET)
    if not ready():
        raise ValueError("Проверка результата конвертации не пройдена; синтез не запускается")
    print(f"Готово: {TARGET}; прежняя Base сохранена отдельно", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=("setup", "download", "verify", "status", "path"), default="setup", nargs="?")
    args = p.parse_args()
    if args.action == "verify":
        verify_source()
    elif args.action == "download":
        download()
        verify_source()
    elif args.action == "status":
        print("ready" if ready() else "conversion required")
    elif args.action == "path":
        print(TARGET)
    else:
        setup()


if __name__ == "__main__":
    main()
