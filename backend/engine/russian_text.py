"""Portable adaptation of Supertonic's Russian book/number/date normalizers.

The source tables and LLM instruction are in supertonic_rules.json. Original
book text is never modified; this module produces a separate speech target.
No Android engines, Silero weights or dictionaries are loaded.
"""
import datetime
import json
from pathlib import Path
import re

VERSION = "supertonic-python-2"
RULES = json.loads(Path(__file__).with_name("supertonic_rules.json").read_text(encoding="utf-8"))
FORMS = {row[0]: row for row in RULES["forms"]}
ROOTS = {int(n): root for n, root in RULES["ordinal_roots"].items()}
UNITS = "ноль один два три четыре пять шесть семь восемь девять".split()
TEENS = "десять одиннадцать двенадцать тринадцать четырнадцать пятнадцать шестнадцать семнадцать восемнадцать девятнадцать".split()
TENS = "_ _ двадцать тридцать сорок пятьдесят шестьдесят семьдесят восемьдесят девяносто".split()
HUNDREDS = "_ сто двести триста четыреста пятьсот шестьсот семьсот восемьсот девятьсот".split()
MONTHS = "января февраля марта апреля мая июня июля августа сентября октября ноября декабря".split()
TOKEN = re.compile(r"[А-Яа-яЁё]+(?:\u0301[А-Яа-яЁё]*)*")
VOWELS = "аеёиоуыэюя"
MASCULINE_A = set("мужчина мужчины юноша юноши папа папы дядя дяди дедушка дедушки судья судьи слуга слуги староста старосты воевода воеводы".split())
FEMININE = set("запись записи страница страницы книга книги минута минуты секунда секунды строка строки глава главы женщина женщины девушка девушки копейка копейки".split())
FEMININE_SOFT = set("ночь дверь жизнь смерть любовь мышь площадь тетрадь вещь память новость кость часть мысль степень дочь мать сеть роль цель соль боль ель осень".split())
NEUTER = set("имя имени окно окна слово слова письмо письма сообщение сообщения предложение предложения место места".split())
MEASURES = {
    "км": ("километр", "километра", "километров"),
    "м": ("метр", "метра", "метров"), "см": ("сантиметр", "сантиметра", "сантиметров"),
    "мм": ("миллиметр", "миллиметра", "миллиметров"),
    "кг": ("килограмм", "килограмма", "килограммов"), "г": ("грамм", "грамма", "граммов"),
    "л": ("литр", "литра", "литров"), "руб.": ("рубль", "рубля", "рублей"),
    "₽": ("рубль", "рубля", "рублей"), "$": ("доллар", "доллара", "долларов"),
    "€": ("евро", "евро", "евро"), "%": ("процент", "процента", "процентов"),
    "°C": ("градус Цельсия", "градуса Цельсия", "градусов Цельсия"),
    "°С": ("градус Цельсия", "градуса Цельсия", "градусов Цельсия"),
    "°": ("градус", "градуса", "градусов"),
}


def plural(n, forms):
    n = abs(n)
    return forms[2] if 11 <= n % 100 <= 14 else forms[0] if n % 10 == 1 else forms[1] if 2 <= n % 10 <= 4 else forms[2]


def integer(n, case=0, feminine=False):
    if abs(n) >= 10 ** 12:
        raise ValueError("Число за пределами поддерживаемого диапазона")
    if n < 0:
        return "минус " + integer(-n, case, feminine)
    if n == 0:
        return FORMS["ноль"][case]
    words = []
    for scale, names in [(10**9, ("миллиард", "миллиарда", "миллиардов")),
                         (10**6, ("миллион", "миллиона", "миллионов")),
                         (1000, ("тысяча", "тысячи", "тысяч")), (1, None)]:
        group, n = divmod(n, scale)
        if not group:
            continue
        h, rest = divmod(group, 100)
        if h:
            words.append(HUNDREDS[h])
        if 10 <= rest < 20:
            words.append(TEENS[rest - 10])
        else:
            t, u = divmod(rest, 10)
            if t:
                words.append(TENS[t])
            if u:
                word = UNITS[u]
                if scale == 1000 or scale == 1 and feminine:
                    word = {1: "одна", 2: "две"}.get(u, word)
                words.append(word)
        if names:
            words.append(plural(group, names))
    return " ".join(FORMS.get(w, [w] * 6)[case] for w in words)


