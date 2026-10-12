import XCTest

@testable import StudioCore

final class CoreTests: XCTestCase {
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
    XCTAssertEqual(bytes, NativeWAV.bytes(first) + Data(repeating: 0, count: 2400 * 4) + NativeWAV.bytes(last))
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
  func testCompressedSpeechIsBitExactAndCorruptionIsRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("segment.spcm")
    let samples = [Float](repeating: 0.03125, count: 24000) + [0, -0.0, Float.leastNonzeroMagnitude, -0.125, 1.25]
    try SpeechCache.save(file, samples: samples, signature: "test")
    let restored = try SpeechPCM.read(file)
    XCTAssertEqual(NativeWAV.bytes(restored), NativeWAV.bytes(samples))
    XCTAssertEqual(SpeechCache.load(file, signature: "test"), samples)
    XCTAssertTrue(try Data(contentsOf: file).count < samples.count * 4)
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
    XCTAssertTrue(jobs.filter { $0.count > 2 }.allSatisfy { $0.allSatisfy { SpeechRecovery.text(NativeIO.string(rows[$0]["tts_text"])).count <= 96 } })
    // Long lines pair only with a similar length; very long ones stay alone.
    let long: [Object] = [200, 210, 205, 120, 600].enumerated().map { i, n in
      ["id": "l\(i)", "speaker": "v\(i % 2)", "tts_text": String(repeating: "а", count: n)]
    }
    XCTAssertEqual(try SpeechBatch.plan(long, pending: Set(long.indices)), [[0, 1], [2], [3], [4]])
    XCTAssertEqual(jobs.first(where: { $0.contains(7) }), [7])
    XCTAssertTrue(try SpeechBatch.plan(rows, pending: pending, maximum: 1).allSatisfy { $0.count == 1 })
    XCTAssertThrowsError(try SpeechBatch.plan(rows, pending: [100]))
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

  func testEveryVoiceDetailInvalidatesDirection() throws {
    let profile: Object = [
      "age": "Пожилой, 70 лет", "personality": "Сдержанный",
      "habits": "Длинные паузы", "speaking_style": "Медленно, тихо",
      "voice_description": "Low resonant baritone",
    ]
    var voice: Object = ["voice_gender": "male", "character_profile": profile]
    voice["tts_instruction"] =
      "Elderly male, low resonant baritone, slow restrained delivery and thoughtful pauses."
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
    for bad: Object in [
      ["paragraphs": [["id": "p00001", "speakers": ["hero"]]]],
      ["paragraphs": [["id": "p00001", "speakers": ["hero", "ghost", "hero", "hero"]]]],
      ["paragraphs": [["id": "p00002", "speakers": ["hero", "narrator", "hero", "hero"]]]],
    ] {
      XCTAssertThrowsError(try NativeDirector.validateSpeakers(
        bad, chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"]))
    }
    // Manner splits a speaker's span; narrator is always calm; a broken list is calm, not an error.
    let toned = try NativeDirector.validateSpeakers(["paragraphs": [[
      "id": "p00001", "speakers": ["hero", "narrator", "hero", "hero"],
      "manners": ["joyful", "angry", "angry", "shouting"]]]], chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"])
    XCTAssertEqual(NativeIO.objects(toned[0]["spans"]).map { NativeIO.string($0["manner"]) }, ["joyful", "calm", "angry", "calm"])
    let untoned = try NativeDirector.validateSpeakers(["paragraphs": [[
      "id": "p00001", "speakers": ["hero", "narrator", "hero", "hero"], "manners": ["angry"]]]],
      chunk: [paragraph], fragments: split, allowed: ["hero", "narrator"])
    XCTAssertEqual(NativeIO.objects(untoned[0]["spans"]).map { NativeIO.string($0["manner"]) }, ["calm", "calm", "calm"])
    XCTAssertEqual(VoiceDirection.mannerInstruction(["tts_voice": "Old frail male voice.", "tts_delivery": "Slow."], manner: "angry"),
      "Old frail male voice. " + VoiceDirection.manners["angry"]! + " Slow." + VoiceDirection.readingRules)
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
    XCTAssertEqual(try ru.normalize("Главы I, II и III"), "Главы первая, вторая и третья")
    XCTAssertEqual(
      try ru.normalize("В 1870 он вернулся."), "В тысяча восемьсот семидесятом он вернулся.")
    XCTAssertEqual(
      try ru.normalize("21.01.2024"), "двадцать первого января две тысячи двадцать четвёртого года")
    XCTAssertEqual(try ru.normalize("12:30"), "двенадцать часов тридцать минут")
    XCTAssertEqual(try ru.normalize("Цена 2,5 кг"), "Цена две целых пять десятых килограмма")
    XCTAssertEqual(try ru.normalize("https://site.ru/page12"), "https://site.ru/page12")
    XCTAssertThrowsError(try ru.normalize("31.02.2024"))
  }
  func testSplitKeepsScalarText() throws {
    let text =
      "Очень длинная реплика. Следующая мысль 😀 состоит из нескольких слов. И ещё немного текста."
    let chunks = NativeBook.split(text, maximum: 35)
    let result = try chunks.map { try NativeIO.scalarSlice(text, $0.0, $0.1) }.joined(
      separator: " ")
    XCTAssertEqual(result, text)
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
    XCTAssertThrowsError(try NativeDirector.mergeCast(merged, [["id": "Князь", "name": "Князь"]]))
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
  func testLLMHTTPFailuresAreClassified() {
    let body = Data("{\"error\":\"model overloaded\"}".utf8)
    XCTAssertTrue(NativeDirector.httpError(503, body) is TransientLLMError)
    XCTAssertTrue(NativeDirector.httpError(429, Data()) is TransientLLMError)
    let rejected = NativeDirector.httpError(401, Data("{\"error\":\"bad key secret\"}".utf8), key: "secret")
    XCTAssertTrue(rejected is StudioError)
    XCTAssertTrue(rejected.localizedDescription.contains("ключ"))
    XCTAssertFalse(rejected.localizedDescription.contains("secret"))
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
