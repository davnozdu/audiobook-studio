import Foundation

public enum SpeechBatch {
  /// Only short (≤96 characters), similarly sized lines share a batch; each lane carries its
  /// own voice, so speakers may mix. Long lines stay single: measured pairs read at the same
  /// speed as one line (1.20× vs 1.19×) with ~1 GB more peak memory. Book order is restored by
  /// segment ID afterwards; scheduling never joins or rewrites text.
  public static func plan(_ rows: [Object], pending: Set<Int>, maximum: Int = 4) throws -> [[Int]] {
    guard (1...4).contains(maximum), pending.allSatisfy(rows.indices.contains) else {
      throw StudioError("Некорректный план пакетной озвучки")
    }
    var remaining = pending, jobs: [[Int]] = []
    for first in rows.indices where remaining.contains(first) {
      let count = SpeechRecovery.text(NativeIO.string(rows[first]["tts_text"])).count
      var indices = [first]
      if maximum > 1, count <= 96 {
        for i in (first + 1)..<min(rows.count, first + 65) where remaining.contains(i) {
          let size = SpeechRecovery.text(NativeIO.string(rows[i]["tts_text"])).count
          if size <= 96, max(0, size - 1) / 24 == max(0, count - 1) / 24 { indices.append(i) }
          if indices.count == maximum { break }
        }
      }
      jobs.append(indices)
      remaining.subtract(indices)
    }
    return jobs
  }

  /// Silence added after a line, by the kind of boundary that follows it (milliseconds). About
  /// 0.3 s of the line's own edge silence (kept by trimming) is heard on top of these values.
  public struct Pauses: Equatable {
    public var comma = 100, sentence = 450, paragraph = 800, chapter = 2000
    public init() {}
    /// Values from the app settings; missing or out-of-range entries keep the defaults.
    public init(_ settings: Any?) {
      let o = NativeIO.object(settings)
      func value(_ key: String, _ fallback: Int) -> Int {
        guard let v = (o[key] as? NSNumber)?.intValue, (0...5000).contains(v) else { return fallback }
        return v
      }
      comma = value("comma", comma); sentence = value("sentence", sentence)
      paragraph = value("paragraph", paragraph); chapter = value("chapter", chapter)
    }
    /// Pause after `row` given the next row (nil at the end of the book).
    func after(_ row: Object, next: Object?) -> Int {
      guard let next else { return chapter }
      if NativeIO.string(next["chapter_id"]) != NativeIO.string(row["chapter_id"]) { return chapter }
      if NativeIO.string(next["paragraph_id"]) != NativeIO.string(row["paragraph_id"]) { return paragraph }
      let text = NativeIO.string(row["text"])
      if NativeBook.sentenceFinished(text) { return sentence }
      // A role change inside a sentence ("— сказал он, —") needs a little more air than a comma.
      return NativeIO.string(next["speaker"]) == NativeIO.string(row["speaker"]) ? comma : comma + 80
    }
  }

  /// Require exactly one nonempty WAV for every original segment, with no extras. With `pauses`
  /// the gaps follow the boundary kind and the user's settings; without, the stored per-line
  /// values (older projects and tests).
  public static func timeline(_ rows: [Object], frameCounts: [String: Int], pauses: Pauses? = nil) throws -> ([Object], Int) {
    let ids = rows.map { NativeIO.string($0["id"]) }
    guard !rows.isEmpty, rows.allSatisfy({ !NativeIO.string($0["speaker"]).isEmpty }),
      Set(ids).count == ids.count, !ids.contains(""), Set(ids) == Set(frameCounts.keys),
      frameCounts.values.allSatisfy({ $0 > 0 }) else {
      throw StudioError("Пакетная озвучка неполна: отсутствуют, повторяются или пусты реплики")
    }
    var frames = 0, timeline: [Object] = []
    for (i, row) in rows.enumerated() {
      let begin = Double(frames) / 24000
      frames += frameCounts[ids[i]]!
      let finish = Double(frames) / 24000
      let requested = row["pause_after_ms"] as? Int ?? 450
      let next = i + 1 < rows.count ? rows[i + 1] : [:]
      let continuing = NativeIO.string(next["paragraph_id"]) == NativeIO.string(row["paragraph_id"])
        && !NativeBook.sentenceFinished(NativeIO.string(row["text"])) && requested == 450
      let pauseMS = pauses.map { $0.after(row, next: i + 1 < rows.count ? rows[i + 1] : nil) }
        ?? (continuing ? (NativeIO.string(next["speaker"]) == NativeIO.string(row["speaker"]) ? 100 : 180) : requested)
      let pause = max(0, min(5000, pauseMS)) * 24
      frames += pause
      timeline.append(["segment_id": ids[i], "speaker": row["speaker"]!,
        "audio_start": begin, "audio_end": finish, "clip_end": Double(frames) / 24000,
        "pause_frames": pause])
    }
    return (timeline, frames)
  }

  public static func verifyOrder(_ rows: [Object], timeline: [Object]) throws {
    guard !rows.isEmpty,
      rows.map({ NativeIO.string($0["id"]) }) == timeline.map({ NativeIO.string($0["segment_id"]) }),
      Set(rows.map { NativeIO.string($0["id"]) }).count == rows.count else {
      throw StudioError("Аудио не покрывает все реплики книги в исходном порядке")
    }
    var cursor: Double = 0
    for (row, clip) in zip(rows, timeline) {
      guard NativeIO.string(row["speaker"]) == NativeIO.string(clip["speaker"]),
        let start = clip["audio_start"] as? Double, let end = clip["audio_end"] as? Double,
        let finish = clip["clip_end"] as? Double,
        start.isFinite, end.isFinite, finish.isFinite,
        abs(start - cursor) < 0.00001, end > start, finish >= end else {
        throw StudioError("Повреждена последовательность аудио · " + NativeIO.string(row["id"]))
      }
      cursor = finish
    }
  }
}
