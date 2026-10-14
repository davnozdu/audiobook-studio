import Foundation

public struct RussianText {
  let rules: Object
  let forms: [String: [String]]
  let roots: [String: String]
  static let vowels = "аеёиоуыэюя"
  static let units = "ноль один два три четыре пять шесть семь восемь девять".components(
    separatedBy: " ")
  static let teens =
    "десять одиннадцать двенадцать тринадцать четырнадцать пятнадцать шестнадцать семнадцать восемнадцать девятнадцать"
    .components(separatedBy: " ")
  static let tens =
    "_ _ двадцать тридцать сорок пятьдесят шестьдесят семьдесят восемьдесят девяносто".components(
      separatedBy: " ")
  static let hundreds = "_ сто двести триста четыреста пятьсот шестьсот семьсот восемьсот девятьсот"
    .components(separatedBy: " ")
  static let months =
    "января февраля марта апреля мая июня июля августа сентября октября ноября декабря".components(
      separatedBy: " ")
  static let measures: [String: [String]] = [
    "км": ["километр", "километра", "километров"], "м": ["метр", "метра", "метров"],
    "см": ["сантиметр", "сантиметра", "сантиметров"],
    "мм": ["миллиметр", "миллиметра", "миллиметров"],
    "кг": ["килограмм", "килограмма", "килограммов"], "г": ["грамм", "грамма", "граммов"],
    "л": ["литр", "литра", "литров"], "руб.": ["рубль", "рубля", "рублей"],
    "₽": ["рубль", "рубля", "рублей"], "$": ["доллар", "доллара", "долларов"],
    "€": ["евро", "евро", "евро"], "%": ["процент", "процента", "процентов"],
    "°C": ["градус Цельсия", "градуса Цельсия", "градусов Цельсия"],
    "°С": ["градус Цельсия", "градуса Цельсия", "градусов Цельсия"],
    "°": ["градус", "градуса", "градусов"],
  ]
  public init(_ file: URL) throws {
    rules = try NativeIO.load(file)
    forms = Dictionary(
      uniqueKeysWithValues: (rules["forms"] as? [[String]] ?? []).map { ($0[0], $0) })
    roots = rules["ordinal_roots"] as? [String: String] ?? [:]
  }
  static func contains(_ words: String, _ word: String) -> Bool {
    words.components(separatedBy: " ").contains(word)
  }
  public static func plural(_ n: Int, _ words: [String]) -> String {
    let n = n.magnitude
    return (11...14).contains(n % 100)
      ? words[2] : n % 10 == 1 ? words[0] : (2...4).contains(n % 10) ? words[1] : words[2]
  }
  static func checkedInteger(_ value: String) throws -> Int {
    guard let n = Int(value) else { throw StudioError("Число за пределами поддерживаемого диапазона") }
    return n
  }
  public func integer(_ number: Int, case c: Int = 0, feminine: Bool = false) throws -> String {
    guard number > -1_000_000_000_000, number < 1_000_000_000_000 else {
      throw StudioError("Число за пределами поддерживаемого диапазона")
    }
    if number < 0 { return "минус " + (try integer(-number, case: c, feminine: feminine)) }
    if number == 0 { return forms["ноль"]?[c] ?? "ноль" }
    var n = number
    var words: [String] = []
    for (scale, names) in [
      (1_000_000_000, ["миллиард", "миллиарда", "миллиардов"]),
      (1_000_000, ["миллион", "миллиона", "миллионов"]), (1000, ["тысяча", "тысячи", "тысяч"]),
      (1, []),
    ] {
      let group = n / scale
      n %= scale
      guard group > 0 else { continue }
      let h = group / 100
      let rest = group % 100
      if h > 0 { words.append(Self.hundreds[h]) }
      if (10..<20).contains(rest) {
        words.append(Self.teens[rest - 10])
      } else {
        let t = rest / 10
        let u = rest % 10
        if t > 0 { words.append(Self.tens[t]) }
        if u > 0 {
          words.append(
            (scale == 1000 || scale == 1 && feminine) && u <= 2
              ? (u == 1 ? "одна" : "две") : Self.units[u])
        }
      }
      if !names.isEmpty { words.append(Self.plural(group, names)) }
    }
    return words.map { forms[$0]?[c] ?? $0 }.joined(separator: " ")
  }
  public func ordinal(_ n: Int, _ ending: String = "ый") throws -> String {
    guard (1..<10000).contains(n) else {
      throw StudioError("Порядковое число вне диапазона 1..9999")
    }
    let tail =
      roots[String(n)] != nil
      ? n
      : (1...19).contains(n % 100)
        ? n % 100 : n % 10 != 0 ? n % 10 : n % 100 != 0 ? n % 100 : n % 1000
    guard var root = roots[String(tail)] else { throw StudioError("Нет формы порядкового числа") }
    var end = ending
    if root == "треть" {
      root = "трет"
      end =
        [
          "ый": "ий", "ая": "ья", "ое": "ье", "ого": "ьего", "ому": "ьему", "ом": "ьем",
          "ым": "ьим", "ую": "ью", "ой": "ьей", "ые": "ьи", "ых": "ьих", "ыми": "ьими",
        ][end] ?? end
    } else if end == "ый" && Self.contains("втор шест седьм восьм сороков", root) {
      end = "ой"
    }
    var head = n == tail ? "" : (try integer(n - tail)) + " "
    if head.hasPrefix("одна тысяча") { head = String(head.dropFirst(5)) }
    return head + root + end
  }
  static func previous(_ before: String) -> String {
    let ns = before as NSString
    return NativeIO.regex("[А-Яа-яЁё]+", before).last.map {
      ns.substring(with: $0.range).lowercased()
    } ?? ""
  }
  static func caseIndex(_ before: String, _ after: String = "") -> Int {
    let w = previous(before)
    let noun =
      NativeIO.regex("[а-яё]+", after.lowercased()).first.map {
        (after.lowercased() as NSString).substring(with: $0.range)
      } ?? ""
    if contains("в на", w) && (noun.hasSuffix("ах") || noun.hasSuffix("ях")) { return 5 }
    if contains("с со", w) && contains("лет часов минут секунд дней", noun) { return 1 }
    if contains(
      "без до из от около после для более менее нет лишился достиг достигли требует хватает", w)
    {
      return 1
    }
    if contains("к по", w) { return 2 }
    if contains("между перед над с со", w) { return 4 }
    return contains("о об при", w) ? 5 : 0
  }
  func decimal(_ raw: String) throws -> String {
    let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",."))
    guard parts.count == 2, let w = Int(parts[0]), let f = Int(parts[1]),
      (1...9).contains(parts[1].count)
    else { throw StudioError("Некорректная дробь") }
    let denominators = [
      "десят", "сот", "тысячн", "десятитысячн", "стотысячн", "миллионн", "десятимиллионн",
      "стомиллионн", "миллиардн",
    ]
    return (raw.hasPrefix("-") ? "минус " : "") + (try integer(abs(w), feminine: true)) + " "
      + Self.plural(w, ["целая", "целых", "целых"]) + " " + (try integer(f, feminine: true)) + " "
      + denominators[parts[1].count - 1] + Self.plural(f, ["ая", "ых", "ых"])
  }
  public static func sub(
    _ pattern: String, _ text: String, _ transform: ([String], String, String) throws -> String
  ) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern)
    let ns = text as NSString
    var result = text
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
    {
      let groups = (0..<match.numberOfRanges).map {
        match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0))
      }
      let value = try transform(
        groups, ns.substring(to: match.range.location),
        ns.substring(from: match.range.location + match.range.length))
      result = (result as NSString).replacingCharacters(in: match.range, with: value)
    }
    return result
  }
  static func roman(_ text: String) throws -> Int {
    let values: [Character: Int] = [
      "I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000,
    ]
    var n = 0
    var previous = 0
    for ch in text.reversed() {
      guard let v = values[ch] else { throw StudioError("Некорректное римское число") }
      n += v < previous ? -v : v
      previous = max(previous, v)
    }
    var rest = n
    var canonical = ""
    for (v, s) in [
      (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"),
      (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ] {
      canonical += String(repeating: s, count: max(0, rest / v))
      rest %= v
    }
    guard (1...3999).contains(n), canonical == text else {
      throw StudioError("Неканоническое римское число")
    }
    return n
  }
  /// Typography that must not be read aloud or trip the model, mapped before numbers are read:
  /// decomposed letters (е + ̈ → ё), soft hyphens and invisible characters, unlinked note marks
  /// (¹, [12], *, †), decorations, № and fractions, maths signs, ligatures; every quote style
  /// becomes «ёлочки», the form Russian text and the reading model use.
  static func symbols(_ input: String) -> String {
    var text = input.precomposedStringWithCanonicalMapping
    text = NativeIO.replace("[\\u00AD\\u200C\\u200D\\u2060\\uFEFF]", text, "")
    text = NativeIO.replace("[\\u00B9\\u00B2\\u00B3\\u2070-\\u2079\\u207A-\\u207F]+", text, "")
    text = NativeIO.replace("\\[(?:\\d{1,4}|\\*{1,3})\\]|\\{\\d{1,4}\\}", text, "")
    text = NativeIO.replace("[*†‡•·■□▪▫◦●○◆◇★☆¶|_~^\\\\]+", text, " ")
    for (sign, words) in [("№№", "номера "), ("№", "номер "), ("½", " одна вторая"), ("⅓", " одна третья"),
      ("¼", " одна четвёртая"), ("¾", " три четвёртых"), ("⅔", " две третьих"), ("±", " плюс-минус "),
      ("≈", " примерно "), ("≠", " не равно "), ("≤", " меньше или равно "), ("≥", " больше или равно "),
      ("÷", " разделить на "), ("×", " на "), ("‰", " промилле"), ("&", " и "),
      ("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl")] {
      text = text.replacingOccurrences(of: sign, with: words)
    }
    for (from, to) in [("„", "«"), ("‹", "«"), ("›", "»"), ("”", "»")] { text = text.replacingOccurrences(of: from, with: to) }
    // “ opens in English style and closes in Russian „…“ style; straight " alternates.
    var out = "", open = false
    for ch in text {
      if ch == "\u{201C}" { out.append(open ? "»" : "«"); open.toggle() }
      else if ch == "\"" { out.append(open ? "»" : "«"); open.toggle() }
      else { if ch == "«" { open = true } else if ch == "»" { open = false }; out.append(ch) }
    }
    // A removed mark must not leave a gap before punctuation ("крест† ." → "крест.").
    out = NativeIO.replace("[ \\t]+([,.!?;:\\u2026»)])", out, "$1")
    out = NativeIO.replace("([«(])[ \\t]+", out, "$1")
    return NativeIO.replace("[ \\t]{2,}", out, " ")
  }
  public func normalize(_ input: String) throws -> String {
    var protected: [String] = []
    var text = try Self.sub(
      "(?:https?://|www\\.)[^\\s<>]+|[\\w.+-]+@[\\w.-]+\\.[A-Za-z]+|\\b[\\w-]+\\.(?:com|org|net|ru|рф)\\b",
      input
    ) { g, _, _ in
      protected.append(g[0])
      return "\u{e000}" + String(UnicodeScalar(0xe100 + protected.count - 1)!) + "\u{e001}"
    }
    text = String(text.unicodeScalars.map { scalar -> String in
      guard CharacterSet.decimalDigits.contains(scalar), let n = Character(String(scalar)).wholeNumberValue,
        (0...9).contains(n) else { return String(scalar) }
      return String(n)
    }.joined())
    text = NativeIO.replace("[^\\S\\n\\r]|[\\u200b\\u0085]", text, " ")
    for dash in "—–‐‑‒⁃−﹣－" { text = text.replacingOccurrences(of: String(dash), with: "-") }
    text = Self.symbols(text)
    // Section signs in treatises: "§ 23" is read "параграф 23", "§§ 4-6" "параграфы 4-6".
    text = NativeIO.replace("§\\s*§\\s*", text, "параграфы ")
    text = NativeIO.replace("§\\s*", text, "параграф ")
    for (key, value) in [
      "Wi-Fi": "вай-фай", "hi-fi": "хай-фай", "WIFI": "вайфай", "SIM": "сим", "PIN": "пин",
      "GIF": "гиф", "MIDI": "миди", "т. е.": "то есть", "т.е.": "то есть", "т. д.": "так далее",
      "т.д.": "так далее", "т. п.": "тому подобное", "т.п.": "тому подобное", "т.к.": "так как",
      "г-н": "господин", "г-жа": "госпожа",
    ] {
      text = NativeIO.replace(
        "(?i)(?<!\\w)" + NSRegularExpression.escapedPattern(for: key), text, value)
    }
    text = NativeIO.replace("([,.!?;:…])(?=[А-Яа-яЁё])", text, "$1 ")
    text = NativeIO.replace("([$€₽])\\s*(\\d+(?:[,.]\\d+)?)", text, "$2 $1")
    text = try Self.sub(
      "(?<![\\w.,/])(\\d{1,2})[./](\\d{1,2})[./](\\d{4}|\\d{2})(?![\\w]|[.,/]\\d)", text
    ) { g, b, _ in
      let day = Int(g[1])!
      let month = Int(g[2])!
      var year = Int(g[3])!
      let current = Calendar.current.component(.year, from: Date())
      if g[3].count == 2 {
        year += year <= current % 100 ? current / 100 * 100 : current / 100 * 100 - 100
      }
      var dc = DateComponents()
      dc.year = year
      dc.month = month
      dc.day = day
      let calendar = Calendar(identifier: .gregorian)
      guard let date = calendar.date(from: dc), calendar.component(.month, from: date) == month,
        calendar.component(.day, from: date) == day
      else { return g[0] }
      return try ordinal(day, Self.dayEnd(b)) + " " + Self.months[month - 1] + " "
        + ordinal(year, "ого") + " года"
    }
    text = try Self.sub(
      "(?i)(?<![\\w.,:/-])(\\d{1,2})\\s+(" + Self.months.joined(separator: "|")
        + ")(?:\\s+(\\d{3,4})(?:\\s*(года|г\\.)(?!\\w))?)?(?!\\w)", text
    ) { g, b, _ in
      guard (1...31).contains(Int(g[1])!) else { return g[0] }
      return try ordinal(Int(g[1])!, Self.dayEnd(b)) + " " + g[2]
        + (g[3].isEmpty ? "" : " " + ordinal(Int(g[3])!, "ого") + (g[4].isEmpty ? "" : " года"))
    }
    text = try Self.sub(
      "(?i)(?<![\\w.,:/-])(\\d{4})\\s*[-–—]\\s*(\\d{4})(?:\\s*(гг\\.|годами|годах|годов|годам|годы|года|г\\.)(?!\\w))?(?!\\w)",
      text
    ) { g, b, _ in
      let a = Int(g[1])!
      let z = Int(g[2])!
      guard (1000...2100).contains(a), z > a, z <= 2100 else { return g[0] }
      let prep = Self.previous(b)
      var noun = g[3].lowercased()
      var ending = ["годы": "ый", "годах": "ом", "годам": "ому", "годами": "ым"][noun] ?? "ого"
      if noun == "гг." || noun == "г." {
        ending = Self.contains("в во", prep) ? "ом" : Self.contains("к ко", prep) ? "ому" : "ого"
        noun = ending == "ом" ? "годах" : ending == "ому" ? "годам" : "годов"
      }
      return try ordinal(a, ending) + " - " + ordinal(z, ending) + (noun.isEmpty ? "" : " " + noun)
    }
    text = try Self.sub("(?i)(?<![\\w.,:/-])(\\d{3,4})\\s*(годом|году|года|год|г\\.)(?!\\w)", text)
    { g, b, _ in
      var noun = g[2].lowercased()
      let prep = Self.previous(b)
      var ending =
        ["годом": "ым", "года": "ого", "год": "ый"][noun]
        ?? (Self.contains("к ко по", prep) ? "ому" : "ом")
      if noun == "г." {
        ending = Self.contains("в во", prep) ? "ом" : Self.contains("к ко", prep) ? "ому" : "ого"
        noun = ending == "ом" || ending == "ому" ? "году" : "года"
      }
      return try ordinal(Int(g[1])!, ending) + " " + noun
    }
    text = try Self.sub("(?<![\\w.,:/-])\\d{4}(?![\\w]|[.,:/-]\\d)", text) { g, b, a in
      let n = Int(g[0])!
      let prep = Self.previous(b)
      let next =
        NativeIO.regex("^[\\s]*([а-яё]+)", a.lowercased()).first.map {
          (a.lowercased() as NSString).substring(with: $0.range(at: 1))
        } ?? ""
      let endings = [
        "с": "ого", "со": "ого", "от": "ого", "до": "ого", "после": "ого", "около": "ого",
        "начиная": "ого", "конца": "ого", "начала": "ого", "середины": "ого", "по": "ый",
        "к": "ому", "ко": "ому", "в": "ом", "во": "ом",
      ]
      if (1000...2100).contains(n), let ending = endings[prep], !Self.counted(next) {
        return try ordinal(n, ending)
      }
      return g[0]
    }
    text = try Self.sub("(?m)^\\s*([IVXLCDM]{1,8})\\.?\\s*$", text) { g, _, _ in
      let n = try Self.roman(g[1])
      return n <= 99 ? "Глава " + (try ordinal(n, "ая")) + "." : g[0]
    }
    let nouns = "(?:век|глав|том|част|раздел|съезд|созыв|тысячелет|класс|квартал|сери|книг)[а-яё]*"
    let number = "(?:[IVXLCDM]{1,8}|\\d{1,3})"
    text = try Self.sub(
      "(?i)\\b(" + nouns + ")((?:\\s+с)?\\s+" + number
        + "(?:(?:\\s*(?:,|и|или|[-–—])\\s*|\\s+по\\s+)" + number + ")*)(?![\\w]|[.,:]\\d)", text
    ) { g, b, _ in
      let noun = g[1]
      let prep = Self.previous(b)
      let listed = !NativeIO.regex(",|\\bи\\b|\\bили\\b|[-–—]|\\bпо\\b", g[2]).isEmpty
      var ending = Self.agree(noun)
      if listed, Self.contains("главы части книги серии", noun.lowercased()),
        !Self.contains("из без от до в на по к с со", prep)
      {
        ending =
          ["ть", "ти", "л", "ла", "ли", "ай", "йте", "ите"].contains { prep.hasSuffix($0) }
          ? "ую" : "ая"
      }
      if listed, noun.lowercased() == "тома", !Self.contains("из без от до в на по к с со", prep) {
        ending = "ый"
      }
      let tail = try Self.sub(number, g[2]) { item, before, _ in
        var end = ending
        if g[2].trimmingCharacters(in: .whitespaces).hasPrefix("с ") {
          let feminine = ["глав", "част", "книг", "сери"].contains {
            noun.lowercased().hasPrefix($0)
          }
          end = Self.previous(before) == "с" ? (feminine ? "ой" : "ого") : (feminine ? "ую" : "ый")
        }
        return try ordinal(Int(item[0]) ?? Self.roman(item[0].uppercased()), end)
      }
      return noun + tail
    }
    text = try Self.sub("\\b([IVXLCDM]{1,8})\\s+(" + nouns + ")\\b", text) { g, _, _ in
      try ordinal(Self.roman(g[1]), Self.agree(g[2])) + " " + g[2]
    }
    text = try Self.sub("\\b([А-ЯЁ][а-яё]+)\\s+([IVXLCDM]{1,8})\\b", text) { g, _, _ in
      let w = g[1].lowercased()
      let female = [
        "екатерин", "елизавет", "анн", "мари", "виктори", "изабелл", "елен", "ольг", "софи",
      ].contains { w.hasPrefix($0) }
      let end =
        female
        ? (w.hasSuffix("у") || w.hasSuffix("ю")
          ? "ую" : w.hasSuffix("ы") || w.hasSuffix("и") || w.hasSuffix("е") ? "ой" : "ая")
        : w.hasSuffix("ом") || w.hasSuffix("ем")
          ? "ым"
          : w.hasSuffix("а") || w.hasSuffix("я")
            ? "ого" : w.hasSuffix("у") || w.hasSuffix("ю") ? "ому" : w.hasSuffix("е") ? "ом" : "ый"
      let n = try Self.roman(g[2])
      return n > 40 ? g[0] : g[1] + " " + (try ordinal(n, end)).capitalized
    }
    text = try Self.sub("(?<![\\w:])(\\d{1,2}):(\\d{2})(?::(\\d{2}))?(?![\\w:])", text) { g, _, _ in
      let h = Int(g[1])!
      let m = Int(g[2])!
      let s = Int(g[3])
      guard h <= 23, m <= 59, (s ?? 0) <= 59 else { return g[0] }
      var out =
        try integer(h) + " " + Self.plural(h, ["час", "часа", "часов"]) + " "
        + integer(m, feminine: true) + " " + Self.plural(m, ["минута", "минуты", "минут"])
      if let s {
        out +=
          " " + (try integer(s, feminine: true)) + " "
          + Self.plural(s, ["секунда", "секунды", "секунд"])
      }
      return out
    }
    text = try Self.sub(
      "(?<!\\d)(?:\\+7|8)[ -]?\\(?\\d{3}\\)?[ -]\\d{3}[ -]\\d{2}[ -]\\d{2}(?!\\d)", text
    ) { g, _, _ in
      let digits = Array(NativeIO.replace("\\D", g[0], ""))
      var words: [String] = []
      for (s, e) in [(0, 1), (1, 4), (4, 7), (7, 9), (9, 11)] {
        let part = String(digits[s..<e])
        words.append(
          try part.hasPrefix("0")
            ? part.map { try integer(Int(String($0))!) }.joined(separator: " ")
            : integer(Int(part)!))
      }
      return (g[0].hasPrefix("+") ? "плюс " : "") + words.joined(separator: " ")
    }
    text = NativeIO.replace("(?<=\\d)[ \\u00a0\\u202f](?=\\d{3}(?:\\D|$))", text, "")
    text = try Self.sub("(?<![\\w/])(\\d{1,2})/(\\d{1,2})(?![\\w/])", text) { g, _, _ in
      let a = Int(g[1])!
      let b = Int(g[2])!
      return (2...99).contains(b)
        ? (try integer(a, feminine: true)) + " "
          + (try ordinal(b, Self.plural(a, ["ая", "ых", "ых"]))) : g[0]
    }
    text = try Self.sub(
      "\\b(\\d+)-(ыми|ого|ому|ый|ая|ое|ую|ой|ых|ым|ом|го|му|ми|й|я|е|ю|х|м)\\b", text
    ) { g, _, _ in
      try ordinal(
        try Self.checkedInteger(g[1]),
        [
          "й": "ый", "я": "ая", "е": "ое", "ю": "ую", "го": "ого", "му": "ому", "м": "ом",
          "х": "ых", "ми": "ыми",
        ][g[2]] ?? g[2])
    }
    let measure = Self.measures.keys.sorted { $0.count > $1.count }.map {
      NSRegularExpression.escapedPattern(for: $0)
    }.joined(separator: "|")
    text = try Self.sub(
      "(?<![\\w.,:/-])(\\d{1,12})\\s*[-–—]\\s*(\\d{1,12})(?![\\w]|[.,:/-]\\d)(?:\\s*(" + measure
        + ")(?!\\w))?", text
    ) { g, _, _ in
      let a = Int(g[1])!
      let b = Int(g[2])!
      return b > a
        ? "от " + (try integer(a, case: 1)) + " до " + (try integer(b, case: 1))
          + (g[3].isEmpty ? "" : " " + Self.measures[g[3]]![2]) : g[0]
    }
    text = try Self.sub(
      "(?<![\\w.,:/-])(-?\\d{1,12}(?:[,.]\\d{1,9})?)\\s*(" + measure + ")(?!\\w)", text
    ) { g, b, _ in
      let words = Self.measures[g[2]]!
      let c = Self.caseIndex(b)
      if g[1].contains(",") || g[1].contains(".") { return try decimal(g[1]) + " " + words[1] }
      let n = Int(g[1])!
      return try integer(n, case: c) + " " + Self.unitForm(n, words, c)
    }
    text = try Self.sub("(?<![\\w.,:/-])(-?\\d{1,12}[,.]\\d{1,9})(?![\\w]|[.,:/]\\d)", text) {
      g, _, _ in try decimal(g[0])
    }
    text = try Self.sub("(?<![\\w.,:/-])(-?\\d{1,12})(?![\\w]|[.,:/-]\\d|-\\w)", text) { g, b, a in
      let n = Int(g[0])!
      let c = Self.caseIndex(b, a)
      let noun =
        NativeIO.regex("[а-яё]+", a.lowercased()).first.map {
          (a.lowercased() as NSString).substring(with: $0.range)
        } ?? ""
      let masculine = Self.contains(
        "мужчина мужчины юноша юноши папа папы дядя дяди дедушка дедушки судья судьи слуга слуги староста старосты воевода воеводы",
        noun)
      let neuter = Self.contains(
        "имя имени окно окна слово слова письмо письма сообщение сообщения предложение предложения место места",
        noun)
      var female =
        !masculine && !neuter
        && Self.contains(
          "запись записи страница страницы книга книги минута минуты секунда секунды строка строки глава главы женщина женщины девушка девушки копейка копейки ночь дверь жизнь смерть любовь мышь площадь тетрадь вещь память новость кость часть мысль степень дочь мать сеть роль цель соль боль ель осень",
          noun)
      // The noun's ending shows its gender only together with the numeral's own form: after
      // 1 the nominative (одна книга), after 2–4 the genitive singular, where masculine and
      // neuter nouns end in -а/-я (два часа, два дня, два окна) and feminine ones in -ы/-и.
      let last = abs(n) % 10, teen = abs(n) % 100 / 10 == 1
      if c == 0 && !masculine && !neuter && !teen {
        if last == 1 { female = female || noun.hasSuffix("а") || noun.hasSuffix("я") }
        if (2...4).contains(last) { female = female || noun.hasSuffix("ы") || noun.hasSuffix("и") }
      }
      if c != 0 && !masculine && !neuter {
        female =
          female
          || ([1: ["ы", "и"], 2: ["е"], 4: ["ой", "ей", "ью"], 5: ["и"]][c] ?? []).contains {
            noun.hasSuffix($0)
          }
      }
      var out = try integer(n, case: c, feminine: female)
      if c == 0 {
        if out.hasSuffix("один") && !masculine && (noun.hasSuffix("у") || noun.hasSuffix("ю"))
          && !noun.hasSuffix("ую")
        {
          out = String(out.dropLast(4)) + "одну"
        } else if (out.hasSuffix("один") || out.hasSuffix("одна")) && noun != "кофе"
          && (neuter || ["о", "ие", "мя"].contains { noun.hasSuffix($0) })
        {
          out = String(out.dropLast(4)) + "одно"
        } else if out.hasSuffix("два") && !masculine && !neuter && !noun.hasSuffix("мени")
          && (noun.hasSuffix("ы") || noun.hasSuffix("и"))
        {
          out = String(out.dropLast(3)) + "две"
        }
      }
      return out
    }
    let alphabet = Array("АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
    let names =
      "а|бэ|вэ|гэ|дэ|е|ё|жэ|зэ|и|и краткое|ка|эль|эм|эн|о|пэ|эр|эс|тэ|у|эф|ха|цэ|че|ша|ща|твёрдый знак|ы|мягкий знак|э|ю|я"
      .components(separatedBy: "|")
    let letters = Dictionary(uniqueKeysWithValues: zip(alphabet, names))
    text = try Self.sub("(?<!\\w)[А-ЯЁ]{2,8}(?!\\w)", text) { g, _, _ in
      let w = g[0]
      let word = rules["wordAcronyms"] as? [String] ?? []
      let spell = rules["letterAcronyms"] as? [String] ?? []
      return !word.contains(w) && (spell.contains(w) || !w.contains { "АЕЁИОУЫЭЮЯ".contains($0) })
        ? w.map { letters[$0]! }.joined(separator: "-") : w.lowercased()
    }
    // A format none of the rules above knows ("2а", "1.2.3", "007") is read digit group by
    // digit group and logged, so one odd number never stops the whole book.
    text = try Self.sub("\\d+", text) { g, b, a in
      let digits = g[0]
      let spelled = digits.count > 12 || (digits.count > 1 && digits.hasPrefix("0"))
      let words = try spelled
        ? digits.map { try integer(Int(String($0))!) }.joined(separator: " ")
        : integer(Int(digits)!)
      NativeIO.emit("log", ["message": "Число «" + digits + "» в необычном формате прочитано как «" + words + "»"])
      let left = b.last.map { $0.isLetter || $0.isNumber } == true ? " " : ""
      let right = a.first.map { $0.isLetter || $0.isNumber } == true ? " " : ""
      return left + words + right
    }
    for (i, value) in protected.enumerated() {
      text = text.replacingOccurrences(
        of: "\u{e000}" + String(UnicodeScalar(0xe100 + i)!) + "\u{e001}", with: value)
    }
    return NativeIO.replace("[ \\t]+", text, " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }
  static func counted(_ word: String) -> Bool {
    !word.isEmpty && !word.hasPrefix("год")
      && (contains(
        "человек лет раз штук тонн минут секунд мест книг страниц слов единиц копеек солдат граммов душ верст миль сажен пудов десятин",
        word)
        || ["ах", "ях", "ам", "ям", "ами", "ями", "ов", "ев", "ей"].contains { word.hasSuffix($0) })
  }
  static func dayEnd(_ before: String) -> String {
    [
      "к": "ому", "ко": "ому", "на": "ое", "по": "ое", "за": "ое", "про": "ое", "сегодня": "ое",
      "завтра": "ое", "вчера": "ое", "послезавтра": "ое", "позавчера": "ое", "перед": "ым",
      "между": "ым", "над": "ым", "под": "ым", "о": "ом", "об": "ом", "при": "ом",
    ][previous(before)] ?? "ого"
  }
  static func agree(_ noun: String) -> String {
    let w = noun.lowercased()
    for stem in ["глав", "част", "книг", "сери"] where w.hasPrefix(stem) {
      let e = String(w.dropFirst(stem.count))
      return contains("у ю", e)
        ? "ую" : contains("ы и е ой ью ей ии ах ям ам ами ями ях", e) ? "ой" : "ая"
    }
    for stem in ["тысячелет", "раздел", "квартал", "созыв", "съезд", "класс", "век", "том"]
    where w.hasPrefix(stem) {
      return [
        "ие": "ое", "ия": "ого", "а": "ого", "ию": "ому", "у": "ому", "ием": "ым", "ом": "ым",
        "ем": "ым", "ии": "ом", "е": "ом", "ов": "ого", "ий": "ого", "ах": "ом", "иях": "ом",
        "ам": "ому", "иям": "ому", "ами": "ым", "иями": "ым",
      ][String(w.dropFirst(stem.count))] ?? "ый"
    }
    return "ый"
  }
  static func unitForm(_ n: Int, _ forms: [String], _ c: Int) -> String {
    if c == 0 || c == 3 { return plural(n, forms) }
    let parts = forms[0].components(separatedBy: " ")
    let first = parts[0]
    if first == "евро" { return first }
    let single = abs(n) % 10 == 1 && abs(n) % 100 != 11
    let soft = first.hasSuffix("ль")
    let stem = soft ? String(first.dropLast()) : first
    let result: String
    if c == 1 {
      result = single ? stem + (soft ? "я" : "а") : forms[2].components(separatedBy: " ")[0]
    } else {
      let endings = [
        2: ["ю", "у", "ям", "ам"], 4: ["ём", "ом", "ями", "ами"], 5: ["е", "е", "ях", "ах"],
      ][c]!
      result = stem + endings[(soft ? 0 : 1) + (single ? 0 : 2)]
    }
    return result + (parts.count > 1 ? " " + parts.dropFirst().joined(separator: " ") : "")
  }
}
