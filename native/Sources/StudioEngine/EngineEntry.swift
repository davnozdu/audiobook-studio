import Darwin
import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
import MLXLMCommon
@preconcurrency import MLXRandom
import StudioCore

@main struct StudioEngine {
  static func main() async {
    _ = setpgid(0, 0)
    // A crashed helper must produce an error event, not kill the engine on a pipe write.
    signal(SIGPIPE, SIG_IGN)
    // Library diagnostics must not corrupt the JSON event stream.
    _ = NativeIO.eventOutput
    dup2(STDERR_FILENO, STDOUT_FILENO)
    do {
      let bundleURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/mlx-swift_Cmlx.bundle")
      guard
        let library = Bundle(url: bundleURL)?.url(forResource: "default", withExtension: "metallib")
      else {
        throw StudioError("В приложении отсутствуют нативные Metal-ядра")
      }
      GPU.metallib = library
      // Keep reusable buffers during synthesis (1/8 of RAM, 512 MB–4 GB): a smaller pool
      // makes Metal reallocate per token. The pool is cleared when each model is released.
      Memory.cacheLimit = Int(min(UInt64(4096 * 1024 * 1024),
        max(UInt64(512 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 8)))
      if CommandLine.arguments.contains("--self-check") {
        let batchError = try Qwen3TTSModel.studioBatchSelfCheck()
        NativeIO.emit("log", ["message": "Qwen batch B=4: padding, позиции и независимые потоки совпадают с одиночным расчётом · ошибка " + String(batchError)])
        let codecIDs = MLXArray([Int32(14), 0, 23, 0, 7, -1])
        guard Qwen3TTSModel.studioDecodedFrameCount(codecIDs, upsampleRate: 1920) == 9600,
          Qwen3TTSModel.studioDecodedFrameCount(MLXArray([Int32(-1), -1]), upsampleRate: 1920) == 0
        else { throw StudioError("Декодер обрезает допустимые нулевые аудиотокены") }
        NativeIO.emit("log", ["message": "Qwen codec: нулевые аудиотокены сохраняют полную длину"])
        let resources = URL(fileURLWithPath: CommandLine.arguments.last!)
        let binaries = resources.deletingLastPathComponent().appendingPathComponent("runtime/bin")
        try NativeAudio(ffmpeg: binaries.appendingPathComponent("ffmpeg"), ffprobe: binaries.appendingPathComponent("ffprobe")).streamingSelfCheck()
        NativeIO.emit("log", ["message": "Потоковая сборка: AAC, музыка, EPUB и очистка проверены без полных WAV-копий"])
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
          .appendingPathComponent("StudioStress")
        let values = (MLXArray([Float(1), Float(4)]) + 1).asArray(Float.self)
        guard values == [2, 5] else { throw StudioError("Нативные Metal-ядра не работают") }
        let fixture = try NativeIO.load(resources.appendingPathComponent("qwen-speaker-mel-check.json"))
        let signal = (0..<4096).map { i -> Float in
          0.2 * Float(sin(2 * Double.pi * 437 * Double(i) / 24000))
            + 0.07 * Float(cos(2 * Double.pi * 3100 * Double(i) / 24000))
            + Float((i % 97) - 48) * 0.0001
        }
        let mel = Qwen3TTSModel.studioSpeakerMel(audio: MLXArray(signal))
        guard mel.shape == (fixture["shape"] as? [Int] ?? []) else {
          throw StudioError("Размер спектра личности голоса не совпадает с Qwen")
        }
        var maxError: Float = 0
        for point in fixture["points"] as? [[Double]] ?? [] {
          let actual = mel[Int(point[0]), Int(point[1])].item(Float.self)
          maxError = max(maxError, abs(actual - Float(point[2])))
        }
        guard (fixture["points"] as? [[Double]])?.count == 28, maxError < 0.002 else {
          throw StudioError("Расчёт личности голоса расходится с PyTorch/librosa · " + String(maxError))
        }
        NativeIO.emit("log", ["message": "Qwen speaker mel соответствует эталону · максимальная ошибка " + String(maxError)])
        let stress = try NativeStress(resources: resources, helper: helper)
        _ = try stress.request(["words": [], "homographs": []])
        _ = try RussianText(resources.appendingPathComponent("supertonic_rules.json"))
        NativeIO.emit("done", ["message": "Нативный комплект готов"])
        return
      }
      guard let line = readLine(), let data = line.data(using: .utf8) else {
        throw StudioError("Нет запроса")
      }
      let request = NativeIO.object(try JSONSerialization.jsonObject(with: data))
      try await Engine(request).run()
    } catch {
      NativeIO.emit("error", ["message": error.localizedDescription])
      exit(1)
    }
  }
}
final class Engine {
  let request: Object, resources: URL, root: URL, audio: NativeAudio, models: NativeModels
  let fm = FileManager.default
  init(_ request: Object) {
    self.request = request
    resources = URL(fileURLWithPath: NativeIO.string(request["resources"]))
    root = URL(fileURLWithPath: NativeIO.string(request["runtime"]))
    models = NativeModels(root: root, resources: resources)
    audio = NativeAudio(
      ffmpeg: URL(fileURLWithPath: NativeIO.string(request["ffmpeg"])),
      ffprobe: URL(fileURLWithPath: NativeIO.string(request["ffprobe"])))
  }
  var project: URL { URL(fileURLWithPath: NativeIO.string(request["project"])) }
  func done(_ message: String, path: URL? = nil) {
    var data: Object = ["message": message]
    if let path { data["path"] = path.path }
    NativeIO.emit("done", data)
  }
  func writeManifest(_ value: Object, at folder: URL) throws {
    try NativeIO.write(folder.appendingPathComponent("roles/manifest.json"), value)
    try NativeIO.write(
      folder.appendingPathComponent("roles/voices.json"), ["voices": value["voices"]!])
    try NativeIO.write(
      folder.appendingPathComponent("characters.json"),
      [
        "input_sha256": NativeIO.object(value["book"])["input_sha256"]!,
        "characters": NativeIO.objects(value["voices"]).map {
          NativeIO.object($0["character_profile"])
        },
      ])
  }
  func edits(_ value: Object) throws -> Object {
    var manifest = value
    var segments = NativeIO.objects(value["segments"])
    let edits = NativeIO.object(request["edits"])
    let voices = NativeIO.objects(value["voices"])
    let ids = Set(segments.map { NativeIO.string($0["id"]) })
    guard Set(edits.keys).isSubset(of: ids) else { throw StudioError("Неизвестный фрагмент") }
    for i in segments.indices {
      if let speaker = edits[NativeIO.string(segments[i]["id"])] as? String {
        // "Not determined" hands the line back to automatic speaker resolution.
        if speaker.isEmpty {
          segments[i]["speaker"] = NSNull()
          segments[i]["voice_id"] = NSNull()
          segments[i]["needs_review"] = true
          segments[i]["confidence"] = "low"
          segments[i]["reason"] = "Пользователь снял назначение"
          continue
        }
        guard let voice = voices.first(where: { NativeIO.string($0["id"]) == speaker }) else {
          throw StudioError("Неизвестный персонаж")
        }
        segments[i]["speaker"] = speaker
        segments[i]["voice_id"] = voice["voice_id"]
        segments[i]["needs_review"] = false
        segments[i]["confidence"] = "high"
        segments[i]["reason"] = "Проверено пользователем"
      }
    }
    manifest["segments"] = segments
    return manifest
  }
  func applyProfiles(_ value: Object) throws -> Object {
    var manifest = value
    var voices = NativeIO.objects(value["voices"])
    let profiles = NativeIO.object(request["profiles"])
    guard
      NativeIO.string(profiles["input_sha256"])
        == NativeIO.string(NativeIO.object(value["book"])["input_sha256"])
    else { throw StudioError("Карточки относятся к другой книге") }
    let rows = NativeIO.objects(profiles["characters"])
    guard rows.count == voices.count,
      Set(rows.map { NativeIO.string($0["id"]) }).count == voices.count
    else { throw StudioError("Изменён список персонажей") }
    for i in voices.indices {
      guard
        let profile = rows.first(where: {
          NativeIO.string($0["id"]) == NativeIO.string(voices[i]["id"])
        })
      else { throw StudioError("Нет карточки персонажа") }
      for field in ["age", "personality", "habits", "speaking_style", "voice_description"] {
        guard profile[field] is String else { throw StudioError("Некорректное поле " + field) }
      }
      voices[i]["character_profile"] = profile
      voices[i]["age"] = profile["age"]
      voices[i]["voice_description"] = profile["voice_description"]
      voices[i]["instruct"] = profile["voice_description"]
    }
    manifest["voices"] = voices
    return manifest
  }
  func run() async throws {
    if fm.fileExists(atPath: project.appendingPathComponent("roles/manifest.json").path) {
      try NativeIO.beginLog(project)
    }
    switch NativeIO.string(request["action"]) {
    case "prepare":
      let book = URL(fileURLWithPath: NativeIO.string(request["book"]))
      let fb2 = NativeFB2.accepts(book)
      guard book.pathExtension.lowercased() == "epub" || fb2, fm.fileExists(atPath: book.path) else {
        throw StudioError("Выберите книгу EPUB или FB2")
      }
      let project = URL(fileURLWithPath: NativeIO.string(request["output"])).appendingPathComponent(
        NativeFB2.baseName(book) + "-" + UUID().uuidString.prefix(8))
      try fm.createDirectory(
        at: project.appendingPathComponent("roles"), withIntermediateDirectories: true)
      if fb2 {
        // The original stays untouched beside a working EPUB copy; the read-along EPUB is
        // still assembled at the end from the spoken text and audio.
        NativeIO.stage("Чтение FB2 и подготовка рабочей копии EPUB")
        try fm.copyItem(at: book, to: project.appendingPathComponent("original-" + book.lastPathComponent))
        try NativeFB2.convert(book, to: project.appendingPathComponent("book.epub"))
      } else {
        try fm.copyItem(at: book, to: project.appendingPathComponent("book.epub"))
      }
      try NativeIO.beginLog(project)
      NativeIO.emit("project", ["path": project.path])
      // The project exists now: invalid LLM answers of this first analysis are kept for diagnosis.
      var directed = request; directed["project"] = project.path
      try await NativeDirector(directed).prepare(
        project, book: project.appendingPathComponent("book.epub"))
      let (manifest, _) = try NativeProject.verify(project)
      try writeManifest(manifest, at: project)
      done("Персонажи, роли и характеры готовы", path: project)
    case "characters":
      let (manifest, source) = try NativeProject.verify(project)
      let director = NativeDirector(request)
      let resolved = try await director.resolve(manifest, source: source)
      try writeManifest(try await director.characterize(resolved, source: source), at: project)
      done("Карточки и голоса обновлены", path: project)
    case "save", "roles-save":
      let (value, _) = try NativeProject.verify(project)
      var manifest = try edits(value)
      if NativeIO.string(request["action"]) == "save" { manifest = try applyProfiles(manifest) }
      try writeManifest(manifest, at: project)
      _ = try NativeProject.verify(project)
      done("Изменения сохранены", path: project)
    case "project-export":
      NativeIO.stage("Сохранение проекта · книга, голоса и аудио")
      try NativeProject.export(
        project, destination: URL(fileURLWithPath: NativeIO.string(request["destination"])),
        settings: NativeIO.object(request["settings"]))
      done("Проект сохранён в один файл")
    case "project-open":
      NativeIO.stage("Открытие проекта")
      let folder = try NativeProject.open(
        URL(fileURLWithPath: NativeIO.string(request["archive"])),
        output: URL(fileURLWithPath: NativeIO.string(request["output"])))
      NativeIO.emit("project", ["path": folder.path])
      done("Проект открыт · можно изменить голоса и собрать книгу заново", path: folder)
    case "sample":
      try sample()
      done("Образец голоса обновлён", path: project)
    case "voice-preview": try await preview()
    case "setup":
      try models.setup()
      done("Нативный движок и модели готовы")
    case "build": try await build()
    default: throw StudioError("Неизвестная команда")
    }
  }
  func sample() throws {
    var (manifest, _) = try NativeProject.verify(project)
    var voices = NativeIO.objects(manifest["voices"])
    guard
      let index = voices.firstIndex(where: {
        NativeIO.string($0["id"]) == NativeIO.string(request["character"])
      })
    else { throw StudioError("Неизвестный персонаж") }
    if request["remove"] as? Bool == true {
      voices[index].removeValue(forKey: "custom_reference")
    } else {
      let text = NativeIO.string(request["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw StudioError("Введите точный текст образца") }
      let sampleURL = URL(fileURLWithPath: NativeIO.string(request["sample"]))
      guard (3...30).contains(try audio.duration(sampleURL)) else {
        throw StudioError("Выберите чистый образец одного голоса длительностью 3–30 секунд")
      }
      let samples = try audio.convert(sampleURL)
      let seconds = Double(samples.count) / 24000
      guard (3...30).contains(seconds) else {
        throw StudioError("Выберите чистый образец одного голоса длительностью 3–30 секунд")
      }
      let relative = "voice-samples/" + NativeIO.string(voices[index]["id"]) + ".wav"
      let target = project.appendingPathComponent(relative)
      try NativeWAV.write(target, samples)
      voices[index]["custom_reference"] = [
        "path": relative, "text": text, "seconds": seconds,
        "sha256": try NativeIO.hashFile(target),
      ]
    }
    manifest["voices"] = voices
    try writeManifest(manifest, at: project)
  }
  func custom(_ voice: Object) throws -> (URL, String)? {
    let ref = NativeIO.object(voice["custom_reference"])
    guard !ref.isEmpty else { return nil }
    let url = NativeProject.sampleURL(NativeIO.string(ref["path"]), project: project)
    let text = NativeIO.string(ref["text"])
    guard fm.fileExists(atPath: url.path) else {
      throw StudioError("Не найден собственный образец · " + NativeIO.string(voice["name"]) + " · загрузите его снова")
    }
    guard !text.isEmpty, try NativeIO.hashFile(url) == NativeIO.string(ref["sha256"]) else {
      throw StudioError("Повреждён собственный образец · " + NativeIO.string(voice["name"]))
    }
    return (url, text)
  }
  func instruction(_ voice: Object) -> String {
    NativeIO.string(voice["tts_instruction"])
  }
  func generate(
    _ model: Qwen3TTSModel, text: String, description: String?, reference: (URL, String)?, seed: Int
  ) async throws -> [Float] {
    if reference == nil, !VoiceDirection.validEnglish(description ?? "") {
      throw StudioError("Не подготовлена английская инструкция голоса")
    }
    if reference == nil {
      NativeIO.emit("log", ["message": "Инструкция VoiceDesign: " + (description ?? "")])
    }
    let ref: MLXArray?
    if let reference {
      let (_, array) = try loadAudioArray(from: reference.0, sampleRate: 24000)
      ref = array
    } else {
      ref = nil
    }
    return try await SpeechRecovery.generate(text: text, seed: seed, label: "образец голоса") { spoken, attemptSeed in
      MLXRandom.seed(UInt64(attemptSeed))
      let audio = try await model.generate(
        text: spoken, voice: description, refAudio: ref, refText: reference?.1, language: "Russian",
        generationParameters: GenerateParameters(
          maxTokens: 4096, temperature: 0.9, topP: 1, topK: 50, repetitionPenalty: 1.05))
      return audio.asArray(Float.self)
    }
  }
  func preview() async throws {
    var text = NativeIO.string(request["text"])
    var description = NativeIO.string(request["description"])
    var reference: (URL, String)?
    var profileSignature = "", referenceHash = ""
    let character = NativeIO.string(request["character"])
    if !character.isEmpty {
      var (manifest, _) = try NativeProject.verify(project)
      text = try NativeProject.excerpt(manifest, character: character)
      guard
        let voice = NativeIO.objects(manifest["voices"]).first(where: {
          NativeIO.string($0["id"]) == character
        })
      else { throw StudioError("Неизвестный персонаж") }
      reference = try custom(voice)
      if reference == nil {
        let directed = try await NativeDirector(request).directVoice(voice)
        manifest["voices"] = NativeIO.objects(manifest["voices"]).map {
          NativeIO.string($0["id"]) == character ? directed : $0
        }
        try writeManifest(manifest, at: project)
        description = instruction(directed)
        profileSignature = try VoiceDirection.signature(directed)
      } else {
        referenceHash = NativeIO.string(NativeIO.object(voice["custom_reference"])["sha256"])
      }
    } else if VoiceDirection.validEnglish(description) {
      // An English description is already a VoiceDesign instruction; no LLM request.
      description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        + VoiceDirection.readingRules
    } else {
      description = instruction(
        try await NativeDirector(request).directVoice(["voice_description": description]))
    }
    guard (20...1000).contains(text.count),
      reference != nil || (10...4000).contains(description.count)
    else {
      throw StudioError("Задайте текст 20–1000 знаков и описание голоса")
    }
    let seed = request["seed"] as? Int ?? 17001
    let signature = try VoiceSample.signature(text: text, instruction: description,
      profile: profileSignature, reference: referenceHash, seed: seed)
    let voiceLab = root.deletingLastPathComponent().appendingPathComponent("VoiceLab")
    if character.isEmpty {
      // Only the newest generator sample is shown; saved copies live where the user put them.
      for old in (try? fm.contentsOfDirectory(at: voiceLab, includingPropertiesForKeys: nil)) ?? [] {
        try? fm.removeItem(at: old)
      }
    }
    let file = character.isEmpty
      ? voiceLab.appendingPathComponent(UUID().uuidString + "/sample.wav")
      : project.appendingPathComponent("preview-samples/" + character + ".wav")
    let meta = file.deletingPathExtension().appendingPathExtension("json")
    if !character.isEmpty, let old = try? NativeIO.load(meta),
      NativeIO.string(old["signature"]) == signature,
      let hash = try? NativeIO.hashFile(file), hash == NativeIO.string(old["sha256"])
    {
      NativeIO.emit("sample", ["path": file.path, "text": text, "description": description, "character": character])
      done("Сохранённая проба готова · без загрузки модели и повторной генерации")
      return
    }
    NativeIO.stage("Проверка модели · проба выбранного голоса")
    let path = try models.ensure(design: reference == nil)
    NativeIO.stage("Загрузка модели в память · нативный MLX")
    NativeIO.emit(
      "log", ["message": "Текст пробы [\(character.isEmpty ? "генератор":character)]: " + text])
    let samples = try await previewSamples(at: path, text: text,
      description: reference == nil ? description : nil, reference: reference,
      seed: seed)
    Memory.clearCache()
    memoryLog("Модель пробы выгружена")
    try NativeWAV.write(file, samples)
    try NativeIO.write(
      meta, ["text": text, "description": description, "character": character,
        "signature": signature, "sha256": try NativeIO.hashFile(file)])
    NativeIO.emit(
      "sample",
      ["path": file.path, "text": text, "description": description, "character": character])
    done("Образец готов · модель будет выгружена")
  }
  func build() async throws {
    let destination = NativeIO.string(request["destination"])
    guard !destination.isEmpty, !fm.fileExists(atPath: destination) else {
      throw StudioError("Выберите новую папку для результата")
    }
    var (manifest, source) = try NativeProject.verify(project)
    NativeProject.cleanupBuildIntermediates(project)
    defer { NativeProject.cleanupBuildIntermediates(project) }
    NativeIO.emit("estimate", ["characters": NativeIO.objects(manifest["segments"]).reduce(0) { $0 + NativeIO.string($1["text"]).count }])
    let director = NativeDirector(request)
    // Stage durations go to run.log so slow steps can be measured on the user's Mac.
    var timings: [String] = []
    var mark = Date()
    func lap(_ name: String) {
      timings.append(name + String(format: " %.1f с", Date().timeIntervalSince(mark)))
      mark = Date()
    }
    if NativeIO.objects(manifest["segments"]).contains(where: {
      NativeIO.string($0["speaker"]).isEmpty
    }) {
      manifest = try await director.resolve(manifest, source: source)
      try writeManifest(manifest, at: project)
    }
    manifest = try NativeProject.speechBlocks(manifest, source: source)
    let basePath = try models.ensure(design: false)
    var voices = NativeIO.objects(manifest["voices"])
    let segments = NativeIO.objects(manifest["segments"])
    let used = Set(segments.map { NativeIO.string($0["speaker"]) })
    for i in voices.indices where used.contains(NativeIO.string(voices[i]["id"])) {
      if try custom(voices[i]) == nil {
        voices[i] = try await director.directVoice(voices[i])
      }
    }
    manifest["voices"] = voices
    try writeManifest(manifest, at: project)
    let designNeeded = try voices.contains { voice in
      guard used.contains(NativeIO.string(voice["id"])) else { return false }
      return try custom(voice) == nil
    }
    let designPath = designNeeded ? try models.ensure(design: true) : basePath
    lap("роли, инструкции и проверка моделей")
    NativeIO.stage("Нормализация текста · словари и нативный Silero")
    var prepared = manifest
    var rows = segments
    do {
      let ru = try RussianText(resources.appendingPathComponent("supertonic_rules.json"))
      let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("StudioStress")
      let stress = try NativeStress(resources: resources, helper: helper)
      let paragraphs = Dictionary(
        uniqueKeysWithValues: NativeIO.objects(source["paragraphs"]).map {
          (NativeIO.string($0["id"]), NativeIO.string($0["text"]))
        })
      var items: [NativeDirector.StressItem] = []
      for i in rows.indices {
        NativeIO.stage("Подготовка речи · \(i+1)/\(rows.count)", Double(i) / Double(rows.count))
        let normalized = try ru.normalize(NativeIO.string(rows[i]["text"]))
        let anchor = NativeIO.object(rows[i]["source"])
        let full = paragraphs[NativeIO.string(rows[i]["paragraph_id"])] ?? ""
        let before = try NativeIO.scalarSlice(full, 0, anchor["char_start"] as? Int ?? 0)
        let after = try NativeIO.scalarSlice(
          full, anchor["char_end"] as? Int ?? 0, full.unicodeScalars.count)
        rows[i]["tts_normalized"] = normalized
        let marked = try stress.annotate(normalized, prefix: before, suffix: after)
        rows[i]["tts_text"] = marked.text
        items.append(NativeDirector.StressItem(text: marked.text, context: full, disputes: marked.disputes))
      }
      if request["cloud_stress"] as? Bool == true {
        // About 4000 characters per request instead of one request per line. The check is
        // optional: without an answer the dictionary and Silero results stay.
        var batches: [[Int]] = [[]]
        var size = 0
        for i in rows.indices {
          if size > 4000 || batches[batches.count - 1].count >= 40 {
            batches.append([])
            size = 0
          }
          batches[batches.count - 1].append(i)
          size += items[i].text.count
        }
        for (number, batch) in batches.enumerated() where !batch.isEmpty {
          NativeIO.stage("Уточнение спорных ударений · LLM · \(number + 1)/\(batches.count)",
            Double(number) / Double(batches.count))
          do {
            let refined = try await director.refineStress(batch.map { items[$0] })
            for (i, text) in zip(batch, refined) { rows[i]["tts_text"] = text }
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            NativeIO.emit("log", ["message": "Проверка ударений LLM пропущена · пакет \(number + 1) · " + error.localizedDescription])
          }
        }
      }
    }
    // Names and surnames are often missing from the dictionaries: the LLM stresses each form
    // once per book (cached), and that answer wins over the dictionary/model guess.
    let castNames = voices.flatMap { [NativeIO.string($0["name"])] + ($0["aliases"] as? [String] ?? []) }
    let nameForms = ProperNames.collect(rows.map { NativeIO.string($0["text"]) }, names: castNames)
    if !nameForms.isEmpty {
      let cache = project.appendingPathComponent("source/name-stress.json")
      var stresses = NativeIO.object(try? NativeIO.load(cache)).compactMapValues { $0 as? String }
      let missing = nameForms.filter { stresses[$0.form] == nil }
      if !missing.isEmpty {
        do {
          let book = NativeIO.object(manifest["book"])
          stresses.merge(try await director.nameStresses(missing, book: ["title": book["title"] ?? "", "author": book["author"] ?? ""])) { old, _ in old }
          try NativeIO.write(cache, stresses)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          NativeIO.emit("log", ["message": "Ударения в именах не уточнены, остаются словарные: " + error.localizedDescription])
        }
      }
      for i in rows.indices {
        rows[i]["tts_text"] = ProperNames.apply(NativeIO.string(rows[i]["tts_text"]), stresses: stresses)
      }
      NativeIO.emit("log", ["message": "Имена и названия: \(nameForms.filter { stresses[$0.form] != nil }.count) из \(nameForms.count) форм с ударением от LLM · "
        + nameForms.prefix(10).compactMap { stresses[$0.form] }.joined(separator: ", ")])
    }
    // Foreign insertions get a Cyrillic reading in the spoken text only; answers are cached
    // per project, and without an answer the fragment stays as written.
    var foreign: [(fragment: String, context: String)] = []
    var seenForeign = Set<String>()
    for row in rows {
      for fragment in ForeignReading.fragments(NativeIO.string(row["tts_text"])) where seenForeign.insert(fragment).inserted {
        foreign.append((fragment, String(NativeIO.string(row["text"]).prefix(200))))
      }
    }
    if !foreign.isEmpty {
      let cache = project.appendingPathComponent("source/foreign-readings.json")
      var readings = NativeIO.object(try? NativeIO.load(cache)).compactMapValues { $0 as? String }
      let missing = foreign.filter { readings[$0.fragment] == nil }
      if !missing.isEmpty {
        do {
          readings.merge(try await director.foreignReadings(missing)) { old, _ in old }
          try NativeIO.write(cache, readings)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          NativeIO.emit("log", ["message": "Прочтение иностранных слов не получено, они останутся как написаны: " + error.localizedDescription])
        }
      }
      for i in rows.indices {
        rows[i]["tts_text"] = ForeignReading.apply(NativeIO.string(rows[i]["tts_text"]), readings: readings)
      }
      let resolved = foreign.filter { readings[$0.fragment] != nil }
      NativeIO.emit("log", ["message": "Иностранные вставки: \(resolved.count) из \(foreign.count) получили русское прочтение · "
        + resolved.prefix(8).map { $0.fragment + " → " + readings[$0.fragment]! }.joined(separator: ", ")])
    }
    prepared["segments"] = rows
    try NativeIO.write(project.appendingPathComponent("source/manifest.json"), prepared)
    lap("текст и ударения")
    var references: [String: (URL, String)] = [:]
    var design: Qwen3TTSModel?
    for voice in voices where used.contains(NativeIO.string(voice["id"])) {
      let id = NativeIO.string(voice["id"])
      if let ref = try custom(voice) {
        references[id] = ref
        continue
      }
      let directory = project.appendingPathComponent("voices")
      let file = directory.appendingPathComponent(id + ".wav")
      let meta = directory.appendingPathComponent(id + ".json")
      let text =
        (try? NativeProject.excerpt(manifest, character: id))
        ?? "Сегодня тихое утро. Я спокойно и ясно читаю эту книгу."
      let signature = try VoiceSample.signature(text: text, instruction: instruction(voice),
        profile: VoiceDirection.signature(voice), seed: voice["seed"] as? Int ?? 17001)
      if fm.fileExists(atPath: file.path), let old = try? NativeIO.load(meta),
        NativeIO.string(old["signature"]) == signature,
        (try NativeIO.hashFile(file)) == NativeIO.string(old["sha256"])
      {
        references[id] = (file, NativeIO.string(old["text"]))
        continue
      }
      let preview = project.appendingPathComponent("preview-samples/" + id + ".wav")
      if let samples = SpeechCache.load(preview, signature: signature) {
        try NativeWAV.write(file, samples)
        try NativeIO.write(meta, ["signature": signature, "text": text,
          "description": instruction(voice), "sha256": try NativeIO.hashFile(file)])
        references[id] = (file, text)
        NativeIO.stage("Используется прослушанный образец · " + NativeIO.string(voice["name"]))
        continue
      }
      NativeIO.stage("Создание голоса · " + NativeIO.string(voice["name"]))
      if design == nil { design = try await Qwen3TTSModel.fromModelDirectory(designPath) }
      let samples = try await generate(
        design!, text: text, description: instruction(voice), reference: nil,
        seed: voice["seed"] as? Int ?? 17001)
      try NativeWAV.write(file, samples)
      try NativeIO.write(
        meta,
        [
          "signature": signature, "text": text, "description": instruction(voice),
          "sha256": try NativeIO.hashFile(file),
        ])
      references[id] = (file, text)
    }
    // Manner samples: the same voice and habits in another momentary state, only for
    // manners that this character actually uses. A failed sample falls back to the main one.
    var mannerUses: [String: Set<String>] = [:]
    for row in rows where VoiceDirection.manner(row["manner"]) != "calm" {
      mannerUses[NativeIO.string(row["speaker"]), default: []].insert(VoiceDirection.manner(row["manner"]))
    }
    for voice in voices where used.contains(NativeIO.string(voice["id"])) {
      let id = NativeIO.string(voice["id"])
      guard try custom(voice) == nil else { continue }
      for manner in (mannerUses[id] ?? []).sorted() {
        guard let description = VoiceDirection.mannerInstruction(voice, manner: manner) else { continue }
        let directory = project.appendingPathComponent("voices")
        let file = directory.appendingPathComponent(id + "--" + manner + ".wav")
        let meta = directory.appendingPathComponent(id + "--" + manner + ".json")
        let text = (try? NativeProject.excerpt(manifest, character: id, manner: manner))
          ?? references[id]?.1 ?? "Сегодня тихое утро. Я спокойно и ясно читаю эту книгу."
        let seed = voice["seed"] as? Int ?? 17001
        let signature = try VoiceSample.signature(text: text, instruction: description,
          profile: VoiceDirection.signature(voice), seed: seed)
        if fm.fileExists(atPath: file.path), let old = try? NativeIO.load(meta),
          NativeIO.string(old["signature"]) == signature,
          (try NativeIO.hashFile(file)) == NativeIO.string(old["sha256"])
        {
          references[id + "|" + manner] = (file, NativeIO.string(old["text"]))
          continue
        }
        NativeIO.stage("Создание голоса · " + NativeIO.string(voice["name"]) + " · " + manner)
        do {
          if design == nil { design = try await Qwen3TTSModel.fromModelDirectory(designPath) }
          let samples = try await generate(design!, text: text, description: description, reference: nil, seed: seed)
          try NativeWAV.write(file, samples)
          try NativeIO.write(meta, ["signature": signature, "text": text, "description": description,
            "sha256": try NativeIO.hashFile(file)])
          references[id + "|" + manner] = (file, text)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          NativeIO.emit("log", ["message": "Образец манеры не создан · \(id) · \(manner) · читается основным голосом: " + error.localizedDescription])
        }
      }
    }
    design = nil
    Memory.clearCache()
    memoryLog("VoiceDesign выгружен")
    lap("голоса VoiceDesign")
    let (timeline, _) = try await synthesize(rows: rows, voices: voices,
      references: references, basePath: basePath)
    Memory.clearCache()
    memoryLog("Модель чтения выгружена перед нормализацией и упаковкой")
    lap("озвучка")
    let raw = project.appendingPathComponent("audio")
    try NativeIO.write(raw.appendingPathComponent("timeline.json"), ["segments": timeline])
    NativeIO.stage("Потоковая нормализация громкости по ролям")
    let gains = try audio.streamingGains(project: project, segments: rows)
    lap("громкость")
    var selectedMusic: URL?
    if request["music_enabled"] as? Bool ?? true {
      let selected = URL(fileURLWithPath: NativeIO.string(request["music"]))
      guard fm.fileExists(atPath: selected.path) else {
        throw StudioError("Не найден музыкальный файл")
      }
      let music = project.appendingPathComponent("music/" + selected.lastPathComponent)
      try fm.createDirectory(
        at: music.deletingLastPathComponent(), withIntermediateDirectories: true)
      if selected.standardizedFileURL != music.standardizedFileURL {
        if fm.fileExists(atPath: music.path) { try fm.removeItem(at: music) }
        try fm.copyItem(at: selected, to: music)
      }
      selectedMusic = music
    }
    NativeIO.stage("Сборка отдельного M4B и EPUB с синхронным аудио")
    let result = try audio.package(
      project: project, manifest: prepared, source: source, timeline: timeline,
      gains: gains, music: selectedMusic, musicPercent: request["music_volume"] as? Double ?? 5)
    let external = URL(fileURLWithPath: destination)
    NativeIO.stage("Сохранение аудиокниги и EPUB · " + destination)
    try fm.copyItem(at: result, to: external)
    NativeIO.stage("Проверка сохранённой книги и очистка временного аудио")
    let cleanupFailures = try NativeProject.cleanupCompletedSpeech(project, exported: external)
    NativeIO.emit("log", ["message": cleanupFailures.isEmpty
      ? "Результат проверен; временное аудио и кеш реплик удалены. Книга, разметка и образцы голосов сохранены."
      : "Результат проверен, но не удалось удалить временные файлы: " + cleanupFailures.joined(separator: ", ")])
    lap("M4B, EPUB и копирование")
    NativeIO.emit("log", ["message": "Время этапов: " + timings.joined(separator: " · ")])
    NativeIO.emit("result", ["path": destination])
    done("Аудиокнига и EPUB сохранены: " + destination, path: project)
  }
  func previewSamples(at path: URL, text: String, description: String?,
    reference: (URL, String)?, seed: Int) async throws -> [Float]
  {
    let model = try await Qwen3TTSModel.fromModelDirectory(path)
    NativeIO.stage("Генерация пробы · \(text.count) знаков · примерно 10 секунд")
    return try await generate(model, text: text, description: description, reference: reference, seed: seed)
  }
  /// Cosine similarity of speaker embeddings required to read lines with a manner sample.
  static let mannerIdentityThreshold = 0.65
  /// Per-batch memory: MLX peak since the previous batch and system swap, to tell
  /// memory pressure apart from slow code in speed measurements.
  func batchMemoryLog(_ batch: Int) {
    let snapshot = Memory.snapshot()
    var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
    let swapMB = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? Double(swap.xsu_used) / 1_048_576 : -1
    NativeIO.emit("log", ["message": String(format:
      "Память пакета %d: MLX активно %.0f МБ · пик %.0f МБ · кеш %.0f МБ · своп системы %.0f МБ", batch,
      Double(snapshot.activeMemory) / 1_048_576, Double(snapshot.peakMemory) / 1_048_576,
      Double(snapshot.cacheMemory) / 1_048_576, swapMB)])
    Memory.peakMemory = 0
  }
  func memoryLog(_ message: String) {
    let snapshot = Memory.snapshot()
    NativeIO.emit("log", ["message": message + String(format:
      " · MLX: активно %.0f МБ, кеш %.0f МБ", Double(snapshot.activeMemory) / 1_048_576,
      Double(snapshot.cacheMemory) / 1_048_576)])
  }
  func synthesize(rows: [Object], voices: [Object], references: [String: (URL, String)],
    basePath: URL) async throws -> ([Object], Int)
  {
    var base: Qwen3TTSModel?
    var voicesReady: [String: StudioQwenSpeaker] = [:]
    var referenceArrays: [String: MLXArray] = [:]
    defer { withExtendedLifetime(referenceArrays) {} }
    var referenceHashes: [String: String] = [:]
    for (id, ref) in references { referenceHashes[id] = try NativeIO.hashFile(ref.0) }
    func prepareVoice(_ key: String, progress: Double) async throws {
      guard voicesReady[key] == nil else { return }
      if base == nil {
        NativeIO.synthesisStage("Загрузка модели озвучки · нативный MLX", progress)
        base = try await Qwen3TTSModel.fromModelDirectory(basePath)
      }
      guard let base, let reference = references[key] else { throw StudioError("Не подготовлен голос " + key) }
      NativeIO.synthesisStage("Подготовка голоса для озвучки · " + key, progress)
      let (_, array) = try loadAudioArray(from: reference.0, sampleRate: 24000)
      referenceArrays[key] = array
      let conditioning = try base.prepareReferenceConditioning(refAudio: array, refText: reference.1, language: "Russian")
      guard let identity = conditioning.speakerEmbedding else { throw StudioError("Не извлечена личность голоса · " + key) }
      let values = identity.asArray(Float.self)
      guard !values.isEmpty, values.allSatisfy({ $0.isFinite }), values.contains(where: { abs($0) > 0.000001 }) else {
        throw StudioError("Повреждено представление личности голоса · " + key)
      }
      let hash = values.withUnsafeBytes { NativeIO.hash(Data($0)) }
      NativeIO.emit("log", ["message": "Личность голоса [\(key)] · \(values.count) признаков · SHA256 " + hash])
      NativeIO.emit("log", ["message": "Образец для озвучки [\(key)] · SHA256 " + (referenceHashes[key] ?? "")])
      voicesReady[key] = try base.studioSpeaker(conditioning)
    }
    // A manner sample is used only while its voice identity stays close to the character's
    // main sample; a drifted sample would sound like another person, so those lines fall back.
    var mannerAccepted = Set<String>()
    var unchecked: [String] = []
    let mannerKeys = Set(rows.map { NativeIO.string($0["speaker"]) + "|" + VoiceDirection.manner($0["manner"]) })
      .filter { references[$0] != nil }
    for key in mannerKeys.sorted() {
      let main = String(key.split(separator: "|")[0])
      let check = references[key]!.0.deletingPathExtension().appendingPathExtension("identity.json")
      if let old = try? NativeIO.load(check), NativeIO.string(old["pair"]) == (referenceHashes[key] ?? "") + ":" + (referenceHashes[main] ?? ""),
        let similarity = old["similarity"] as? Double {
        if similarity >= Self.mannerIdentityThreshold { mannerAccepted.insert(key) }
      } else { unchecked.append(key) }
    }
    for key in unchecked {
      try Task.checkCancellation()
      let main = String(key.split(separator: "|")[0])
      try await prepareVoice(main, progress: 0)
      try await prepareVoice(key, progress: 0)
      let a = voicesReady[main]!.conditioning.speakerEmbedding!.asArray(Float.self)
      let b = voicesReady[key]!.conditioning.speakerEmbedding!.asArray(Float.self)
      let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
      let norms = sqrt(a.reduce(Float(0)) { $0 + $1 * $1 }) * sqrt(b.reduce(Float(0)) { $0 + $1 * $1 })
      let similarity = Double(dot / max(norms, 1e-12))
      let accepted = similarity >= Self.mannerIdentityThreshold
      if accepted { mannerAccepted.insert(key) }
      // A rejected sample is never read: drop its conditioning. Its source array stays in
      // referenceArrays, because upstream caches by ObjectIdentifier and a freed address could
      // be reused by another voice.
      else { voicesReady.removeValue(forKey: key) }
      try NativeIO.write(references[key]!.0.deletingPathExtension().appendingPathExtension("identity.json"),
        ["pair": (referenceHashes[key] ?? "") + ":" + (referenceHashes[main] ?? ""), "similarity": similarity])
      NativeIO.emit("log", ["message": String(format: "Манера [%@]: сходство с основным голосом %.3f · %@", key, similarity,
        accepted ? "используется" : "голос отличается, реплики читаются основным образцом")])
    }
    func voiceKey(_ row: Object) -> String {
      let key = NativeIO.string(row["speaker"]) + "|" + VoiceDirection.manner(row["manner"])
      return mannerAccepted.contains(key) ? key : NativeIO.string(row["speaker"])
    }
    let raw = project.appendingPathComponent("audio/segments")
    try fm.createDirectory(at: raw, withIntermediateDirectories: true)
    var files: [URL] = [], signatures: [String] = [], seeds: [Int] = []
    var framesByID: [String: Int] = [:]
    var pending: Set<Int> = []
    var completed = 0
    func weight(_ i: Int) -> Int { max(1, NativeIO.string(rows[i]["text"]).count) }
    for (i, row) in rows.enumerated() {
      try Task.checkCancellation()
      let id = NativeIO.string(row["id"]), speaker = NativeIO.string(row["speaker"]), key = voiceKey(row)
      guard let reference = references[key], let hash = referenceHashes[key] else {
        throw StudioError("Не подготовлен голос " + key)
      }
      let seed = max(0, (voices.first(where: { NativeIO.string($0["id"]) == speaker })?["seed"] as? Int ?? 17001) + i)
      let signature = try SpeechCache.signature(text: SpeechRecovery.text(NativeIO.string(row["tts_text"])),
        referenceHash: hash, referenceText: reference.1, seed: seed)
      let file = raw.appendingPathComponent(id + ".spcm")
      files.append(file); signatures.append(signature); seeds.append(seed)
      if let samples = SpeechCache.load(file, signature: signature) {
        framesByID[id] = samples.count; completed += weight(i)
      } else { pending.insert(i) }
    }
    let total = rows.indices.reduce(0) { $0 + weight($1) }
    let jobs = try SpeechBatch.plan(rows, pending: pending)
    NativeIO.emit("log", ["message": "План озвучки: \(jobs.count) запусков · \(pending.count) новых реплик · \(jobs.filter { $0.count > 1 }.count) пакетов · до 4 коротких реплик, голоса могут смешиваться"])
    var measurements: [(Double, Double, Int)] = []
    for (jobNumber, indices) in jobs.enumerated() {
      try Task.checkCancellation()
      let start = Date(), progress = Double(completed) / Double(max(1, total))
      let laneSpeakers = indices.map { voiceKey(rows[$0]) }
      var listed = Set<String>()
      let speakerList = laneSpeakers.filter { listed.insert($0).inserted }
      let ids = indices.map { NativeIO.string(rows[$0]["id"]) }
      NativeIO.synthesisStage("Пакетная озвучка · \(jobNumber+1)/\(jobs.count) · \(indices.count) реплик · " + speakerList.joined(separator: ", "), progress)
      for key in speakerList { try await prepareVoice(key, progress: progress) }
      guard let base else { throw StudioError("Модель озвучки не загружена") }
      let laneVoices = try laneSpeakers.map { speaker -> StudioQwenSpeaker in
        guard let voice = voicesReady[speaker] else { throw StudioError("Не подготовлен голос " + speaker) }
        return voice
      }
      let texts = indices.map { SpeechRecovery.text(NativeIO.string(rows[$0]["tts_text"])) }
      var timings: [String: Double] = [:]
      let waves = try await SpeechRecovery.batch(texts: texts, seeds: indices.map { seeds[$0] }, labels: indices.indices.map { ids[$0] + " · " + laneSpeakers[$0] },
        operation: { lanes, attemptSeeds in
          NativeIO.synthesisStage("Пакетная озвучка · \(jobNumber+1)/\(jobs.count) · \(lanes.count) реплик · " + speakerList.joined(separator: ", "), progress)
          return try await base.studioGenerateBatch(texts: lanes.map { texts[$0] }, speakers: lanes.map { laneVoices[$0] },
            seeds: attemptSeeds.map { UInt64($0) },
            generationParameters: GenerateParameters(maxTokens: 4096, temperature: 0.9, topP: 1, topK: 50, repetitionPenalty: 1.05),
            timing: { name, seconds in timings[name, default: 0] += seconds })
        }, accepted: { lane, samples in
          let i = indices[lane]
          try SpeechCache.save(files[i], samples: samples, signature: signatures[i])
          framesByID[ids[lane]] = samples.count
          NativeIO.emit("log", ["message": String(format: "Реплика %@ · %.1f с речи · пакет %d", ids[lane], Double(samples.count) / 24000, jobNumber+1)])
        })
      let duration = waves.reduce(0) { $0 + Double($1.count) / 24000 }
      let elapsed = max(0.001, Date().timeIntervalSince(start))
      let chars = indices.reduce(0) { $0 + weight($1) }
      completed += chars
      measurements.append((duration, elapsed, chars))
      if measurements.count > 12 { measurements.removeFirst() }
      NativeIO.emit("log", ["message": String(format: "Пакет %d · %d реплик · %.1f с речи за %.1f с · %.2f× · %@",
        jobNumber+1, indices.count, duration, elapsed, duration / elapsed, ids.joined(separator: ", "))])
      NativeIO.emit("log", ["message": String(format: "Расчёт пакета %d: вход %.3f с · первый шаг (контекст + кадр) %.3f с · остальные токены %.3f с · декодер %.3f с",
        jobNumber+1, timings["input"] ?? 0, timings["first_step"] ?? 0,
        timings["remaining_tokens"] ?? 0, timings["decode"] ?? 0)])
      batchMemoryLog(jobNumber + 1)
      let seconds = measurements.reduce(0) { $0 + $1.1 }
      let characters = measurements.reduce(0) { $0 + $1.2 }
      NativeIO.emit("metrics", ["message": "Озвучивание книги", "speed": measurements.reduce(0) { $0 + $1.0 } / seconds,
        "eta": Double(max(0, total - completed)) * seconds / Double(max(1, characters)),
        "seconds_per_character": seconds / Double(max(1, characters)),
        "fraction": Double(completed) / Double(max(1, total)), "completed": framesByID.count, "total": rows.count])
    }
    // Verify each saved file, including cache hits, BEFORE deriving any montage timings.
    NativeIO.synthesisStage("Проверка всех реплик перед монтажом", 1)
    for (i, row) in rows.enumerated() {
      try Task.checkCancellation()
      guard let samples = SpeechCache.load(files[i], signature: signatures[i]) else {
        throw StudioError("Отсутствует или повреждена готовая реплика · " + NativeIO.string(row["id"]))
      }
      framesByID[NativeIO.string(row["id"])] = samples.count
    }
    let result = try SpeechBatch.timeline(rows, frameCounts: framesByID)
    try SpeechBatch.verifyOrder(rows, timeline: result.0)
    NativeIO.emit("log", ["message": "Полнота озвучки проверена: \(rows.count)/\(rows.count) реплик · исходный порядок и голоса сохранены"])
    return result
  }

}
