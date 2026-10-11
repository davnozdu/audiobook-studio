"""Report dictionary-versus-final edits for any prepared book; never edit it."""
import argparse
import json
from pathlib import Path
from prepare_speech import WORD


def audit(path, out):
    manifest = json.loads(Path(path).read_text(encoding="utf-8"))
    changes = []
    for segment in manifest["segments"]:
        before = WORD.findall(segment["tts_dictionary_text"])
        after = WORD.findall(segment["tts_text"])
        if len(before) != len(after):
            raise ValueError("Word counts differ: " + segment["id"])
        for index, (a, b) in enumerate(zip(before, after)):
            if a != b:
                changes.append(dict(segment_id=segment["id"], word_index=index, dictionary=a,
                                    final=b, original_context=segment["text"]))
    report = dict(source=str(Path(path).resolve()), policy=manifest["speech_preparation"].get("llm_policy", "legacy text rewrite"),
                  changed_words=len(changes), changes=changes)
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Dictionary → final: {len(changes)} changed words; {out}")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    audit(args.manifest, args.out)
