import Foundation

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
    guard offsets >= 28, records >= offsets + count * 4, records <= data.count else {
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
  let metadata: Object, dictionary: Object, binary: AccentDictionary
  let process = Process(), input = Pipe(), output = Pipe()
  var pending = Data()
  public init(resources: URL, helper: URL) throws {
    metadata = try NativeIO.load(resources.appendingPathComponent("silero/metadata.json"))
    dictionary = try NativeIO.load(
      resources.appendingPathComponent("resources/stress_dictionary.json"))
    binary = try AccentDictionary(
      resources.appendingPathComponent("resources/russian_accents_full.sacc"))
    process.executableURL = helper
    process.arguments = [resources.appendingPathComponent("silero").path]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    NativeIO.emit("child", ["pid": process.processIdentifier])
  }
  deinit {
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    NativeIO.emit("child", ["pid": 0])
  }
  public func request(_ value: Object) throws -> Object {
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(10)
    // The engine ignores SIGPIPE, so a crashed helper surfaces here as a write error.
    do { try input.fileHandleForWriting.write(contentsOf: data) } catch {
      throw StudioError("Нативный движок ударений завершился раньше времени")
    }
    while pending.firstIndex(of: 10) == nil {
      let chunk = output.fileHandleForReading.availableData
      guard !chunk.isEmpty else {
        throw StudioError("Нативный движок ударений завершился раньше времени")
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
  static func transfer(_ original: String, _ prediction: String) -> String {
    guard plain(original) == plain(prediction) else { return original }
    let scalars = Array(original.unicodeScalars)
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
      if scalar == "ё" || scalar == "Ё" {
        if letter == "е" { letter = "ё" } else if letter == "Е" { letter = "Ё" }
      }
      afterYo = letter == "ё" || letter == "Ё"
      out.append(letter)
      index += 1
    }
    let result = String(out)
    return vowelCount(result) <= 1 ? result.replacingOccurrences(of: "\u{301}", with: "") : result
  }
  /// Silero exceptions store the stressed character and, when present, the 'е' that is 'ё'.
  static func exception(_ word: String, _ object: Object) -> String? {
    guard let entry = object[word] as? [Int], let position = entry.first, position >= 0,
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
    let vocab = metadata["vocab"] as? [String: Int] ?? [:]
    let never = Set(metadata["never_split"] as? [String] ?? [])
    let unk = metadata["unk"] as? Int ?? 100
    var basic: [String] = []
    for token in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
      if never.contains(token) {
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
    var ids = [metadata["cls"] as? Int ?? 101]
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
    ids.append(metadata["sep"] as? Int ?? 102)
    return ids
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
  public func annotate(_ text: String, prefix: String = "", suffix: String = "") throws
    -> Annotated
  {
    let matches = NativeIO.regex("[А-Яа-яЁё]+(?:\\u0301[А-Яа-яЁё]*)*", text)
    let ns = text as NSString
    let homographs = NativeIO.object(metadata["homographs"])
    let patterns = NativeIO.object(metadata["patterns"])
    // Hyphenated words ("по-моему", "кто-то") are looked up whole first: their stress
    // differs from the parts read separately ("моему́").
    var compounds: [(NSRange, String)] = []
    for m in NativeIO.regex("[А-Яа-яЁё]+(?:-[А-Яа-яЁё]+)+", text) {
      let original = ns.substring(with: m.range)
      guard let entry = try binary.lookup(original.lowercased()),
        Self.plain(entry) == Self.plain(original)
      else { continue }
      let marked = Self.transfer(original, entry)
      if marked != original { compounds.append((m.range, marked)) }
    }
    var words: [String] = []
    var wordPositions: [Int] = []
    var homos: [Object] = []
    var homoPositions: [Int] = []
    var predictions: [Int: String] = [:]
    for (i, m) in matches.enumerated() {
      let original = ns.substring(with: m.range)
      let word = original.lowercased()
      if compounds.contains(where: { NSLocationInRange(m.range.location, $0.0) }) { continue }
      // One-vowel words need no stress mark, but все/всё, чем/чём and similar
      // homographs still have to choose their letter from context.
      let yoHomograph = (homographs[word] as? [String])?.contains { $0.contains("ё") } ?? false
      let vowels = Self.vowelCount(word)
      guard !word.contains("\u{301}"), !word.contains("ё"), vowels > 1 || (vowels == 1 && yoHomograph)
      else { continue }
      if homographs[word] != nil || patterns[word] != nil {
        let before = String(
          cleanContext(prefix + ns.substring(to: m.range.location), start: true).suffix(150))
        let after = String(
          cleanContext(ns.substring(from: m.range.location + m.range.length) + suffix, start: false)
            .prefix(150))
        let marked = (before + " [HOMO] " + word + " [/HOMO] " + after).trimmingCharacters(
          in: .whitespacesAndNewlines)
        let rule = NativeIO.object(patterns[word])
        var matched = false
        if let regex = try? NSRegularExpression(
          pattern: NativeIO.string(rule["pattern"]), options: .caseInsensitive),
          let match = regex.firstMatch(in: marked, range: NSRange(marked.startIndex..., in: marked))
        {
          for (j, variant) in (rule["variants"] as? [String] ?? []).enumerated()
          where match.range(withName: "v\(j)").location != NSNotFound {
            predictions[i] = variant
            matched = true
            break
          }
        }
        if !matched && homographs[word] != nil {
          let tokens = tokenize(marked)
          guard let start = tokens.firstIndex(of: metadata["homo_start"] as? Int ?? -1),
            let end = tokens.firstIndex(of: metadata["homo_end"] as? Int ?? -1)
          else { throw StudioError("Не удалось отметить омограф") }
          homos.append(["tokens": tokens, "start": start, "end": end])
          homoPositions.append(i)
        }
        if matched || homographs[word] != nil { continue }
      }
      let context = (prefix + text + suffix).replacingOccurrences(of: "\u{301}", with: "")
        .lowercased()
      let phrases = NativeIO.object(dictionary["phrases"])[word] as? [[String]] ?? []
      let cleanBefore = (prefix + ns.substring(to: m.range.location)).replacingOccurrences(
        of: "\u{301}", with: ""
      ).utf16.count
      for pair in phrases.sorted(by: { $0[0].count > $1[0].count }) where pair.count >= 2 {
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
      if let corrected = NativeIO.object(dictionary["corrections"])[word] as? String {
        predictions[i] = corrected
        continue
      }
      if NativeIO.object(dictionary["homographs"])[word] == nil {
        if let exc = Self.exception(word, NativeIO.object(dictionary["exceptions"])) {
          predictions[i] = exc
          continue
        }
        let gram = Set(
          (NativeIO.object(NativeIO.object(dictionary["gram"])[word])).values.compactMap {
            $0 as? String
          })
        if gram.count == 1 {
          predictions[i] = gram.first!
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
      if let exc = Self.exception(word, NativeIO.object(metadata["exceptions"])) {
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
      let variants = homographs[original.lowercased()] as? [String] ?? []
      let p = homoPreds[j]
      guard variants.indices.contains(p) else {
        throw StudioError("Нет варианта ударения омографа")
      }
      predictions[i] = variants[p]
      if homoProbabilities.indices.contains(j), (0.2...0.8).contains(homoProbabilities[j]) {
        var readings: [String] = []
        for variant in variants {
          let reading = Self.transfer(original, variant)
          if !readings.contains(reading) { readings.append(reading) }
        }
        if readings.count > 1 { disputes[i] = readings }
      }
    }
    var replacements = compounds
    for (i, m) in matches.enumerated() {
      if let target = predictions[i] {
        replacements.append((m.range, Self.transfer(ns.substring(with: m.range), target)))
      }
    }
    var output = text
    for (range, value) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
      output = (output as NSString).replacingCharacters(in: range, with: value)
    }
    return Annotated(text: output, disputes: disputes)
  }
}
