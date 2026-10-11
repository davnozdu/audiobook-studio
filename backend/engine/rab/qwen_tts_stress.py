#!/usr/bin/env python3
"""Озвучка текстового файла с ударениями моделью Qwen3-TTS через MLX (Apple Silicon: M1/M2/M3/M4).

Модель: siriusfreak/qwen3-tts-12hz-1.7b-ru-stress-cf, дообученная Qwen/Qwen3-TTS-12Hz-1.7B-Base для
русских ударений. Ударение задаётся знаком U+0301 после ударной гласной («за́мок», «замо́к»). Скрипт понимает
и запись «+» перед гласной (как у RUAccent: «з+амок») и сам переводит её в U+0301.

Запускается на MLX (библиотека mlx-audio): веса PyTorch из репозитория переводятся в MLX при загрузке.

Base-модель говорит голосом из образца (клонирование голоса). Образец можно указать (--ref-audio + --ref-text).
Если его нет, скрипт сам запишет образец системным голосом macOS Milena (команда say).

Пример:
    venv-tts/bin/python qwen_tts_stress.py текст.txt -o текст.wav
"""

import argparse
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEFAULT_MODEL = "siriusfreak/qwen3-tts-12hz-1.7b-ru-stress-cf"
# Только то, что нужно для синтеза: без lora/, meter/, eval/, scripts/ из репозитория модели.
MODEL_FILES = [
    "config.json",
    "generation_config.json",
    "preprocessor_config.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "model.safetensors",
    "speech_tokenizer/*",
]
ACUTE = "́"
VOWELS = "аеёиоуыэюяАЕЁИОУЫЭЮЯ"
DEFAULT_REF_TEXT = (
    "Добрый день. Меня зовут Милена, я читаю этот текст спокойно и разборчиво, "
    "чтобы получился хороший образец голоса."
)


def normalize_stress(text: str) -> str:
    """«+» перед гласной → U+0301 после неё."""
    text = re.sub(rf"\+([{VOWELS}])", rf"\1{ACUTE}", text)
    # Ударение над «ё» не нужно.
    return re.sub(rf"([ёЁ]){ACUTE}", r"\1", text)


def split_text(text: str, max_chars: int) -> list[str]:
    """Режет текст на куски по абзацам и предложениям, не длиннее max_chars."""
    chunks: list[str] = []
    for para in text.splitlines():
        para = " ".join(para.split())
        if not para:
            continue
        cur = ""
        for sent in re.split(r"(?<=[.!?…»])\s+", para):
            while len(sent) > max_chars:  # очень длинное предложение режем по запятой или пробелу
                cut = max(sent.rfind(", ", 0, max_chars), sent.rfind(" ", 0, max_chars))
                cut = cut + 1 if cut > 0 else max_chars
                if cur:
                    chunks.append(cur)
                    cur = ""
                chunks.append(sent[:cut].strip())
                sent = sent[cut:].strip()
            if cur and len(cur) + 1 + len(sent) > max_chars:
                chunks.append(cur)
                cur = sent
            else:
                cur = f"{cur} {sent}".strip()
        if cur:
            chunks.append(cur)
    return chunks


def make_macos_reference(voice: str, text: str, workdir: Path) -> Path:
    """Записывает образец голоса системным синтезатором macOS (say) в WAV 24 кГц моно."""
    aiff = workdir / "ref.aiff"
    wav = workdir / "ref.wav"
    try:
        subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1", str(aiff), str(wav)], check=True)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        sys.exit(
            f"Не удалось записать образец голосом «{voice}»: {e}\n"
            "Русские голоса в системе: say -v '?' | grep ru_RU\n"
            "Добавить голос: Системные настройки → Универсальный доступ → Устный контент → Системный голос → "
            "Управление голосами → Русский.\n"
            "Или укажите свой образец: --ref-audio файл.wav --ref-text \"точный текст образца\"."
        )
    return wav


def write_wav(path: Path, audio, sr: int) -> None:
    import numpy as np
    from scipy.io import wavfile

    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype(np.int16)
    wavfile.write(str(path), sr, pcm)


