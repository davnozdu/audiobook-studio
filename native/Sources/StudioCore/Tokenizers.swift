import Foundation

/// The two Hugging Face tokenizers RUAccent's networks were trained with, read from their
/// tokenizer.json and reproduced exactly: byte-level BPE with added tokens (the DeBERTa homograph
/// classifier) and BERT WordPiece (the ё-homograph tagger).
public final class ByteLevelBPE {
  let vocab: [String: Int], ranks: [String: Int]
  /// Added tokens by first scalar, longest first: matched before BPE, leftmost-longest.
  let added: [Unicode.Scalar: [([Unicode.Scalar], Int)]]
  let bytes: [Character]
  var cache: [String: [Int]] = [:]
  public let cls: Int, sep: Int, pad: Int
  static let pattern = "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"
  public init(_ file: URL) throws {
    let json = try NativeIO.load(file)
    let model = NativeIO.object(json["model"])
    vocab = (model["vocab"] as? [String: Int]) ?? [:]
    var ranks: [String: Int] = [:]
    for (rank, merge) in (model["merges"] as? [Any] ?? []).enumerated() {
      let pair = (merge as? String) ?? (merge as? [String] ?? []).joined(separator: " ")
      if ranks[pair] == nil { ranks[pair] = rank }
    }
    self.ranks = ranks
    var added: [Unicode.Scalar: [([Unicode.Scalar], Int)]] = [:]
    for token in NativeIO.objects(json["added_tokens"]) {
      let content = Array(NativeIO.string(token["content"]).unicodeScalars)
      guard let first = content.first, let id = token["id"] as? Int else { continue }
      added[first, default: []].append((content, id))
    }
    self.added = added.mapValues { $0.sorted { $0.0.count > $1.0.count } }
    // GPT-2 byte-to-unicode table: printable bytes stand for themselves, the rest from U+0100.
    var table = [Character](repeating: " ", count: 256), next = 0
    for b in 0..<256 {
      let printable = (33...126).contains(b) || (161...172).contains(b) || (174...255).contains(b)
      table[b] = Character(Unicode.Scalar(printable ? b : 256 + next)!)
      if !printable { next += 1 }
    }
    bytes = table
    guard vocab.count > 0, !ranks.isEmpty, let s = vocab["<s>"], let e = vocab["</s>"], let p = vocab["<pad>"] else {
      throw StudioError("Некорректный токенизатор BPE")
    }
    cls = s; sep = e; pad = p
  }
  /// Token IDs of `text` without special tokens.
  public func encode(_ text: String) -> [Int] {
    let scalars = Array(text.unicodeScalars)
    var ids: [Int] = [], start = 0, p = 0
    func plain(_ end: Int) {
      if end > start { ids += pretokenized(String(String.UnicodeScalarView(scalars[start..<end]))) }
    }
    while p < scalars.count {
      if let candidates = added[scalars[p]],
        let hit = candidates.first(where: { p + $0.0.count <= scalars.count && Array(scalars[p..<(p + $0.0.count)]) == $0.0 }) {
        plain(p)
        ids.append(hit.1)
        p += hit.0.count; start = p
      } else { p += 1 }
    }
    plain(scalars.count)
    return ids
  }
  func pretokenized(_ text: String) -> [Int] {
    let ns = text as NSString
    var ids: [Int] = []
    for match in NativeIO.regex(Self.pattern, text) {
      let word = String(Data(ns.substring(with: match.range).utf8).map { bytes[Int($0)] })
      if let known = cache[word] { ids += known; continue }
      let encoded = bpe(word).compactMap { vocab[$0] }
      if cache.count < 100_000 { cache[word] = encoded }
      ids += encoded
    }
    return ids
  }
  func bpe(_ word: String) -> [String] {
    var parts = word.map { String($0) }
    while parts.count > 1 {
      var best: (rank: Int, index: Int)?
      for i in 0..<(parts.count - 1) {
        if let rank = ranks[parts[i] + " " + parts[i + 1]], best == nil || rank < best!.rank { best = (rank, i) }
      }
      guard let pair = best else { break }
      let first = parts[pair.index], second = parts[pair.index + 1]
      var merged: [String] = [], i = 0
      while i < parts.count {
        if i + 1 < parts.count, parts[i] == first, parts[i + 1] == second { merged.append(first + second); i += 2 }
        else { merged.append(parts[i]); i += 1 }
      }
      parts = merged
    }
    return parts
  }
  /// RoBERTa pair: <s> A </s></s> B </s>, longest-first truncation to `maximum` tokens.
  public func pair(_ a: String, _ b: String, maximum: Int = 512) -> [Int] {
    var x = encode(a), y = encode(b)
    while x.count + y.count + 4 > maximum, !(x.isEmpty && y.isEmpty) {
      if x.count >= y.count { x.removeLast() } else { y.removeLast() }
    }
    return [cls] + x + [sep, sep] + y + [sep]
  }
}

public final class WordPiece {
  let vocab: [String: Int]
  public let cls: Int, sep: Int, unk: Int
  public init(_ file: URL) throws {
    let json = try NativeIO.load(file)
    vocab = (NativeIO.object(json["model"])["vocab"] as? [String: Int]) ?? [:]
    guard let c = vocab["[CLS]"], let s = vocab["[SEP]"], let u = vocab["[UNK]"] else {
      throw StudioError("Некорректный токенизатор WordPiece")
    }
    cls = c; sep = s; unk = u
  }
  static func punctuation(_ s: Unicode.Scalar) -> Bool {
    let v = s.value
    if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
    return CharacterSet.punctuationCharacters.contains(s)
  }
  /// BERT words of `text` (whitespace and single punctuation marks split), as scalar ranges.
  public static func words(_ text: String) -> [Range<Int>] {
    let scalars = Array(text.unicodeScalars)
    var result: [Range<Int>] = [], start: Int?
    for (i, s) in scalars.enumerated() {
      let control = CharacterSet.controlCharacters.contains(s) && !"\t\n\r".unicodeScalars.contains(s)
      if CharacterSet.whitespacesAndNewlines.contains(s) || control || s.value == 0 || s.value == 0xFFFD {
        if let b = start { result.append(b..<i); start = nil }
      } else if punctuation(s) {
        if let b = start { result.append(b..<i); start = nil }
        result.append(i..<(i + 1))
      } else if start == nil { start = i }
    }
    if let b = start { result.append(b..<scalars.count) }
    return result
  }
  /// Pieces of one word, or [UNK] when it cannot be spelled from the vocabulary.
  public func pieces(_ word: [Unicode.Scalar]) -> [Int] {
    guard word.count <= 100 else { return [unk] }
    var ids: [Int] = [], start = 0
    while start < word.count {
      var end = word.count, found: Int?
      while end > start {
        let piece = (start > 0 ? "##" : "") + String(String.UnicodeScalarView(word[start..<end]))
        if let id = vocab[piece] { found = id; break }
        end -= 1
      }
      guard let id = found else { return [unk] }
      ids.append(id); start = end
    }
    return ids
  }
}
