import XCTest

@testable import StudioCore

final class CoreTests: XCTestCase {
  func testUnicodeNumbersAndOverlongOrdinalNeverTrap() throws {
    let ru = try RussianText(rules)
    for (unicode, ascii) in [("١٢:٣٠", "12:30"), ("٢٥%", "25%"), ("٢١.٠١.٢٠٢٤", "21.01.2024"), ("Стоимость １２ рублей.", "Стоимость 12 рублей."), ("Номер ١٢٣٤٥.", "Номер 12345.")] {
      XCTAssertEqual(try ru.normalize(unicode), try ru.normalize(ascii))
    }
    XCTAssertEqual(try ru.normalize("https://example.invalid/١٢"), "https://example.invalid/١٢")
    XCTAssertThrowsError(try ru.normalize("999999999999999999999999999-й"))
    XCTAssertThrowsError(try ru.integer(Int.min))
    // An unknown number format is read as it stands instead of stopping the book.
    XCTAssertEqual(try ru.normalize("Дом 2а, пункт 1.2.3."), "Дом два а, пункт один.два.три.")
    XCTAssertTrue(NativeIO.regex("\\d", try ru.normalize("В 25:70 и 31.02.2020")).isEmpty)
    XCTAssertEqual(RussianText.plural(Int.min, ["a", "b", "c"]), "c")
  }
  func testSACCOverflowIsRejectedBeforeArithmetic() throws {
    let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: file) }
    var data = Data("SACC".utf8)
    data += NativeWAV.little(UInt32(1)); data += NativeWAV.little(UInt32(1))
    data += NativeWAV.little(UInt64(Int.max)); data += NativeWAV.little(UInt64(Int.max))
    try data.write(to: file)
    XCTAssertThrowsError(try AccentDictionary(file))
  }
  func testPCMDeclaredSizeBoundsDecompression() throws {
    let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: file) }
    for (version, mode, algorithm) in [("SPC2", UInt8(3), NSData.CompressionAlgorithm.lzma), ("SPC1", UInt8(1), NSData.CompressionAlgorithm.lzfse)] {
      var data = Data(version.utf8); data += NativeWAV.little(UInt32(24000)); data += NativeWAV.little(UInt64(1)); data.append(mode)
      data += try (Data(count: 4 * 1024 * 1024) as NSData).compressed(using: algorithm) as Data
      try data.write(to: file)
      XCTAssertThrowsError(try SpeechPCM.read(file))
    }
  }
  func testArchiveBudgetRejectsBeforeExtraction() throws {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source"), archive = root.appendingPathComponent("book.zip"), output = root.appendingPathComponent("output")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(count: 2 * 1024 * 1024).write(to: source.appendingPathComponent("large"))
    try NativeIO.zip(source, to: archive)
    XCTAssertThrowsError(try NativeIO.unpack(archive, to: output, budget: ArchiveBudget(expandedBytes: 1024, memberBytes: 1024, members: 100)))
    XCTAssertFalse(fm.fileExists(atPath: output.path))
    XCTAssertThrowsError(try NativeIO.archiveSize(archive, budget: ArchiveBudget(expandedBytes: 4 * 1024 * 1024, memberBytes: 4 * 1024 * 1024, members: 0)))
    try NativeIO.unpack(archive, to: output)
    XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("large")).count, 2 * 1024 * 1024)
  }
  func testZIP64ProjectBudgetReadsLargeDeclaredSizes() throws {
    let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: file) }
    let large: UInt64 = 5 * 1024 * 1024 * 1024
    var directory = Data(count: 46)
    directory.replaceSubrange(0..<4, with: NativeWAV.little(UInt32(0x02014b50)))
    directory.replaceSubrange(24..<28, with: NativeWAV.little(UInt32.max))
    directory.replaceSubrange(28..<30, with: NativeWAV.little(UInt16(1)))
    directory.replaceSubrange(30..<32, with: NativeWAV.little(UInt16(12)))
    directory.append(97); directory += NativeWAV.little(UInt16(1)); directory += NativeWAV.little(UInt16(8)); directory += NativeWAV.little(large)
    var record = Data(count: 56)
    record.replaceSubrange(0..<4, with: NativeWAV.little(UInt32(0x06064b50)))
    record.replaceSubrange(4..<12, with: NativeWAV.little(UInt64(44)))
    record.replaceSubrange(24..<32, with: NativeWAV.little(UInt64(1)))
    record.replaceSubrange(32..<40, with: NativeWAV.little(UInt64(1)))
    record.replaceSubrange(40..<48, with: NativeWAV.little(UInt64(directory.count)))
    var locator = NativeWAV.little(UInt32(0x07064b50)); locator += NativeWAV.little(UInt32(0)); locator += NativeWAV.little(UInt64(directory.count)); locator += NativeWAV.little(UInt32(1))
    var end = Data(count: 22)
    end.replaceSubrange(0..<4, with: NativeWAV.little(UInt32(0x06054b50)))
    end.replaceSubrange(8..<10, with: NativeWAV.little(UInt16.max)); end.replaceSubrange(10..<12, with: NativeWAV.little(UInt16.max))
    end.replaceSubrange(12..<16, with: NativeWAV.little(UInt32.max)); end.replaceSubrange(16..<20, with: NativeWAV.little(UInt32.max))
    try (directory + record + locator + end).write(to: file)
    XCTAssertEqual(try NativeIO.archiveSize(file, budget: .project), large)
    XCTAssertThrowsError(try NativeIO.archiveSize(file, budget: ArchiveBudget(expandedBytes: large, memberBytes: large - 1, members: 10)))
  }
  func testForgedZIPSizeCannotExpandUnbounded() throws {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source"), archive = root.appendingPathComponent("bad.zip"), output = root.appendingPathComponent("output")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(count: 2 * 1024 * 1024).write(to: source.appendingPathComponent("large"))
    try NativeIO.zip(source, to: archive)
    var data = try Data(contentsOf: archive)
    // Lie only in the central directory; actual compressed body still expands to 2 MiB.
    var index = 0
    while index + 46 <= data.count {
      if data[index..<index + 4] == Data([0x50, 0x4b, 0x01, 0x02]),
         data[index + 24..<index + 28] == NativeWAV.little(UInt32(2 * 1024 * 1024)) {
        data.replaceSubrange(index + 24..<index + 28, with: NativeWAV.little(UInt32(1)))
      }
      index += 1
    }
    try data.write(to: archive)
    XCTAssertThrowsError(try NativeIO.unpack(archive, to: output))
    XCTAssertFalse(fm.fileExists(atPath: output.path))
  }
  func testProjectRoundTripNeverRewritesBookText() throws {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let project = root.appendingPathComponent("original"), archive = root.appendingPathComponent("book.studioproject")
    try fm.createDirectory(at: project, withIntermediateDirectories: true)
    let text = "studio-project://example"
    try Data("book".utf8).write(to: project.appendingPathComponent("book.epub"))
    let paragraph: Object = ["id": "p1", "chapter_id": "c1", "text": text]
    let segment: Object = ["id": "s1", "paragraph_id": "p1", "chapter_id": "c1", "speaker": "v1", "text": text, "source": ["char_start": 0, "char_end": text.unicodeScalars.count]]
    try NativeIO.write(project.appendingPathComponent("roles/source.json"), ["chapters": [["id": "c1"]], "paragraphs": [paragraph]])
    try NativeIO.write(project.appendingPathComponent("roles/manifest.json"), ["book": ["input_sha256": try NativeIO.hashFile(project.appendingPathComponent("book.epub"))], "voices": [["id": "v1"]], "segments": [segment]])
    let music = project.appendingPathComponent("music.wav"); try Data([1]).write(to: music)
    try NativeProject.export(project, destination: archive, settings: ["music": music.path, "description": "studio-project://unchanged"])
    let opened = try NativeProject.open(archive, output: root)
    let (manifest, source) = try NativeProject.verify(opened)
    XCTAssertEqual(NativeIO.string(NativeIO.objects(source["paragraphs"])[0]["text"]), text)
    XCTAssertEqual(NativeIO.string(NativeIO.objects(manifest["segments"])[0]["text"]), text)
    let settings = try NativeIO.load(opened.appendingPathComponent("studio-settings.json"))
    XCTAssertEqual(settings["description"] as? String, "studio-project://unchanged")
    XCTAssertTrue(fm.fileExists(atPath: NativeIO.string(settings["music"])), "music=\(settings["music"] ?? "missing"), root=\(opened.path)")
  }
  func testExportNamesFitFilesystemBytes() throws {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let title = String(repeating: "👨‍👩‍👧‍👦", count: 40)
    let base = NativeProject.exportBase(["book": ["title": title]])
    XCTAssertTrue(base.utf8.count <= 180)
    try Data([1]).write(to: root.appendingPathComponent(base + ".m4b"))
    let projectName = NativeIO.fileStem(String(repeating: "a", count: 250)) + "-12345678"
    try fm.createDirectory(at: root.appendingPathComponent(projectName), withIntermediateDirectories: true)
  }
  func stressFixture(_ root: URL, script: String) throws -> URL {
    try NativeIO.write(root.appendingPathComponent("silero/metadata.json"), [:])
    try NativeIO.write(root.appendingPathComponent("resources/stress_dictionary.json"), [:])
    var data = Data("SACC".utf8); data += NativeWAV.little(UInt32(1)); data += NativeWAV.little(UInt32(0)); data += NativeWAV.little(UInt64(28)); data += NativeWAV.little(UInt64(28))
    try data.write(to: root.appendingPathComponent("resources/russian_accents_full.sacc"))
    let helper = root.appendingPathComponent("helper")
    try ("#!/bin/sh\n" + script).write(to: helper, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    return helper
  }
  func testStressRequestAndShutdownHaveDeadlines() throws {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    var helper = try stressFixture(root, script: "trap '' TERM\nread line\nprintf '{}\\n'\nwhile :; do /bin/sleep 1; done\n")
    let start = Date()
    do { let stress = try NativeStress(resources: root, helper: helper); _ = try stress.request(["test": 1]) }
    XCTAssertTrue(Date().timeIntervalSince(start) < 4)
    helper = try stressFixture(root, script: "trap '' TERM\nread line\nwhile :; do /bin/sleep 1; done\n")
    let stress = try NativeStress(resources: root, helper: helper)
    let before = Date()
    XCTAssertThrowsError(try stress.request(["test": 1], timeout: 0.1))
    XCTAssertTrue(Date().timeIntervalSince(before) < 2)
  }
  func testPCMStreamPreservesExactOrderPausesAndFinalSamples() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let rows: [Object] = [
      ["id": "first", "speaker": "v", "text": "Первая.", "pause_after_ms": 100],
      ["id": "last", "speaker": "v", "text": "Последняя.", "pause_after_ms": 0]]
    let first: [Float] = [0.1, -0.2, 0.3], last: [Float] = [0.4, -0.5, 0.625, 0.00001]
    for (id, samples) in [("last", last), ("first", first)] {
      try SpeechCache.save(root.appendingPathComponent("audio/segments/" + id + ".spcm"), samples: samples, signature: id)
    }
    let (timeline, frames) = try SpeechBatch.timeline(rows, frameCounts: ["first": first.count, "last": last.count])
    var bytes = Data()
    let written = try NativeAudio.streamMontage(project: root, segments: rows, timeline: timeline, gains: [:]) { bytes += $0 }
    XCTAssertEqual(written, frames)
    // The cache keeps 16-bit PCM: the montage carries exactly the stored values, in order, with the pause.
    func stored(_ s: [Float]) -> [Float] { SpeechPCM.quantize(s).map { Float($0) / 32767 } }
    XCTAssertEqual(bytes, NativeWAV.bytes(stored(first)) + Data(repeating: 0, count: 2400 * 4) + NativeWAV.bytes(stored(last)))
    XCTAssertThrowsError(try NativeAudio.streamMontage(project: root, segments: rows, timeline: timeline, gains: [:]) { _ in throw StudioError("consumer failed") })
    var broken = timeline; broken[0]["pause_frames"] = 0
    XCTAssertThrowsError(try NativeAudio.streamMontage(project: root, segments: rows, timeline: broken, gains: [:]) { _ in })
  }
  func testStreamProcessHandlesBackpressureProducerAndConsumerFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data(repeating: 37, count: 1024 * 1024)
    let out = root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try NativeIO.stream(URL(fileURLWithPath: "/usr/bin/tee"), [out.path]) { try $0.write(contentsOf: data) }
    XCTAssertEqual(try Data(contentsOf: out), data)
    XCTAssertThrowsError(try NativeIO.stream(URL(fileURLWithPath: "/usr/bin/false"), []) { try $0.write(contentsOf: data) })
    XCTAssertThrowsError(try NativeIO.stream(URL(fileURLWithPath: "/usr/bin/tee"), [out.path]) { _ in throw StudioError("producer failed") })
    // A consumer that ignores SIGTERM is killed after the grace period instead of hanging the build.
    let started = Date()
    XCTAssertThrowsError(try NativeIO.stream(URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; while :; do sleep 0.1; done"]) { _ in
      throw StudioError("producer failed") })
    XCTAssertTrue(Date().timeIntervalSince(started) < 15)
  }
  func testTenAndTwentyHourBooksKeepAllSegmentsAnd64BitSizes() throws {
    for hours in [10, 20] {
      let rows: [Object] = (0..<(hours * 720)).map { i in
        ["id": "s\(i)", "speaker": "v\(i % 7)", "text": "Реплика.", "tts_text": "Реплика.", "pause_after_ms": 0]
      }
      let jobs = try SpeechBatch.plan(rows, pending: Set(rows.indices))
      XCTAssertEqual(jobs.flatMap { $0 }.sorted(), Array(rows.indices))
      let counts = Dictionary(uniqueKeysWithValues: rows.map { (NativeIO.string($0["id"]), 120000) })
      let (timeline, frames) = try SpeechBatch.timeline(rows, frameCounts: counts)
      try SpeechBatch.verifyOrder(rows, timeline: timeline)
      XCTAssertEqual(frames, hours * 3600 * 24000)
      XCTAssertEqual(timeline.last?["audio_end"] as? Double, Double(hours * 3600))
      let header = NativeWAV.header64(frames: frames)
      XCTAssertEqual(header.count, 80)
      let size = header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 28, as: UInt64.self)) }
      XCTAssertEqual(size, UInt64(hours) * 3600 * 24000 * 4)
      if hours == 20 { XCTAssertTrue(size > UInt64(UInt32.max)) }
    }
  }
  func testCompressedSpeechIsLossless16BitAndCorruptionIsRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("segment.spcm")
    // Speech-like signal with extremes: 16-bit values come back exactly, the rest within ½ LSB.
    var samples: [Float] = (0..<48000).map { (i: Int) -> Float in
      let t = Double(i)
      let low: Double = sin(t * 0.03) * 0.6
      let high: Double = sin(t * 0.31) * 0.2
      return Float(low + high)
    }
    samples += [0, -0.0, Float.leastNonzeroMagnitude, -0.125, 1.25, -1.25, 0.00002, -0.00002]
    try SpeechCache.save(file, samples: samples, signature: "test")
    let restored = try SpeechPCM.read(file)
    XCTAssertEqual(restored.count, samples.count)
    XCTAssertEqual(SpeechPCM.quantize(restored), SpeechPCM.quantize(samples))
    XCTAssertTrue(zip(restored, samples).allSatisfy { abs($0 - max(-1, min(1, $1))) <= 0.5 / 32767 + 1e-7 })
    XCTAssertEqual(SpeechCache.load(file, signature: "test"), restored)
    // About a third of the former Float32 size on a smooth signal.
    XCTAssertTrue(try Data(contentsOf: file).count < samples.count * 4 / 3)
    // The former exact Float32 container is still readable.
    let legacy = root.appendingPathComponent("legacy.spcm")
    var old = Data("SPC1".utf8); old += NativeWAV.little(UInt32(24000)); old += NativeWAV.little(UInt64(3)); old.append(0)
    old += NativeWAV.bytes([0.5, -0.25, 0.125]); try old.write(to: legacy)
    XCTAssertEqual(try SpeechPCM.read(legacy), [0.5, -0.25, 0.125])
    try Data("truncated".utf8).write(to: file)
    XCTAssertNil(SpeechCache.load(file, signature: "test"))
    XCTAssertThrowsError(try SpeechPCM.read(file))
  }
  func testSuccessfulCleanupRequiresVerifiedExportAndKeepsSources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project"), exported = root.appendingPathComponent("export")
    let speech = project.appendingPathComponent("audio/segments/s1.spcm")
    let keep = ["book.epub", "roles/manifest.json", "voices/narrator.wav", "audio/timeline.json", "run.log"]
    for name in keep + ["audio/segments/s1.spcm", "audio/segments/s1.json", "audio-normalized/sample.wav"] {
      let file = project.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: file)
    }
    XCTAssertThrowsError(try NativeProject.cleanupCompletedSpeech(project, exported: exported))
    XCTAssertTrue(FileManager.default.fileExists(atPath: speech.path))
    let result = project.appendingPathComponent("result")
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    for name in ["audiobook.m4b", "audiobook.epub"] { try Data("result".utf8).write(to: result.appendingPathComponent(name)) }
    try NativeIO.write(result.appendingPathComponent("package-report.json"), ["state": "complete"])
    try FileManager.default.copyItem(at: result, to: exported)
    let m4b = exported.appendingPathComponent("audiobook.m4b")
    try Data("broken".utf8).write(to: m4b)
    XCTAssertThrowsError(try NativeProject.cleanupCompletedSpeech(project, exported: exported))
    XCTAssertTrue(FileManager.default.fileExists(atPath: speech.path))
    try Data("result".utf8).write(to: m4b)
    XCTAssertTrue(try NativeProject.cleanupCompletedSpeech(project, exported: exported).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: speech.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("audio-normalized").path))
    for name in keep { XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path)) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: m4b.path))
    XCTAssertTrue(try NativeProject.cleanupCompletedSpeech(project, exported: exported).isEmpty)
    // Saved from the window the files carry the book's author and title.
    let manifest: Object = ["book": ["title": "Сон смешного человека", "author": "Федор Михайлович Достоевский"]]
    let base = NativeProject.exportBase(manifest)
    XCTAssertEqual(base, "Федор Михайлович Достоевский - Сон смешного человека")
    XCTAssertEqual(NativeProject.exportBase(["book": ["title": "A/B: C?", "author": ""]]), "AB C")
    let names = NativeProject.exportNames(base: base)
    XCTAssertEqual(names["audiobook.m4b"], base + ".m4b"); XCTAssertEqual(names["package-report.json"], "package-report.json")
    for (from, to) in names where from != to {
      try FileManager.default.moveItem(at: exported.appendingPathComponent(from), to: exported.appendingPathComponent(to))
    }
    XCTAssertThrowsError(try NativeProject.cleanupCompletedSpeech(project, exported: exported))
    XCTAssertTrue(try NativeProject.cleanupCompletedSpeech(project, exported: exported, names: names).isEmpty)
  }
  func testBatchPlannerKeepsEveryIDAndSpeaker() throws {
    let rows: [Object] = (0..<15).map { i in
      ["id": "s\(i)", "speaker": i % 2 == 0 ? "hero" : "narrator",
       "tts_text": i == 7 ? String(repeating: "длинная ", count: 50) : "Короткая реплика."]
    }
    let pending = Set(rows.indices).subtracting([3, 9])
    let jobs = try SpeechBatch.plan(rows, pending: pending)
    XCTAssertEqual(Set(jobs.flatMap { $0 }), pending)
    XCTAssertEqual(jobs.flatMap { $0 }.count, pending.count)
    XCTAssertTrue(jobs.allSatisfy { (1...4).contains($0.count) })
    // Voices may mix within a batch; only similarly sized short lines share one.
    XCTAssertTrue(jobs.contains { Set($0.map { NativeIO.string(rows[$0]["speaker"]) }).count == 2 })
    XCTAssertTrue(jobs.filter { $0.count > 1 }.allSatisfy { $0.allSatisfy { SpeechRecovery.text(NativeIO.string(rows[$0]["tts_text"])).count <= 96 } })
    // Long lines stay single even with an equally long neighbour.
    let long: [Object] = [200, 210, 205, 120, 600].enumerated().map { i, n in
      ["id": "l\(i)", "speaker": "v\(i % 2)", "tts_text": String(repeating: "а", count: n)]
    }
    XCTAssertEqual(try SpeechBatch.plan(long, pending: Set(long.indices)), [[0], [1], [2], [3], [4]])
    XCTAssertEqual(jobs.first(where: { $0.contains(7) }), [7])
    XCTAssertTrue(try SpeechBatch.plan(rows, pending: pending, maximum: 1).allSatisfy { $0.count == 1 })
    XCTAssertThrowsError(try SpeechBatch.plan(rows, pending: [100]))
  }
  func testNarratorDirectionKeepsCancellation() async throws {
    let task = Task {
      try await NativeDirector([:]).narratorProfile(["id": "narrator"], source: ["title": "К", "author": "А",
        "paragraphs": [["id": "p1", "text": "Текст."]]], paragraphIDs: ["p1"])
    }
    task.cancel()
    do { _ = try await task.value; XCTFail("cancellation became a template fallback") } catch is CancellationError {}
  }
  func testSampleRetriesWhenModelThrows() async throws {
    var calls = 0
    let samples = try await SpeechRecovery.generate(text: "Проба голоса.", seed: 5, label: "образец") { _, _ in
      calls += 1
      if calls < 3 { throw StudioError("Qwen reached the audio token limit before finishing the utterance") }
      return [Float](repeating: 0.1, count: 4800) + [Float](repeating: 0, count: 2400)
    }
    XCTAssertEqual(calls, 3); XCTAssertFalse(samples.isEmpty)
    var cancelled = 0
    do {
      _ = try await SpeechRecovery.generate(text: "Проба.", seed: 5, label: "образец") { _, _ in cancelled += 1; throw CancellationError() }
      XCTFail("cancellation was swallowed")
    } catch is CancellationError {}
    XCTAssertEqual(cancelled, 1)
  }
  func testMannerSamplesAreMeasuredAgainstTheCalmVoice() throws {
    // Voiced speech-like signal: a tone with harmonics in 0.5 s syllables separated by short gaps.
    func voice(_ hz: Double, _ amplitude: Float, seconds: Double = 3) -> [Float] {
      (0..<Int(seconds * 24000)).map { i in
        let t = Double(i) / 24000
        let on = (i / 6000) % 2 == 0 || (i % 12000) < 10000
        let v = sin(2 * .pi * hz * t) + 0.5 * sin(4 * .pi * hz * t) + 0.25 * sin(6 * .pi * hz * t)
        return on ? amplitude * Float(v) : 0
      }
    }
    let text = String(repeating: "слово ", count: 6)
    let calm = VoiceAcoustics.measure(voice(100, 0.2), text: text)!
    XCTAssertEqual(calm.pitch, 100, accuracy: 3)
    XCTAssertTrue(calm.voiced > 0.8)
    let shout = VoiceAcoustics.measure(voice(170, 0.5), text: text)!.change(from: calm)
    XCTAssertEqual(shout.pitch, 12 * log2(1.7), accuracy: 0.5)
    XCTAssertEqual(shout.level, 20 * log10(2.5), accuracy: 0.5)
    XCTAssertTrue(VoiceAcoustics.strength("shouting", shout).audible)
    XCTAssertFalse(VoiceAcoustics.strength("sad", shout).audible)
    // The same voice "excited" but slower: the pitch alone is not enough.
    let slow = VoiceAcoustics.measure(voice(170, 0.2), text: String(repeating: "слово ", count: 4))!.change(from: calm)
    XCTAssertFalse(VoiceAcoustics.strength("excited", slow).audible)
    // A whisper is noise: almost nothing voiced.
    var seed: UInt32 = 1
    let noise = (0..<72000).map { _ -> Float in seed = seed &* 1664525 &+ 1013904223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.05 }
    let whisper = VoiceAcoustics.measure(noise, text: text)!.change(from: calm)
    XCTAssertTrue(VoiceAcoustics.strength("whisper", whisper).audible)
    XCTAssertTrue(VoiceAcoustics.strength("calm", whisper).audible)   // no sign to check
    XCTAssertEqual(VoiceAcoustics.speechLevel(voice(100, 0.2))!, calm.level, accuracy: 0.5)
    // Stronger steps keep the timbre text and add intensity; unknown steps give nothing.
    let profile: Object = ["tts_voice": "Low husky baritone", "tts_delivery": "Slow and dry"]
    let base = VoiceDirection.mannerInstruction(profile, manner: "shouting")!
    let strongest = VoiceDirection.mannerInstruction(profile, manner: "shouting", level: 2)!
    XCTAssertTrue(base.hasPrefix("Low husky baritone.") && strongest.hasPrefix("Low husky baritone."))
    XCTAssertTrue(strongest.contains("extreme")); XCTAssertNil(VoiceDirection.mannerInstruction(profile, manner: "shouting", level: 3))
    XCTAssertNil(VoiceDirection.mannerInstruction(profile, manner: "calm"))
    for manner in ["shouting", "crying", "muttering", "laughing", "tender", "surprised", "stern", "anxious", "contemptuous"] {
      XCTAssertEqual(VoiceDirection.manner(manner), manner)
    }
  }
  func testEmotionalLinesAreLevelledToTheirSpeaker() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func tone(_ amplitude: Float) -> [Float] { (0..<24000).map { amplitude * Float(sin(Double($0) * 0.05)) } }
    let rows: [Object] = [
      ["id": "a", "speaker": "hero", "manner": "calm"], ["id": "b", "speaker": "hero", "manner": "calm"],
      ["id": "q", "speaker": "hero", "manner": "calm"], ["id": "n", "speaker": "hero", "manner": "calm"],
      ["id": "c", "speaker": "hero", "manner": "shouting"], ["id": "d", "speaker": "hero", "manner": "whisper"],
      ["id": "e", "speaker": "other", "manner": "calm"]]
    for (id, amplitude) in [("a", Float(0.1)), ("b", 0.1), ("q", 0.05), ("n", 0.105), ("c", 0.4), ("d", 0.025), ("e", 0.3)] {
      try SpeechCache.save(root.appendingPathComponent("audio/segments/" + id + ".spcm"), samples: tone(amplitude), signature: id)
    }
    let audio = NativeAudio(ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), ffprobe: URL(fileURLWithPath: "/usr/bin/false"))
    let gains = try audio.lineGains(project: root, segments: rows)
    // A quiet calm phrase is lifted; tiny differences (n, 0.4 dB) and other speakers are left alone.
    XCTAssertEqual(Set(gains.keys), ["q", "c", "d"])
    XCTAssertEqual(gains["q"]!, 20 * log10(2.0), accuracy: 0.3)
    // A shout keeps +3 dB over the usual line; a whisper comes to the usual loudness.
    XCTAssertEqual(gains["c"]!, -20 * log10(4.0) + 3, accuracy: 0.3)
    XCTAssertEqual(gains["d"]!, 20 * log10(4.0), accuracy: 0.3)
    // The presence lift for a shout keeps length and leaves low frequencies as they were.
    let low = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 200 / 24000)) * 0.1 }
    let lifted = NativeAudio.presence(low)
    XCTAssertEqual(lifted.count, low.count)
    XCTAssertEqual(VoiceAcoustics.speechLevel(Array(lifted[2400...]))!, VoiceAcoustics.speechLevel(Array(low[2400...]))!, accuracy: 0.3)
    let high = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 2800 / 24000)) * 0.1 }
    XCTAssertEqual(VoiceAcoustics.speechLevel(Array(NativeAudio.presence(high)[2400...]))! - VoiceAcoustics.speechLevel(Array(high[2400...]))!, 4, accuracy: 0.3)
  }
  func testLongFragmentsAreCutAtSentencesForManner() throws {
    let monologue = "— И тогда я понял, что всё это было зря и что никто меня не услышит в этом сером холодном городе. Нет! Не отдам я её вам никогда, слышите, никогда и ни за что на свете, хоть убейте!"
    let parts = NativeDirector.fragments(monologue).map { String(String.UnicodeScalarView(Array(monologue.unicodeScalars)[$0.0..<$0.1])) }
    XCTAssertEqual(parts, ["— И тогда я понял, что всё это было зря и что никто меня не услышит в этом сером холодном городе.",
      "Нет!", "Не отдам я её вам никогда, слышите, никогда и ни за что на свете, хоть убейте!"])
    XCTAssertEqual(parts.joined(separator: " "), monologue)
    XCTAssertEqual(NativeDirector.fragments("— Нет! Не отдам! — вскричал он.").count, 2)   // short lines stay whole
  }
  func testBookThatPrintsYoKeepsItsOwnYe() throws {
    // Detection: no ё at all; ё throughout; ё only here and there (еще, ее, шел printed with е).
    XCTAssertFalse(NativeStress.hasYo("Он еще шел по дороге и думал о ней."))
    XCTAssertTrue(NativeStress.hasYo("Он ещё шёл по дороге. Её не было. Ещё раз всё проверил, ещё."))
    XCTAssertFalse(NativeStress.hasYo("Фёдор Михайлович. Он еще шел, ее не было, еще раз, еще."))
    XCTAssertTrue(NativeStress.hasYo("Пётр пришёл."))   // too few telling words: any ё counts
    XCTAssertTrue(NativeStress.hasYo("Е\u{308}лка. Все готово."))   // ё written as е + U+0308
    // A book that prints ё: a predicted ё never changes the author's е, nor turns into е́.
    XCTAssertEqual(NativeStress.transfer("осел", "осёл"), "осёл")
    XCTAssertEqual(NativeStress.transfer("осел", "осёл", keepYo: true), "осел")
    XCTAssertEqual(NativeStress.transfer("узнает", "узнаёт", keepYo: true), "узнает")
    XCTAssertEqual(NativeStress.transfer("узнает", "узна\u{301}ет", keepYo: true), "узна\u{301}ет")
    XCTAssertEqual(NativeStress.transfer("все", "всё", keepYo: true), "все")
    XCTAssertEqual(NativeStress.transfer("замок", "замок", keepYo: true), "замок")
    XCTAssertEqual(ProperNames.apply("Пришел Семен.", stresses: ["семен": "Семён"], keepYo: true), "Пришел Семен.")
    XCTAssertEqual(ProperNames.apply("Пришел Семен.", stresses: ["семен": "Семён"]), "Пришел Семён.")
    // A word the author printed with ё keeps its stress through the name layer.
    XCTAssertEqual(ProperNames.authored("Берёза росла. Ма\u{301}рия"), ["береза", "мария"])
    XCTAssertEqual(ProperNames.apply("Берёза", stresses: ["береза": "бёреза"], keep: ProperNames.authored("Берёза")), "Берёза")
  }
  func testStressArbitrationPrefersCommonReadingsAndMajority() throws {
    let uzhe = ["уже\u{301}", "у\u{301}же"], zamok = ["за\u{301}мок", "замо\u{301}к"]
    // A rare reading needs all three votes; anything less gives the common one.
    XCTAssertEqual(StressRules.arbitrate(uzhe, votes: ["у\u{301}же", nil, nil]), "уже\u{301}")
    XCTAssertEqual(StressRules.arbitrate(uzhe, votes: ["у\u{301}же", "у\u{301}же", nil]), "уже\u{301}")
    XCTAssertEqual(StressRules.arbitrate(uzhe, votes: ["у\u{301}же", "у\u{301}же", "у\u{301}же"]), "у\u{301}же")
    XCTAssertEqual(StressRules.arbitrate(["Уже\u{301}", "У\u{301}же"], votes: ["У\u{301}же"]), "Уже\u{301}")   // case kept
    // Ordinary homographs: the majority, a tie to the first vote (Silero); nothing named — nil.
    XCTAssertEqual(StressRules.arbitrate(zamok, votes: ["за\u{301}мок", "замо\u{301}к", "замо\u{301}к"]), "замо\u{301}к")
    XCTAssertEqual(StressRules.arbitrate(zamok, votes: ["за\u{301}мок", "замо\u{301}к", nil]), "за\u{301}мок")
    XCTAssertNil(StressRules.arbitrate(zamok, votes: ["замок", nil, nil]))
    // A second answer is asked for disagreement or any rare reading, not for agreement on a common one.
    XCTAssertTrue(StressRules.needsSecondOpinion(zamok, votes: ["за\u{301}мок", "замо\u{301}к"]))
    XCTAssertTrue(StressRules.needsSecondOpinion(uzhe, votes: ["у\u{301}же", "у\u{301}же"]))
    XCTAssertFalse(StressRules.needsSecondOpinion(uzhe, votes: ["уже\u{301}", "уже\u{301}"]))
    XCTAssertFalse(StressRules.needsSecondOpinion(zamok, votes: ["за\u{301}мок", nil]))
    // Without the LLM: Silero's rare «у́же» in the text becomes «уже́»; other words stay.
    let text = "Он у\u{301}же ушёл в за\u{301}мок."
    let item = NativeDirector.StressItem(text: text, context: text, disputes: [1: uzhe, 3: zamok])
    XCTAssertEqual(NativeDirector.settle(item), "Он уже\u{301} ушёл в за\u{301}мок.")
    // Orthoepic norms and the user's own words.
    XCTAssertEqual(StressRules.orthoepy["звонит"], "звони\u{301}т")
    XCTAssertEqual(StressRules.orthoepy["началось"], "начало\u{301}сь")
    XCTAssertEqual(StressRules.orthoepy["начать"], "нача\u{301}ть")
    let own = StressRules.userDictionary("за\u{301}мок\nЛе\u{301}бедев\nз+амок\nвойна\u{301}\nе\u{308}лка\n  творо\u{301}г \nвсё\nплохо\nдва\u{301}ра\u{301}за\nhello")
    XCTAssertEqual(own, ["замок": "за\u{301}мок", "лебедев": "ле\u{301}бедев", "творог": "творо\u{301}г", "все": "всё",
      "война": "война\u{301}", "елка": "ёлка"])
  }
  func testBeta4AuditStressAndEmotionFixes() throws {
    // B4-01: a name's stress changes only capitalised words and never an author's mark.
    XCTAssertEqual(ProperNames.apply("Лу\u{301}ка купил лука\u{301}.", stresses: ["лука": "лу\u{301}ка"]), "Лу\u{301}ка купил лука\u{301}.")
    XCTAssertEqual(ProperNames.apply("Лука купил лука.", stresses: ["лука": "лу\u{301}ка"]), "Лу\u{301}ка купил лука.")
    let authored = "Ма\u{301}рия пришла."
    XCTAssertEqual(ProperNames.authored(authored), ["мария"])
    XCTAssertEqual(ProperNames.apply(authored, stresses: ["мария": "Мари\u{301}я"], keep: ProperNames.authored(authored)), authored)
    // The user's words apply to every word, hyphenated ones included, with or without names.
    XCTAssertEqual(ProperNames.apply("по-мо\u{301}ему так", stresses: ["по-моему": "по-моему\u{301}"], namesOnly: false), "по-моему\u{301} так")
    // B4-02: no «+», one mark, ё without a second mark.
    XCTAssertFalse(ProperNames.valid("мар+и\u{301}я", for: "мария"))
    XCTAssertFalse(ProperNames.valid("фёд+ор", for: "федор"))
    XCTAssertFalse(ProperNames.valid("Мари\u{301}\u{301}я", for: "мария"))
    XCTAssertTrue(ProperNames.valid("Мари\u{301}я", for: "мария"))
    XCTAssertTrue(ProperNames.valid("Фёдор", for: "федор"))
    XCTAssertFalse(ForeignReading.valid("сёма\u{301}"))
    XCTAssertTrue(ForeignReading.valid("сёма"))
    // B4-07: a damaged cache entry fails the same checks and is asked anew.
    XCTAssertFalse(ProperNames.valid("лю\u{301}дмила", for: "мария"))
    XCTAssertFalse(ForeignReading.valid(""))
    // B4-04: an unchanged sample never counts as an audible emotion.
    let unchanged = VoiceAcoustics.Change(pitch: 0, range: 0, level: 0, tempo: 1, voiced: 0)
    for manner in VoiceDirection.manners.keys where manner != "calm" {
      XCTAssertFalse(VoiceAcoustics.strength(manner, unchanged).audible, manner)
    }
    // B4-05: the fundamental, not a multiple of the period.
    for hz in [110.0, 175, 220, 350, 450] {
      let tone = (0..<12000).map { Float(0.2 * sin(2 * Double.pi * hz * Double($0) / 24000)) }
      XCTAssertEqual(VoiceAcoustics.measure(tone, text: "слово")!.pitch, hz, accuracy: hz * 0.03)
    }
    // B4-06: a huge or negative seed retries without overflow; ordinary seeds are unchanged.
    XCTAssertEqual(SpeechRecovery.attemptSeed(17001, 1), 17001 + 104729)
    XCTAssertTrue(SpeechRecovery.attemptSeed(Int.max, 2) >= 0)
    XCTAssertEqual(SpeechRecovery.attemptSeed(-5, 0), 0)
    // B4-08: a profile without its timbre or habit parts is designed again.
    var voice: Object = ["name": "Князь", "tts_instruction": "Light airy tenor, young adult. Gentle hesitant warm delivery." + VoiceDirection.readingRules]
    voice["tts_profile_sha256"] = try VoiceDirection.signature(voice)
    XCTAssertNil(try VoiceDirection.cached(voice))
    voice["tts_voice"] = "Light airy tenor, young adult"; voice["tts_delivery"] = "Gentle hesitant warm delivery"
    XCTAssertNotNil(try VoiceDirection.cached(voice))
  }
  func testAllOrEverythingByGrammar() {
    // Cases from «Лотерея» that Silero alone got wrong, and the ones it got right.
    let cases: [(String, String, String?)] = [
      ("— ", " готовы? — спросил господин", "все"), ("Пока не вытянут ", ", бумажку не разворачивать.", "все"),
      ("Ты совсем не дал ему выбрать. ", " видели.", "все"), ("Её услышали ", " до единого.", "все"),
      ("пусть угасающую, но ", " же традицию.", "всё"), ("— ", " ясно. Гарри, вы забрали", "всё"),
      ("а они ", " продолжают рожать.", "все"), ("На ", " было определено.", "всё"),
      ("Ну-ка, ", ", ну-ка, разом!", nil), ("если ", " так, то", nil), ("через пять минут ", " ушли", "все"),
      ("Почти ", ", кому я рассказывал", "все"), ("Вот ", ", что я знаю", "всё"),
    ]
    for (before, after, expected) in cases {
      XCTAssertEqual(StressRules.allOrEverything(before: before, after: after), expected, before + "|" + after)
    }
  }
  func testTwinVoicesAreToldByPitchRangeAndTempo() throws {
    func v(_ pitch: Double, _ range: Double, _ rate: Double) -> VoiceAcoustics {
      VoiceAcoustics(pitch: pitch, range: range, level: -20, rate: rate, voiced: 0.6)
    }
    // «Лотерея»: narrator and old Warner were twins; Mrs Delacroix and Mrs Hutchinson were not.
    XCTAssertTrue(VoiceAcoustics.twins(v(115, 8.0, 10.8), v(118, 7.0, 10.4)))
    XCTAssertFalse(VoiceAcoustics.twins(v(286, 12.6, 13.9), v(222, 7.6, 14.1)))
    XCTAssertFalse(VoiceAcoustics.twins(v(169, 8.4, 11.0), v(167, 10.9, 11.9)))   // range differs
    XCTAssertFalse(VoiceAcoustics.twins(v(115, 8.0, 10.8), v(118, 7.0, 12.5)))    // tempo differs
    XCTAssertTrue(VoiceAcoustics.distance(v(140, 8, 10), v(115, 8, 10)) > VoiceAcoustics.distance(v(118, 7, 10), v(115, 8, 10)))
    let voice: Object = ["tts_voice": "Gravelly old man, 70s", "tts_delivery": "Slow and grumbling", "seed": 5]
    let higher = VoiceDirection.redesigned(voice, higher: true), lower = VoiceDirection.redesigned(voice, higher: false)
    XCTAssertTrue(NativeIO.string(higher["tts_instruction"]).hasPrefix("Gravelly old man, 70s. Clearly higher"))
    XCTAssertTrue(NativeIO.string(lower["tts_instruction"]).contains("Clearly lower, deeper pitch"))
    XCTAssertTrue(NativeIO.string(lower["tts_instruction"]).hasSuffix(VoiceDirection.readingRules))
    XCTAssertTrue(VoiceDirection.validEnglish(NativeIO.string(higher["tts_instruction"])))
  }
  func testPausesFollowBoundaryKindAndSettings() throws {
    let rows: [Object] = [
      ["id": "a", "speaker": "hero", "text": "— Да,", "paragraph_id": "p1", "chapter_id": "c1"],
      ["id": "b", "speaker": "narrator", "text": "— сказал он, —", "paragraph_id": "p1", "chapter_id": "c1"],
      ["id": "c", "speaker": "hero", "text": "идём.", "paragraph_id": "p1", "chapter_id": "c1"],
      ["id": "d", "speaker": "narrator", "text": "Они шли так:", "paragraph_id": "p1", "chapter_id": "c1"],
      ["id": "e", "speaker": "narrator", "text": "молча.", "paragraph_id": "p1", "chapter_id": "c1"],
      ["id": "f", "speaker": "narrator", "text": "Конец главы.", "paragraph_id": "p2", "chapter_id": "c1"],
      ["id": "g", "speaker": "narrator", "text": "Глава вторая", "paragraph_id": "p3", "chapter_id": "c2"]]
    let counts = Dictionary(uniqueKeysWithValues: rows.map { (NativeIO.string($0["id"]), 2400) })
    let (timeline, _) = try SpeechBatch.timeline(rows, frameCounts: counts, pauses: SpeechBatch.Pauses())
    // role change mid-sentence (the voice-change minimum), role change, sentence, colon in one voice
    // (as a comma), paragraph, chapter, end of book.
    XCTAssertEqual(timeline.map { ($0["pause_frames"] as! Int) / 24 }, [350, 350, 450, 100, 800, 2000, 2000])
    let custom = SpeechBatch.Pauses(["comma": 200, "sentence": 700, "paragraph": 1200, "chapter": 3500, "speaker": 500, "bogus": 1])
    XCTAssertEqual(try SpeechBatch.timeline(rows, frameCounts: counts, pauses: custom).0.map { ($0["pause_frames"] as! Int) / 24 },
      [500, 500, 700, 200, 1200, 3500, 3500])
    XCTAssertEqual(SpeechBatch.Pauses(["sentence": 99999]), SpeechBatch.Pauses())  // out of range keeps the default
    // A voice change never gets less than the minimum, even with zero boundary pauses.
    let zero = SpeechBatch.Pauses(["comma": 0, "sentence": 0, "paragraph": 0, "chapter": 0])
    XCTAssertEqual(try SpeechBatch.timeline(rows, frameCounts: counts, pauses: zero).0.map { ($0["pause_frames"] as! Int) / 24 },
      [350, 350, 350, 0, 0, 0, 0])
    // "— ответил князь: ‖ — Князей…": a colon before another voice is the end of the author's sentence.
    let colon: [Object] = [
      ["id": "a", "speaker": "narrator", "text": "— тотчас же ответил князь:", "paragraph_id": "p1", "chapter_id": "c1"],
      ["id": "b", "speaker": "prince", "text": "— князей Мышкиных теперь и совсем нет,", "paragraph_id": "p1", "chapter_id": "c1"],
      ["id": "c", "speaker": "prince", "text": "кроме меня.", "paragraph_id": "p1", "chapter_id": "c1"]]
    let colonCounts = Dictionary(uniqueKeysWithValues: colon.map { (NativeIO.string($0["id"]), 2400) })
    XCTAssertEqual(try SpeechBatch.timeline(colon, frameCounts: colonCounts, pauses: SpeechBatch.Pauses()).0.map { ($0["pause_frames"] as! Int) / 24 },
      [450, 100, 2000])
    XCTAssertTrue(NativeBook.introducesSpeech("сказал он: — ")); XCTAssertFalse(NativeBook.introducesSpeech("сказал он,"))
  }
  func testMontageAcceptsTheLongestPauseTheSettingsAllow() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let rows: [Object] = [
      ["id": "a", "speaker": "v", "text": "Конец главы.", "paragraph_id": "p1", "chapter_id": "c1"],
      ["id": "b", "speaker": "v", "text": "Глава вторая.", "paragraph_id": "p2", "chapter_id": "c2"]]
    for id in ["a", "b"] {
      try SpeechCache.save(root.appendingPathComponent("audio/segments/" + id + ".spcm"), samples: [0.1, 0.2], signature: id)
    }
    // 5000 ms chapter pause plus the comma-based values clamped at the same limit.
    let pauses = SpeechBatch.Pauses(["chapter": SpeechBatch.maxPauseMS, "comma": SpeechBatch.maxPauseMS])
    let (timeline, frames) = try SpeechBatch.timeline(rows, frameCounts: ["a": 2, "b": 2], pauses: pauses)
    XCTAssertEqual(timeline.map { $0["pause_frames"] as! Int }, [120_000, 120_000])
    let written = try NativeAudio.streamMontage(project: root, segments: rows, timeline: timeline, gains: [:]) { _ in }
    XCTAssertEqual(written, frames)
  }
  func testBatchRecoveryRetriesOnlyUnfinishedLane() async throws {
    let complete = [Float](repeating: 0.1, count: 4800) + [Float](repeating: 0, count: 2400)
    var calls: [[Int]] = [], attemptSeeds: [[Int]] = [], saved: [Int] = []
    let output = try await SpeechRecovery.batch(texts: ["Один.", "Два.", "Три."], seeds: [10, 20, 30],
      labels: ["s0", "s1", "s2"], operation: { indices, seeds in
        calls.append(indices); attemptSeeds.append(seeds)
        return calls.count == 1 ? [complete, nil, complete] : [complete]
      }, accepted: { i, _ in saved.append(i) })
    XCTAssertEqual(calls, [[0, 1, 2], [1]])
    XCTAssertEqual(attemptSeeds, [[10, 20, 30], [104749]])
    XCTAssertEqual(saved, [0, 2, 1])
    XCTAssertEqual(output, [complete, complete, complete])
  }
  func testBatchFailureRetainsCompletedNeighbours() async throws {
    let complete: [Float] = [0.1, -0.1]
    var calls: [[Int]] = [], saved: [Int] = []
    do {
      _ = try await SpeechRecovery.batch(texts: ["Один.", "Два."], seeds: [1, 2], labels: ["s0", "s1"],
        operation: { indices, _ in calls.append(indices); return indices.map { $0 == 0 ? complete : nil } },
        accepted: { i, _ in saved.append(i) })
      XCTFail("An unfinished lane must stop packaging")
    } catch { XCTAssertTrue(error.localizedDescription.contains("s1")) }
    XCTAssertEqual(calls, [[0, 1], [1], [1]])
    XCTAssertEqual(saved, [0])
  }
  func testBatchRejectsLostLaneAndSilentAudio() async throws {
    var saved = 0
    do {
      _ = try await SpeechRecovery.batch(texts: ["Один.", "Два."], seeds: [1, 2], labels: ["s0", "s1"],
        operation: { _, _ in [[0.1]] }, accepted: { _, _ in saved += 1 })
      XCTFail("A mismatched result count must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("потеряла")) }
    XCTAssertEqual(saved, 0)
    var attempts = 0
    do {
      _ = try await SpeechRecovery.batch(texts: ["Один."], seeds: [1], labels: ["silent"],
        operation: { _, _ in attempts += 1; return [[0, 0]] }, accepted: { _, _ in saved += 1 })
      XCTFail("Silent batch audio must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("silent")) }
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(saved, 0)
  }
  func testBatchMontageRestoresBookOrderAndFullFinalSegment() throws {
    let rows: [Object] = [
      ["id": "s0", "speaker": "hero", "paragraph_id": "p1", "text": "Да,", "pause_after_ms": 450],
      ["id": "s1", "speaker": "narrator", "paragraph_id": "p1", "text": "сказал он.", "pause_after_ms": 450],
      ["id": "s2", "speaker": "hero", "paragraph_id": "p2", "text": "Конец!", "pause_after_ms": 800],
    ]
    let counts = ["s2": 48000, "s0": 24000, "s1": 12000] // completion order differs from book
    let (timeline, frames) = try SpeechBatch.timeline(rows, frameCounts: counts)
    XCTAssertEqual(timeline.map { NativeIO.string($0["segment_id"]) }, ["s0", "s1", "s2"])
    XCTAssertEqual(timeline.map { NativeIO.string($0["speaker"]) }, ["hero", "narrator", "hero"])
    XCTAssertEqual(frames, 84000 + (180 + 450 + 800) * 24)
    XCTAssertEqual(timeline[2]["audio_end"] as? Double,
      (timeline[2]["audio_start"] as! Double) + 2)
    XCTAssertNoThrow(try SpeechBatch.verifyOrder(rows, timeline: timeline))
    XCTAssertThrowsError(try SpeechBatch.verifyOrder(rows, timeline: Array(timeline.reversed())))
    XCTAssertThrowsError(try SpeechBatch.verifyOrder(rows, timeline: Array(timeline.dropLast())))
    XCTAssertThrowsError(try SpeechBatch.timeline(rows, frameCounts: ["s0": 24000, "s1": 12000]))
    XCTAssertThrowsError(try SpeechBatch.timeline(rows, frameCounts: counts.merging(["extra": 1]) { $1 }))
    XCTAssertThrowsError(try SpeechBatch.timeline(rows + [rows[0]], frameCounts: counts))
    XCTAssertThrowsError(try SpeechBatch.timeline(rows, frameCounts: ["s0": 24000, "s1": 12000, "s2": 0]))
  }
  func testTrimPreservesQuietFinalConsonants() throws {
    let silence = [Float](repeating: 0, count: 12000)
    let speech = [Float](repeating: 0.1, count: 2400)
    let consonant = [Float](repeating: 0.0005, count: 3600)
    let result = NativeWAV.trim(silence + speech + consonant + silence)
    XCTAssertEqual(result, Array(silence.suffix(2400)) + speech + consonant + Array(silence.prefix(4800)))
    XCTAssertTrue(NativeWAV.trim(silence).isEmpty)
    XCTAssertEqual(NativeWAV.trim(speech + consonant), speech + consonant)
  }
  func testStrongUnfinishedTailRetriesWithoutFading() async throws {
    let active = [Float](repeating: 0.1, count: 4800)
    let complete = active + [Float](repeating: 0, count: 2400)
    XCTAssertTrue(SpeechRecovery.activeTail(active))
    XCTAssertFalse(SpeechRecovery.activeTail(complete))
    XCTAssertFalse(SpeechRecovery.activeTail(active + [Float](repeating: 0.0005, count: 2400)))
    var attempts = 0
    let output = try await SpeechRecovery.generate(text: "Конец.", seed: 10, label: "tail-test") { _, _ in
      attempts += 1; return attempts == 1 ? active : complete
    }
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(output, complete)
    attempts = 0
    do {
      _ = try await SpeechRecovery.generate(text: "Конец.", seed: 10, label: "tail-test") { _, _ in
        attempts += 1; return active
      }
      XCTFail("Suspect output must not be saved as complete")
    } catch { XCTAssertTrue(error.localizedDescription.contains("tail-test")) }
    XCTAssertEqual(attempts, 3)
  }
  func testSentenceCanExtendPastTargetWithoutLosingText() throws {
    let first = String(repeating: "слово ", count: 48) + "конец.»"
    let text = first + " Далее совсем другая мысль."
    let spans = NativeBook.split(text)
    XCTAssertEqual(try NativeIO.scalarSlice(text, spans[0].0, spans[0].1), first)
    XCTAssertEqual(try spans.map { try NativeIO.scalarSlice(text, $0.0, $0.1) }.joined(separator: " "), text)
    XCTAssertTrue(NativeBook.sentenceFinished(first))
    XCTAssertFalse(NativeBook.sentenceFinished("хотя в"))
    // Every closing quote the dialogue markup knows ends a sentence after . ! ? …
    for quoted in ["«Конец.»", "„Конец!“", "„Конец?”", "‹Конец…›", "‚Конец.‘", "‘Конец.’", "“Конец.”", "\"Конец.\"", "(Конец.)"] {
      XCTAssertTrue(NativeBook.sentenceFinished(quoted), quoted)
    }
    XCTAssertFalse(NativeBook.sentenceFinished("„Конец,“"))
    let nested = String(repeating: "слово ", count: 48) + "„конец.“"
    XCTAssertEqual(NativeBook.split(nested + " Далее.").count, 2)
  }
  func testOldSpeechBlocksRejoinOnlyWithinOneRole() throws {
    let text = String(repeating: "слово ", count: 40) + "конец. Реплика другого."
    let split = 239, boundary = 246
    let rows: [Object] = try [(0, split, "narrator"), (split, boundary, "narrator"), (boundary, text.unicodeScalars.count, "hero")].enumerated().map { i, span in
      ["id": "old\(i)", "speaker": span.2, "paragraph_id": "p1", "chapter_id": "ch1",
       "source": ["char_start": span.0, "char_end": span.1],
       "text": try NativeIO.scalarSlice(text, span.0, span.1), "pause_after_ms": 450,
       "tts_text": "Устаревший текст"]
    }
    let migrated = try NativeProject.speechBlocks(["segments": rows], source: ["paragraphs": [["id": "p1", "text": text]]])
    let result = NativeIO.objects(migrated["segments"])
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result.map { NativeIO.string($0["speaker"]) }, ["narrator", "hero"])
    XCTAssertEqual(result.map { NativeIO.string($0["text"]) }.joined(separator: " "), text)
    XCTAssertNil(result[0]["tts_text"])
    let again = try NativeProject.speechBlocks(migrated, source: ["paragraphs": [["id": "p1", "text": text]]])
    XCTAssertEqual(try NativeIO.json(again), try NativeIO.json(migrated))
  }
  func testReferenceExcerptEndsAtCompleteSentence() throws {
    let text = "Это законченная первая мысль. " + String(repeating: "продолжение ", count: 25)
    let excerpt = try NativeProject.excerpt(["segments": [["speaker": "hero", "text": text]]], character: "hero")
    XCTAssertEqual(excerpt, "Это законченная первая мысль.")
  }
  func testLoudnessJSONWithFFmpegSummaryAfterIt() throws {
    let report = """
      [Parsed_loudnorm_0 @ 0x123]
      {"input_i":"-21.75","input_tp":"-18.06","input_lra":"0.00"}
      [out#0/null @ 0x456] video:0KiB audio:1125KiB
      size=N/A time=00:00:03.00 bitrate=N/A speed=87.6x
      """
    let (lufs, peak) = try NativeAudio.parseLoudness(Data(report.utf8))
    XCTAssertEqual(lufs, -21.75)
    XCTAssertEqual(peak, -18.06)
    for report in ["", "{broken}", "{\"input_i\":\"-inf\",\"input_tp\":\"-inf\"}"] {
      XCTAssertThrowsError(try NativeAudio.parseLoudness(Data(report.utf8)))
    }
  }
  func testListenedReferenceCanBeReusedButNotAfterEdits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("preview.wav")
    let samples = (0..<2400).map { Float(sin(Double($0) * 0.1) * 0.2) }
    let key = try VoiceSample.signature(text: "Реплика персонажа", instruction: "Older male, worn nasal voice",
      profile: "profile1", seed: 17)
    try SpeechCache.save(file, samples: samples, signature: key)
    XCTAssertEqual(SpeechCache.load(file, signature: key), samples)
    for changed in [
      try VoiceSample.signature(text: "Другая реплика", instruction: "Older male, worn nasal voice", profile: "profile1", seed: 17),
      try VoiceSample.signature(text: "Реплика персонажа", instruction: "Young male, soft light voice", profile: "profile1", seed: 17),
      try VoiceSample.signature(text: "Реплика персонажа", instruction: "Older male, worn nasal voice", profile: "profile2", seed: 17),
      try VoiceSample.signature(text: "Реплика персонажа", instruction: "Older male, worn nasal voice", profile: "profile1", seed: 18),
    ] { XCTAssertNil(SpeechCache.load(file, signature: changed)) }
  }
  func testCompactVoiceDirectionAndOldCacheInvalidation() throws {
    let description: Object = [
      "voice": "Older-sounding male voice. Low-mid pitch. Thin worn nasal timbre with slight hoarseness.",
      "delivery": "Soft, tired and eager to please. Quick attentive phrases with small upward pitch turns and hesitant endings. Keep articulation clear.",
    ]
    let result = try VoiceDirection.compose(description)
    XCTAssertTrue(result.hasSuffix(VoiceDirection.readingRules))
    XCTAssertTrue(result.contains("Older-sounding"))
    XCTAssertTrue(result.contains("eager to please"))
    var invalid = description
    invalid["delivery"] = "Add interjections and repeat words. Insert he-he sounds and laughs between phrases."
    XCTAssertThrowsError(try VoiceDirection.compose(invalid))
    invalid["delivery"] = "Говори тихо, с заискивающей интонацией."
    XCTAssertThrowsError(try VoiceDirection.compose(invalid))
    var prohibition = description
    prohibition["delivery"] = "Soft, tired and eager to please. Do not add extra words or sounds."
    XCTAssertNoThrow(try VoiceDirection.compose(prohibition))
    var voice: Object = ["voice_gender": "male", "voice_description": description["voice"]!]
    voice["tts_instruction"] = result
    voice["tts_voice"] = description["voice"]!; voice["tts_delivery"] = description["delivery"]!
    voice["tts_profile_sha256"] = NativeIO.hash(try NativeIO.json(["version": 1, "profile": VoiceDirection.input(voice)]))
    XCTAssertNil(try VoiceDirection.cached(voice))
    voice["tts_profile_sha256"] = try VoiceDirection.signature(voice)
    XCTAssertNotNil(try VoiceDirection.cached(voice))
  }
  func testLLMJSONWrappersAndErrors() throws {
    for content in ["{\"characters\":[]}", "  ```json\n{\"characters\":[]}\n```  ", "```\n{\"characters\":[]}\n```", "\u{FEFF}{\"characters\":[]}"] {
      let reply = try NativeIO.json(["done": true, "done_reason": "stop", "message": ["content": content]])
      XCTAssertNotNil(try LLMReply.parse(reply)["characters"])
    }
    for reply: Object in [
      ["done_reason": "length", "message": ["content": "{}"]],
      ["done": false, "message": ["content": "{}"]],
      ["message": ["content": ""]],
      ["message": ["content": "```json\n{broken}\n```"]],
      ["message": ["content": "[1,2]"]],
    ] { XCTAssertThrowsError(try LLMReply.parse(NativeIO.json(reply))) }
    XCTAssertThrowsError(try LLMReply.parse(Data("not JSON".utf8)))
  }
  func testSilentSpeechRetriesAndStops() async throws {
    var seeds: [Int] = []
    let result = try await SpeechRecovery.generate(text: "— Да… как же это? —", seed: 10, label: "test") { text, seed in
      XCTAssertEqual(text, "Да… как же это?")
      seeds.append(seed)
      return seeds.count == 1 ? [0, 0] : [0.1, -0.2]
    }
    XCTAssertEqual(result, [0.1, -0.2])
    XCTAssertEqual(seeds, [10, 104739])
    var attempts = 0
    do {
      _ = try await SpeechRecovery.generate(text: "Нет", seed: 1, label: "seg000034") { _, _ in
        attempts += 1; return [0, 0]
      }
      XCTFail("Silent speech must fail after bounded retries")
    } catch { XCTAssertTrue(error.localizedDescription.contains("seg000034")) }
    XCTAssertEqual(attempts, 3)
  }
  func testShortSentencesShareOneSpeechBlock() throws {
    let text = "Первое предложение. Второе предложение! Третье предложение?"
    let chunks = NativeBook.split(text)
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(try NativeIO.scalarSlice(text, chunks[0].0, chunks[0].1), text)
  }
  func testCleanupPreservesUsefulProjectFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let retained = ["book.epub", "roles/manifest.json", "voices/narrator.wav", "audio/segments/s1.wav", "audio/segments/s1.json", "result/audiobook.m4b"]
    let disposable = ["audio-normalized/sample.wav", "audio-music/sample.wav", "audio/sample.wav", "result/chapters.txt"]
    for name in retained + disposable {
      let file = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("test".utf8).write(to: file)
    }
    NativeProject.cleanupBuildIntermediates(root)
    for name in retained { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
    for name in disposable { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
  }
  func testSpeechCacheInvalidationAndCorruption() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("segment.wav")
    let key = try SpeechCache.signature(text: "Привет!", referenceHash: "voice1", referenceText: "Образец", seed: 1)
    let samples: [Float] = [0.1, -0.2, 0.3]
    try SpeechCache.save(file, samples: samples, signature: key)
    XCTAssertEqual(SpeechCache.load(file, signature: key), samples)
    for changed in [
      try SpeechCache.signature(text: "Пока!", referenceHash: "voice1", referenceText: "Образец", seed: 1),
      try SpeechCache.signature(text: "Привет!", referenceHash: "voice2", referenceText: "Образец", seed: 1),
      try SpeechCache.signature(text: "Привет!", referenceHash: "voice1", referenceText: "Другой", seed: 1),
      try SpeechCache.signature(text: "Привет!", referenceHash: "voice1", referenceText: "Образец", seed: 2),
    ] { XCTAssertNil(SpeechCache.load(file, signature: changed)) }
    try Data("broken".utf8).write(to: file)
    XCTAssertNil(SpeechCache.load(file, signature: key))
  }
  func testModelCacheRecoveryWithoutNetwork() throws {
    let folder = temporary()
    defer { try? fm.removeItem(at: folder) }
    let resources = folder.appendingPathComponent("resources")
    let root = folder.appendingPathComponent("engine")
    let name = "Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-source"
    let payload = Data("valid model fixture".utf8)
    try NativeIO.write(resources.appendingPathComponent("stress_model_files.json"), [
      "repo": "unused", "revision": "unused",
      "files": [["path": "config.json", "size": payload.count, "sha256": NativeIO.hash(payload)]],
    ])
    let model = NativeModels(root: root, resources: resources)
    let target = root.appendingPathComponent("models/" + name + "/config.json")
    let old = folder.appendingPathComponent("models/" + name + "/config.json")
    try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try payload.write(to: old)
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0, count: payload.count).write(to: target)
    _ = try model.ensure(design: false)
    XCTAssertEqual(try Data(contentsOf: target), payload)
    let validation = root.appendingPathComponent("model-validation.json")
    let before = try Data(contentsOf: validation)
    _ = try model.ensure(design: false)
    XCTAssertEqual(try Data(contentsOf: validation), before)
    // Same-length edits must invalidate verification, even if mtime is restored.
    let attributes = try fm.attributesOfItem(atPath: target.path)
    let identity = try model.fileIdentity(target, size: payload.count, sha: NativeIO.hash(payload))
    try Data(repeating: 0, count: payload.count).write(to: target)
    try fm.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: target.path)
    XCTAssertNotEqual(try model.fileIdentity(target, size: payload.count, sha: NativeIO.hash(payload)), identity)
    _ = try model.ensure(design: false)
    XCTAssertEqual(try Data(contentsOf: target), payload)
    // A valid cache is accepted without downloading or reading the legacy location.
    try fm.removeItem(at: old)
    _ = try model.ensure(design: false)
    // A completed partial download is validated and promoted without a range request.
    try fm.removeItem(at: target)
    try payload.write(to: target.appendingPathExtension("partial"))
    _ = try model.ensure(design: false)
    XCTAssertEqual(try Data(contentsOf: target), payload)
    XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("partial").path))
  }
  func testNarratorEditsSurviveReanalysis() async throws {
    let voice: Object = [
      "id": "narrator", "name": "Рассказчик", "voice_gender": "female",
      "voice_description": "Calm mature female contralto",
      "character_profile": [
        "id": "narrator", "age": "75 лет", "habits": "Длинные паузы",
        "speaking_style": "", "voice_description": "Quiet female contralto",
      ],
    ]
    let updated = try await NativeDirector([:]).characterize(
      ["voices": [voice], "segments": []], source: ["paragraphs": []])
    let profile = NativeIO.object(NativeIO.objects(updated["voices"])[0]["character_profile"])
    XCTAssertEqual(NativeIO.string(profile["age"]), "75 лет")
    XCTAssertEqual(NativeIO.string(profile["habits"]), "Длинные паузы")
    XCTAssertEqual(NativeIO.string(profile["voice_description"]), "Quiet female contralto")
    XCTAssertFalse(NativeIO.string(profile["speaking_style"]).isEmpty)
  }

  func testReserveVoicesHaveOwnGenderAndTimbre() async throws {
    let female = NativeDirector.reserveVoice(7, female: true), male = NativeDirector.reserveVoice(8)
    XCTAssertEqual(NativeIO.string(female["id"]), "other_voices_female")
    XCTAssertEqual(NativeIO.string(female["voice_gender"]), "female")
    XCTAssertEqual(NativeIO.string(male["id"]), "other_voices")
    // Without an answering LLM unresolved lines still get the male reserve voice,
    // with its own neutral timbre rather than the narrator template.
    let resolved = try await NativeDirector([:]).resolve(["voices": [["id": "narrator", "voice_id": "voice_001"]],
      "segments": [["id": "seg000001", "paragraph_id": "p1", "speaker": NSNull(), "text": "— Да."]]],
      source: ["paragraphs": [["id": "p1", "text": "— Да."]]])
    let other = NativeIO.objects(resolved["voices"]).first { NativeIO.string($0["id"]) == "other_voices" }
    XCTAssertEqual(NativeIO.string(NativeIO.objects(resolved["segments"])[0]["speaker"]), "other_voices")
    XCTAssertTrue(NativeIO.string(NativeIO.object(other?["character_profile"])["voice_description"]).hasPrefix("Neutral adult"))
  }
  func testCastAuditFindings() async throws {
    // An empty profile field does not hide the filled top-level description.
    let input = VoiceDirection.input(["voice_gender": "male", "voice_description": "Distinct deep gravelly bass",
      "character_profile": ["voice_description": "", "age": "40"]])
    XCTAssertEqual(NativeIO.string(input["voice_description"]), "Distinct deep gravelly bass")
    XCTAssertEqual(NativeIO.string(input["age"]), "40")
    // Announcer wording is flagged unless the profile itself asks for it.
    XCTAssertEqual(Set(VoiceDirection.unwanted("Neutral warm baritone, clear diction. Flat steady narration.", profile: ["habits": "живой"])),
      ["neutral", "clear diction", "flat"])
    XCTAssertEqual(VoiceDirection.unwanted("Flat mechanical voice.", profile: ["voice_description": "flat mechanical robot"]), [])
    // A first-person narrator's own listed speech keeps its manner; plain narration stays calm.
    let text = "— Прочь! — крикнул я и ушёл."
    let paragraph: Object = ["id": "p1", "text": text]
    let rows = try NativeDirector.validateSpeakers(["paragraphs": [["id": "p1", "speech": [["n": 1, "speaker": "narrator", "manner": "angry"]]]]],
      chunk: [paragraph], fragments: [NativeDirector.fragments(text)], allowed: ["narrator"])
    XCTAssertEqual(NativeIO.objects(rows[0]["spans"]).map { NativeIO.string($0["manner"]) }, ["angry", "calm"])
    // The narrator template keeps an age and voice already found (audit: 80-year-old → 35–50 baritone).
    let narrated = try await NativeDirector([:]).characterize(["voices": [["id": "narrator", "name": "Рассказчик", "voice_gender": "male",
      "age": "80 лет", "voice_description": "Old frail high tenor"]], "segments": []], source: ["paragraphs": []])
    let profile = NativeIO.object(NativeIO.objects(narrated["voices"])[0]["character_profile"])
    XCTAssertEqual(NativeIO.string(profile["age"]), "80 лет")
    XCTAssertEqual(NativeIO.string(profile["voice_description"]), "Old frail high tenor")
  }
  func testEveryVoiceDetailInvalidatesDirection() throws {
    let profile: Object = [
      "age": "Пожилой, 70 лет", "personality": "Сдержанный",
      "habits": "Длинные паузы", "speaking_style": "Медленно, тихо",
      "voice_description": "Low resonant baritone",
    ]
    var voice: Object = ["voice_gender": "male", "character_profile": profile]
    voice["tts_instruction"] =
      "Elderly male, low resonant baritone, slow restrained delivery and thoughtful pauses."
    voice["tts_voice"] = "Elderly male, low resonant baritone"; voice["tts_delivery"] = "Slow restrained delivery, thoughtful pauses"
    voice["tts_profile_sha256"] = try VoiceDirection.signature(voice)
    XCTAssertNotNil(try VoiceDirection.cached(voice))
    for field in VoiceDirection.fields {
      XCTAssertEqual(
        NativeIO.string(VoiceDirection.input(voice)[field]), NativeIO.string(profile[field]))
      var edited = voice
      var changed = profile
      changed[field] = NativeIO.string(profile[field]) + " Новое уточнение"
      edited["character_profile"] = changed
      XCTAssertNil(try VoiceDirection.cached(edited), field)
    }
    voice["voice_gender"] = "female"
    XCTAssertNil(try VoiceDirection.cached(voice))
  }

  func testSpeechDirectionRequiresEnglish() throws {
    XCTAssertTrue(
      VoiceDirection.validEnglish("Soft mature female contralto, gentle unhurried delivery."))
    XCTAssertFalse(VoiceDirection.validEnglish("Тихий взрослый женский голос, неторопливая речь."))
    XCTAssertFalse(VoiceDirection.validEnglish("Soft female voice, неторопливая речь."))
    XCTAssertFalse(VoiceDirection.validEnglish(""))
  }

  let fm = FileManager.default
  var rules: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "backend/engine/supertonic_rules.json")
  }
  func testScalarOffsets() throws {
    XCTAssertEqual(try NativeIO.scalarSlice("A😀Б", 1, 2), "😀")
    XCTAssertThrowsError(try NativeIO.scalarSlice("A", 0, 2))
  }
  func testDialogueFragmentsSeparateAuthorRemarks() throws {
    func parts(_ text: String) throws -> [String] {
      try NativeDirector.fragments(text).map { try NativeIO.scalarSlice(text, $0.0, $0.1) }
    }
    XCTAssertEqual(
      try parts("— А позвольте, с кем имею честь… — обратился вдруг угреватый господин к белокурому молодому человеку."),
      ["— А позвольте, с кем имею честь…", "— обратился вдруг угреватый господин к белокурому молодому человеку."])
    XCTAssertEqual(
      try parts("— Тьфу тебя! — сплюнул черномазый. — Пять недель назад я, вот как и вы, — обратился он к князю, — с одним узелком."),
      ["— Тьфу тебя!", "— сплюнул черномазый.", "— Пять недель назад я, вот как и вы,",
       "— обратился он к князю,", "— с одним узелком."])
    // A dash inside speech without preceding punctuation is not a boundary.
    XCTAssertEqual(try parts("— Это — правда."), ["— Это — правда."])
    XCTAssertEqual(try parts("Он сказал: «Пойдём». Все встали."), ["Он сказал:", "«Пойдём».", "Все встали."])
    XCTAssertEqual(try parts("«Да», — ответил он."), ["«Да»,", "— ответил он."])
    // Quoted terms and titles inside a sentence are not speech (Nietzsche: dozens of «terms»).
    XCTAssertEqual(try parts("Слово «хороший» и понятие «хорошее и плохое» в «Генеалогии морали» означают разное."),
      ["Слово «хороший» и понятие «хорошее и плохое» в «Генеалогии морали» означают разное."])
    // Other quote styles are recognised the same way.
    XCTAssertEqual(try parts("Он сказал: „Пойдём“. Все встали."), ["Он сказал:", "„Пойдём“.", "Все встали."])
    XCTAssertEqual(try parts("“Да”, — ответил он."), ["“Да”,", "— ответил он."])
    XCTAssertEqual(try parts("Он закричал \"Стой! Кто идёт?\" и выстрелил."), ["Он закричал", "\"Стой! Кто идёт?\"", "и выстрелил."])
    XCTAssertEqual(try parts("Д’Артаньян вошёл."), ["Д’Артаньян вошёл."])
    XCTAssertEqual(try parts("— «Вперёд!» — крикнул он."), ["— «Вперёд!»", "— крикнул он."])
  }
  func testSpeakerFragmentsRebuildParagraphExactly() throws {
    let text = "— Да 😀! — сказал он. — Идём, — и ничего больше!"
    let paragraph: Object = ["id": "p00001", "text": text]
    let split = [NativeDirector.fragments(text)]
    XCTAssertEqual(split[0].count, 4)
    let answer: Object = ["paragraphs": [[
      "id": "p00001", "speakers": ["hero", "narrator", "hero", "hero"], "confidence": "high",
    ]]]
    let rows = try NativeDirector.validateSpeakers(
      answer, chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"])
    let spans = NativeIO.objects(rows[0]["spans"])
    XCTAssertEqual(spans.map { NativeIO.string($0["speaker"]) }, ["hero", "narrator", "hero"])
    XCTAssertEqual(
      try spans.map { try NativeIO.scalarSlice(text, $0["start"] as! Int, $0["end"] as! Int) },
      ["— Да 😀!", "— сказал он.", "— Идём, — и ничего больше!"])
    // A speaker outside the cast never fails the answer: a spelling variant of a cast ID becomes
    // that ID, any other ID an unknown speaker (settled later from context).
    let stray = try NativeDirector.validateSpeakers(["paragraphs": [["id": "p00001", "speakers": ["Hero", "narrator", "mrs_draves", "hero"]]]],
      chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"])
    XCTAssertEqual(NativeIO.objects(stray[0]["spans"]).map { NativeIO.string($0["speaker"]) }, ["hero", "narrator", "", "hero"])
    for bad: Object in [
      ["paragraphs": [["id": "p00001", "speakers": ["hero"]]]],
      ["paragraphs": [["id": "p00002", "speakers": ["hero", "narrator", "hero", "hero"]]]],
    ] {
      XCTAssertThrowsError(try NativeDirector.validateSpeakers(
        bad, chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"]))
    }
    // Sparse answer: only characters' fragments are listed, everything else is the calm narrator.
    let sparse = try NativeDirector.validateSpeakers(["paragraphs": [[
      "id": "p00001", "speech": [["n": 1, "speaker": "hero", "manner": "joyful"], ["n": 3, "speaker": "hero", "manner": "joyful"], ["n": 4, "speaker": "hero"]]]]],
      chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"])
    XCTAssertEqual(NativeIO.objects(sparse[0]["spans"]).map { NativeIO.string($0["speaker"]) + ":" + NativeIO.string($0["manner"]) },
      ["hero:joyful", "narrator:calm", "hero:joyful", "hero:calm"])
    XCTAssertEqual(NativeIO.objects(try NativeDirector.validateSpeakers(["paragraphs": [["id": "p00001", "speech": []]]],
      chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"])[0]["spans"]).map { NativeIO.string($0["speaker"]) }, ["narrator"])
    XCTAssertThrowsError(try NativeDirector.validateSpeakers(["paragraphs": [["id": "p00001", "speech": [["n": 9, "speaker": "hero"]]]]],
      chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"]))
    // Manner splits a speaker's span; narrator is always calm; a broken list is calm, not an error.
    let toned = try NativeDirector.validateSpeakers(["paragraphs": [[
      "id": "p00001", "speakers": ["hero", "narrator", "hero", "hero"],
      "manners": ["joyful", "angry", "angry", "yelling"]]]], chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"])
    XCTAssertEqual(NativeIO.objects(toned[0]["spans"]).map { NativeIO.string($0["manner"]) }, ["joyful", "calm", "angry", "calm"])
    let untoned = try NativeDirector.validateSpeakers(["paragraphs": [[
      "id": "p00001", "speakers": ["hero", "narrator", "hero", "hero"], "manners": ["angry"]]]],
      chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"])
    XCTAssertEqual(NativeIO.objects(untoned[0]["spans"]).map { NativeIO.string($0["manner"]) }, ["calm", "calm", "calm"])
    // The state takes over pace, loudness and energy explicitly; voice and age stay (audit: "fast… / very slow…").
    XCTAssertEqual(VoiceDirection.mannerInstruction(["tts_voice": "Old frail male voice.", "tts_delivery": "Slow."], manner: "angry"),
      "Old frail male voice. Usual character: Slow. For this sample, the state overrides the usual pace, loudness and energy, keeping the same voice and age. "
        + VoiceDirection.manners["angry"]! + VoiceDirection.readingRules)
    XCTAssertNil(VoiceDirection.mannerInstruction(["tts_voice": "Old frail male voice."], manner: "calm"))
    XCTAssertNil(VoiceDirection.mannerInstruction([:], manner: "angry"))
  }
  func testExcerptNeverBorrowsAnotherRole() throws {
    let own =
      "Я внимательно смотрю на дорогу и вспоминаю вчерашний разговор. Вдалеке слышен шум поезда, который медленно приближается к станции."
    let manifest: Object = [
      "segments": [
        ["speaker": "narrator", "text": "Чужой текст, который нельзя использовать."],
        ["speaker": "hero", "text": own],
      ]
    ]
    let excerpt = try NativeProject.excerpt(manifest, character: "hero")
    XCTAssertFalse(excerpt.contains("Чужой"))
    XCTAssertTrue((110...150).contains(excerpt.count))
    XCTAssertThrowsError(try NativeProject.excerpt(manifest, character: "missing"))
  }
  func testNumberAndDateNormalization() throws {
    let ru = try RussianText(rules)
    XCTAssertEqual(try ru.integer(1234), "одна тысяча двести тридцать четыре")
    XCTAssertEqual(try ru.normalize("25%"), "двадцать пять процентов")
    XCTAssertEqual(try ru.normalize("Глава IV"), "Глава четвёртая")
    // Genitive after 2–4: -а/-я is masculine or neuter, -ы/-и feminine.
    for (input, output) in [("За 2 часа.", "За два часа."), ("Купил 2 карандаша.", "Купил два карандаша."),
      ("Взял 2 билета.", "Взял два билета."), ("Через 2 дня.", "Через два дня."), ("За 2 минуты.", "За две минуты."),
      ("Прошло 2 недели.", "Прошло две недели."), ("Открыли 2 окна.", "Открыли два окна."),
      ("Это 1 книга.", "Это одна книга."), ("Прошло 22 года.", "Прошло двадцать два года.")] {
      XCTAssertEqual(try ru.normalize(input), output)
    }
    XCTAssertEqual(try ru.normalize("Главы I, II и III"), "Главы первая, вторая и третья")
    XCTAssertEqual(
      try ru.normalize("В 1870 он вернулся."), "В тысяча восемьсот семидесятом он вернулся.")
    XCTAssertEqual(
      try ru.normalize("21.01.2024"), "двадцать первого января две тысячи двадцать четвёртого года")
    XCTAssertEqual(try ru.normalize("12:30"), "двенадцать часов тридцать минут")
    XCTAssertEqual(try ru.normalize("Цена 2,5 кг"), "Цена две целых пять десятых килограмма")
    XCTAssertEqual(try ru.normalize("https://site.ru/page12"), "https://site.ru/page12")
    // An impossible date is read as it stands instead of stopping the book.
    XCTAssertEqual(try ru.normalize("31.02.2024"), "тридцать один.ноль два.две тысячи двадцать четыре")
  }
  func testBracketsAreSpoken() throws {
    let ru = try RussianText(rules)
    XCTAssertEqual(try ru.normalize("Кроме этого (превосходного) дома."),
      "Кроме этого, скобка открывается, превосходного, скобка закрывается, дома.")
    XCTAssertEqual(try ru.normalize("(Примечание автора.) Дальше."),
      "скобка открывается, Примечание автора, скобка закрывается. Дальше.")
    XCTAssertEqual(try ru.normalize("См. (там же): текст"), "См. скобка открывается, там же, скобка закрывается: текст")
    XCTAssertEqual(try ru.normalize("сострадания (— я враг изнеженности —) кажется"),
      "сострадания, скобка открывается, я враг изнеженности, скобка закрывается, кажется")
    XCTAssertEqual(try ru.normalize("«(смеётся) Да»"), "«скобка открывается, смеётся, скобка закрывается, Да»")
    XCTAssertEqual(try ru.normalize("Без скобок, как было."), "Без скобок, как было.")
  }
  func testShortLinesOfOneVoiceShareACall() throws {
    func row(_ id: String, _ speaker: String, _ text: String, _ paragraph: String, chapter: String = "c1",
      manner: String = "calm") -> Object {
      ["id": id, "speaker": speaker, "text": text, "tts_text": text, "paragraph_id": paragraph,
       "chapter_id": chapter, "manner": manner]
    }
    let long = String(repeating: "Длинное предложение рассказчика. ", count: 7)
    let rows = SpeechGroups.assign([
      row("s1", "narrator", "Глава первая", "p1"), row("s2", "narrator", "Он сел.", "p2"),
      row("s3", "ivan", "— Да.", "p3"), row("s4", "ivan", "— Нет.", "p4"),
      row("s5", "ivan", "— Ну!", "p5", manner: "angry"), row("s6", "narrator", "* * *", "p6"),
      row("s7", "narrator", "Утро.", "p7"), row("s8", "narrator", long, "p8"),
      row("s9", "narrator", "Конец.", "p9", chapter: "c2"),
    ])
    // One speaker, manner and chapter per call; a scene break stays apart, a short line joins a long one.
    XCTAssertEqual(SpeechGroups.units(rows), [[0, 1], [2, 3], [4], [5], [6, 7], [8]])
    XCTAssertEqual(NativeIO.string(rows[1]["synthesis_group"]), "s1")
    XCTAssertEqual(SpeechGroups.text(rows, unit: [0, 1]), "Глава первая. Он сел.")
    XCTAssertEqual(SpeechBatch.Pauses().after(rows[0], next: rows[1]), 0)
    XCTAssertEqual(SpeechBatch.Pauses().after(rows[1], next: rows[2]), 800)
    // The cut falls in the silence near the expected boundary and the pieces add up exactly.
    var audio = [Float](repeating: 0, count: 48000)
    for i in 0..<20000 { audio[i] = 0.3 * sin(Float(i) * 0.05) }
    for i in 26000..<48000 { audio[i] = 0.3 * sin(Float(i) * 0.07) }
    let parts = SpeechGroups.split(audio, weights: [10, 11])
    XCTAssertEqual(parts.count, 2)
    XCTAssertEqual(parts[0].count + parts[1].count, audio.count)
    XCTAssertTrue((20000...26000).contains(parts[0].count))
    XCTAssertEqual(SpeechGroups.split(audio, weights: [5]).count, 1)
    XCTAssertEqual(SpeechGroups.weight("за́мок, да!"), 7)
  }
  func testStressModesCombineSileroAndRUAccent() {
    // "Никак": Silero's ё stays, its marks go, the book's own mark stays.
    XCTAssertEqual(StressRules.onlyYo("Всё бы́ло за́мком, ещё", original: "Все было за́мком, еще"), "Всё было за́мком, ещё")
    // RUAccent fills a word Silero left bare, disputes a different stress and votes on homographs.
    let silero = NativeDirector.StressItem(text: "Ста́рый за́мок, кумпатрия и все", context: "",
      disputes: [1: ["за́мок", "замо́к"]])
    let both = StressRules.secondVoice(silero, "Стары́й замо́к, кумпа́трия и всё")
    XCTAssertEqual(both.text, "Ста́рый за́мок, кумпа́трия и все")
    XCTAssertEqual(both.disputes[0], ["Ста́рый", "Стары́й"])
    XCTAssertEqual(both.disputes[4], ["все", "всё"])
    XCTAssertEqual(both.votes, [0: "Стары́й", 1: "замо́к", 4: "всё"])
    // Without the LLM a tie between the two engines keeps Silero's reading.
    XCTAssertEqual(NativeDirector.settle(both), "Ста́рый за́мок, кумпа́трия и все")
    // Words differing in letters are never merged.
    XCTAssertEqual(StressRules.secondVoice(silero, "Другой текст").text, silero.text)
    XCTAssertEqual(WordPiece.words("все, кто-то!"), [0..<3, 3..<4, 5..<8, 8..<9, 9..<11, 11..<12])
  }
  func testForeignSpeakerIDMatchesFoldedCastID() {
    XCTAssertEqual(NativeDirector.castID("dühring"), "duhring")
    XCTAssertEqual(NativeDirector.speakerKey("Dühring"), NativeDirector.speakerKey("duhring"))
    XCTAssertEqual(NativeDirector.speakerKey("old man"), "old_man")
  }
  func testSplitKeepsScalarText() throws {
    let text =
      "Очень длинная реплика. Следующая мысль 😀 состоит из нескольких слов. И ещё немного текста."
    let chunks = NativeBook.split(text, maximum: 35)
    let result = try chunks.map { try NativeIO.scalarSlice(text, $0.0, $0.1) }.joined(
      separator: " ")
    XCTAssertEqual(result, text)
  }
  func testFB2BecomesEPUBWithoutNotes() throws {
    let folder = temporary()
    defer { try? fm.removeItem(at: folder) }
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).base64EncodedString()
    let fb2 = """
      <?xml version="1.0" encoding="UTF-8"?>
      <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
      <description><title-info><author><first-name>Фридрих</first-name><last-name>Ницше</last-name></author>
      <book-title>К генеалогии морали</book-title><coverpage><image l:href="#cover.png"/></coverpage><lang>ru</lang></title-info></description>
      <body><title><p>Фридрих Ницше</p></title>
      <section><title><p>ПРЕДИСЛОВИЕ</p></title><subtitle>1</subtitle><p>Мы чужды себе<a l:href="#n1" type="note">note 1</a>, <emphasis>мы</emphasis> познающие.</p>
      <empty-line/><image l:href="#cover.png"/><cite><p>Цитата.</p><text-author>Автор</text-author></cite></section>
      <section><title><p>РАССМОТРЕНИЕ ПЕРВОЕ</p><p>«ДОБРО И ЗЛО»</p></title><epigraph><p>Эпиграф.</p></epigraph>
      <poem><stanza><v>Строка один</v><v>Строка два<a l:href="#n2">2</a></v></stanza></poem></section></body>
      <body name="notes"><section id="n1"><p>Примечание не читается.</p></section><section id="n2"><p>И это.</p></section></body>
      <binary id="cover.png" content-type="image/png">\(png)</binary></FictionBook>
      """
    let input = folder.appendingPathComponent("book.fb2"), output = folder.appendingPathComponent("book.epub")
    try Data(fb2.utf8).write(to: input)
    XCTAssertTrue(NativeFB2.accepts(input)); XCTAssertTrue(NativeFB2.accepts(URL(fileURLWithPath: "/x/Книга.FB2.zip")))
    XCTAssertEqual(NativeFB2.baseName(URL(fileURLWithPath: "/x/Книга.fb2.zip")), "Книга")
    try NativeFB2.convert(input, to: output)
    let book = try NativeBook.read(output)
    XCTAssertEqual(NativeIO.string(book["title"]), "К генеалогии морали")
    XCTAssertEqual(NativeIO.string(book["author"]), "Фридрих Ницше")
    XCTAssertEqual(NativeIO.objects(book["paragraphs"]).map { NativeIO.string($0["text"]) }, [
      "Фридрих Ницше", "ПРЕДИСЛОВИЕ", "1", "Мы чужды себе, мы познающие.", "Цитата.", "Автор",
      "РАССМОТРЕНИЕ ПЕРВОЕ", "«ДОБРО И ЗЛО»", "Эпиграф.", "Строка один", "Строка два"])
    XCTAssertEqual(NativeIO.objects(book["chapters"]).map { NativeIO.string($0["title"]) },
      ["Фридрих Ницше", "ПРЕДИСЛОВИЕ", "РАССМОТРЕНИЕ ПЕРВОЕ"])
    XCTAssertEqual(NativeBook.cover(output)?.ext, "png")
  }
  func testEPUBNotesForeignWordsAndSections() throws {
    let html = try XMLDocument(xmlString: """
      <html xmlns:epub="http://www.idpf.org/2007/ops"><body><p>Текст<sup><a href="#fn1">1</a></sup> и<a epub:type="noteref" href="#fn2">*</a> ещё <a href="ch2.xhtml">глава 2</a>.</p>
      <aside epub:type="footnote" id="fn1"><p>Сноска.</p></aside><section role="doc-endnotes"><p>Конец.</p></section></body></html>
      """, options: [])
    let all = NativeBook.elements(html)
    let ids = Dictionary(uniqueKeysWithValues: all.compactMap { n in n.attribute(forName: "id")?.stringValue.map { ($0, n) } })
    for node in all where NativeBook.isNoteContainer(node) || NativeBook.isNoteReference(node, ids: ids) { node.detach() }
    XCTAssertEqual(NativeIO.replace("\\s+", html.rootElement()?.stringValue ?? "", " ").trimmingCharacters(in: .whitespaces),
      "Текст и ещё глава 2.")
    // Audit: a plain aside and a numbered link to a section are book text, not notes.
    let plain = try XMLDocument(xmlString: """
      <html><body><p>См. главу <a href="chapter.xhtml#section2">2</a>.</p><aside><p>Важная авторская вставка.</p></aside>
      <p>Сноска<sup><a href="#fn7">7</a></sup> и ссылка <sup><a href="notes.xhtml#note12">12</a></sup>.</p><p id="section2">Продолжение.</p></body></html>
      """, options: [])
    let plainAll = NativeBook.elements(plain)
    let plainIDs = Dictionary(uniqueKeysWithValues: plainAll.compactMap { n in n.attribute(forName: "id")?.stringValue.map { ($0, n) } })
    for node in plainAll where NativeBook.isNoteContainer(node) || NativeBook.isNoteReference(node, ids: plainIDs) { node.detach() }
    XCTAssertEqual(NativeIO.replace("\\s+", plain.rootElement()?.stringValue ?? "", ""),
      "См.главу2.Важнаяавторскаявставка.Сноскаиссылка.Продолжение.")
    XCTAssertEqual(ForeignReading.fragments("Это a priori, а не vis inertiae; Übermensch и ressentiment, Fin-Gal."),
      ["a priori", "vis inertiae", "Übermensch", "ressentiment", "Fin-Gal"])
    XCTAssertEqual(ForeignReading.apply("Это a priori и Übermensch.", readings: ["a priori": "а при\u{301}ори"]),
      "Это а при\u{301}ори и Übermensch.")
    XCTAssertTrue(ForeignReading.valid("ю\u{301}бермэнш")); XCTAssertTrue(ForeignReading.valid("вис ине\u{301}рциэ"))
    XCTAssertFalse(ForeignReading.valid("Übermensch")); XCTAssertFalse(ForeignReading.valid("сверх-человек (перевод)"))
    // Audit: marks alone, a mark after a consonant, or an unstressed polysyllable are rejected.
    XCTAssertFalse(ForeignReading.valid("\u{301}\u{301}")); XCTAssertFalse(ForeignReading.valid("при\u{301}\u{301}ори"))
    XCTAssertFalse(ForeignReading.valid("пр\u{301}иори")); XCTAssertFalse(ForeignReading.valid("априори"))
    XCTAssertTrue(ForeignReading.valid("шлехт")); XCTAssertTrue(ForeignReading.valid("хик ни\u{301}гер эст"))
    let ru = try RussianText(rules)
    XCTAssertEqual(try ru.normalize("См. § 7 и §§ 9"), "См. параграф семь и параграфы девять")
    // Typography: decomposed ё, soft hyphen, note marks, decorations, №, fractions, quote styles, ligatures.
    XCTAssertEqual(try ru.normalize("Е\u{0308}лка и пере\u{00AD}нос¹²."), "Ёлка и перенос.")
    XCTAssertEqual(try ru.normalize("Слово[12] и знак* и крест†."), "Слово и знак и крест.")
    XCTAssertEqual(try ru.normalize("* * *"), "")
    XCTAssertEqual(try ru.normalize("Дом № 5"), "Дом номер пять")
    XCTAssertEqual(try ru.normalize("Ещё ½ часа."), "Ещё одна вторая часа.")
    XCTAssertEqual(try ru.normalize("Он сказал „да“ и “нет” и \"может\"."), "Он сказал «да» и «нет» и «может».")
    XCTAssertEqual(try ru.normalize("ﬁnal"), "final")
  }
  func testNamesStressAndYoAreChecked() {
    let text = "Он видел Рогожина у окна. Рогожин молчал; потом пришёл генерал Епанчин и Фёдор."
    let forms = ProperNames.collect([text], names: ["Лев Мышкин"])
    // Inside a sentence or from the cast; the sentence-initial "Он" and one-vowel "Лев" are not names to stress.
    XCTAssertEqual(forms.map(\.form), ["мышкин", "рогожина", "епанчин", "федор"])
    XCTAssertTrue(ProperNames.valid("рого\u{301}жина", for: "рогожина"))
    XCTAssertTrue(ProperNames.valid("фёдор", for: "федор"))
    XCTAssertFalse(ProperNames.valid("семёна\u{301}", for: "семена"))   // ё is already the stress
    XCTAssertFalse(ProperNames.valid("рогожина", for: "рогожина"))       // no stress at all
    XCTAssertFalse(ProperNames.valid("раго\u{301}жина", for: "рогожина"))  // letters changed
    XCTAssertEqual(ProperNames.apply("Рого\u{301}жин и РОГОЖИНА, Федор.", stresses: ["рогожин": "рого\u{301}жин", "рогожина": "рого\u{301}жина", "федор": "фёдор"]),
      "Рого\u{301}жин и РОГО\u{301}ЖИНА, Фёдор.")
    XCTAssertEqual(NativeStress.yoNames["федоровича"], "фёдоровича")
    // A word already stressed in the book keeps every letter (audit: "за́мок" → "за́́мо").
    XCTAssertEqual(NativeStress.transfer("за\u{301}мок", "за\u{301}мок"), "за\u{301}мок")
    XCTAssertEqual(NativeStress.transfer("Мука\u{301}", "му\u{301}ка"), "Му\u{301}ка")
    XCTAssertEqual(NativeStress.transfer("елка", "ё\u{301}лка"), "ёлка")
    XCTAssertTrue(NativeStress.sentenceStart("Он ушёл. — Федор" as NSString, before: 11, prefix: ""))
    XCTAssertFalse(NativeStress.sentenceStart("Он и Федор" as NSString, before: 5, prefix: ""))
    // Words already stressed (in the book or by the dictionary) are not candidates again.
    XCTAssertEqual(NativeDirector.stressCandidates("за\u{301}мок и замок").map(\.id), [2])
  }
  func testLegacyPythonRuntimeIsRemovedButModelsStay() throws {
    let root = temporary()
    defer { try? fm.removeItem(at: root) }
    for dir in ["models/Qwen", ".venv-mlx", ".cache/x", "data/stress"] {
      try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in ["model-validation.json", "prepare_qwen.py", "requirements.txt", "models/Qwen/model.safetensors"] {
      try Data("x".utf8).write(to: root.appendingPathComponent(file))
    }
    let removed = NativeModels(root: root, resources: root).removeLegacyRuntime()
    XCTAssertEqual(Set(removed), [".venv-mlx", ".cache", "data", "prepare_qwen.py", "requirements.txt"])
    XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("models/Qwen/model.safetensors").path))
    XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("model-validation.json").path))
  }
  func temporary() -> URL {
    let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
  func fixture(_ folder: URL) throws -> Object {
    let book = folder.appendingPathComponent("book.epub")
    try Data("fixture".utf8).write(to: book)
    let source: Object = [
      "paragraphs": [["id": "p00001", "chapter_id": "ch001", "text": "Я 😀 читаю книгу."]],
      "chapters": [["id": "ch001", "title": "Глава"]],
    ]
    let manifest: Object = [
      "format": "qwen-audiobook-project", "book": ["input_sha256": try NativeIO.hashFile(book)],
      "voices": [["id": "narrator", "voice_id": "voice_001"]],
      "segments": [
        [
          "id": "seg000001", "paragraph_id": "p00001", "chapter_id": "ch001", "speaker": "narrator",
          "text": "Я 😀 читаю книгу.", "source": ["char_start": 0, "char_end": 16],
        ]
      ],
    ]
    try NativeIO.write(folder.appendingPathComponent("roles/source.json"), source)
    try NativeIO.write(folder.appendingPathComponent("roles/manifest.json"), manifest)
    return manifest
  }
  func testProjectRoundtripAndMissingTextRejected() throws {
    let folder = temporary()
    defer { try? fm.removeItem(at: folder) }
    let p = folder.appendingPathComponent("book")
    try fm.createDirectory(at: p, withIntermediateDirectories: true)
    var manifest = try fixture(p)
    _ = try NativeProject.verify(p)
    let archive = folder.appendingPathComponent("test.audiobookstudio")
    try NativeProject.export(p, destination: archive, settings: ["music_enabled": false])
    let opened = try NativeProject.open(archive, output: folder)
    _ = try NativeProject.verify(opened)
    // A chapter record lost from the registry would drop its lines from the EPUB only.
    let sourceFile = p.appendingPathComponent("roles/source.json")
    let intact = try NativeIO.load(sourceFile)
    var source = intact
    source["chapters"] = []
    try NativeIO.write(sourceFile, source)
    XCTAssertThrowsError(try NativeProject.verify(p))
    let segments = NativeIO.objects(manifest["segments"])
    let timeline = segments.map { ["segment_id": $0["id"]!, "audio_start": 0.0, "clip_end": 1.0] as Object }
    let audio = folder.appendingPathComponent("a.m4a"); try Data("a".utf8).write(to: audio)
    XCTAssertThrowsError(try NativeBook.epub(manifest, source: source, timeline: timeline, audio: audio,
      output: folder.appendingPathComponent("lost.epub")))
    _ = try NativeBook.epub(manifest, source: intact, timeline: timeline, audio: audio, output: folder.appendingPathComponent("ok.epub"))
    try NativeIO.write(sourceFile, intact)
    manifest["segments"] = []
    try NativeIO.write(p.appendingPathComponent("roles/manifest.json"), manifest)
    XCTAssertThrowsError(try NativeProject.verify(p))
  }
  func testWAVMontageFramePreservation() throws {
    let folder = temporary()
    defer { try? fm.removeItem(at: folder) }
    let file = folder.appendingPathComponent("audio.wav")
    let montage = try WAVMontage(file)
    try montage.append([0.2, -0.4, 0.1])
    try montage.silence(7)
    try montage.append([0.5])
    try montage.finish()
    let samples = try NativeWAV.read(file)
    XCTAssertEqual(samples.count, 11)
    XCTAssertEqual(samples[10], 0.5)
    XCTAssertEqual(samples[3...9], ArraySlice([Float](repeating: 0, count: 7)))
  }
  func testBinaryDictionaryBounds() throws {
    let folder = temporary()
    defer { try? fm.removeItem(at: folder) }
    let file = folder.appendingPathComponent("test.sacc")
    func le<T: FixedWidthInteger>(_ n: T) -> Data {
      var v = n.littleEndian
      return withUnsafeBytes(of: &v) { Data($0) }
    }
    var data = Data("SACC".utf8)
    data += le(UInt32(1))
    data += le(UInt32(1))
    data += le(UInt64(28))
    data += le(UInt64(32))
    data += le(UInt32(0))
    let key = Data("книга".utf8)
    let value = Data("кн+ига".utf8)
    data += le(UInt16(key.count))
    data += le(UInt16(value.count))
    data += key
    data += value
    try data.write(to: file)
    let dict = try AccentDictionary(file)
    XCTAssertEqual(try dict.lookup("книга"), "кн+ига")
    XCTAssertNil(try dict.lookup("кот"))
    try Data("SACC".utf8).write(to: file)
    XCTAssertThrowsError(try AccentDictionary(file))
  }
  func testRoleLevelStaysInAudiobookRange() {
    XCTAssertEqual(NativeAudio.loudnessTarget([(-24, -12), (-19, -8)]), -20)
    XCTAssertEqual(NativeAudio.loudnessTarget([(-20, -0.2)]), -21.4, accuracy: 0.0001)
    // One transient peak must not pull the whole book far below -20 LUFS.
    XCTAssertEqual(NativeAudio.loudnessTarget([(-24, -0.2)]), -23)
    XCTAssertEqual(NativeAudio.loudnessTarget([]), -20)
  }
  func testCastMergeKeepsIdentityAcrossChunks() throws {
    let first = try NativeDirector.mergeCast([], [
      ["id": "myshkin", "name": "Князь Мышкин", "gender": "unknown", "aliases": ["Князь"]],
    ])
    let merged = try NativeDirector.mergeCast(first, [
      ["id": "myshkin", "name": "Мышкин", "gender": "male", "aliases": ["Лев Николаевич"]],
      ["id": "rogozhin", "name": "Рогожин", "gender": "male"],
    ])
    XCTAssertEqual(merged.count, 2)
    XCTAssertEqual(NativeIO.string(merged[0]["name"]), "Князь Мышкин")
    XCTAssertEqual(NativeIO.string(merged[0]["gender"]), "male")
    XCTAssertEqual(merged[0]["aliases"] as? [String], ["Князь", "Лев Николаевич", "Мышкин"])
    let fixed = try NativeDirector.mergeCast(merged, [["id": "myshkin", "name": "Мышкин", "gender": "female"]])
    XCTAssertEqual(NativeIO.string(fixed[0]["gender"]), "male")
    XCTAssertThrowsError(try NativeDirector.mergeCast(merged, []))
    let folded = try NativeDirector.mergeCast(merged, [
      ["id": "dühring", "name": "Дюринг", "gender": "male"], ["id": "Князь", "name": "Князь"],
      ["id": "", "name": "Старый слуга"],
    ])
    XCTAssertEqual(folded.map { NativeIO.string($0["id"]) }, ["myshkin", "rogozhin", "duhring", "knyaz", "staryy_sluga"])
    XCTAssertEqual(NativeDirector.castID("2nd Officer"), "c_2nd_officer")
    XCTAssertThrowsError(try NativeDirector.mergeCast(merged, [["id": "", "name": " "]]))
  }
  func testProfileKeepsOnlyVerifiableEvidence() throws {
    var card: Object = [
      "id": "hero", "age": "30", "personality": "Смелый", "habits": "Пауза",
      "speaking_style": "Быстро", "voice_description": "Bright tenor", "certainty": "medium",
      "assumptions": ["Возраст примерный"],
      "evidence": [
        ["kind": "book", "reference": "p00001", "note": "Реплика"],
        ["kind": "book", "reference": "p99999", "note": "Выдумано"],
        ["kind": "web", "reference": "https://unknown.example", "note": "Нет в поиске"],
      ],
    ]
    let profile = try NativeDirector.validateProfile(
      card, id: "hero", paragraphIDs: ["p00001"], urls: [])
    XCTAssertEqual(NativeIO.objects(profile["evidence"]).count, 1)
    card["evidence"] = [["kind": "book", "reference": "p99999"]]
    XCTAssertThrowsError(try NativeDirector.validateProfile(card, id: "hero", paragraphIDs: ["p00001"], urls: []))
    card["evidence"] = [["kind": "book", "reference": "p00001"]]
    XCTAssertThrowsError(try NativeDirector.validateProfile(card, id: "villain", paragraphIDs: ["p00001"], urls: []))
  }
  func testSpeakerAnswersKeepValidRowsOnly() {
    let rows: [Object] = [
      ["id": "seg1", "speaker": "hero"], ["id": "seg2", "speaker": "ghost"],
      ["id": "seg3", "speaker": NSNull()], ["id": "seg9", "speaker": "hero"],
    ]
    let result = NativeDirector.acceptAssignments(
      rows, ids: ["seg1", "seg2", "seg3"], allowed: ["hero", "narrator"])
    XCTAssertEqual(result, ["seg1": "hero", "seg3": ""])
  }
  func testCloudStressAppliesOnlyValidWords() {
    let text = "Мама мыла раму."
    // Word IDs follow regex order: 0 "Мама", 1 "мыла", 2 "раму".
    let rows: [Object] = [
      ["id": 0, "word": "Ма\u{301}ма"], ["id": 1, "word": "мы\u{301}лла"],
      ["id": "2", "word": "р\u{301}аму"],
    ]
    XCTAssertEqual(NativeDirector.applyStress(text, rows: rows), "Ма\u{301}ма мыла раму.")
    XCTAssertEqual(NativeDirector.applyStress(text, rows: []), text)
  }
  func testStressKeepsYoAndBookLetters() {
    // Dictionaries and homographs know 'ё' that books often print as 'е'.
    XCTAssertEqual(NativeStress.transfer("Еще", "ещё\u{301}"), "Ещё")
    XCTAssertEqual(NativeStress.transfer("осел", "ос+ёл"), "осёл")
    XCTAssertEqual(NativeStress.transfer("осел", "ос+ел"), "осе\u{301}л")
    XCTAssertEqual(NativeStress.transfer("все", "вс+ё"), "всё")
    // One-vowel words get no mark; two-vowel words keep theirs.
    XCTAssertEqual(NativeStress.transfer("все", "вс+е"), "все")
    XCTAssertEqual(NativeStress.transfer("домой", "дом+ой"), "домо\u{301}й")
    XCTAssertEqual(NativeStress.transfer("Кто-то", "кто\u{301}-то"), "Кто\u{301}-то")
    XCTAssertEqual(NativeStress.transfer("книга", "стол"), "книга")
    XCTAssertEqual(NativeStress.vowelCount("домо\u{301}й"), 2)
    // Silero exceptions: [stressed character, 'е' that is 'ё' or -1].
    XCTAssertEqual(NativeStress.exception("берет", ["берет": [3, 3]]), "берёт")
    XCTAssertEqual(NativeStress.exception("того", ["того": [3, -1]]), "того\u{301}")
    XCTAssertNil(NativeStress.exception("того", ["того": [2, -1]]))
  }
  func testCloudStressChoosesOnlyPreparedHomographReadings() {
    let text = "Всё ра\u{301}вно мы узна\u{301}ем."
    let disputes = [1: ["ра\u{301}вно", "равно\u{301}"]]
    XCTAssertEqual(
      NativeDirector.applyStress(text, rows: [["id": 1, "word": "равно\u{301}"]], disputes: disputes),
      "Всё равно\u{301} мы узна\u{301}ем.")
    XCTAssertEqual(
      NativeDirector.applyStress(text, rows: [["id": 1, "word": "ра\u{301}вно\u{301}"]], disputes: disputes),
      text)
    XCTAssertEqual(NativeDirector.stressCandidates(text, disputes: disputes).map(\.id), [1])
  }
  func testLLMHTTPFailuresAreClassified() throws {
    let body = Data("{\"error\":\"model overloaded\"}".utf8)
    XCTAssertTrue(NativeDirector.httpError(503, body) is TransientLLMError)
    XCTAssertTrue(NativeDirector.httpError(429, Data()) is TransientLLMError)
    let rejected = NativeDirector.httpError(401, Data("{\"error\":\"bad key secret\"}".utf8), key: "secret")
    XCTAssertTrue(rejected is StudioError)
    XCTAssertTrue(rejected.localizedDescription.contains("ключ"))
    XCTAssertFalse(rejected.localizedDescription.contains("secret"))
    // DeepSeek: OpenAI-style error object and chat completion body.
    let balance = NativeDirector.httpError(402, Data("{\"error\":{\"message\":\"Insufficient Balance\"}}".utf8), service: "DeepSeek")
    XCTAssertTrue(balance.localizedDescription.contains("DeepSeek") && balance.localizedDescription.contains("Insufficient Balance"))
    func completion(_ content: String, _ reason: String = "stop") -> Data {
      try! NativeIO.json(["choices": [["finish_reason": reason, "message": ["role": "assistant", "content": content]]]])
    }
    XCTAssertEqual(NativeIO.string(try LLMReply.parseChatCompletion(completion("{\"voice\":\"low\"}"))["voice"]), "low")
    for bad in [completion(""), completion("{\"a\":", "length"), Data("{\"error\":{\"message\":\"x\"}}".utf8)] {
      do { _ = try LLMReply.parseChatCompletion(bad); XCTFail("accepted a broken completion") }
      catch { XCTAssertTrue((error as? StudioError)?.message.hasPrefix("LLM:") == true) }
    }
  }
  func testOwnSampleSurvivesMovedProject() throws {
    let folder = temporary()
    defer { try? fm.removeItem(at: folder) }
    let sample = folder.appendingPathComponent("voice-samples/hero.wav")
    try fm.createDirectory(at: sample.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("wav".utf8).write(to: sample)
    XCTAssertEqual(NativeProject.sampleURL("voice-samples/hero.wav", project: folder).path, sample.path)
    XCTAssertEqual(NativeProject.sampleURL("/old/place/voice-samples/hero.wav", project: folder).path, sample.path)
    XCTAssertEqual(NativeProject.sampleURL("../../etc/hero.wav", project: folder).path,
      folder.appendingPathComponent("etc/hero.wav").path)
  }
  func testEPUBDivTextDuplicateIDsAndCover() throws {
    let folder = temporary()
    defer { try? fm.removeItem(at: folder) }
    let book = folder.appendingPathComponent("book")
    try fm.createDirectory(at: book.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try fm.createDirectory(at: book.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: book.appendingPathComponent("mimetype"))
    try Data("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)
      .write(to: book.appendingPathComponent("META-INF/container.xml"))
    try Data("<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Книга</dc:title><meta name=\"cover\" content=\"img\"/></metadata><manifest><item id=\"c1\" href=\"c1.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"c1\" href=\"other.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"img\" href=\"cover.jpg\" media-type=\"image/jpeg\"/></manifest><spine><itemref idref=\"c1\"/></spine></package>".utf8)
      .write(to: book.appendingPathComponent("OEBPS/content.opf"))
    try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><body><div class=\"chapter\"><h1>Глава</h1><div>Текст прямо в блоке.</div></div></body></html>".utf8)
      .write(to: book.appendingPathComponent("OEBPS/c1.xhtml"))
    let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    try image.write(to: book.appendingPathComponent("OEBPS/cover.jpg"))
    let epub = folder.appendingPathComponent("book.epub")
    try NativeIO.zip(book, to: epub, epub: true)
    let parsed = try NativeBook.read(epub)
    XCTAssertEqual(
      NativeIO.objects(parsed["paragraphs"]).map { NativeIO.string($0["text"]) },
      ["Глава", "Текст прямо в блоке."])
    let cover = try XCTUnwrap(NativeBook.cover(epub))
    XCTAssertEqual(cover.data, image)
    XCTAssertEqual(cover.ext, "jpg")
  }
  func testEPUBReadAlongPreservesText() throws {
    let folder = temporary()
    defer { try? fm.removeItem(at: folder) }
    let text = "Ёж 😀 сказал: «Я дома!»"
    let id = "seg000001"
    let source: Object = [
      "paragraphs": [["id": "p00001", "chapter_id": "ch001", "text": text]],
      "chapters": [["id": "ch001", "title": "Первая глава"]],
    ]
    let manifest: Object = [
      "book": ["title": "Тест", "author": "Автор"],
      "segments": [
        [
          "id": id, "paragraph_id": "p00001", "chapter_id": "ch001", "text": text,
          "source": ["char_start": 0, "char_end": text.unicodeScalars.count],
        ]
      ],
    ]
    let audio = folder.appendingPathComponent("fixture.m4b")
    try Data("fixture".utf8).write(to: audio)
    let output = folder.appendingPathComponent("fixture.epub")
    try NativeBook.epub(
      manifest, source: source,
      timeline: [["segment_id": id, "audio_start": 0.0, "clip_end": 1.0]], audio: audio,
      output: output, cover: (Data([0x89, 0x50, 0x4E, 0x47]), "png"))
    let parsed = try NativeBook.read(output)
    XCTAssertEqual(
      NativeIO.objects(parsed["paragraphs"]).map { NativeIO.string($0["text"]) }, [text])
    XCTAssertEqual(NativeIO.string(parsed["title"]), "Тест")
    XCTAssertEqual(NativeBook.cover(output)?.ext, "png")
  }

}
