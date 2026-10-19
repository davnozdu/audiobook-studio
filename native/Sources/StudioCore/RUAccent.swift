import Foundation
import Darwin

/// RUAccent (ruaccent/accentuator, MIT) on the Mac: its word dictionary is the bundled
/// russian_accents_full.sacc (built from RUAccent's own accents.json), its networks run in the
/// StudioAccent helper. As in RUAccent: ё-homographs (все/всё, осел/осёл) are tagged by a
/// DistilBERT model, stress homographs (за́мок/замо́к) are chosen by the DeBERTa classifier
/// turbo3.1 from the sentence, other words come from the dictionary, unknown ones from the
/// character model.
public final class RUAccent {
  let root: URL, dictionary: AccentDictionary
  let omographs: [String: [String]], yoHomographs: [String: String]
  let bpe: ByteLevelBPE, wordPiece: WordPiece
  let accentVocab: [String: Int]
  let process = Process(), input = Pipe(), output = Pipe()
  var pending = Data()
  /// The book prints its ё: an е of the book is never turned into ё.
  public var keepYo = false
  /// Fixed readings that win over RUAccent: the orthoepic norms and the user's own words.
  public var overrides: [String: String] = [:]
  public init(root: URL, dictionary: AccentDictionary, helper: URL) throws {
    self.root = root
    self.dictionary = dictionary
    omographs = (try NativeIO.load(root.appendingPathComponent("dictionary/omographs.json")) as Object)
      .compactMapValues { $0 as? [String] }
    yoHomographs = (try NativeIO.load(root.appendingPathComponent("dictionary/yo_homographs.json")) as Object)
      .compactMapValues { $0 as? String }
    bpe = try ByteLevelBPE(root.appendingPathComponent("nn/nn_omograph/turbo3.1/tokenizer.json"))
    wordPiece = try WordPiece(root.appendingPathComponent("nn/nn_yo_homograph_resolver/tokenizer.json"))
    let lines = try String(contentsOf: root.appendingPathComponent("nn/nn_accent/vocab.txt"), encoding: .utf8)
      .components(separatedBy: "\n")
    accentVocab = Dictionary(lines.enumerated().filter { !$0.element.isEmpty }.map { ($0.element, $0.offset) },
      uniquingKeysWith: { a, _ in a })
    guard !omographs.isEmpty, accentVocab["[bos]"] != nil, accentVocab["[eos]"] != nil else {
      throw StudioError("Повреждены данные RUAccent")
    }
    process.executableURL = helper
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw StudioError("Не удалось подготовить канал RUAccent")
    }
    try process.run()
    NativeIO.emit("child", ["pid": process.processIdentifier])
  }
  deinit {
    try? input.fileHandleForWriting.close()
    NativeIO.stop(process, grace: 2)
    NativeIO.emit("child", ["pid": process.processIdentifier, "ended": true])
  }
  /// Logits of one network for a batch of rows; rows are padded on the right with the mask at 0.
  func run(_ model: String, _ rows: [[Int]], pad: Int, types: Bool = false) throws -> (shape: [Int], data: [Double]) {
    let width = rows.map(\.count).max() ?? 0
    var inputs: Object = [
      "input_ids": rows.map { $0 + [Int](repeating: pad, count: width - $0.count) },
      "attention_mask": rows.map { [Int](repeating: 1, count: $0.count) + [Int](repeating: 0, count: width - $0.count) },
    ]
    if types { inputs["token_type_ids"] = rows.map { _ in [Int](repeating: 0, count: width) } }
    var data = try JSONSerialization.data(withJSONObject: ["model": root.appendingPathComponent(model).path, "inputs": inputs])
    data.append(10)
    do { try input.fileHandleForWriting.write(contentsOf: data) } catch {
      throw StudioError("Движок RUAccent завершился раньше времени")
    }
    let deadline = Date().addingTimeInterval(300)
    while pending.firstIndex(of: 10) == nil {
      let chunk = output.fileHandleForReading.availableData
      guard !chunk.isEmpty, Date() < deadline else { throw StudioError("Движок RUAccent не ответил") }
      pending.append(chunk)
    }
    let end = pending.firstIndex(of: 10)!
    let answer = NativeIO.object(try JSONSerialization.jsonObject(with: pending.prefix(end)))
    pending.removeSubrange(...end)
    if let error = answer["error"] as? String { throw StudioError("RUAccent: " + error) }
    let shape = (answer["shape"] as? [NSNumber] ?? []).map(\.intValue)
    let values = (answer["data"] as? [NSNumber] ?? []).map(\.doubleValue)
    guard !shape.isEmpty, shape.reduce(1, *) == values.count else { throw StudioError("Некорректный ответ RUAccent") }
    return (shape, values)
  }
  static func softmax(_ x: ArraySlice<Double>) -> [Double] {
    let top = x.max() ?? 0
    let e = x.map { exp($0 - top) }, sum = e.reduce(0, +)
    return e.map { $0 / sum }
  }
  /// RUAccent's split_by_words: words and runs of punctuation (" - " is a dash of its own).
  static let tokenPattern = "\\w*(?:\\+\\w+)*|[^\\w\\s]+"
  /// The stressed text: book letters kept, marks as U+0301, ё where RUAccent places it (unless
  /// `keepYo`). Words with a printed stress mark or ё stay as they are.
  public func annotate(_ text: String) throws -> String {
    var output = text
    var replacements: [(NSRange, String)] = []
    let ns = text as NSString
    // Sentence by sentence, as RUAccent reads: its networks look at one sentence.
    var start = 0
    let breaks = NativeIO.regex("(?<=[.!?…])\\s+", text).map { $0.range.location + $0.range.length } + [ns.length]
    for stop in breaks where stop > start {
      let range = NSRange(location: start, length: stop - start)
      replacements += try sentence(ns.substring(with: range), offset: start)
      start = stop
    }
    for (range, value) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
      output = (output as NSString).replacingCharacters(in: range, with: value)
    }
    return output
  }
  func sentence(_ text: String, offset: Int) throws -> [(NSRange, String)] {
    let ns = text as NSString
    let spaced = text.replacingOccurrences(of: " - ", with: " ~ ")
    let tokens = NativeIO.regex(Self.tokenPattern, spaced).filter { $0.range.length > 0 }.map { $0.range }
    // From the spaced copy: a lone dash stays "~" so joining the context never glues it to words.
    var words = tokens.map { (spaced as NSString).substring(with: $0) }
    let cyrillic = words.map { NativeIO.regex("^[А-Яа-яЁё]+$", $0).count == 1 }
    // 1. ё-homographs: the tagger reads the lowercased sentence; a word tagged YO takes its ё form.
    if !keepYo, words.enumerated().contains(where: { cyrillic[$0.offset] && yoHomographs[$0.element.lowercased()] != nil }) {
      let lower = text.lowercased(), scalars = Array(lower.unicodeScalars)
      let spans = WordPiece.words(lower)
      var ids = [wordPiece.cls], owner: [Int] = [-1]
      for (k, span) in spans.enumerated() {
        let pieces = wordPiece.pieces(Array(scalars[span]))
        ids += pieces; owner += [Int](repeating: k, count: pieces.count)
      }
      ids.append(wordPiece.sep); owner.append(-1)
      if ids.count <= 512 {
        let result = try run("nn/nn_yo_homograph_resolver/model.onnx", [ids], pad: 0)
        let labels = result.shape.last ?? 3
        var sums: [Int: [Double]] = [:], counts: [Int: Int] = [:]
        for (t, k) in owner.enumerated() where k >= 0 {
          let p = Self.softmax(result.data[(t * labels)..<((t + 1) * labels)])
          sums[k] = zip(sums[k] ?? [Double](repeating: 0, count: labels), p).map { $0 + $1 }
          counts[k, default: 0] += 1
        }
        // A BERT word starting where our token starts carries its label (2 = YO).
        var tagged: Set<Int> = []
        let scalarOffsets = Self.scalarOffsets(text)
        for (k, span) in spans.enumerated() {
          guard let s = sums[k] else { continue }
          if s.indices.max(by: { s[$0] < s[$1] }) == 2 { tagged.insert(span.lowerBound) }
        }
        for (i, range) in tokens.enumerated() where cyrillic[i] {
          if let form = yoHomographs[words[i].lowercased()], tagged.contains(scalarOffsets[range.location] ?? -1) {
            words[i] = Self.capital(words[i], form)
          }
        }
      }
    }
    var predictions: [Int: String] = [:]
    // 2. Stress homographs: each reading is scored against the sentence with the word in <w></w>.
    var pairs: [[Int]] = [], owners: [(Int, String)] = []
    for (i, word) in words.enumerated() where cyrillic[i] {
      let lower = word.lowercased()
      if overrides[NativeStress.plain(lower)] != nil { continue }
      guard let readings = omographs[lower], readings.count > 1 else { continue }
      var context = words
      context[i] = " <w>" + word + "</w> "
      var joined = Self.tight(context.joined(separator: " "))
      joined = NativeIO.replace("\\s+(?=[,.?!:;…])", joined, "")
      for reading in readings { pairs.append(bpe.pair(joined, reading)); owners.append((i, reading)) }
    }
    if !pairs.isEmpty {
      var best: [Int: (Double, String)] = [:]
      // Several requests of at most 16 pairs: memory stays small on long sentences.
      for chunk in stride(from: 0, to: pairs.count, by: 16) {
        let part = Array(pairs[chunk..<min(pairs.count, chunk + 16)])
        let result = try run("nn/nn_omograph/turbo3.1/model.onnx", part, pad: bpe.pad)
        for k in part.indices {
          let p = Self.softmax(result.data[(k * 2)..<(k * 2 + 2)])[1]
          let (i, reading) = owners[chunk + k]
          if best[i] == nil || p > best[i]!.0 { best[i] = (p, reading) }
        }
      }
      for (i, choice) in best { predictions[i] = choice.1 }
    }
    // 3. Other words: the dictionary, the character model for words it does not know.
    var unknown: [Int] = []
    for (i, word) in words.enumerated() where cyrillic[i] && predictions[i] == nil {
      let lower = word.lowercased()
      if let fixed = overrides[NativeStress.plain(lower)] { predictions[i] = fixed; continue }
      if let entry = try dictionary.lookup(lower), NativeStress.plain(entry) == NativeStress.plain(lower) {
        predictions[i] = entry; continue
      }
      if NativeStress.vowelCount(lower) > 1 { unknown.append(i) }
    }
    if !unknown.isEmpty {
      let unk = accentVocab["[unk]"] ?? 1
      let rows = unknown.map { i in
        [accentVocab["[bos]"]!] + words[i].lowercased().map { accentVocab[String($0)] ?? unk } + [accentVocab["[eos]"]!]
      }
      let result = try run("nn/nn_accent/model.onnx", rows, pad: accentVocab["[pad]"] ?? 0, types: true)
      let width = result.shape.count == 3 ? result.shape[1] : 0, labels = result.shape.last ?? 3
      for (r, i) in unknown.enumerated() {
        let letters = Array(words[i])
        var marked = ""
        // Token t (after [bos]) is letter t-1; a primary stress at ≥ 0.55 marks that letter.
        for (t, letter) in letters.enumerated() {
          let base = (r * width + t + 1) * labels
          guard base + labels <= result.data.count else { break }
          let p = Self.softmax(result.data[base..<(base + labels)])
          let label = p.indices.max(by: { p[$0] < p[$1] })!
          marked += (label == 1 && p[label] >= 0.55 ? "+" : "") + String(letter)
        }
        if marked.contains("+") { predictions[i] = marked }
      }
    }
    var result: [(NSRange, String)] = []
    for (i, range) in tokens.enumerated() {
      guard var target = predictions[i] else {
        // Only the ё from step 1, without a stress.
        if words[i] != ns.substring(with: range) {
          result.append((NSRange(location: offset + range.location, length: range.length),
            NativeStress.transfer(ns.substring(with: range), words[i], keepYo: keepYo)))
        }
        continue
      }
      target = NativeStress.acute(target)
      // A dictionary reading of е where the tagger chose ё keeps the ё.
      if words[i].lowercased().contains("ё"), !target.contains("ё"),
        NativeStress.plain(target) == NativeStress.plain(words[i]) {
        target = Self.withYo(target, words[i])
      }
      let original = ns.substring(with: range)
      let marked = NativeStress.transfer(original, target, keepYo: keepYo)
      if marked != original { result.append((NSRange(location: offset + range.location, length: range.length), marked)) }
    }
    return result
  }
  /// Copies the ё of `yo` into `marked`, which has the same letters with е.
  static func withYo(_ marked: String, _ yo: String) -> String {
    let source = Array(yo.lowercased().unicodeScalars)
    var out = String.UnicodeScalarView(), k = 0, skipMark = false
    for s in marked.unicodeScalars {
      if s.value == 0x301 { if !skipMark { out.append(s) }; continue }
      var letter = s
      skipMark = false
      if k < source.count, source[k] == "ё", s == "е" || s == "Е" { letter = s == "е" ? "ё" : "Ё"; skipMark = true }
      out.append(letter); k += 1
    }
    return String(out)
  }
  /// UTF-16 offset → scalar offset, for matching BERT words to our tokens.
  static func scalarOffsets(_ text: String) -> [Int: Int] {
    var map: [Int: Int] = [:], utf16 = 0
    for (k, s) in text.unicodeScalars.enumerated() { map[utf16] = k; utf16 += s.utf16.count }
    return map
  }
  /// RUAccent's fix_capital: the source's letter case on the target, when lengths match.
  static func capital(_ source: String, _ target: String) -> String {
    let s = Array(source), t = Array(target)
    guard s.count == t.count else { return target }
    return String(zip(s, t).map { $0.isUppercase ? Character($1.uppercased()) : Character($1.lowercased()) })
  }
  /// RUAccent's delete_spaces_before_punc.
  static func tight(_ text: String) -> String {
    var out = text
    for c in "!\"#$%&'()*,./:;<=>?@[\\]^_`{|}-" {
      if c == "-" { out = out.replacingOccurrences(of: " -", with: "-").replacingOccurrences(of: "- ", with: "-") }
      out = out.replacingOccurrences(of: " " + String(c), with: String(c))
    }
    return out.replacingOccurrences(of: "~", with: "-")
  }
}