def ordinal(n, ending="ый"):
    if n <= 0 or n >= 10000:
        raise ValueError("Порядковое число вне диапазона 1..9999")
    tail = n if n in ROOTS else n % 100 if 1 <= n % 100 <= 19 else n % 10 if n % 10 else n % 100 if n % 100 else n % 1000
    root = ROOTS[tail]
    if root == "треть":
        root = "трет"
        ending = {"ый": "ий", "ая": "ья", "ое": "ье", "ого": "ьего", "ому": "ьему",
                  "ом": "ьем", "ым": "ьим", "ую": "ью", "ой": "ьей", "ые": "ьи", "ых": "ьих", "ыми": "ьими"}.get(ending, ending)
    elif ending == "ый" and root in {"втор", "шест", "седьм", "восьм", "сороков"}:
        ending = "ой"
    head = integer(n - tail) + " " if n != tail else ""
    if head.startswith("одна тысяча"):
        head = head[5:]
    return head + root + ending


def previous(text, start):
    words = TOKEN.findall(text[max(0, start - 60):start])
    return words[-1].lower().replace("\u0301", "") if words else ""


def inferred_case(before, after=""):
    word = previous(before, len(before))
    next_word = re.search(r"[а-яё]+", after.lower())
    noun = next_word[0] if next_word else ""
    if word in {"в", "на"} and noun.endswith(("ах", "ях")):
        return 5
    if word in {"с", "со"} and noun in {"лет", "часов", "минут", "секунд", "дней"}:
        return 1
    if word in {"без", "до", "из", "от", "около", "после", "для", "более", "менее", "нет", "лишился", "достиг", "достигли", "требует", "хватает"}:
        return 1
    if word in {"к", "по"}:
        return 2
    if word in {"между", "перед", "над", "с", "со"}:
        return 4
    return 5 if word in {"о", "об", "при"} else 0


def counted(word):
    return bool(word) and not word.startswith("год") and (word in {
        "человек", "лет", "раз", "штук", "тонн", "минут", "секунд", "мест", "книг", "страниц",
        "слов", "единиц", "копеек", "солдат", "граммов", "душ", "верст", "миль", "сажен", "пудов", "десятин"
    } or word.endswith(("ах", "ях", "ам", "ям", "ами", "ями", "ов", "ев", "ей")))


def decimal(raw):
    whole, fraction = re.split(r"[,.]", raw)
    if len(fraction) > 9:
        raise ValueError("Дробь длиннее девяти знаков")
    negative = "минус " if whole.startswith("-") else ""
    whole = abs(int(whole))
    denominators = ["десят", "сот", "тысячн", "десятитысячн", "стотысячн", "миллионн", "десятимиллионн", "стомиллионн", "миллиардн"]
    f = int(fraction)
    return negative + integer(whole, feminine=True) + " " + plural(whole, ("целая", "целых", "целых")) + " " + integer(f, feminine=True) + " " + denominators[len(fraction)-1] + plural(f, ("ая", "ых", "ых"))


