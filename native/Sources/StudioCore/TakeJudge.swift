import Foundation

/// Even reading at generation time, ported from qwen-epub-audiobook ecd8a7a. An audit of a 75-minute
/// book found clicks mid-phrase in pauses (−36…−48 dB, 1–5 ms bursts), most often near brackets,
/// colons and semicolons. Their source was the voice sample: lip clicks in its pauses at commas,
/// which the model copies with the timbre. So the sample is cleaned before the model hears it, and
/// every take is judged right after synthesis; a bad one is read again with another seed, never
/// filtered.
public enum ReferenceCleanup {
  /// A click is looked for only in a pause: the level around it is below this.
  public static let quietDB = -42.0

  /// Clicks in pauses: a short (≈1 ms) broadband burst 25+ times stronger than its surroundings,
  /// in silence. Consonants are longer and sit on speech, so the rule leaves them alone.
  /// Sample ranges, start..<end.
  public static func quietClicks(_ audio: [Float], sampleRate: Int = 24000) -> [Range<Int>] {
    let frame = max(1, sampleRate / 1000), n = audio.count / frame
    guard n >= 60 else { return [] }
    var second = [Double](repeating: 0, count: audio.count)
    if audio.count > 2 {
      for i in 1..<(audio.count - 1) {
        second[i] = Double(audio[i + 1]) - 2 * Double(audio[i]) + Double(audio[i - 1])
      }
    }
    var logEnergy = [Double](repeating: 0, count: n), energy = [Double](repeating: 0, count: n)
    var level = [Double](repeating: 0, count: n)
    for f in 0..<n {
      var s2 = 0.0, a2 = 0.0
      for i in (f * frame)..<((f + 1) * frame) { s2 += second[i] * second[i]; a2 += Double(audio[i]) * Double(audio[i]) }
      energy[f] = (s2 / Double(frame)).squareRoot() + 1e-7
      logEnergy[f] = log(energy[f])
      level[f] = 20 * log10((a2 / Double(frame)).squareRoot() + 1e-9)
    }
    // Centred mean over 81 frames with zeros beyond the edges (numpy "same" convolution).
    var prefix = [Double](repeating: 0, count: n + 1)
    for f in 0..<n { prefix[f + 1] = prefix[f] + logEnergy[f] }
    var events: [(Int, Int)] = [], last = -100
    for f in 0..<n {
      let lo = max(0, f - 40), hi = min(n, f + 41)
      let around = exp((prefix[hi] - prefix[lo]) / 81)
      guard energy[f] / around > 25, energy[f] > 0.004 else { continue }
      var window = Array(level[max(0, f - 20)..<min(n, f + 21)]).sorted()
      let middle = window.count / 2
      let median = window.count % 2 == 1 ? window[middle] : (window[middle - 1] + window[middle]) / 2
      window.removeAll()
      guard median < quietDB else { continue }      // on speech it is a speech sound, not a click
      if f - last > 6 { events.append((f, f)) } else { events[events.count - 1].1 = f }
      last = f
    }
    return events.map { ($0.0 * frame)..<(($0.1 + 1) * frame) }
  }

  /// The voice sample without clicks in its pauses: each click is lowered into silence by a smooth
  /// 3 ms dip (2 ms either side of the burst); speech is not touched.
  public static func clean(_ audio: [Float], sampleRate: Int = 24000) -> (samples: [Float], removed: Int) {
    let clicks = quietClicks(audio, sampleRate: sampleRate)
    guard !clicks.isEmpty else { return (audio, 0) }
    var out = audio
    let pad = sampleRate * 2 / 1000, fade = sampleRate * 3 / 1000
    let ramp = (0..<fade).map { 0.5 - 0.5 * cos(Double.pi * Double($0) / Double(max(1, fade - 1))) }
    for click in clicks {
      let a = max(0, click.lowerBound - pad), b = min(out.count, click.upperBound + pad)
      var envelope = [Double](repeating: 0, count: b - a + 2 * fade)
      for k in 0..<fade { envelope[k] = 1 - ramp[k]; envelope[envelope.count - fade + k] = ramp[k] }
      let lo = a - fade, hi = b + fade
      for i in max(0, lo)..<min(out.count, hi) { out[i] *= Float(envelope[i - lo]) }
    }
    return (out, clicks.count)
  }
}

/// Judges one take of a line right after synthesis. A bad take is heard as "it broke off and
/// went on" or "another voice": a click in a pause; a pace this book never has (1.45× faster than
/// its typical pace — text swallowed — or 0.6× slower; 6–20 letters a second at most); long pauses
/// beyond the places where a pause belongs (. ! ? … : ;); a voice drifted from its sample. The pace
/// and voice limits come from the book itself (the median of what is already read), so they fit
/// any book and any sample. Short takes (under 25 letters or 2 s) are not judged on pace or pauses.
public final class TakeJudge {
  public static let tempoFast = 1.45, tempoSlow = 0.6, tempoLimits = (6.0, 20.0)
  public static let longPause = 0.9, strongStops = ".!?…:;"
  public static let voiceFloor = 0.5, voiceMargin = 0.1, voiceMinimumSeconds = 1.5
  public private(set) var rates: [Double] = [], similarities: [Double] = []
  public init() {}

