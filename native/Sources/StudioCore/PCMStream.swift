import Foundation
import Darwin

extension NativeIO {
  /// Bounded stdin pipe; stderr is spooled separately so neither pipe deadlocks.
  /// Closing stdin signals EOF. A failed producer terminates the consumer and
  /// never returns a successful result, even if FFmpeg wrote a partial file.
  /// SIGTERM, then SIGKILL if the consumer is still alive after `grace` seconds: a hung or
  /// TERM-ignoring child must not keep the failed build waiting forever.
  static func stop(_ process: Process, grace: TimeInterval) {
    if process.isRunning { process.terminate() }
    let deadline = Date().addingTimeInterval(grace)
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
  public static func stream(_ executable: URL, _ arguments: [String],
    produce: (FileHandle) throws -> Void) throws -> Data {
    let process = Process(), input = Pipe()
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-stream-" + UUID().uuidString)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let errors = try FileHandle(forWritingTo: log)
    defer {
      try? errors.close(); try? input.fileHandleForWriting.close()
      try? input.fileHandleForReading.close(); try? FileManager.default.removeItem(at: log)
    }
    // Report EPIPE as a Swift error rather than terminating the engine on SIGPIPE.
    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw StudioError("Не удалось подготовить поток аудио")
    }
    process.executableURL = executable; process.arguments = arguments
    process.standardInput = input.fileHandleForReading
    process.standardOutput = FileHandle.nullDevice; process.standardError = errors
    try process.run()
    emit("child", ["pid": process.processIdentifier])
    defer { emit("child", ["pid": 0]) }
    try input.fileHandleForReading.close()
    do {
      try produce(input.fileHandleForWriting)
      try input.fileHandleForWriting.close()
    } catch {
      try? input.fileHandleForWriting.close()
      stop(process, grace: 5)
      throw error
    }
    process.waitUntilExit()
    try errors.close()
    let reader = try FileHandle(forReadingFrom: log)
    defer { try? reader.close() }
    let size = try reader.seekToEnd()
    try reader.seek(toOffset: size > 65536 ? size - 65536 : 0)
    let stderr = try reader.readToEnd() ?? Data()
    guard process.terminationStatus == 0 else {
      throw StudioError(executable.lastPathComponent + ": "
        + String((String(data: stderr, encoding: .utf8) ?? "").suffix(1500)))
    }
    return stderr
  }
}

