import Foundation

public enum NativeWAV {
  static func little<T: FixedWidthInteger>(_ value: T) -> Data {
    var v = value.littleEndian
    return withUnsafeBytes(of: &v) { Data($0) }
  }
  public static func header(frames: Int, sampleRate: Int = 24000) throws -> Data {
    guard frames >= 0, frames <= (Int(UInt32.max) - 36) / 4 else {
      throw StudioError("Книга превышает предел WAV (около 12 часов); разделите на части")
    }
    var data = Data("RIFF".utf8)
    data += little(UInt32(frames * 4 + 36))
    data += Data("WAVEfmt ".utf8)
    data += little(UInt32(16))
    data += little(UInt16(3))
    data += little(UInt16(1))
    data += little(UInt32(sampleRate))
    data += little(UInt32(sampleRate * 4))
    data += little(UInt16(4))
    data += little(UInt16(32))
    data += Data("data".utf8)
    data += little(UInt32(frames * 4))
    return data
  }
  public static func header64(frames: Int, sampleRate: Int = 24000) -> Data {
    var data = Data("RF64".utf8)
    data += little(UInt32.max)
    data += Data("WAVEds64".utf8)
    data += little(UInt32(28))
    data += little(UInt64(frames) * 4 + 72)
    data += little(UInt64(frames) * 4)
    data += little(UInt64(frames))
    data += little(UInt32(0))
    data += Data("fmt ".utf8)
    data += little(UInt32(16))
    data += little(UInt16(3))
    data += little(UInt16(1))
    data += little(UInt32(sampleRate))
    data += little(UInt32(sampleRate * 4))
    data += little(UInt16(4))
    data += little(UInt16(32))
    data += Data("data".utf8)
    data += little(UInt32.max)
    return data
  }
  public static func samples(_ data: Data) throws -> [Float] {
    guard data.count % 4 == 0 else { throw StudioError("Оборванные аудиоданные") }
    return data.withUnsafeBytes { bytes in
      stride(from: 0, to: data.count, by: 4).map {
        Float(
          bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
        )
      }
    }
  }
  public static func bytes(_ samples: [Float]) -> Data { samples.withUnsafeBytes { Data($0) } }
  public static func read(_ file: URL) throws -> [Float] {
    let data = try Data(contentsOf: file)
    guard data.count >= 44 else { throw StudioError("Некорректный рабочий WAV") }
    let rf64 = String(data: data[0..<4], encoding: .utf8) == "RF64"
    let offset = rf64 ? 80 : 44
    guard data.count >= offset,
      String(data: data[(offset - 8)..<(offset - 4)], encoding: .utf8) == "data"
    else { throw StudioError("Некорректные рабочие аудиоданные") }
    return try samples(Data(data.dropFirst(offset)))
  }
  public static func write(_ file: URL, _ samples: [Float], sampleRate: Int = 24000) throws {
    guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }),
      samples.contains(where: { abs($0) > 0.00001 })
    else { throw StudioError("Модель вернула пустое аудио") }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = try header(frames: samples.count, sampleRate: sampleRate)
    data += bytes(samples)
    try data.write(to: file, options: .atomic)
  }
  public static func trim(_ samples: [Float]) -> [Float] {
    guard let first = samples.firstIndex(where: { abs($0) > 0.003 }),
      let last = samples.lastIndex(where: { abs($0) > 0.003 })
    else { return [] }
    return Array(samples[max(0, first - 1200)..<min(samples.count, last + 1201)])
  }
}
public final class WAVMontage {
  let handle: FileHandle
  public private(set) var frames = 0
  public init(_ file: URL) throws {
    FileManager.default.createFile(atPath: file.path, contents: NativeWAV.header64(frames: 0))
    handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
  }
  deinit { try? handle.close() }
  public func append(_ samples: [Float]) throws {
    try handle.write(contentsOf: NativeWAV.bytes(samples))
    frames += samples.count
  }
  public func silence(_ count: Int) throws { try append([Float](repeating: 0, count: count)) }
  public func finish() throws {
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: NativeWAV.header64(frames: frames))
    try handle.close()
  }
}
public struct NativeAudio {
  public let ffmpeg: URL, ffprobe: URL
  public init(ffmpeg: URL, ffprobe: URL) {
    self.ffmpeg = ffmpeg
    self.ffprobe = ffprobe
  }
  @discardableResult public func ff(_ arguments: [String]) throws -> Data {
    try NativeIO.run(
      ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + arguments, events: true)
  }
  public func convert(_ file: URL) throws -> [Float] {
    try NativeWAV.samples(ff(["-i", file.path, "-ac", "1", "-ar", "24000", "-f", "f32le", "-"]))
  }
  public func duration(_ file: URL) throws -> Double {
    let data = try NativeIO.run(
      ffprobe,
      ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", file.path])
    guard
      let duration = Double(
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
      duration.isFinite
    else { throw StudioError("Не удалось прочитать длительность аудио") }
    return duration
  }
  public func measure(_ file: URL) throws -> (Double, Double) {
    let (_, stderr) = try NativeIO.capture(
      ffmpeg,
      [
        "-hide_banner", "-nostats", "-i", file.path, "-af",
        "loudnorm=I=-20:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-",
      ], events: true)
    return try Self.parseLoudness(stderr)
  }
  static func parseLoudness(_ stderr: Data) throws -> (Double, Double) {
    let text = String(data: stderr, encoding: .utf8) ?? ""
    // FFmpeg prints its output summary after the loudnorm JSON, even with -nostats.
    guard let end = text.lastIndex(of: "}"),
      let start = text[..<end].lastIndex(of: "{"),
      let data = String(text[start...end]).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? Object,
      let lufs = Double(NativeIO.string(object["input_i"])),
      let peak = Double(NativeIO.string(object["input_tp"])), lufs.isFinite, peak.isFinite
    else { throw StudioError("Не удалось измерить громкость роли") }
    return (lufs, peak)
  }
  static let minimumMeasuredFrames = 3 * 24000
  /// Common role level: -20 LUFS, lowered for loud peaks but never below -23 LUFS.
  /// Peaks still above -1.5 dBTP are caught by the limiter while encoding the M4B.
  static func loudnessTarget(_ measurements: [(Double, Double)]) -> Double {
    let peakSafe = measurements.map { $0.0 - 1.5 - $0.1 - 0.1 }.min() ?? -20
    return min(-20, max(-23, peakSafe))
  }
  public func normalize(project: URL, segments: [Object], timeline: [Object]) throws -> URL {
    let fm = FileManager.default
    let raw = project.appendingPathComponent("audio")
    let out = project.appendingPathComponent("audio-normalized")
    let roles = out.appendingPathComponent("measurements")
    try fm.createDirectory(at: roles, withIntermediateDirectories: true)
    let speakers = Set(segments.map { NativeIO.string($0["speaker"]) })
    var measurements: [String: (Double, Double)] = [:]
    for speaker in speakers.sorted() {
      NativeIO.stage("Измерение громкости · " + speaker)
      let file = roles.appendingPathComponent(speaker + ".wav")
      let montage = try WAVMontage(file)
      let parts = segments.filter { NativeIO.string($0["speaker"]) == speaker }.map {
        raw.appendingPathComponent("segments/" + NativeIO.string($0["id"]) + ".wav")
      }
      // EBU R128 integrated loudness is -inf below one 400 ms block. Repeating a short
      // role keeps its level and peak while giving the meter enough audio.
      repeat {
        let before = montage.frames
        for part in parts { try montage.append(NativeWAV.read(part)) }
        if montage.frames == before { break }
      } while montage.frames < Self.minimumMeasuredFrames
      try montage.finish()
      if let measured = try? measure(file) {
        measurements[speaker] = measured
      } else {
        NativeIO.emit("log", ["message": "Громкость роли не измерена, уровень оставлен без изменений · " + speaker])
      }
    }
    let target = Self.loudnessTarget(Array(measurements.values))
    let gains = measurements.mapValues { target - $0.0 }
    let montage = try WAVMontage(out.appendingPathComponent("sample.wav"))
    for (segment, row) in zip(segments, timeline) {
      let sid = NativeIO.string(segment["id"])
      let speaker = NativeIO.string(segment["speaker"])
      let gain = Float(pow(10, (gains[speaker] ?? 0) / 20))
      let samples = try NativeWAV.read(raw.appendingPathComponent("segments/" + sid + ".wav")).map {
        $0 * gain
      }
      try montage.append(samples)
      let pause = (row["pause_frames"] as? Int ?? 0)
      try montage.silence(pause)
    }
    try montage.finish()
    try NativeIO.write(out.appendingPathComponent("timeline.json"), ["segments": timeline])
    try NativeIO.write(
      out.appendingPathComponent("loudness.json"),
      [
        "method": "role-integrated EBU R128 + constant gain + output limiter", "actual_lufs": target,
        "true_peak_limit_db": -1.5, "gains_db": gains, "timing_unchanged": true,
      ])
    try fm.removeItem(at: roles)
    return out
  }
  public func mix(_ source: URL, music: URL, percent: Double, project: URL, total: Double) throws
    -> URL
  {
    guard percent.isFinite, (0...50).contains(percent) else {
      throw StudioError("Некорректная громкость музыки")
    }
    let out = project.appendingPathComponent("audio-music")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let mixed = out.appendingPathComponent("sample.wav")
    try ff([
      "-i", source.appendingPathComponent("sample.wav").path, "-stream_loop", "-1", "-i",
      music.path, "-filter_complex",
      "[1:a]aresample=24000,aformat=channel_layouts=mono,volume=\(percent/100)[music];[0:a][music]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.84:level=0:latency=1[out]",
      "-map", "[out]", "-t", String(total), "-ac", "1", "-ar", "24000", "-c:a", "pcm_f32le",
      "-rf64", "auto", mixed.path,
    ])
    guard abs(try duration(mixed) - total) < 0.002 else {
      throw StudioError("Наложение музыки изменило длительность")
    }
    try NativeIO.write(
      out.appendingPathComponent("music.json"),
      ["source": music.path, "volume_percent": percent, "loop": true, "timing_unchanged": true])
    try FileManager.default.copyItem(
      at: source.appendingPathComponent("timeline.json"),
      to: out.appendingPathComponent("timeline.json"))
    return out
  }
  public func package(
    project: URL, manifest: Object, source: Object, timeline: [Object], audio: URL
  ) throws -> URL {
    let out = project.appendingPathComponent("result")
    let fm = FileManager.default
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let book = NativeIO.object(manifest["book"])
    let segments = NativeIO.objects(manifest["segments"])
    let chapters = NativeIO.objects(source["chapters"])
    let total = timeline.last?["clip_end"] as? Double ?? 0
    func escape(_ text: String) -> String {
      var s = text
      for c in ["\\", "=", ";", "#"] { s = s.replacingOccurrences(of: c, with: "\\" + c) }
      return s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
    let title = escape(NativeIO.string(book["title"]))
    var metadata =
      ";FFMETADATA1\ntitle=\(title)\nalbum=\(title)\nartist=\(escape(NativeIO.string(book["author"])))\ngenre=Audiobook\n"
    var chapterStarts: [(String, Double)] = []
    for (s, row) in zip(segments, timeline) {
      let cid = NativeIO.string(s["chapter_id"])
      if chapterStarts.last?.0 != cid {
        chapterStarts.append((cid, row["audio_start"] as? Double ?? 0))
      }
    }
    for (i, chapter) in chapterStarts.enumerated() {
      let end = i + 1 < chapterStarts.count ? chapterStarts[i + 1].1 : total
      let name = NativeIO.string(
        chapters.first(where: { NativeIO.string($0["id"]) == chapter.0 })?["title"])
      metadata +=
        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int((chapter.1*1000).rounded()))\nEND=\(Int((end*1000).rounded()))\ntitle=\(escape(name))\n"
    }
    let meta = FileManager.default.temporaryDirectory.appendingPathComponent("chapters-" + UUID().uuidString + ".txt")
    defer { try? fm.removeItem(at: meta) }
    try Data(metadata.utf8).write(to: meta)
    let cover = NativeBook.cover(project.appendingPathComponent("book.epub"))
    let coverFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cover-" + UUID().uuidString + "." + (cover?.ext ?? "jpg"))
    defer { try? fm.removeItem(at: coverFile) }
    var arguments = [
      "-i", audio.appendingPathComponent("sample.wav").path, "-f", "ffmetadata", "-i", meta.path,
    ]
    var coverMapping: [String] = []
    if let cover {
      try cover.data.write(to: coverFile)
      arguments += ["-i", coverFile.path]
      coverMapping = ["-map", "2:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
    }
    let m4b = out.appendingPathComponent("audiobook.m4b")
    // The limiter is delay-compensated, so sentence timing for the EPUB overlay is unchanged.
    try ff(arguments + ["-map", "0:a:0"] + coverMapping + [
      "-map_metadata", "1", "-map_chapters", "1",
      "-af", "alimiter=limit=0.84:level=0:latency=1", "-c:a", "aac", "-b:a", "96k",
      "-movflags", "+faststart", m4b.path,
    ])
    guard abs(try duration(m4b) - total) < 0.15 else {
      throw StudioError("Длительность M4B не соответствует разметке")
    }
    try NativeBook.epub(
      manifest, source: source, timeline: timeline, audio: m4b,
      output: out.appendingPathComponent("audiobook.epub"), cover: cover)
    try NativeIO.write(
      out.appendingPathComponent("package-report.json"),
      [
        "state": "complete", "audio_seconds": total, "chapters": chapterStarts.count,
        "segments": segments.count, "engine": "native-swift-mlx",
      ])
    return out
  }
}
