import Foundation
import Darwin

public final class AccentDictionary {
  let data: Data, count: Int, offsets: Int, records: Int
  static func integer(_ data: Data, _ offset: Int, _ size: Int) throws -> Int {
    guard offset >= 0, offset + size <= data.count else {
      throw StudioError("Оборванный словарь SACC")
    }
    var value: UInt64 = 0
    for i in 0..<size { value |= UInt64(data[offset + i]) << (i * 8) }
    guard value <= UInt64(Int.max) else { throw StudioError("Недопустимое смещение SACC") }
    return Int(value)
  }
  public init(_ file: URL) throws {
    data = try Data(contentsOf: file, options: .mappedIfSafe)
    guard data.count >= 28, String(data: data[0..<4], encoding: .utf8) == "SACC",
      try Self.integer(data, 4, 4) == 1
    else { throw StudioError("Некорректный заголовок SACC") }
    count = try Self.integer(data, 8, 4)
    offsets = try Self.integer(data, 12, 8)
    records = try Self.integer(data, 20, 8)
    guard offsets >= 28, offsets <= data.count, records >= offsets, records <= data.count,
      count <= (records - offsets) / 4 else {
      throw StudioError("Некорректная структура SACC")
    }
  }
  public func lookup(_ word: String) throws -> String? {
    let query = Data(word.lowercased().utf8)
    var low = 0
    var high = count - 1
    while low <= high {
      let index = (low + high) / 2
      let offset = records + (try Self.integer(data, offsets + index * 4, 4))
      guard offset >= records, offset + 4 <= data.count else {
        throw StudioError("Некорректная запись SACC")
      }
      let ks = try Self.integer(data, offset, 2)
      let vs = try Self.integer(data, offset + 2, 2)
      guard offset + 4 + ks + vs <= data.count else { throw StudioError("Оборванная запись SACC") }
      let key = data[(offset + 4)..<(offset + 4 + ks)]
      if key == query {
        return String(data: data[(offset + 4 + ks)..<(offset + 4 + ks + vs)], encoding: .utf8)
      }
      if key.lexicographicallyPrecedes(query) { low = index + 1 } else { high = index - 1 }
    }
    return nil
  }
}
public final class NativeStress {
  let binary: AccentDictionary
  // Typed once at start: bridging these Foundation dictionaries per word made stress
  // preparation take about 13 seconds per 1000 characters.
  let homographs: [String: [String]], patterns: [String: Object], sileroExceptions: [String: [Int]]
  let vocab: [String: Int], neverSplit: Set<String>
  let unk: Int, cls: Int, sep: Int, homoStart: Int, homoEnd: Int
  let phrases: [String: [[String]]], corrections: [String: String]
  let dictionaryHomographs: Set<String>, dictionaryExceptions: [String: [Int]]
  let gram: [String: Set<String>]
  var compiledPatterns: [String: NSRegularExpression?] = [:]
  let process = Process(), input = Pipe(), output = Pipe()
  var pending = Data()
  public init(resources: URL, helper: URL) throws {
    let metadata = try NativeIO.load(resources.appendingPathComponent("silero/metadata.json"))
    let dictionary = try NativeIO.load(
      resources.appendingPathComponent("resources/stress_dictionary.json"))
    binary = try AccentDictionary(
      resources.appendingPathComponent("resources/russian_accents_full.sacc"))
    homographs = metadata["homographs"] as? [String: [String]] ?? [:]
    patterns = metadata["patterns"] as? [String: Object] ?? [:]
    sileroExceptions = metadata["exceptions"] as? [String: [Int]] ?? [:]
    vocab = metadata["vocab"] as? [String: Int] ?? [:]
    neverSplit = Set(metadata["never_split"] as? [String] ?? [])
    unk = metadata["unk"] as? Int ?? 100
    cls = metadata["cls"] as? Int ?? 101
    sep = metadata["sep"] as? Int ?? 102
    homoStart = metadata["homo_start"] as? Int ?? -1
    homoEnd = metadata["homo_end"] as? Int ?? -1
    phrases = (dictionary["phrases"] as? [String: [[String]]] ?? [:]).mapValues {
      $0.filter { $0.count >= 2 }.sorted { $0[0].count > $1[0].count }
    }
    corrections = dictionary["corrections"] as? [String: String] ?? [:]
    dictionaryHomographs = Set((dictionary["homographs"] as? Object ?? [:]).keys)
    dictionaryExceptions = dictionary["exceptions"] as? [String: [Int]] ?? [:]
    gram = (dictionary["gram"] as? [String: [String: String]] ?? [:]).mapValues { Set($0.values) }
    process.executableURL = helper
    process.arguments = [resources.appendingPathComponent("silero").path]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw StudioError("Не удалось подготовить канал ударений")
    }
    try process.run()
    NativeIO.emit("child", ["pid": process.processIdentifier])
  }
  deinit {
    try? input.fileHandleForWriting.close()
    NativeIO.stop(process, grace: 2)
    NativeIO.emit("child", ["pid": process.processIdentifier, "ended": true])
  }
  public func request(_ value: Object, timeout: TimeInterval = 120) throws -> Object {
    guard timeout.isFinite, timeout > 0, timeout <= 600 else { throw StudioError("Некорректный таймаут ударений") }
    let lock = NSLock(), timer = DispatchSource.makeTimerSource(queue: .global())
    var finished = false, expired = false
    let worker = process
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler {
      lock.lock(); defer { lock.unlock() }
      guard !finished else { return }
      expired = true
      if worker.isRunning { kill(-worker.processIdentifier, SIGKILL); kill(worker.processIdentifier, SIGKILL) }
    }
    timer.resume()
    defer { lock.lock(); finished = true; lock.unlock(); timer.cancel() }
    func failure() -> StudioError {
      lock.lock(); defer { lock.unlock() }
      return StudioError(expired ? "Движок ударений не ответил вовремя" : "Нативный движок ударений завершился раньше времени")
    }
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(10)
    // The engine ignores SIGPIPE, so a crashed helper surfaces here as a write error.
    do { try input.fileHandleForWriting.write(contentsOf: data) } catch {
      throw failure()
    }
    while pending.firstIndex(of: 10) == nil {
      let chunk = output.fileHandleForReading.availableData
      guard !chunk.isEmpty else {
        throw failure()
      }
      guard pending.count + chunk.count <= 8 * 1024 * 1024 else {
        NativeIO.stop(process, grace: 2)
        throw StudioError("Слишком большой ответ движка ударений")
      }
      pending.append(chunk)
    }
    let end = pending.firstIndex(of: 10)!
    let line = pending.prefix(end)
    pending.removeSubrange(...end)
    return NativeIO.object(try JSONSerialization.jsonObject(with: line))
  }
  public static func acute(_ text: String) -> String {
    NativeIO.replace("\\+([аеёиоуыэюяАЕЁИОУЫЭЮЯ])", text, "$1\u{301}")
  }
  public static func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "\u{301}", with: "")
      .lowercased().replacingOccurrences(of: "ё", with: "е")
  }
  /// Counted by scalars: a stressed vowel with its combining mark is one Character.
  static func vowelCount(_ word: String) -> Int {
    word.lowercased().unicodeScalars.filter { RussianText.vowels.unicodeScalars.contains($0) }.count
  }
  /// Puts the predicted stress on the book's own letters. A predicted 'ё' replaces the
  /// book's 'е' (books are often printed without 'ё'); 'ё' is always stressed, so no mark
  /// follows it. One-vowel words get no mark, as Silero does without stress_single_vowel.
  /// With `keepYo` (the book already prints its 'ё') a prediction that would turn the book's 'е'
  /// into 'ё' leaves the word exactly as printed: the author wrote 'е', and the stress of the
  /// 'е' reading is a different one (узна́ет, not узнае́т). Homographs pick their 'е' reading first.
  static func transfer(_ original: String, _ prediction: String, keepYo: Bool = false) -> String {
    guard plain(original) == plain(prediction) else { return original }
    // Letters only: an existing mark in the original would take a letter's place and cut the
    // word ("за́мок" → "за́́мо"). The prediction carries the stress.
    let scalars = Array(original.unicodeScalars.filter { $0.value != 0x301 })
    var out = String.UnicodeScalarView()
    var index = 0
    var afterYo = false
    for scalar in acute(prediction).unicodeScalars {
      if scalar.value == 0x301 {
        if !afterYo { out.append(scalar) }
        afterYo = false
        continue
      }
      guard index < scalars.count else { return original }
      var letter = scalars[index]
      if scalar == "ё" || scalar == "Ё", letter == "е" || letter == "Е" {
        if keepYo { return original }
        letter = letter == "е" ? "ё" : "Ё"
      }
      afterYo = letter == "ё" || letter == "Ё"
      out.append(letter)
      index += 1
    }
    let result = String(out)
    return vowelCount(result) <= 1 ? result.replacingOccurrences(of: "\u{301}", with: "") : result
  }
  /// Silero exceptions store the stressed character and, when present, the 'е' that is 'ё'.
  static func exception(_ word: String, _ object: [String: [Int]]) -> String? {
    guard let entry = object[word], let position = entry.first, position >= 0,
      position < word.unicodeScalars.count
    else { return nil }
    var scalars = Array(word.unicodeScalars)
    guard RussianText.vowels.unicodeScalars.contains(scalars[position]) else { return nil }
    if entry.count > 1, entry[1] >= 0, entry[1] < scalars.count, scalars[entry[1]] == "е" {
      scalars[entry[1]] = "ё"
      if entry[1] == position { return String(String.UnicodeScalarView(scalars)) }
    }
    return String(String.UnicodeScalarView(scalars[0...position])) + "\u{301}"
      + String(String.UnicodeScalarView(scalars[(position + 1)...]))
  }
  func cleanContext(_ text: String, start: Bool) -> String {
    var out = NativeIO.replace("[^a-zA-Zа-яА-ЯёЁ0-9\\s.!?,\\-]", text, "")
    out = NativeIO.replace("\\s+", out, " ")
    out = NativeIO.replace("-{2,}", out, " - ")
    out = NativeIO.replace("([.!?])\\1+", out, "$1")
    out = NativeIO.replace(",{2,}", out, ",")
    out = NativeIO.replace("\\s+([.,!?])", out, "$1")
    out = NativeIO.replace("([.,!?])(?=\\S)", out, "$1 ")
    out = NativeIO.replace("\\s+", out, " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if start {
      out = out.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?-"))
      out = String(out.prefix(1)).uppercased() + out.dropFirst().lowercased()
    } else {
      out = String(out.prefix(1)) + out.dropFirst().lowercased()
      if !out.isEmpty && !".!?".contains(out.last!) { out += "." }
    }
    return out
  }
  func tokenize(_ text: String) -> [Int] {
    var basic: [String] = []
    for token in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
      if neverSplit.contains(token) {
        basic.append(token)
        continue
      }
      var word = ""
      for scalar in token.unicodeScalars {
        let cp = scalar.value
        let punct =
          CharacterSet.punctuationCharacters.contains(scalar) || (33...47).contains(cp)
          || (58...64).contains(cp) || (91...96).contains(cp) || (123...126).contains(cp)
        if punct {
          if !word.isEmpty {
            basic.append(word)
            word = ""
          }
          basic.append(String(scalar))
        } else if !CharacterSet.controlCharacters.contains(scalar) {
          word.unicodeScalars.append(scalar)
        }
      }
      if !word.isEmpty { basic.append(word) }
    }
    var ids = [cls]
    for token in basic {
      let chars = Array(token.unicodeScalars)
      if chars.count > 100 {
        ids.append(unk)
        continue
      }
      var start = 0
      var pieces: [Int] = []
      var bad = false
      while start < chars.count {
        var end = chars.count
        var found: Int?
        while end > start {
          let part = (start > 0 ? "##" : "") + String(String.UnicodeScalarView(chars[start..<end]))
          if let id = vocab[part] {
            found = id
            break
          }
          end -= 1
        }
        guard let id = found else {
          bad = true
          break
        }
        pieces.append(id)
        start = end
      }
      ids += bad ? [unk] : pieces
    }
    ids.append(sep)
    return ids
  }
  /// Silero phrase pattern of a homograph, compiled once per word.
  func pattern(_ word: String) -> NSRegularExpression? {
    if let cached = compiledPatterns[word] { return cached }
    let compiled = try? NSRegularExpression(
      pattern: NativeIO.string(patterns[word]?["pattern"]), options: .caseInsensitive)
    compiledPatterns[word] = .some(compiled)
    return compiled
  }
  public func apply(_ text: String, prefix: String = "", suffix: String = "") throws -> String {
    try annotate(text, prefix: prefix, suffix: suffix).text
  }
  public struct Annotated {
    public let text: String
    /// Homographs the neural model resolved with low confidence, by word index in `text`
    /// (same word regex as `stressCandidates`), with every reading rendered on the word.
    public let disputes: [Int: [String]]
  }
  /// The book already prints 'ё' (set by the engine for the whole book): its 'е' is never turned
  /// into 'ё' again, and все/всё-type pairs need no guessing.
  public var bookHasYo = false
  /// Fixed readings that win over the dictionary and the model: the orthoepic norms and the
  /// user's own words (plain form → marked form).
  public var overrides: [String: String] = [:]
  /// True when the text uses 'ё' throughout. Any 'ё' counts, unless the commonest words that
  /// always take it (ещё, её) are mostly printed with 'е': a lone 'ё' in a name or an epigraph does
  /// not make a book printed without 'ё' complete.
  /// Words that always take ё in a text that prints it; their е-spelling betrays a book printed
  /// without ё or with ё only here and there (всё, узнаёт).
  static let yoForms: Set<String> = ["ещё", "её", "нём", "идёт", "пришёл", "шёл", "нашёл", "ушёл", "вошёл",
    "подошёл", "зашёл", "пошёл", "чёрт", "чёрный", "тёмный", "лёгкий", "жёлтый", "твёрдый", "счёт", "лёд",
    "мёд", "берёза", "звёзды", "слёзы", "ребёнок", "ребёнка", "всё-таки", "ёлка", "живёт", "даёт", "берёт"]
  static let yeForms: Set<String> = Set(yoForms.map { $0.replacingOccurrences(of: "ё", with: "е") })
  public static func hasYo(_ text: String) -> Bool {
    // Composed form: «е» + U+0308 is the same ё.
    let lower = text.precomposedStringWithCanonicalMapping.lowercased()
    guard lower.unicodeScalars.contains("ё") else { return false }
    var with = 0, without = 0
    for word in lower.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted) {
      if yoForms.contains(word) { with += 1 } else if yeForms.contains(word) { without += 1 }
    }
    return with + without < 3 || Double(with) >= 0.9 * Double(with + without)
  }
  /// A homograph's readings usable here: in a book that prints ё, only those without a new ё
  /// (осе́л, узна́ет); all of them otherwise, or if none is without ё.
  func readingsKeeping(_ readings: [String]) -> [String] {
    guard bookHasYo else { return readings }
    let plain = readings.filter { !$0.contains("ё") }
    return plain.isEmpty ? readings : plain
  }
  /// Name forms with 'ё' that the dictionaries miss or confuse with common words.
  static let yoNames: [String: String] = {
    var forms: [String: String] = [:]
    let stems: [(String, [String])] = [
      ("фёдор", ["", "а", "у", "ом", "е"]), ("фёдоров", ["ич", "ича", "ичу", "ичем", "иче", "на", "ны", "не", "ну", "ной"]),
      ("алён", ["а", "ы", "е", "у", "ой", "ушка", "ушки", "ушке", "ушку"]), ("семён", ["", "а", "у", "ом", "е"]),
      ("семёнов", ["ич", "ича", "ичу", "ичем", "иче", "на", "ны", "не", "ну", "ной"]), ("пётр", [""]),
      ("фёкл", ["а", "ы", "е", "у", "ой"]), ("артём", ["", "а", "у", "ом", "е"]), ("матрён", ["а", "ы", "е", "у", "ой"]),
      ("алёш", ["а", "и", "е", "у", "ей"]), ("серёж", ["а", "и", "е", "у", "ей"]), ("лёш", ["а", "и", "е", "у", "ей"]),
    ]
    for (stem, endings) in stems {
      for ending in endings { forms[(stem + ending).replacingOccurrences(of: "ё", with: "е")] = stem + ending }
    }
    return forms
  }()
  /// True when only spaces, quotes or dashes separate the word from a sentence end or the line start.
  static func sentenceStart(_ text: NSString, before location: Int, prefix: String) -> Bool {
    let head = (prefix + text.substring(to: location)).trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "«»\"„“-—–(")))
    guard let last = head.last else { return true }
    return ".!?…".contains(last)
  }
  public func annotate(_ text: String, prefix: String = "", suffix: String = "") throws
    -> Annotated
  {
    let matches = NativeIO.regex("[А-Яа-яЁё]+(?:\\u0301[А-Яа-яЁё]*)*", text)
    let ns = text as NSString
    let context = (prefix + text + suffix).replacingOccurrences(of: "\u{301}", with: "")
      .lowercased()
    // Hyphenated words ("по-моему", "кто-то") are looked up whole first: their stress
    // differs from the parts read separately ("моему́").
    var compounds: [(NSRange, String)] = []
    for m in NativeIO.regex("[А-Яа-яЁё]+(?:-[А-Яа-яЁё]+)+", text) {
      let original = ns.substring(with: m.range)
      // The user's own word or a norm wins over the dictionary for a hyphenated word too.
      if !original.unicodeScalars.contains("\u{301}"), let fixed = overrides[Self.plain(original)] {
        compounds.append((m.range, Self.transfer(original, fixed, keepYo: bookHasYo)))
        continue
      }
      guard let entry = try binary.lookup(original.lowercased()),
        Self.plain(entry) == Self.plain(original)
      else { continue }
      let marked = Self.transfer(original, entry, keepYo: bookHasYo)
      if marked != original { compounds.append((m.range, marked)) }
    }
    var words: [String] = []
    var wordPositions: [Int] = []
    var homos: [Object] = []
    var homoPositions: [Int] = []
    var predictions: [Int: String] = [:]
    var ruled: [Int] = []  // homographs settled by a context pattern; the LLM check may still differ
    for (i, m) in matches.enumerated() {
      let original = ns.substring(with: m.range)
      let word = original.lowercased()
      if compounds.contains(where: { NSLocationInRange(m.range.location, $0.0) }) { continue }
      // One-vowel words need no stress mark, but все/всё, чем/чём and similar
      // homographs still have to choose their letter from context.
      let yoHomograph = !bookHasYo && (homographs[word]?.contains { $0.contains("ё") } ?? false)
      let vowels = Self.vowelCount(word)
      // By scalars: String.contains("\u{301}") is false for "за́мок" (the mark joins its vowel),
      // and a stress already printed in the book must be kept as it is.
      guard !word.unicodeScalars.contains("\u{301}"), !word.unicodeScalars.contains("ё") else { continue }
      if let fixed = overrides[Self.plain(word)] {
        predictions[i] = fixed
        continue
      }
      // Personal names whose common-word twin has no 'ё' (Фёдора/федо́ра, Семёна/семена́).
      if !bookHasYo, let name = Self.yoNames[word], original.first?.isUppercase == true,
        !Self.sentenceStart(ns, before: m.range.location, prefix: prefix) {
        predictions[i] = name
        continue
      }
      // One-vowel words carry no mark, but still take 'ё' from the dictionary (лёд, Пётр, шёл).
      if vowels == 1 && !yoHomograph {
        // By scalars: "ё" followed by the stress mark is a different Character ("ё́").
        if !bookHasYo, word.contains("е"), let entry = try binary.lookup(word), entry.unicodeScalars.contains("ё"),
          Self.plain(entry) == Self.plain(word) {
          predictions[i] = entry
        }
        continue
      }
      guard vowels > 0 else { continue }
      // все/всё by the grammar of the clause where it decides; the LLM check still votes.
      if word == "все", !bookHasYo, homographs[word] != nil,
        let decided = StressRules.allOrEverything(
          before: String((prefix + ns.substring(to: m.range.location)).suffix(80)),
          after: String((ns.substring(from: m.range.location + m.range.length) + suffix).prefix(80))) {
        predictions[i] = decided
        ruled.append(i)
        continue
      }
      if homographs[word] != nil || patterns[word] != nil {
        let before = String(
          cleanContext(prefix + ns.substring(to: m.range.location), start: true).suffix(150))
        let after = String(
          cleanContext(ns.substring(from: m.range.location + m.range.length) + suffix, start: false)
            .prefix(150))
        let marked = (before + " [HOMO] " + word + " [/HOMO] " + after).trimmingCharacters(
          in: .whitespacesAndNewlines)
        let rule = patterns[word] ?? [:]
        var matched = false
        if !rule.isEmpty, let regex = pattern(word),
          let match = regex.firstMatch(in: marked, range: NSRange(marked.startIndex..., in: marked))
        {
          for (j, variant) in (rule["variants"] as? [String] ?? []).enumerated()
          where match.range(withName: "v\(j)").location != NSNotFound {
            predictions[i] = variant
            matched = true
            if homographs[word] != nil { ruled.append(i) }
            break
          }
        }
        if !matched && homographs[word] != nil {
          let tokens = tokenize(marked)
          guard let start = tokens.firstIndex(of: homoStart),
            let end = tokens.firstIndex(of: homoEnd)
          else { throw StudioError("Не удалось отметить омограф") }
          homos.append(["tokens": tokens, "start": start, "end": end])
          homoPositions.append(i)
        }
        if matched || homographs[word] != nil { continue }
      }
      let cleanBefore = (prefix + ns.substring(to: m.range.location)).replacingOccurrences(
        of: "\u{301}", with: ""
      ).utf16.count
      for pair in phrases[word] ?? [] {
        let hits = NativeIO.regex(
          "(?<!\\w)" + NSRegularExpression.escapedPattern(for: pair[0]) + "(?!\\w)", context)
        if hits.contains(where: {
          $0.range.location <= cleanBefore
            && $0.range.location + $0.range.length >= cleanBefore + word.utf16.count
        }) {
          predictions[i] = pair[1]
          break
        }
      }
      if predictions[i] != nil { continue }
      if let corrected = corrections[word] {
        predictions[i] = corrected
        continue
      }
      if !dictionaryHomographs.contains(word) {
        if let exc = Self.exception(word, dictionaryExceptions) {
          predictions[i] = exc
          continue
        }
        if let variants = gram[word], variants.count == 1 {
          predictions[i] = variants.first!
          continue
        }
        if let entry = try binary.lookup(word), Self.plain(entry) == Self.plain(word),
          NativeIO.regex("^[А-Яа-яЁё]+(?:\\u0301[А-Яа-яЁё]*)*$", Self.acute(entry)).count == 1,
          Self.acute(entry).unicodeScalars.filter({ $0.value == 0x301 }).count <= 1
        {
          predictions[i] = entry
          continue
        }
      }
      if let exc = Self.exception(word, sileroExceptions) {
        predictions[i] = exc
        continue
      }
      words.append(word)
      wordPositions.append(i)
    }
    let response = try request(["words": words, "homographs": homos])
    let stress = NativeIO.objects(response["stress"])
    let homoPreds = response["homographs"] as? [Int] ?? []
    let homoProbabilities = response["homograph_probabilities"] as? [Double] ?? []
    guard stress.count == words.count, homoPreds.count == homos.count else {
      throw StudioError("Некорректный ответ нативной модели ударений")
    }
    for (j, i) in wordPositions.enumerated() {
      let row = stress[j]
      let vowel = row["vowel"] as? Int ?? -1
      let prob = row["probability"] as? Double ?? 0
      var chars = Array(words[j].unicodeScalars)
      let positions = chars.indices.filter { RussianText.vowels.unicodeScalars.contains(chars[$0]) }
      if prob > 0.5 && positions.indices.contains(vowel) {
        let p = positions[vowel]
        // As in Silero: the predicted 'ё' is used only where the stress falls on that 'е'.
        let yo = row["yo"] as? Int ?? 0
        let ye = chars.indices.filter { chars[$0] == "е" }
        if yo > 0, (row["yo_probability"] as? Double ?? 0) > 0.5, yo - 1 < ye.count, ye[yo - 1] == p {
          chars[p] = "ё"
          predictions[i] = String(String.UnicodeScalarView(chars))
        } else {
          predictions[i] =
            String(String.UnicodeScalarView(chars[0...p])) + "\u{301}"
            + String(String.UnicodeScalarView(chars[(p + 1)...]))
        }
      }
    }
    var disputes: [Int: [String]] = [:]
    for (j, i) in homoPositions.enumerated() {
      let original = ns.substring(with: matches[i].range)
      let all = homographs[original.lowercased()] ?? []
      let p = homoPreds[j]
      guard all.indices.contains(p) else {
        throw StudioError("Нет варианта ударения омографа")
      }
      let variants = readingsKeeping(all)
      predictions[i] = variants.contains(all[p]) ? all[p] : variants[0]
      // Every homograph goes to the optional LLM check, not only uncertain ones: the model is
      // confidently wrong too (за́мок/замо́к, все/всё, бе́лки/белки́, сре́ду/среду́, о́рган/орга́н).
      _ = homoProbabilities
      do {
        var readings: [String] = []
        for variant in variants {
          let reading = Self.transfer(original, variant, keepYo: bookHasYo)
          if !readings.contains(reading) { readings.append(reading) }
        }
        if readings.count > 1 { disputes[i] = readings }
      }
    }
    for i in ruled {
      let original = ns.substring(with: matches[i].range)
      var readings: [String] = []
      for variant in readingsKeeping(homographs[original.lowercased()] ?? []) {
        let reading = Self.transfer(original, variant, keepYo: bookHasYo)
        if !readings.contains(reading) { readings.append(reading) }
      }
      if readings.count > 1 { disputes[i] = readings }
    }
    var replacements = compounds
    for (i, m) in matches.enumerated() {
      if var target = predictions[i] {
        // A context rule may name the ё reading; a book that prints ё takes its е reading.
        if bookHasYo, target.contains("ё"), let readings = homographs[ns.substring(with: m.range).lowercased()] {
          target = readingsKeeping(readings)[0]
        }
        replacements.append((m.range, Self.transfer(ns.substring(with: m.range), target, keepYo: bookHasYo)))
      }
    }
    var output = text
    for (range, value) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
      output = (output as NSString).replacingCharacters(in: range, with: value)
    }
    return Annotated(text: output, disputes: disputes)
  }
}