def date_text(text):
    day_end = {"к": "ому", "ко": "ому", "на": "ое", "по": "ое", "за": "ое", "про": "ое", "сегодня": "ое", "завтра": "ое", "вчера": "ое", "послезавтра": "ое", "позавчера": "ое", "перед": "ым", "между": "ым", "над": "ым", "под": "ым", "о": "ом", "об": "ом", "при": "ом"}
    def day(m):
        d = int(m[1])
        if not 1 <= d <= 31:
            raise ValueError("Некорректная дата: " + m[0])
        ending = day_end.get(previous(text, m.start()), "ого")
        if m.re is numeric:
            year = int(m[3])
            if len(m[3]) == 2:
                current = datetime.date.today().year
                year += current // 100 * 100 if year <= current % 100 else current // 100 * 100 - 100
            try:
                datetime.date(year, int(m[2]), d)
            except ValueError:
                raise ValueError("Некорректная дата: " + m[0]) from None
            result = ordinal(d, ending) + " " + MONTHS[int(m[2])-1] + " " + ordinal(year, "ого") + " года"
        else:
            result = ordinal(d, ending) + " " + m[2]
            if m[3]:
                result += " " + ordinal(int(m[3]), "ого") + (" года" if m[4] else "")
                if m[4] == "г." and sentence_stop(text[m.end():]):
                    result += "."
        if not text[:m.start()].rstrip(' «"(—–-') or text[:m.start()].rstrip(' «"(—–-')[-1] in ".!?…\n":
            result = result[0].upper() + result[1:]
        return result
    numeric = re.compile(r"(?<![\w.,/])(\d{1,2})[./](\d{1,2})[./](\d{4}|\d{2})(?![\w]|[.,/]\d)")
    text = numeric.sub(day, text)
    text = re.sub(r"(?<![\w.,:/-])(\d{1,2})\s+(" + "|".join(MONTHS) + r")(?:\s+(\d{3,4})(?:\s*(года|г\.)(?!\w))?)?(?!\w)", day, text, flags=re.I)
    def years(m):
        first, last = int(m[1]), int(m[2])
        tail = text[m.end():]
        next_word = re.search(r"[а-яё]+", tail.lower())
        if not (1000 <= first < last <= 2100) or not m[3] and next_word and counted(next_word[0]):
            return m[0]
        noun = (m[3] or "").lower()
        ending = {"годы": "ый", "годах": "ом", "годам": "ому", "годами": "ым"}.get(noun, "ого")
        if noun in {"гг.", "г."}:
            prep = previous(text, m.start())
            ending, noun = ("ом", "годах") if prep in {"в", "во"} else ("ому", "годам") if prep in {"к", "ко"} else ("ого", "годов")
        return ordinal(first, ending) + " — " + ordinal(last, ending) + (" " + noun if noun else "") + ("." if m[0].endswith(".") and sentence_stop(tail) else "")
    text = re.sub(r"(?<![\w.,:/-])(\d{4})\s*[-–—]\s*(\d{4})(?:\s*(гг\.|годами|годах|годов|годам|годы|года|г\.)(?!\w))?(?!\w)", years, text, flags=re.I)
    def year(m):
        noun = m[2].lower()
        prep = previous(text, m.start())
        ending = {"годом": "ым", "года": "ого", "год": "ый"}.get(noun, "ому" if prep in {"к", "ко", "по"} else "ом")
        if noun == "г.":
            ending = "ом" if prep in {"в", "во"} else "ому" if prep in {"к", "ко"} else "ого"
            noun = "году" if ending in {"ом", "ому"} else "года"
        return ordinal(int(m[1]), ending) + " " + noun + ("." if m[0].endswith(".") and sentence_stop(text[m.end():]) else "")
    text = re.sub(r"(?<![\w.,:/-])(\d{3,4})\s*(годом|году|года|год|г\.)(?!\w)", year, text, flags=re.I)
    def bare_year(m):
        n = int(m[0])
        prep = previous(text, m.start())
        next_word = re.match(r"\s*([а-яё]+)", text[m.end():].lower())
        endings = {"с": "ого", "со": "ого", "от": "ого", "до": "ого", "после": "ого", "около": "ого", "начиная": "ого", "конца": "ого", "начала": "ого", "середины": "ого", "по": "ый", "к": "ому", "ко": "ому", "в": "ом", "во": "ом"}
        return ordinal(n, endings[prep]) if 1000 <= n <= 2100 and prep in endings and not (next_word and counted(next_word[1])) else m[0]
    return re.sub(r"(?<![\w.,:/-])\d{4}(?![\w]|[.,:/-]\d)", bare_year, text)


def sentence_stop(tail):
    rest = tail.lstrip(" \t")
    return not rest or rest[0] == "\n" or rest[0].isupper()


def roman(word):
    values = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}
    n, prev = 0, 0
    for c in reversed(word):
        if c not in values:
            raise ValueError("Некорректное римское число")
        value = values[c]
        n += -value if value < prev else value
        prev = max(prev, value)
    rest, canonical = n, ""
    for value, letters in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]:
        count, rest = divmod(rest, value)
        canonical += letters * count
    if not 1 <= n <= 3999 or canonical != word:
        raise ValueError("Неканоническое римское число: " + word)
    return n