extension NativeAudio {
  /// Package small deterministic signal fixtures with the shipped FFmpeg. This
  /// checks both music paths and EPUB/cleanup; it is not voice generation.
  public func streamingSelfCheck() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let rows: [Object] = (0..<3).map { i in
      ["id": "s\(i)", "speaker": "v\(i % 2)", "text": "Проверка.", "tts_text": "Проверка.",
       "paragraph_id": "p\(i)", "chapter_id": "ch1", "pause_after_ms": 100,
       "source": ["char_start": 0, "char_end": 9]]
    }
    var counts: [String: Int] = [:]
    for (i, row) in rows.enumerated() {
      let id = NativeIO.string(row["id"])
      let samples = (0..<(24000 + i * 12000)).map { Float(0.1 * sin(Double($0) * 0.031)) }
      counts[id] = samples.count
      try SpeechCache.save(root.appendingPathComponent("audio/segments/" + id + ".spcm"), samples: samples, signature: id)
    }
    let (timeline, _) = try SpeechBatch.timeline(rows, frameCounts: counts)
    let gains = try streamingGains(project: root, segments: rows)
    guard gains.count == 2 else { throw StudioError("Потоковое измерение громкости не работает") }
    let music = root.appendingPathComponent("fixture-music.wav")
    try NativeWAV.write(music, (0..<12000).map { Float(0.03 * cos(Double($0) * 0.019)) })
    let manifest: Object = ["book": ["title": "Проверка", "author": "Studio"], "segments": rows]
    let source: Object = ["chapters": [["id": "ch1", "title": "Глава"]],
      "paragraphs": rows.map { ["id": $0["paragraph_id"]!, "chapter_id": "ch1", "text": "Проверка."] }]
    for enabled in [false, true] {
      let result = try package(project: root, manifest: manifest, source: source, timeline: timeline,
        gains: gains, music: enabled ? music : nil, musicPercent: 5)
      let m4b = result.appendingPathComponent("audiobook.m4b")
      let decoded = try convert(m4b)
      let total = timeline.last?["clip_end"] as! Double
      guard abs(Double(decoded.count) / 24000 - total) < 0.15 else {
        throw StudioError("Потоковая сборка изменила длину декодированного AAC")
      }
      let parsed = try NativeBook.read(result.appendingPathComponent("audiobook.epub"))
      guard NativeIO.objects(parsed["paragraphs"]).count == rows.count else {
        throw StudioError("Потоковая сборка потеряла текст EPUB")
      }
    }
    let exported = root.appendingPathComponent("export")
    try FileManager.default.copyItem(at: root.appendingPathComponent("result"), to: exported)
    guard try NativeProject.cleanupCompletedSpeech(root, exported: exported).isEmpty,
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("audio/segments").path) else {
      throw StudioError("Очистка временного аудио не работает")
    }
    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("audio-normalized").path),
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("audio-music").path) else {
      throw StudioError("Потоковая сборка создала полный рабочий WAV")
    }
  }
  /// Role measurements also use stdin: no whole-role WAV is stored on disk.
  public func streamingGains(project: URL, segments: [Object]) throws -> [String: Double] {
    var measurements: [String: (Double, Double)] = [:]
    let groups = Dictionary(grouping: segments) { NativeIO.string($0["speaker"]) }
    for speaker in groups.keys.sorted() {
      try Task.checkCancellation()
      NativeIO.stage("Потоковое измерение громкости · " + speaker)
      let parts = groups[speaker]!.map { SpeechCache.segmentURL(project, id: NativeIO.string($0["id"])) }
      do {
        let stderr = try NativeIO.stream(ffmpeg, ["-hide_banner", "-nostats",
          "-f", "f32le", "-ar", "24000", "-ac", "1", "-i", "pipe:0", "-af",
          "loudnorm=I=-20:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"]) { sink in
          var frames = 0
          repeat {
            for part in parts {
              try Task.checkCancellation()
              let samples = try SpeechCache.readAudio(part)
              guard !samples.isEmpty else { throw StudioError("Пустая реплика при измерении громкости") }
              try sink.write(contentsOf: NativeWAV.bytes(samples)); frames += samples.count
            }
          } while frames < Self.minimumMeasuredFrames
        }
        measurements[speaker] = try Self.parseLoudness(stderr)
      } catch {
        try Task.checkCancellation()
        NativeIO.emit("log", ["message": "Громкость роли не измерена, уровень оставлен без изменений · " + speaker])
      }
    }
    let target = Self.loudnessTarget(Array(measurements.values))
    let gains = measurements.mapValues { target - $0.0 }
    try NativeIO.write(project.appendingPathComponent("audio/loudness.json"), [
      "method": "streamed role-integrated EBU R128 + constant gain + output limiter",
      "actual_lufs": target, "true_peak_limit_db": -1.5, "gains_db": gains, "timing_unchanged": true])
    return gains
  }

  /// Stream exact original-order samples and pauses. Only one utterance occupies
  /// memory and the consumer's bounded pipe applies backpressure.
  @discardableResult public static func streamMontage(project: URL, segments: [Object],
    timeline: [Object], gains: [String: Double], write: (Data) throws -> Void) throws -> Int {
    try SpeechBatch.verifyOrder(segments, timeline: timeline)
    var frames = 0
    for (segment, clip) in zip(segments, timeline) {
      try Task.checkCancellation()
      let id = NativeIO.string(segment["id"]), speaker = NativeIO.string(segment["speaker"])
      let gain = Float(pow(10, (gains[speaker] ?? 0) / 20))
      guard gain.isFinite else { throw StudioError("Некорректный уровень громкости · " + speaker) }
      let samples = try SpeechCache.readAudio(SpeechCache.segmentURL(project, id: id)).map { $0 * gain }
      let expected = (clip["audio_end"] as! Double) - (clip["audio_start"] as! Double)
      guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }),
        abs(Double(samples.count) / 24000 - expected) < 0.00001 else {
        throw StudioError("Длина аудио не соответствует реплике · " + id)
      }
      try write(NativeWAV.bytes(samples)); frames += samples.count
      let pause = clip["pause_frames"] as? Int ?? 0
      guard (0...SpeechBatch.maxPauseMS * 24).contains(pause),
        abs(Double(pause) / 24000 - ((clip["clip_end"] as! Double) - (clip["audio_end"] as! Double))) < 0.00001 else {
        throw StudioError("Некорректная пауза · " + id)
      }
      if pause > 0 { try write(Data(repeating: 0, count: pause * 4)); frames += pause }
    }
    guard abs(Double(frames) / 24000 - (timeline.last?["clip_end"] as! Double)) < 0.00001 else {
      throw StudioError("Потоковый монтаж потерял конец книги")
    }
    return frames
  }
}
