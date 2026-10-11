"""Supertonic dictionaries first; ambiguous homographs left for contextual LLM."""
import hashlib
import json
import mmap
from pathlib import Path
import re
import struct
import russian_text as ru


def plain(word):
    return word.replace("+", "").replace("\u0301", "").lower().replace("ё", "е")


def acute(word):
    return re.sub(r"\+([аеёиоуыэюяАЕЁИОУЫЭЮЯ])", lambda m: m[1] + "\u0301", word)


class BinaryAccentDictionary:
    """SACC v1, the same on-disk format used by Supertonic Android."""
    def __init__(self, path):
        self.file = open(path, "rb")
        self.buffer = mmap.mmap(self.file.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            if len(self.buffer) < 28:
                raise ValueError("Слишком короткий SACC")
            magic, version, self.count, self.offsets, self.data = struct.unpack_from("<4sIIQQ", self.buffer)
            if magic != b"SACC" or version != 1 or self.offsets < 28 or self.data < self.offsets + self.count * 4 or self.data > len(self.buffer):
                raise ValueError("Некорректный заголовок SACC")
        except BaseException:
            self.close()
            raise

    def lookup(self, word):
        query = word.lower().encode("utf-8")
        low, high = 0, self.count - 1
        while low <= high:
            index = (low + high) // 2
            offset = self.data + struct.unpack_from("<I", self.buffer, self.offsets + index * 4)[0]
            if not self.data <= offset <= len(self.buffer) - 4:
                raise ValueError("Некорректное смещение SACC")
            key_size, value_size = struct.unpack_from("<HH", self.buffer, offset)
            if offset + 4 + key_size + value_size > len(self.buffer):
                raise ValueError("Оборванная запись SACC")
            key = self.buffer[offset+4:offset+4+key_size]
            if key < query:
                low = index + 1
            elif key > query:
                high = index - 1
            else:
                return self.buffer[offset+4+key_size:offset+4+key_size+value_size].decode("utf-8")
        return None

    def close(self):
        if getattr(self, "buffer", None) is not None:
            self.buffer.close()
            self.buffer = None
        if getattr(self, "file", None) is not None:
            self.file.close()
            self.file = None

    def __del__(self):
        self.close()


class StressDictionary:
    def __init__(self, directory):
        path = Path(directory) / "dictionary.json"
        if not path.is_file():
            raise ValueError("Не импортированы словари Supertonic: " + str(path))
        raw = path.read_bytes()
        self.sha256 = hashlib.sha256(raw).hexdigest()
        self.data = json.loads(raw)
        self.binary = None
        binary = Path(directory) / "russian_accents_full.sacc"
        if binary.is_file():
            checksum = hashlib.sha256()
            with binary.open("rb") as reader:
                for block in iter(lambda: reader.read(256 * 1024), b""):
                    checksum.update(block)
            sha = checksum.hexdigest()
            if binary.stat().st_size != 179200764 or sha != "a1ac32606e99f6d8ab8e8ce796b0005b0693908555460656976c54e171658b27":
                raise ValueError("Размер/SHA-256 бинарного словаря russian-v1.1 не совпадает")
            self.binary = BinaryAccentDictionary(binary)
            self.sha256 = hashlib.sha256((self.sha256 + sha).encode()).hexdigest()

    def lookup(self, word, text="", start=0, stop=0):
        key = word.lower()
        # Context phrases supplied by Supertonic resolve a subset of homographs
        # without loading BERT. Only use a phrase containing THIS occurrence.
        context = text.replace("\u0301", "").lower()
        offset_start = len(text[:start].replace("\u0301", ""))
        offset_stop = len(text[:stop].replace("\u0301", ""))
        for phrase, value in sorted(self.data.get("phrases", {}).get(key, []), key=lambda x: -len(x[0])):
            for match in re.finditer(r"(?<!\w)" + re.escape(phrase.lower()) + r"(?!\w)", context):
                if match.start() <= offset_start < offset_stop <= match.end():
                    return acute(value)
        correction = self.data["corrections"].get(key)
        if correction:
            return acute(correction)
        # Silero's homodict explicitly lists contextual alternatives. Never
        # pick the first one by dictionary order; the LLM gets an unmarked word.
        if key in self.data["homographs"]:
            return None
        entry = self.data["exceptions"].get(key)
        if entry:
            stress, yo = entry
            value = list(key)
            if 0 <= yo < len(value):
                value[yo] = "ё"
            if 0 <= stress < len(value) and value[stress] in ru.VOWELS and "ё" not in value:
                value[stress] += "\u0301"
            return "".join(value)
        variants = set(self.data.get("gram", {}).get(key, {}).values())
        if len(variants) == 1:
            return acute(next(iter(variants)))
        if self.binary:
            target = self.binary.lookup(key)
            if target:
                target = acute(target)
                # A multi-variant/invalid dictionary value is not a decision.
                # Let the LLM resolve it, never take a random first variant.
                if (ru.TOKEN.fullmatch(target) and plain(target) == plain(word) and target.count("\u0301") <= 1
                        and all(i > 0 and target[i-1].lower() in ru.VOWELS for i, c in enumerate(target) if c == "\u0301")):
                    return target
        return None

    def apply(self, text):
        count = 0
        def replace(match):
            nonlocal count
            original = match[0]
            if "\u0301" in original or "ё" in original.lower():
                return original
            # A lexical stress marker on a one-vowel word carries no location
            # information, but can cause artificial emphasis in a TTS model.
            if sum(c in ru.VOWELS for c in original.lower()) <= 1:
                return original
            target = self.lookup(original, text, match.start(), match.end())
            if target is None and text[match.end():match.end()+1] == "-":
                prefix = self.data["prefixes"].get(original.lower())
                target = acute(prefix) if prefix else None
            if target is None or plain(original) != plain(target):
                return original
            # Restore the exact original capitalization letter by letter.
            result, index = [], 0
            for c in target:
                if c == "\u0301":
                    result.append(c)
                else:
                    result.append(c.upper() if original[index].isupper() else c)
                    index += 1
            marked = "".join(result)
            count += marked != original
            return marked
        return ru.TOKEN.sub(replace, text), count