  public struct Verdict {
    public let problems: [String], rate: Double?, similarity: Double?
  }
  /// Speech length without the edges, and the number of long pauses inside it.
  public static func speechShape(_ audio: [Float], sampleRate: Int = 24000) -> (seconds: Double, pauses: Int) {
    let window = max(1, sampleRate / 100), n = audio.count / window
    guard n >= 10 else { return (0, 0) }
    let level = (0..<n).map { f -> Double in
      var sum = 0.0
      for i in (f * window)..<((f + 1) * window) { sum += Double(audio[i]) * Double(audio[i]) }
      return 20 * log10((sum / Double(window)).squareRoot() + 1e-9)
    }
    // numpy percentile, linear interpolation.
    let sorted = level.sorted(), rank = 0.95 * Double(n - 1)
    let low = Int(rank.rounded(.down)), high = min(n - 1, low + 1)
    let p95 = sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    let threshold = max(p95 - 35, -60)
    let voiced = level.map { $0 > threshold }
    guard let first = voiced.firstIndex(of: true), let last = voiced.lastIndex(of: true) else { return (0, 0) }
    var pauses = 0, run = 0
    for flag in voiced[first...last] + [true] {
      if !flag { run += 1 } else {
        if Double(run) * 0.01 >= longPause { pauses += 1 }
        run = 0
      }
    }
    return (Double(last - first + 1) * 0.01, pauses)
  }
  public var voiceLimit: Double {
    similarities.count < 5 ? Self.voiceFloor : max(Self.voiceFloor, Self.median(similarities) - Self.voiceMargin)
  }
  public var tempo: (low: Double, high: Double) {
    var (low, high) = Self.tempoLimits
    if rates.count >= 5 {
      let typical = Self.median(rates)
      low = max(low, typical * Self.tempoSlow); high = min(high, typical * Self.tempoFast)
    }
    return (low, high)
  }
  static func median(_ values: [Double]) -> Double {
    let s = values.sorted(), m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
  }
  /// The verdict on one take of `text` (the text the model read). `similarity` is the cosine of
  /// the take's speaker embedding with the sample's, when it could be measured.
  public func judge(_ audio: [Float], text: String, similarity: Double?, sampleRate: Int = 24000) -> Verdict {
    var problems: [String] = []
    let clicks = ReferenceCleanup.quietClicks(audio, sampleRate: sampleRate)
    if !clicks.isEmpty { problems.append("щелчок в паузе ×\(clicks.count)") }
    let letters = text.filter { $0.isLetter }.count
    let (voiced, pauses) = Self.speechShape(audio, sampleRate: sampleRate)
    let rate: Double? = voiced > 0 ? Double(letters) / voiced : nil
    if letters >= 25, voiced >= 2, let rate {
      let (low, high) = tempo
      if rate > high {
        problems.append(String(format: "слишком быстро (%.1f букв/с > %.1f): похоже, текст проглочен", rate, high))
      } else if rate < low {
        problems.append(String(format: "слишком медленно (%.1f букв/с < %.1f)", rate, low))
      }
      let allowed = text.filter { Self.strongStops.contains($0) }.count
      if pauses > allowed { problems.append("лишние долгие паузы: \(pauses) при уместных \(allowed)") }
    }
    if let similarity, similarity < voiceLimit {
      problems.append(String(format: "голос уехал: сходство с образцом %.2f < %.2f", similarity, voiceLimit))
    }
    return Verdict(problems: problems, rate: rate, similarity: similarity)
  }
  /// The accepted take becomes part of the book's typical pace and voice; a take with a pace
  /// problem does not move the typical pace.
  public func record(_ verdict: Verdict) {
    if let similarity = verdict.similarity { similarities.append(similarity) }
    if let rate = verdict.rate, !verdict.problems.contains(where: { $0.contains("быстро") || $0.contains("медленно") }) {
      rates.append(rate)
    }
  }
  /// Typical pace from lines already in the cache (a book resumed after an interruption).
  public func remember(rate: Double) { rates.append(rate) }
  /// Fewer problems wins; at equal count the closer voice.
  public static func better(_ a: Verdict, than b: Verdict) -> Bool {
    if a.problems.count != b.problems.count { return a.problems.count < b.problems.count }
    return (a.similarity ?? 0) > (b.similarity ?? 0)
  }
}