def agree(noun):
    w = noun.lower()
    for stem in ("глав", "част", "книг", "сери"):
        if w.startswith(stem):
            ending = w[len(stem):]
            return "ую" if ending in {"у", "ю"} else "ой" if ending in {"ы", "и", "е", "ой", "ью", "ей", "ии", "ах", "ям", "ам", "ами", "ями", "ях"} else "ая"
    for stem in ("тысячелет", "раздел", "квартал", "созыв", "съезд", "класс", "век", "том"):
        if w.startswith(stem):
            return {"ие":"ое", "ия":"ого", "а":"ого", "ию":"ому", "у":"ому", "ием":"ым", "ом":"ым", "ем":"ым", "ии":"ом", "е":"ом", "ов":"ого", "ий":"ого", "ах":"ом", "иях":"ом", "ам":"ому", "иям":"ому", "ами":"ым", "иями":"ым"}.get(w[len(stem):], "ый")
    return "ый"


def roman_text(text):
    nouns = r"(?:век|глав|том|част|раздел|съезд|созыв|тысячелет|класс|квартал|сери|книг)[а-яё]*"
    number = r"(?:[IVXLCDM]{1,8}|\d{1,3})"
    def value(word):
        return int(word) if word.isdigit() else roman(word)
    text = re.sub(r"(?m)^\s*([IVXLCDM]{1,8})\.?\s*$", lambda m: "Глава " + ordinal(roman(m[1]), "ая") + "." if roman(m[1]) <= 99 else m[0], text)
    def label(m):
        noun, tail = m[1], m[2]
        ending = agree(noun)
        listed = bool(re.search(r",|\bи\b|\bили\b|[-–—]|\bпо\b", tail))
        before = previous(text, m.start())
        if listed and noun.lower() in {"главы", "части", "книги", "серии"} and before not in {"из", "без", "от", "до", "в", "на", "по", "к", "с", "со"}:
            ending = "ую" if before.endswith(("ть", "ти", "л", "ла", "ли", "ай", "йте", "ите")) else "ая"
        if listed and noun.lower() == "тома" and before not in {"из", "без", "от", "до", "в", "на", "по", "к", "с", "со"}:
            ending = "ый"
        if tail.lstrip().startswith("с "):
            def range_item(x):
                feminine = noun.lower().startswith(("глав", "част", "книг", "сери"))
                end = ("ой" if feminine else "ого") if previous(tail, x.start()) == "с" else ("ую" if feminine else "ый")
                return ordinal(value(x[0]), end)
            tail = re.sub(number, range_item, tail)
        else:
            tail = re.sub(number, lambda x: ordinal(value(x[0]), ending), tail)
        return noun + tail
    text = re.sub(r"\b(" + nouns + r")((?:\s+с)?\s+" + number + r"(?:(?:\s*(?:,|и|или|[-–—])\s*|\s+по\s+)" + number + r")*)(?![\w]|[.,:]\d)", label, text, flags=re.I)
    text = re.sub(r"\b([IVXLCDM]{1,8})\s+(" + nouns + r")\b", lambda m: ordinal(roman(m[1]), agree(m[2])) + " " + m[2], text, flags=re.I)
    def ruler(m):
        name, num = m[1], roman(m[2])
        if num > 40:
            return m[0]
        w = name.lower()
        if w.startswith(("екатерин", "елизавет", "анн", "мари", "виктори", "изабелл", "елен", "ольг", "софи")):
            ending = "ую" if w.endswith(("у", "ю")) else "ой" if w.endswith(("ы", "и", "е", "ой", "ей")) else "ая"
        else:
            ending = "ым" if w.endswith(("ом", "ем", "ём")) else "ого" if w.endswith(("а", "я")) else "ому" if w.endswith(("у", "ю")) else "ом" if w.endswith("е") else "ый"
        return name + " " + ordinal(num, ending).capitalize()
    return re.sub(r"\b([А-ЯЁ][а-яё]+)\s+([IVXLCDM]{1,8})\b", ruler, text)


def unit_form(n, forms, case):
    if case in (0, 3):
        return plural(n, forms)
    first, _, tail = forms[0].partition(" ")
    if first == "евро":
        return first
    single = abs(n) % 10 == 1 and abs(n) % 100 != 11
    soft = first.endswith("ль")
    stem = first[:-1] if soft else first
    if case == 1:
        result = stem + ("я" if soft else "а") if single else forms[2].split()[0]
    else:
        endings = {2: ("ю", "у", "ям", "ам"), 4: ("ём", "ом", "ями", "ами"), 5: ("е", "е", "ях", "ах")}
        result = stem + endings[case][(0 if soft else 1) + (0 if single else 2)]
    return result + (" " + tail if tail else "")


