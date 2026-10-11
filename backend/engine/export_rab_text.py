"""Export prepared book speech to the working rab synthesizer (one voice)."""
import argparse
import hashlib
import json
from pathlib import Path


def export(manifest_path, destination):
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    from prepare_speech import check
    check(manifest)
    paragraphs = []
    paragraph_id = None
    for segment in manifest["segments"]:
        if segment["paragraph_id"] != paragraph_id:
            paragraphs.append([])
            paragraph_id = segment["paragraph_id"]
        paragraphs[-1].append(segment["tts_text"])
    text = "\n".join(" ".join(p) for p in paragraphs) + "\n"
    destination = Path(destination)
    destination.write_text(text, encoding="utf-8")
    report = {
        "source_manifest": str(Path(manifest_path).resolve()),
        "text_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "paragraphs": len(paragraphs), "source_segments": len(manifest["segments"]),
        "acute_marks": text.count("\u0301"), "llm": manifest.get("speech_preparation", {}).get("mode") in {"llm", "hybrid-llm"},
        "synthesis": "text export only; no audio generated",
    }
    destination.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    export(args.manifest, args.out)