def main() -> None:
    ap = argparse.ArgumentParser(description="Озвучить текстовый файл с ударениями (Qwen3-TTS на MLX, русский).")
    ap.add_argument("input", help="текстовый файл UTF-8 с ударениями (U+0301 после гласной или + перед ней)")
    ap.add_argument("-o", "--output", help="выходной WAV (по умолчанию рядом с текстом, .wav)")
    ap.add_argument("--model", default=DEFAULT_MODEL, help=f"модель HF или локальная папка (по умолчанию {DEFAULT_MODEL})")
    ap.add_argument("--ref-audio", help="образец голоса: WAV 5–15 секунд, один голос, без музыки")
    ap.add_argument("--ref-text", help="точная расшифровка образца (обязательна вместе с --ref-audio)")
    ap.add_argument("--mac-voice", default="Milena", help="голос macOS для автообразца (по умолчанию Milena)")
    ap.add_argument("--max-chars", type=int, default=250, help="максимум символов в одном куске (по умолчанию 250)")
    ap.add_argument("--pause", type=float, default=0.35, help="пауза между кусками, секунд (по умолчанию 0.35)")
    ap.add_argument("--seed", type=int, default=42, help="зерно случайности, чтобы результат повторялся")
    ap.add_argument("--temperature", type=float, default=0.9, help="ниже — ровнее и стабильнее (например 0.7)")
    ap.add_argument("--save-chunks", action="store_true", help="сохранить и каждый кусок отдельным файлом")
    args = ap.parse_args()

    if bool(args.ref_audio) != bool(args.ref_text):
        sys.exit("--ref-audio и --ref-text указываются вместе.")
    if not args.ref_audio and sys.platform != "darwin":
        sys.exit("Нет образца голоса: укажите --ref-audio и --ref-text (автообразец есть только на macOS).")

    src = Path(args.input)
    chunks = split_text(normalize_stress(src.read_text(encoding="utf-8")), args.max_chars)
    if not chunks:
        sys.exit("Файл пуст.")
    out = Path(args.output) if args.output else src.with_suffix(".wav")

    import mlx.core as mx
    import numpy as np
    from mlx_audio.tts.utils import load_model

    print(f"Модель: {args.model} (MLX, {mx.default_device()}). Кусков текста: {len(chunks)}")
    print("Первый запуск скачивает ~4 ГБ в ~/.cache/huggingface, дальше берётся из кэша.")
    t0 = time.time()
    model = load_model(args.model, allow_patterns=MODEL_FILES)
    print(f"Модель загружена за {time.time() - t0:.0f} с")

    with tempfile.TemporaryDirectory() as tmp:
        if args.ref_audio:
            ref_audio, ref_text = args.ref_audio, args.ref_text
        else:
            ref_text = DEFAULT_REF_TEXT
            ref_audio = str(make_macos_reference(args.mac_voice, ref_text, Path(tmp)))
            print(f"Образец голоса записан голосом macOS «{args.mac_voice}»")
        # Образец читаем один раз: дальше в модель передаётся уже массив.
        from mlx_audio.utils import load_audio

        ref_wave = load_audio(ref_audio, sample_rate=model.sample_rate)

    sr = model.sample_rate
    pieces = []
    for i, chunk in enumerate(chunks, 1):
        mx.random.seed(args.seed + i)
        t = time.time()
        parts = [
            np.asarray(r.audio, dtype=np.float32)
            for r in model.generate(
                text=chunk,
                lang_code="russian",
                ref_audio=ref_wave,
                ref_text=ref_text,
                temperature=args.temperature,
            )
        ]
        wav = np.concatenate(parts) if parts else np.zeros(0, dtype=np.float32)
        print(f"[{i}/{len(chunks)}] {len(wav) / sr:5.1f} с звука за {time.time() - t:5.1f} с: {chunk[:70]}")
        if args.save_chunks:
            write_wav(out.with_name(f"{out.stem}_{i:03d}.wav"), wav, sr)
        pieces.append(wav)
        if i < len(chunks):
            pieces.append(np.zeros(int(sr * args.pause), dtype=np.float32))

    audio = np.concatenate(pieces)
    write_wav(out, audio, sr)
    print(f"\nГотово: {out} ({len(audio) / sr:.1f} с звука, всего {time.time() - t0:.0f} с)")


if __name__ == "__main__":
    main()