def normalize(text):
    # Keep URLs/emails/identifiers opaque rather than accidentally verbalizing them.
    protected = []
    def protect(m):
        protected.append(m[0])
        return "\ue000" + chr(0xE100 + len(protected) - 1) + "\ue001"
    text = re.sub(r"(?:https?://|www\.)[^\s<>]+|[\w.+-]+@[\w.-]+\.[A-Za-z]+|\b[\w-]+\.(?:com|org|net|ru|рф)\b", protect, text)
    text = re.sub(r"[^\S\n\r]|[\u200b\u0085]", " ", text)
    text = text.translate(str.maketrans({c: "-" for c in "‐‑‒⁃−﹣－"}))
    text = re.sub(r"(?<=[а-яёА-ЯЁ])-\s*\r?\n\s*(?=[а-яёА-ЯЁ])", "", text)
    text = re.sub(r"\[\d{1,5}\]", "", text)
    for key, value in {"Wi-Fi":"вай-фай", "hi-fi":"хай-фай", "WIFI":"вайфай", "SIM":"сим", "PIN":"пин", "GIF":"гиф", "MIDI":"миди"}.items():
        text = re.sub(r"(?<!\w)" + re.escape(key) + r"(?!\w)", value, text, flags=re.I)
    for key, value in {"т. е.":"то есть", "т.е.":"то есть", "т. д.":"так далее", "т.д.":"так далее", "т. п.":"тому подобное", "т.п.":"тому подобное", "т.к.":"так как", "г-н":"господин", "г-жа":"госпожа"}.items():
        text = re.sub(r"(?<!\w)" + re.escape(key), value, text, flags=re.I)
    text = re.sub(r"([,.!?;:…])(?=[А-Яа-яЁё])", r"\1 ", text)
    text = re.sub(r"([$€₽])\s*(\d+(?:[,.]\d+)?)", r"\2 \1", text)
    text = date_text(text)
    text = roman_text(text)
    def time(m):
        h, minute = int(m[1]), int(m[2])
        sec = int(m[3]) if m[3] else None
        if h > 23 or minute > 59 or sec is not None and sec > 59:
            raise ValueError("Некорректное время: " + m[0])
        result = integer(h) + " " + plural(h, ("час", "часа", "часов")) + " " + integer(minute, feminine=True) + " " + plural(minute, ("минута", "минуты", "минут"))
        return result + (" " + integer(sec, feminine=True) + " " + plural(sec, ("секунда", "секунды", "секунд")) if sec is not None else "")
    text = re.sub(r"(?<![\w:])(\d{1,2}):(\d{2})(?::(\d{2}))?(?![\w:])", time, text)
    def phone(m):
        digits = re.sub(r"\D", "", m[0])
        groups = [digits[:1], digits[1:4], digits[4:7], digits[7:9], digits[9:]]
        return ("плюс " if m[0].startswith("+") else "") + " ".join(" ".join(integer(int(c)) for c in g) if g.startswith("0") else integer(int(g)) for g in groups)
    text = re.sub(r"(?<!\d)(?:\+7|8)[ -]?\(?\d{3}\)?[ -]\d{3}[ -]\d{2}[ -]\d{2}(?!\d)", phone, text)
    text = re.sub(r"(?<!\w)(\d{1,3}(?:[ \u00a0\u202f]\d{3})+)(?!\w)", lambda m: re.sub(r"\s", "", m[0]), text)
    text = re.sub(r"(?<![\w/])(\d{1,2})/(\d{1,2})(?![\w/])", lambda m: integer(int(m[1]), feminine=True) + " " + ordinal(int(m[2]), plural(int(m[1]), ("ая", "ых", "ых"))) if 2 <= int(m[2]) <= 99 else m[0], text)
    suffixes = {"й":"ый", "я":"ая", "е":"ое", "ю":"ую", "го":"ого", "му":"ому", "м":"ом", "х":"ых", "ми":"ыми"}
    text = re.sub(r"\b(\d+)-(ыми|ого|ому|ый|ая|ое|ую|ой|ых|ым|ом|го|му|ми|й|я|е|ю|х|м)\b", lambda m: ordinal(int(m[1]), "ые" if m[2] == "е" and re.match(r"\s+год", text[m.end():]) else suffixes.get(m[2], m[2])), text)
    measure_pattern = "|".join(re.escape(k) for k in sorted(MEASURES, key=len, reverse=True))
    def span(m):
        a, b = int(m[1]), int(m[2])
        if b <= a:
            return m[0]
        unit = m[3]
        return "от " + integer(a, 1) + " до " + integer(b, 1) + (" " + MEASURES[unit][2] if unit else "")
    text = re.sub(r"(?<![\w.,:/-])(\d{1,12})\s*[-–—]\s*(\d{1,12})(?![\w]|[.,:/-]\d)(?:\s*(" + measure_pattern + r")(?!\w))?", span, text)
    def measure(m):
        raw, unit = m[1], m[2]
        case = inferred_case(text[:m.start()])
        if re.search(r"[,.]", raw):
            result = decimal(raw) + " " + MEASURES[unit][1]
        else:
            n = int(raw)
            result = integer(n, case) + " " + unit_form(n, MEASURES[unit], case)
        return result + ("." if unit.endswith(".") and sentence_stop(text[m.end():]) else "")
    text = re.sub(r"(?<![\w.,:/-])(-?\d{1,12}(?:[,.]\d{1,9})?)\s*(" + measure_pattern + r")(?!\w)", measure, text)
    text = re.sub(r"(?<![\w.,:/-])(-?\d{1,12}[,.]\d{1,9})(?![\w]|[.,:/]\d)", lambda m: decimal(m[0]), text)
    def number(m):
        n = int(m[0])
        after = text[m.end():]
        case = inferred_case(text[:m.start()], after)
        found = re.match(r"\s+([а-яё]+)", after.replace("\u0301", "").lower())
        noun = found[1] if found else ""
        feminine = noun not in MASCULINE_A and noun not in NEUTER and (noun in FEMININE or noun in FEMININE_SOFT or noun.endswith(("а", "я")))
        if case and noun not in MASCULINE_A and noun not in NEUTER:
            feminine = feminine or noun.endswith({1: ("ы", "и"), 2: ("е",), 4: ("ой", "ей", "ью"), 5: ("и",)}.get(case, ()))
        result = integer(n, case, feminine)
        if case == 0:
            if result.endswith("один") and noun not in MASCULINE_A and noun.endswith(("у", "ю")) and not noun.endswith("ую"):
                result = result[:-4] + "одну"
            elif result.endswith(("один", "одна")) and noun != "кофе" and (noun in NEUTER or noun.endswith(("о", "ие", "мя"))):
                result = result[:-4] + "одно"
            elif result.endswith("два") and noun not in MASCULINE_A and noun not in NEUTER and not noun.endswith("мени") and noun.endswith(("ы", "и")):
                result = result[:-3] + "две"
        return result
    text = re.sub(r"(?<![\w.,:/-])(-?\d{1,12})(?![\w]|[.,:/-]\d|-\w)", number, text)
    alphabet = "А Б В Г Д Е Ё Ж З И Й К Л М Н О П Р С Т У Ф Х Ц Ч Ш Щ Ъ Ы Ь Э Ю Я".split()
    names = "а|бэ|вэ|гэ|дэ|е|ё|жэ|зэ|и|и краткое|ка|эль|эм|эн|о|пэ|эр|эс|тэ|у|эф|ха|цэ|че|ша|ща|твёрдый знак|ы|мягкий знак|э|ю|я".split("|")
    letter_names = dict(zip(alphabet, names))
    def acronym(m):
        word = m[0]
        spell = word not in RULES["wordAcronyms"] and (word in RULES["letterAcronyms"] or not any(c in "АЕЁИОУЫЭЮЯ" for c in word))
        return "-".join(letter_names[c] for c in word) if spell else word.lower()
    text = re.sub(r"(?<!\w)[А-ЯЁ]{2,8}(?!\w)", acronym, text)
    # Do not silently mispronounce invalid formats or oversized numbers.
    if re.search(r"\d", text):
        raise ValueError("Нераскрытый числовой формат; требуется ручная проверка")
    for i, original in enumerate(protected):
        text = text.replace("\ue000" + chr(0xE100 + i) + "\ue001", original)
    return speech_punctuation(re.sub(r"[ \t]+", " ", text).strip())


def speech_punctuation(text):
    """Canonical short dash for Qwen, never applied to displayed EPUB text."""
    return text.translate(str.maketrans({c: "-" for c in "—–‐‑‒⁃−﹣－"}))
