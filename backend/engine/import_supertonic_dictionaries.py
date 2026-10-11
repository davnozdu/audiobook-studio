#!/usr/bin/env python3
"""Import portable dictionary data, not Android/Silero neural weights."""
import argparse
import hashlib
import json
from pathlib import Path
from prepare_qwen import write


def run(source, out):
    source, out = Path(source), Path(out)
    assets = source / "ruvoice-tts/app/src/main/assets"
    silero = assets / "silero/silero_ru.json"
    stress = assets / "dicts/stress/Системный.txt"
    replacements = assets / "dicts/replace/Системный.txt"
    fixes = source / "ruvoice-tts/tools/stress_fixes.txt"
    data = json.loads(silero.read_text(encoding="utf-8"))
    corrections = {}
    for path in (stress, fixes):
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].strip()
            parts = line.split("=", 1) if "=" in line else line.split(None, 1)
            if len(parts) == 2:
                key, value = (x.strip() for x in parts)
                if value.replace("+", "").replace("\u0301", "").replace("ё", "е") == key.replace("ё", "е"):
                    corrections[key] = value
    prefixes = {}
    for line in replacements.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if "=" in line:
            key, value = (x.strip() for x in line.split("=", 1))
            if key.endswith("-*") and value.endswith("-*"):
                prefixes[key[:-2]] = value[:-2]
    result = {"version": 1, "exceptions": data["exceptions"],
              "homographs": data["homodict"], "corrections": corrections, "prefixes": prefixes,
              "phrases": data["phrases"], "gram": data["gram"],
              "provenance": {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in (silero, stress, fixes, replacements)}}
    write(out / "dictionary.json", result)
    print(json.dumps({"exceptions": len(result["exceptions"]), "homographs": len(result["homographs"]),
                      "corrections": len(corrections), "prefixes": len(prefixes), "out": str(out)}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--out", default=str(Path(__file__).parent / "data/stress"))
    args = parser.parse_args()
    run(args.source, args.out)
