import Foundation

/// Short lines of one voice read in one model call. Alone, a one- or two-word line ("— Да.",
/// "Он сел.", a heading) comes out torn or rushed; read together with its neighbours it sounds
/// like the rest of the book. Lines stay separate for timing, loudness and read-along: only the
/// call to the model is shared, and its audio is cut between the lines at natural pauses.
/// Lines of different characters, manners or chapters are never joined.
public enum SpeechGroups {
  /// A line shorter than this joins its neighbour of the same voice.
  public static let minimum = 100
  /// The longest text one call reads (about 20 s of speech; the model drifts beyond that).
  public static let maximum = 260

  /// Marks runs of consecutive rows that share a call with "synthesis_group" (the first row's
  /// ID). A run grows while one side is shorter than `minimum` and both fit in `maximum`.
  public static func assign(_ rows: [Object]) -> [Object] {
    var result = rows
    for i in result.indices { result[i].removeValue(forKey: "synthesis_group") }
    var run: [Int] = [], size = 0
    func flush() {
      if run.count > 1 {
        let id = NativeIO.string(result[run[0]]["id"])
        for i in run { result[i]["synthesis_group"] = id }
      }
      run = []; size = 0
    }
    for (i, row) in result.enumerated() {
      let text = NativeIO.string(row["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
      // A scene break or a lone mark has nothing to say: it never joins a call.
      guard !NativeIO.regex("[\\p{L}\\p{N}]", text).isEmpty else { flush(); continue }
      if let last = run.last, joinable(result[last], row),
        min(size, text.count) < minimum, size + 1 + text.count <= maximum {
        run.append(i); size += 1 + text.count
        continue
      }
      flush()
      run = [i]; size = text.count
    }
    flush()
    return result
  }
  static func joinable(_ a: Object, _ b: Object) -> Bool {
    let speaker: Bool = NativeIO.string(a["speaker"]) == NativeIO.string(b["speaker"])
    let manner: Bool = VoiceDirection.manner(a["manner"]) == VoiceDirection.manner(b["manner"])
    let chapter: Bool = NativeIO.string(a["chapter_id"]) == NativeIO.string(b["chapter_id"])
    return speaker && manner && chapter
  }
  /// True when both rows are read in one call.
  public static func shared(_ a: Object, _ b: Object) -> Bool {
    let group = NativeIO.string(a["synthesis_group"])
    return !group.isEmpty && group == NativeIO.string(b["synthesis_group"])
  }
  /// Row indices per model call, in book order: a group's rows together, every other row alone.
  public static func units(_ rows: [Object]) -> [[Int]] {
    var units: [[Int]] = []
    for i in rows.indices {
      if let last = units.last?.last, shared(rows[last], rows[i]) { units[units.count - 1].append(i) }
      else { units.append([i]) }
    }
    return units
  }
  /// The text of one call. Where a line without a final mark meets the next paragraph (a
  /// heading, a line of verse), a full stop is added for the model only, so "Глава первая" and
  /// "Он вошёл" are not read as one phrase.
  public static func text(_ rows: [Object], unit: [Int]) -> String {
    var parts: [String] = []
    for (k, i) in unit.enumerated() {
      var part = SpeechRecovery.text(NativeIO.string(rows[i]["tts_text"]))
      if k + 1 < unit.count,
        NativeIO.string(rows[unit[k + 1]]["paragraph_id"]) != NativeIO.string(rows[i]["paragraph_id"]),
        NativeIO.regex("[.!?…:;,][»”\"')\\]]*\\s*$", part).isEmpty {
        part += "."
      }
      parts.append(part)
    }
    return parts.joined(separator: " ")
  }
  /// A line's share of the call's audio: its letters and digits, stress marks aside.
  public static func weight(_ text: String) -> Int {
    max(1, text.unicodeScalars.filter { $0.value != 0x301 && CharacterSet.alphanumerics.contains($0) }.count)
  }
  /// Cuts the audio of one call between its lines. The expected boundary follows the share of
  /// text (speech runs at an even 12–13 characters a second); around it the quietest place
  /// (energy smoothed over 150 ms) is chosen, that is the natural pause between sentences. The
  /// pieces are consecutive and together give exactly the original audio.
  public static func split(_ audio: [Float], weights: [Int], sampleRate: Int = 24000) -> [[Float]] {
    let count = weights.count, total = audio.count
    guard count > 1 else { return [audio] }
    let frame = max(1, sampleRate / 100)
    let frames = max(1, (total + frame - 1) / frame)
    var energy = [Double](repeating: 0, count: frames)
    for f in 0..<frames {
      var sum = 0.0
      for s in (f * frame)..<min(total, (f + 1) * frame) { sum += Double(audio[s]) * Double(audio[s]) }
      energy[f] = (sum / Double(frame)).squareRoot()
    }
    // Centred moving average over 15 frames, zeros beyond the edges (numpy "same" convolution).
    let width = 15, half = width / 2
    var smooth = [Double](repeating: 0, count: frames)
    for f in 0..<frames {
      var sum = 0.0
      for g in max(0, f - half)...min(frames - 1, f + width - 1 - half) { sum += energy[g] }
      smooth[f] = sum / Double(width)
    }
    let all = Double(weights.reduce(0) { $0 + max(1, $1) })
    let shares = weights.map { Double(max(1, $0)) / all }
    let shortest = max(1, min(sampleRate / 20, total / count))
    var cuts: [Int] = [], previous = 0, cumulative = 0.0
    for k in 1..<count {
      cumulative += shares[k - 1]
      let expected = cumulative * Double(total)
      var radius = 0.4 * min(shares[k - 1], shares[k]) * Double(total)
      radius = min(max(radius, 0.25 * Double(sampleRate)), 1.5 * Double(sampleRate))
      let low = max(Double(previous + shortest), expected - radius)
      let high = min(Double(total - (count - k) * shortest), expected + radius)
      var cut: Int
      if high <= low {
        cut = Int(min(max(expected, Double(previous + shortest)), Double(total - (count - k) * shortest)))
      } else {
        let first = Int((low / Double(frame)).rounded(.up)), last = Int((high / Double(frame)).rounded(.down))
        if last < first || first >= frames {
          cut = Int((low + high) / 2)
        } else {
          // The quietest frame; at equal quiet, the one nearest the expected boundary.
          var best = first
          for f in first...min(last, frames - 1) {
            let a = smooth[f], b = smooth[best]
            if a < b || (a == b && abs(Double(f * frame) - expected) < abs(Double(best * frame) - expected)) { best = f }
          }
          cut = Int(min(max(Double(best * frame + frame / 2), low), high))
        }
      }
      cut = min(max(cut, previous + 1), total - (count - k))
      cuts.append(cut)
      previous = cut
    }
    var pieces: [[Float]] = [], start = 0
    for cut in cuts + [total] {
      pieces.append(Array(audio[start..<cut]))
      start = cut
    }
    return pieces
  }
}
