import XCTest

@testable import StudioCore

final class CoreTests: XCTestCase {
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
  func testRolesPreserveAllText() throws {
    let paragraph: Object = ["id": "p00001", "text": "— Да! 😀 — сказал он."]
    let answer: Object = [
      "paragraphs": [
        [
          "id": "p00001",
          "segments": [
            ["text": "— Да! 😀", "speaker": "hero"],
            ["text": "— сказал он.", "speaker": "narrator"],
          ],
        ]
      ]
    ]
    let rows = try NativeDirector.validateRoles(
      answer, chunk: [paragraph], allowed: ["hero", "narrator"])
    let spans = NativeIO.objects(rows[0]["spans"])
    XCTAssertEqual(spans[1]["start"] as? Int, 8)
    let bad: Object = [
      "paragraphs": [["id": "p00001", "segments": [["text": "— Да! 😀", "speaker": "hero"]]]]
    ]
    XCTAssertThrowsError(
      try NativeDirector.validateRoles(bad, chunk: [paragraph], allowed: ["hero"]))
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
