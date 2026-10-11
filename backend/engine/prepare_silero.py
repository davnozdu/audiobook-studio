#!/usr/bin/env python3
"""Contextual Silero Stress preparation; no LLM and no audio generation."""
import argparse
import getpass
from collections import defaultdict
from copy import deepcopy
from importlib.metadata import version
import json
import os
from pathlib import Path
import re
import time
from types import SimpleNamespace

from prepare_qwen import digest, load, write
from prepare_speech import VERSION, check, process, validate_text

WORD = re.compile(r"[А-Яа-яЁё]+(?:\u0301[А-Яа-яЁё]*)*")
MARKED_WORD = re.compile(r"[+А-Яа-яЁё\u0301]+")
VOWELS = "аеёиоуыэюя"


def choose_cloud():
    """Explicit opt-in; N bypasses both credentials and cached LLM decisions."""
    while True:
        try:
            answer = input("Вы хотите сделать обработку через облачную LLM? Y/N (Enter = Y): ").strip().lower()
        except EOFError:
            print("Нет ответа: продолжаем без LLM.", flush=True)
            return False, None
        if answer in {"n", "no", "нет", "н"}:
            print("Облачная LLM отключена: только словарь + Silero.", flush=True)
            return False, None
        if answer in {"", "y", "yes", "да", "д"}:
            try:
                key = getpass.getpass("Ollama API key (не сохраняется): ").strip()
            except EOFError:
                key = ""
            if not key:
                print("Ключ не введён: продолжаем без LLM.", flush=True)
                return False, None
            return True, key
        print("Введите Y или нажмите Enter для LLM; N или «нет» — без LLM.", flush=True)


def acute(word):
    """Silero + BEFORE vowel -> U+0301 AFTER vowel; reject malformed marks."""
    result = ""
    pending = False
    for char in word:
        if char == "+":
            if pending:
                raise ValueError("Повторный знак +")
            pending = True
        else:
            result += char
            if pending:
                if char.lower() not in VOWELS:
                    raise ValueError("Ударение перед согласной")
                if char.lower() != "ё":
                    result += "\u0301"
                pending = False
    if pending or result.count("\u0301") > 1:
        raise ValueError("Некорректное ударение Silero")
    return result


def project(original, predicted):
    """Transfer only accents, retaining ALL original letters and punctuation."""
    source = list(WORD.finditer(original))
    target = [acute(m.group()) for m in MARKED_WORD.finditer(predicted)]
    plain = lambda w: w.replace("\u0301", "").replace('ё','е').replace('Ё','Е')
    if [plain(m.group()).lower() for m in source] != [plain(w).lower() for w in target]:
        raise ValueError("Silero изменил слова: результат не принят")
    parts, end = [], 0
    for match, marked in zip(source, target):
        word = match.group()
        replacement = word
        if "\u0301" not in word and "ё" not in word.lower() and ("\u0301" in marked or 'ё' in marked.lower()):
            # Some Silero exceptions restore ё even with put_yo=False. Extract
            # its stress position, never transfer changed letters into the book.
            position = marked.index("\u0301") if '\u0301' in marked else marked.lower().index('ё')+1
            if sum(c.lower() in VOWELS for c in word) > 1:
                replacement = word[:position] + "\u0301" + word[position:]
        parts.extend([original[end:match.start()], replacement])
        end = match.end()
    parts.append(original[end:])
    return "".join(parts)


def hybrid_text(original, dictionary_text, silero_text, homographs):
    """Dictionary wins except for known ambiguous and unmarked words."""
    source = WORD.findall(original)
    dictionary = WORD.findall(dictionary_text)
    predicted = WORD.findall(silero_text)
    if len(source) != len(dictionary) or len(source) != len(predicted):
        raise ValueError("Несовпадение слов при гибридной обработке")
    chosen, decisions = [], []
    for authored, known, neural in zip(source, dictionary, predicted):
        key = authored.replace("\u0301", "").lower()
        if "\u0301" in authored or "ё" in key:
            value, engine = authored, "author"
        elif key in homographs:
            value, engine = neural, "silero_homograph"
        elif "\u0301" in known or "ё" in known.lower():
            value, engine = known, "dictionary"
        elif sum(c.lower() in VOWELS for c in authored) > 1:
            value, engine = neural, "silero_unknown"
        else:
            value, engine = known, "unchanged"
        chosen.append(value)
        decisions.append(engine)
    iterator = iter(chosen)
    return WORD.sub(lambda _: next(iterator), original), decisions


