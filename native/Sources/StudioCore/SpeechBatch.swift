import Foundation

public enum SpeechBatch {
  /// Similarly sized lines share a batch: up to four short lines, or two long ones (memory
  /// grows with length). Each lane carries its own voice, so speakers may mix. Book order is
  /// restored by segment ID afterwards; scheduling never joins or rewrites text.
  public static func plan(_ rows: [Object], pending: Set<Int>, maximum: Int = 4) throws -> [[Int]] {
    guard (1...4).contains(maximum), pending.allSatisfy(rows.indices.contains) else {
      throw StudioError("Некорректный план пакетной озвучки")
    }
    func size(_ i: Int) -> Int { SpeechRecovery.text(NativeIO.string(rows[i]["tts_text"])).count }
    // Length class: short lines in 24-character steps, long ones in 48/64-character steps.
    func bucket(_ count: Int) -> Int? {
      count <= 96 ? max(0, count - 1) / 24 : count <= 240 ? 100 + (count - 1) / 48
        : count <= 480 ? 200 + (count - 1) / 64 : nil
    }
    var remaining = pending, jobs: [[Int]] = []
    for first in rows.indices where remaining.contains(first) {
      let count = size(first)
      let capacity = min(maximum, count <= 96 ? 4 : 2)
      var indices = [first]
      if capacity > 1, let group = bucket(count) {
        for i in (first + 1)..<min(rows.count, first + 65) where remaining.contains(i) {
          if bucket(size(i)) == group { indices.append(i) }
          if indices.count == capacity { break }
        }
      }
      jobs.append(indices)
      remaining.subtract(indices)
    }
    return jobs
  }

  /// Require exactly one nonempty WAV for every original segment, with no extras.
  public static func timeline(_ rows: [Object], frameCounts: [String: Int]) throws -> ([Object], Int) {
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
      let pauseMS = continuing
        ? (NativeIO.string(next["speaker"]) == NativeIO.string(row["speaker"]) ? 100 : 180) : requested
      let pause = max(0, min(3000, pauseMS)) * 24
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