def prepare(manifest, accentor, package_version, dictionary_dir, strategy="hybrid"):
    args = SimpleNamespace(command="offline", dictionary_dir=dictionary_dir, batch_chars=2400)
    result = process(deepcopy(manifest), args, Path("."))
    groups = defaultdict(list)
    for segment in result["segments"]:
        groups[segment["paragraph_id"]].append(segment)
    from stress_dictionary import StressDictionary
    dictionary = StressDictionary(dictionary_dir)
    homographs = set(dictionary.data.get("homographs", {}))
    homographs.update(getattr(getattr(accentor, "homosolver", None), "homodict", {}))
    homographs.update(key for key, variants in dictionary.data.get("gram", {}).items()
                      if len(set(variants.values())) > 1)
    changes = []
    fallbacks = []
    decisions_count = defaultdict(int)
    start = time.monotonic()
    for number, segments in enumerate(groups.values(), 1):
        # Use full paragraphs, never isolated words; ignore dictionary accents
        # so that they cannot anchor Silero's independent contextual prediction.
        original = " ".join(s["tts_normalized"] for s in segments)
        clean = original.replace("\u0301", "")
        prediction = accentor(clean, put_yo=False, put_yo_homo=False,
                              stress_single_vowel=False)
        try:
            projected = project(original, prediction)
            silero_valid = True
        except ValueError as exc:
            projected = ' '.join(s['tts_dictionary_text'] for s in segments)
            silero_valid = False
            fallbacks.append({'paragraph_id':segments[0]['paragraph_id'],'reason':str(exc)})
            print(f"Silero: сохранён словарный абзац {segments[0]['paragraph_id']} ({exc})",flush=True)
        # Character offsets differ only by inserted acute marks. Split back by
        # original word counts, not by Silero punctuation or sentence splitting.
        words = iter(WORD.findall(projected))
        for segment in segments:
            independent = WORD.sub(lambda _: next(words), segment["tts_normalized"])
            segment["tts_silero_text"] = independent
            segment['tts_silero_valid'] = silero_valid
            if strategy == "hybrid":
                text, decisions = hybrid_text(segment["tts_normalized"], segment["tts_dictionary_text"], independent, homographs)
                for decision in decisions:
                    decisions_count[decision] += 1
            else:
                text = independent
            validate_text(segment["tts_normalized"], text)
            baseline = WORD.findall(segment["tts_dictionary_text"])
            final = WORD.findall(text)
            for index, (before, after) in enumerate(zip(baseline, final)):
                if before != after:
                    changes.append({"segment_id": segment["id"], "word_index": index,
                                    "dictionary": before, "final": after,
                                    "context": segment["tts_normalized"]})
            segment["tts_text"] = text
            segment["tts_sha256"] = digest([VERSION, segment["text"], text])
        print(f"Silero Stress: абзац {number}/{len(groups)}", flush=True)
    result["speech_preparation"].update(
        mode="hybrid" if strategy == "hybrid" else "silero", model=f"silero-stress-{package_version}", llm_policy="disabled",
        stress=any("\u0301" in s["tts_text"] for s in result["segments"]),
        stress_review=[], silero_seconds=round(time.monotonic()-start, 3),
        silero_policy="independent full-paragraph prediction; original accents/letters preserved; yo restoration disabled",
        stress_strategy=strategy,
        silero_fallbacks=fallbacks,
        hybrid_policy="dictionary for marked unambiguous words; Silero for known homographs and unmarked words; author accents protected" if strategy == "hybrid" else None,
    )
    check(result)
    report = {"engine": f"silero-stress-{package_version}", "strategy": strategy, "llm": False,
              "segments": len(result["segments"]), "paragraphs": len(groups),
              "dictionary_acute_marks": sum(s["tts_dictionary_text"].count("\u0301") for s in result["segments"]),
              "final_acute_marks": sum(s["tts_text"].count("\u0301") for s in result["segments"]),
              "word_sources": dict(decisions_count),
              "silero_fallbacks": fallbacks,
              "different_words": len(changes), "changes": changes,
              "inference_seconds": result["speech_preparation"]["silero_seconds"],
              "warning": "Disagreement is not proof of error; no audio generated."}
    return result, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out")
    parser.add_argument("--strategy", choices=["hybrid", "silero"], default="hybrid")
    parser.add_argument("--dictionary-dir", default=str(Path(__file__).parent / "data/stress"))
    parser.add_argument("--llm-disputes", choices=["off", "ask", "run", "advance"], default="off")
    parser.add_argument("--model", default="deepseek-v4.1-flash")
    parser.add_argument("--endpoint", default="https://ollama.com")
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--max-tokens", type=int, default=4096)
    args = parser.parse_args()
    try:
        cloud_key = None
        if args.llm_disputes == "ask":
            enabled, cloud_key = choose_cloud()
            args.llm_disputes = "run" if enabled else "off"
        import torch
        from silero_stress import load_accentor
        torch.set_num_threads(1)
        start = time.monotonic()
        accentor = load_accentor()
        print(f"Silero Stress {version('silero-stress')}: CPU, загрузка {time.monotonic()-start:.2f}s", flush=True)
        result, report = prepare(load(args.manifest), accentor, version("silero-stress"), args.dictionary_dir, args.strategy)
        del accentor
        print("Silero Stress освобождён; арбитраж LLM не загружает локальную модель.", flush=True)
        destination = Path(args.out or args.manifest)
        if args.llm_disputes != "off":
            if args.strategy != "hybrid" or not args.endpoint.startswith("https://"):
                raise ValueError("Арбитраж требует гибрид и HTTPS")
            from arbitrate_stress import arbitrate, disputes
            candidates = disputes(result)
            write(destination.parent / "stress-disputes.json", {"disputes": candidates})
            key = None
            if candidates and args.llm_disputes == "run":
                key = cloud_key or os.environ.get("OLLAMA_API_KEY") or getpass.getpass("Ollama API key (не сохраняется): ")
            cloud_key = None
            args.command = args.llm_disputes
            args.no_think = True
            reviewed, arbitration = arbitrate(result, args, destination.parent / "dispute-cache", key)
            key = None
            write(destination.parent / "stress-arbitration.json", arbitration)
            if reviewed is None:
                print("Подготовлен запрос для LLM; аудио не запускается.")
                return
            result = reviewed
            report.update(llm=True, arbitration=arbitration,
                          final_acute_marks=sum(s['tts_text'].count('\u0301') for s in result['segments']))
        write(destination, result)
        write(destination.parent / "silero-comparison.json", report)
        from export_rab_text import export
        export(destination, destination.parent / "book-stressed.txt")
        print(json.dumps({k: v for k, v in report.items() if k != "changes"}, ensure_ascii=False))
        print("Silero Stress освобождён; выход процесса освобождает оставшуюся память.")
    except (ImportError, ValueError, OSError) as exc:
        parser.exit(1, f"Ошибка Silero Stress: {exc}\n")


if __name__ == "__main__":
    main()
