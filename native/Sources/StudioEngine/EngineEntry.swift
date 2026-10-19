import Darwin
import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
import MLXLMCommon
@preconcurrency import MLXRandom
import StudioCore

@main struct StudioEngine {
  nonisolated(unsafe) static var paceTimer: DispatchSourceTimer?
  /// The app's build mode can change while a book is read: the file says "gentle" or not and is
  /// read again every 2 seconds.
  static func watchPace(_ path: String) {
    guard !path.isEmpty else { return }
    let read = {
      StudioPace.gentle = (try? String(contentsOfFile: path, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "gentle"
    }
    read()
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.setEventHandler(handler: read)
    timer.resume()
    paceTimer = timer
  }
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
        // The RUAccent helper starts with its bundled ONNX Runtime and answers a request (an
        // absent model is reported as an error line; the models themselves download on first use).
        let accent = Process(), accentIn = Pipe(), accentOut = Pipe()
        accent.executableURL = helper.deletingLastPathComponent().appendingPathComponent("StudioAccent")
        accent.standardInput = accentIn; accent.standardOutput = accentOut
        try accent.run()
        try accentIn.fileHandleForWriting.write(contentsOf: Data("{\"model\":\"/nonexistent.onnx\",\"inputs\":{}}\n".utf8))
        try accentIn.fileHandleForWriting.close()
        let accentAnswer = accentOut.fileHandleForReading.readDataToEndOfFile()
        accent.waitUntilExit()
        guard accent.terminationStatus == 0, String(data: accentAnswer, encoding: .utf8)?.contains("\"error\"") == true else {
          throw StudioError("Помощник RUAccent не запускается")
        }
        NativeIO.emit("log", ["message": "RUAccent: ONNX Runtime загружается и отвечает"])
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
      Self.watchPace(NativeIO.string(request["pace_file"]))
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
    let leftovers = models.removeLegacyRuntime()
    if !leftovers.isEmpty { NativeIO.emit("log", ["message": "Удалены остатки прежнего Python-движка: " + leftovers.sorted().joined(separator: ", ")]) }
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
        NativeIO.fileStem(NativeFB2.baseName(book)) + "-" + UUID().uuidString.prefix(8))
      try fm.createDirectory(
        at: project.appendingPathComponent("roles"), withIntermediateDirectories: true)
      if fb2 {
        // The original stays untouched beside a working EPUB copy; the read-along EPUB is
        // still assembled at the end from the spoken text and audio.
        NativeIO.stage("Чтение FB2 и подготовка рабочей копии EPUB")
        try fm.copyItem(at: book, to: project.appendingPathComponent("original-" + NativeIO.fileStem(book.deletingPathExtension().lastPathComponent) + "." + book.pathExtension))
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
        let others: [Object] = NativeIO.objects(manifest["voices"]).filter {
          NativeIO.string($0["id"]) != character && !NativeIO.string($0["tts_voice"]).isEmpty
        }.map { ["name": $0["name"] ?? "", "voice": $0["tts_voice"]!] }
        let directed = try await NativeDirector(request).directVoice(voice, cast: others)
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
    let replace = request["replace"] as? Bool ?? false
    guard !destination.isEmpty, replace || !fm.fileExists(atPath: destination) else {
      throw StudioError("Выберите новую папку для результата")
    }
    // Never replace the project itself or a folder that contains it.
    let target = URL(fileURLWithPath: destination).standardizedFileURL.path
    guard !(project.standardizedFileURL.path + "/").hasPrefix(target + "/") else {
      throw StudioError("Нельзя сохранить результат поверх папки проекта")
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
    // Voices are designed as one cast: the narrator first, then by number of lines; each request
    // sees the timbres chosen so far and must differ from them audibly.
    let lines = Dictionary(segments.map { (NativeIO.string($0["speaker"]), 1) }, uniquingKeysWith: +)
    let order = voices.indices.filter { used.contains(NativeIO.string(voices[$0]["id"])) }.sorted {
      let a = NativeIO.string(voices[$0]["id"]), b = NativeIO.string(voices[$1]["id"])
      return a == "narrator" || (b != "narrator" && (lines[a] ?? 0) > (lines[b] ?? 0))
    }
    var cast: [Object] = []
    for i in order {
      if try custom(voices[i]) == nil {
        voices[i] = try await director.directVoice(voices[i], cast: cast)
      }
      let timbre = NativeIO.string(voices[i]["tts_voice"])
      if !timbre.isEmpty { cast.append(["name": voices[i]["name"] ?? "", "voice": timbre]) }
    }
    manifest["voices"] = voices
    try writeManifest(manifest, at: project)
    let designNeeded = try voices.contains { voice in
      guard used.contains(NativeIO.string(voice["id"])) else { return false }
      return try custom(voice) == nil
    }
    let designPath = designNeeded ? try models.ensure(design: true) : basePath
    lap("роли, инструкции и проверка моделей")
    // Stress: "none" (the reading model alone), "silero" (dictionary + Silero, the default),
    // "ruaccent" (dictionary + RUAccent) or "all" (Silero and RUAccent vote, the LLM settles their
    // disputes and stresses names). The letter ё has a setting of its own.
    let stressMode = ["none", "silero", "ruaccent", "all"].contains(NativeIO.string(request["stress_mode"]))
      ? NativeIO.string(request["stress_mode"]) : "silero"
    let yoMode = ["keep", "auto", "always"].contains(NativeIO.string(request["yo_mode"])) ? NativeIO.string(request["yo_mode"]) : "auto"
    NativeIO.stage("Нормализация текста · ударения: " + ["none": "без расстановки", "silero": "Silero",
      "ruaccent": "RUAccent", "all": "Silero + RUAccent + LLM"][stressMode]!)
    var prepared = manifest
    var rows = segments
    let own = StressRules.userDictionary(NativeIO.string(request["stress_dictionary"]))
    if !own.isEmpty { NativeIO.emit("log", ["message": "Свой словарь ударений: \(own.count) слов"]) }
    let bookText = NativeIO.objects(source["paragraphs"]).map { NativeIO.string($0["text"]) }.joined(separator: "\n")
    // A book that already prints 'ё' keeps its own 'е' (automatic mode): no second, guessed placement.
    let printsYo = NativeStress.hasYo(bookText)
    let bookHasYo = yoMode == "keep" || (yoMode == "auto" && printsYo)
    NativeIO.emit("log", ["message": yoMode == "keep"
      ? "Буква ё: как в книге — буквы книги не меняются"
      : yoMode == "always" ? "Буква ё: расставляется всегда, по словарю и модели"
      : printsYo
      ? "В книге уже расставлена ё — повторная расстановка пропущена, буквы книги не меняются"
      : bookText.precomposedStringWithCanonicalMapping.lowercased().contains("ё")
        ? "Ё в книге стоит выборочно (ещё, её и другие напечатаны через е) — недостающая ё расставляется"
        : "В книге нет ё — буква ё расставляется по словарю и модели ударений"])
    do {
      let ru = try RussianText(resources.appendingPathComponent("supertonic_rules.json"))
      let binaries = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      // Silero also places ё when stresses are off; only "как в книге" with RUAccent alone skips it.
      let needsSilero = stressMode == "silero" || stressMode == "all" || (stressMode == "none" && !bookHasYo)
      let stress: NativeStress? = try needsSilero ? NativeStress(resources: resources, helper: binaries.appendingPathComponent("StudioStress")) : nil
      stress?.bookHasYo = bookHasYo
      // Orthoepic norms, then the user's own words, win over the dictionary and the model.
      stress?.overrides = StressRules.orthoepy.merging(own) { $1 }
      var accent: RUAccent?
      if stressMode == "ruaccent" || stressMode == "all" {
        let root = try models.ensureRUAccent()
        NativeIO.stage("Загрузка RUAccent")
        accent = try RUAccent(root: root,
          dictionary: AccentDictionary(resources.appendingPathComponent("resources/russian_accents_full.sacc")),
          helper: binaries.appendingPathComponent("StudioAccent"))
        accent?.keepYo = bookHasYo
        accent?.overrides = StressRules.orthoepy.merging(own) { $1 }
      }
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
        var item = NativeDirector.StressItem(text: normalized, context: full)
        switch stressMode {
        case "none":
          // Only the letter ё from Silero; no stress marks except those printed in the book.
          if let stress { item = NativeDirector.StressItem(text: StressRules.onlyYo(try stress.annotate(normalized, prefix: before, suffix: after).text, original: normalized), context: full) }
        case "ruaccent":
          item = NativeDirector.StressItem(text: try accent!.annotate(normalized), context: full)
        case "all":
          let marked = try stress!.annotate(normalized, prefix: before, suffix: after)
          item = StressRules.secondVoice(NativeDirector.StressItem(text: marked.text, context: full, disputes: marked.disputes),
            try accent!.annotate(normalized))
        default:
          let marked = try stress!.annotate(normalized, prefix: before, suffix: after)
          item = NativeDirector.StressItem(text: marked.text, context: full, disputes: marked.disputes)
        }
        rows[i]["tts_text"] = item.text
        items.append(item)
      }
      if stressMode == "all" {
        let disputed = items.reduce(0) { $0 + $1.votes.count }
        NativeIO.emit("log", ["message": "Silero и RUAccent: расходятся в \(disputed) словах — решает LLM, без ответа — словарь и Silero"])
      }
      if stressMode != "all" {
        // Without the LLM check a rare homograph reading from Silero alone gives way to the common one.
        for i in rows.indices { rows[i]["tts_text"] = NativeDirector.settle(items[i]) }
      } else {
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
            for i in batch { rows[i]["tts_text"] = NativeDirector.settle(items[i]) }
          }
        }
      }
    }
    // Names and surnames are often missing from the dictionaries: the LLM stresses each form
    // once per book (cached), and that answer wins over the dictionary/model guess.
    let castNames = voices.flatMap { [NativeIO.string($0["name"])] + ($0["aliases"] as? [String] ?? []) }
    // Names are asked of the LLM only in the "Silero + RUAccent + LLM" mode.
    let nameForms = stressMode == "all" ? ProperNames.collect(rows.map { NativeIO.string($0["text"]) }, names: castNames) : []
    if !nameForms.isEmpty {
      let cache = project.appendingPathComponent("source/name-stress.json")
      // A cached answer is checked again: a damaged or edited entry is dropped and asked anew.
      var stresses = NativeIO.object(try? NativeIO.load(cache)).compactMapValues { $0 as? String }
        .filter { ProperNames.valid($0.value, for: $0.key) }
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
        // Names only (capitalised), never over the author's own marks; norms beat the LLM here.
        rows[i]["tts_text"] = ProperNames.apply(NativeIO.string(rows[i]["tts_text"]),
          stresses: stresses.merging(StressRules.orthoepy) { $1 }, keepYo: bookHasYo,
          keep: ProperNames.authored(NativeIO.string(rows[i]["text"])))
      }
      NativeIO.emit("log", ["message": "Имена и названия: \(nameForms.filter { stresses[$0.form] != nil }.count) из \(nameForms.count) форм с ударением от LLM · "
        + nameForms.prefix(10).compactMap { stresses[$0.form] }.joined(separator: ", ")])
    }
    // Priority, highest first: the author's printed marks, the user's own words, the norms, the
    // LLM's names, the dictionary and the model. The own words come last so nothing overwrites them.
    if !own.isEmpty {
      for i in rows.indices {
        // The user's own entry is an explicit decision: its ё is placed even in a book that prints ё.
        rows[i]["tts_text"] = ProperNames.apply(NativeIO.string(rows[i]["tts_text"]), stresses: own, keepYo: false,
          namesOnly: false, keep: ProperNames.authored(NativeIO.string(rows[i]["text"])))
      }
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
        .filter { ForeignReading.valid($0.value) }
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
    var fresh = Set<String>()   // voices designed in this build (not cached, previewed or own)
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
        ?? "Это мой голос в этой книге. Сейчас я расскажу свою часть истории."
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
      fresh.insert(id)
    }
    // Twin voices: a voice made in this build that sounds like an earlier one of the same gender
    // (pitch, range, tempo) is designed again clearly higher, then lower, with another seed; the
    // version farther from its twin is kept. Voices of a book already being read never change.
    var measured: [String: VoiceAcoustics] = [:]
    func acoustics(_ id: String) -> VoiceAcoustics? {
      if let known = measured[id] { return known }
      let value = references[id].flatMap { ref in (try? NativeWAV.read(ref.0)).flatMap { VoiceAcoustics.measure($0, text: ref.1) } }
      measured[id] = value
      return value
    }
    var changedCast = false
    for n in voices.indices where fresh.contains(NativeIO.string(voices[n]["id"])) && NativeIO.string(voices[n]["id"]) != "narrator" {
      let id = NativeIO.string(voices[n]["id"]), gender = NativeIO.string(voices[n]["voice_gender"])
      guard !["", "unknown"].contains(gender), let own = acoustics(id),
        let twin = voices[..<n].first(where: { other in
          let oid = NativeIO.string(other["id"])
          return used.contains(oid) && NativeIO.string(other["voice_gender"]) == gender
            && acoustics(oid).map { VoiceAcoustics.twins(own, $0) } == true
        }), let twinSound = acoustics(NativeIO.string(twin["id"])) else { continue }
      let ref = references[id]!
      var best: (voice: Object, samples: [Float], distance: Double)?
      for (k, higher) in [true, false].enumerated() {
        try Task.checkCancellation()
        NativeIO.stage("Голос похож на «" + NativeIO.string(twin["name"]) + "» · новый вариант · " + NativeIO.string(voices[n]["name"]))
        var candidate = VoiceDirection.redesigned(voices[n], higher: higher)
        candidate["seed"] = (voices[n]["seed"] as? Int ?? 17001) &+ 7919 * (k + 1)
        if design == nil { design = try await Qwen3TTSModel.fromModelDirectory(designPath) }
        let samples = try await generate(design!, text: ref.1, description: instruction(candidate), reference: nil,
          seed: candidate["seed"] as? Int ?? 17001)
        guard let sound = VoiceAcoustics.measure(samples, text: ref.1) else { continue }
        let distance = VoiceAcoustics.distance(sound, twinSound)
        if best == nil || distance > best!.distance { best = (candidate, samples, distance) }
        if !VoiceAcoustics.twins(sound, twinSound) { break }
      }
      guard let best, best.distance > VoiceAcoustics.distance(own, twinSound) else { continue }
      voices[n] = best.voice
      measured[id] = VoiceAcoustics.measure(best.samples, text: ref.1)
      let file = ref.0, meta = file.deletingPathExtension().appendingPathExtension("json")
      try NativeWAV.write(file, best.samples)
      try NativeIO.write(meta, ["signature": try VoiceSample.signature(text: ref.1, instruction: instruction(best.voice),
        profile: VoiceDirection.signature(best.voice), seed: best.voice["seed"] as? Int ?? 17001),
        "text": ref.1, "description": instruction(best.voice), "sha256": try NativeIO.hashFile(file)])
      changedCast = true
      NativeIO.emit("log", ["message": String(format: "Голос «%@» звучал как «%@» — создан заново, отличие %.1f пт",
        NativeIO.string(voices[n]["name"]), NativeIO.string(twin["name"]), best.distance)])
    }
    if changedCast {
      manifest["voices"] = voices
      try writeManifest(manifest, at: project)
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
    // Off in the settings: each emotion keeps the loudness the model gave it.
    let lineGains = try (request["level_emotions"] as? Bool ?? true) ? audio.lineGains(project: project, segments: rows) : [:]
    // Noise and grating clean-up of the speech, a setting of its own (on unless switched off).
    let cleanup = request["denoise"] as? Bool ?? true
    let gains = try audio.streamingGains(project: project, segments: rows, lineGains: lineGains, cleanup: cleanup)
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
      gains: gains, lineGains: lineGains, music: selectedMusic, musicPercent: request["music_volume"] as? Double ?? 5,
      cleanup: cleanup)
    let external = URL(fileURLWithPath: destination)
    if fm.fileExists(atPath: external.path) {
      // Replacement confirmed in the save panel: the old folder goes to the Trash (recoverable) only
      // now, after the new book has been assembled and verified.
      guard replace else { throw StudioError("Папка результата уже существует") }
      NativeIO.stage("Прежняя папка результата перемещается в Корзину")
      try fm.trashItem(at: external, resultingItemURL: nil)
    }
    NativeIO.stage("Сохранение аудиокниги и EPUB · " + destination)
    try fm.copyItem(at: result, to: external)
    // Saved from the window: the files are named after the book ("Автор - Название.m4b"). Telegram
    // keeps the result names and names the cloud copies itself.
    let names = NativeProject.exportNames(base: request["named_files"] as? Bool == true ? NativeProject.exportBase(prepared) : "")
    for (from, to) in names where from != to {
      try fm.moveItem(at: external.appendingPathComponent(from), to: external.appendingPathComponent(to))
    }
    NativeIO.stage("Проверка сохранённой книги и очистка временного аудио")
    let cleanupFailures = try NativeProject.cleanupCompletedSpeech(project, exported: external, names: names)
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
  /// Two different characters this close in speaker embedding are reported as sounding alike.
  static let castSimilarityWarning = 0.85
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
    // Every line of a character is read from that character's one sample, whatever its
    // manner: a separate VoiceDesign sample per emotion came out as a different person.
    func voiceKey(_ row: Object) -> String { NativeIO.string(row["speaker"]) }
    let raw = project.appendingPathComponent("audio/segments")
    try fm.createDirectory(at: raw, withIntermediateDirectories: true)
    var files: [URL] = [], signatures: [String] = [], seeds: [Int] = []
    var framesByID: [String: Int] = [:]
    var pending: Set<Int> = []   // indices into `units`
    var completed = 0
    func weight(_ i: Int) -> Int { max(1, NativeIO.string(rows[i]["text"]).count) }
    func spoken(_ i: Int) -> String { SpeechRecovery.text(NativeIO.string(rows[i]["tts_text"])) }
    func silent(_ i: Int) -> Bool { NativeIO.regex("[\\p{L}\\p{N}]", spoken(i)).isEmpty }
    // One model call per unit: short lines of one voice read together (SpeechGroups), every other
    // line alone. A group holding a line with nothing to say is read line by line.
    var units: [[Int]] = []
    for unit in SpeechGroups.units(rows) {
      if unit.count > 1 && unit.contains(where: silent) { units += unit.map { [$0] } } else { units.append(unit) }
    }
    let unitTexts = units.map { $0.count == 1 ? spoken($0[0]) : SpeechGroups.text(rows, unit: $0) }
    for (u, unit) in units.enumerated() {
      var missing = false
      for (k, i) in unit.enumerated() {
        try Task.checkCancellation()
        let row = rows[i]
        let id = NativeIO.string(row["id"]), speaker = NativeIO.string(row["speaker"]), key = voiceKey(row)
        guard let reference = references[key], let hash = referenceHashes[key] else {
          throw StudioError("Не подготовлен голос " + key)
        }
        // A single line keeps its former seed and signature, so books already begun keep their cache.
        let seed = SpeechRecovery.attemptSeed((voices.first(where: { NativeIO.string($0["id"]) == speaker })?["seed"] as? Int ?? 17001) &+ unit[0], 0)
        let text = unit.count == 1 ? spoken(i) : unitTexts[u] + "\u{1F}\(k + 1)/\(unit.count)"
        let signature = try SpeechCache.signature(text: text, referenceHash: hash, referenceText: reference.1, seed: seed)
        let file = raw.appendingPathComponent(id + ".spcm")
        files.append(file); signatures.append(signature); seeds.append(seed)
        // Nothing to say (a "* * *" scene break, a lone note mark): the model would read symbols or
        // return silence that fails three times. A 0.5 s inaudible pause (-94 dBFS) keeps the line in
        // timing, montage and read-along instead.
        if silent(i) {
          let pause = (0..<12000).map { $0 % 2 == 0 ? Float(0.00002) : Float(-0.00002) }
          if SpeechCache.load(file, signature: signature) == nil { try SpeechCache.save(file, samples: pause, signature: signature) }
          framesByID[id] = pause.count; completed += weight(i)
          continue
        }
        if let samples = SpeechCache.load(file, signature: signature) {
          framesByID[id] = samples.count
        } else { missing = true }
      }
      // A call is repeated whole when any of its lines is missing.
      if missing { pending.insert(u) }
      else { completed += unit.filter { !silent($0) }.reduce(0) { $0 + weight($1) } }
    }
    let total = rows.indices.reduce(0) { $0 + weight($1) }
    // Cast check: speaker-embedding similarity of every pair of main voices, narrator included.
    // Very close pairs are reported so they can be redesigned («Другой вариант голоса»).
    let mains = Set(rows.map { NativeIO.string($0["speaker"]) }).filter { references[$0] != nil }.sorted()
    if !pending.isEmpty && mains.count > 1 {
      for key in mains { try await prepareVoice(key, progress: 0) }
      var pairs: [(String, Double)] = []
      for (n, a) in mains.enumerated() {
        for b in mains[(n + 1)...] {
          let x = voicesReady[a]!.conditioning.speakerEmbedding!.asArray(Float.self)
          let y = voicesReady[b]!.conditioning.speakerEmbedding!.asArray(Float.self)
          let dot = zip(x, y).reduce(Float(0)) { $0 + $1.0 * $1.1 }
          let norm = sqrt(x.reduce(Float(0)) { $0 + $1 * $1 }) * sqrt(y.reduce(Float(0)) { $0 + $1 * $1 })
          pairs.append((a + " ↔ " + b, Double(dot / max(norm, 1e-12))))
        }
      }
      pairs.sort { $0.1 > $1.1 }
      NativeIO.emit("log", ["message": "Сходство голосов состава (1 = одинаковые): " + pairs.prefix(5).map {
        String(format: "%@ %.2f", $0.0, $0.1) }.joined(separator: " · ")])
      let close = pairs.filter { $0.1 >= Self.castSimilarityWarning }
      if !close.isEmpty {
        NativeIO.emit("log", ["message": "Внимание: голоса звучат похоже — " + close.map { $0.0 }.joined(separator: ", ")
          + ". Можно выбрать «Другой вариант голоса» в карточке."])
      }
    }
    let jobs = try SpeechBatch.plan(unitTexts.map { ["tts_text": $0] }, pending: pending)
    let joined = units.filter { $0.count > 1 }
    NativeIO.emit("log", ["message": "План озвучки: \(jobs.count) запусков · \(pending.reduce(0) { $0 + units[$1].count }) новых реплик · \(jobs.filter { $0.count > 1 }.count) пакетов · до 4 коротких реплик, голоса могут смешиваться"
      + (joined.isEmpty ? "" : " · короткие реплики одного голоса склеены: \(joined.reduce(0) { $0 + $1.count }) реплик в \(joined.count) вызовах")])
    var measurements: [(Double, Double, Int)] = []
    for (jobNumber, indices) in jobs.enumerated() {
      try Task.checkCancellation()
      let start = Date(), progress = Double(completed) / Double(max(1, total))
      let laneSpeakers = indices.map { voiceKey(rows[units[$0][0]]) }
      var listed = Set<String>()
      let speakerList = laneSpeakers.filter { listed.insert($0).inserted }
      let ids = indices.map { units[$0].map { NativeIO.string(rows[$0]["id"]) }.joined(separator: "+") }
      NativeIO.synthesisStage("Пакетная озвучка · \(jobNumber+1)/\(jobs.count) · \(indices.count) реплик · " + speakerList.joined(separator: ", "), progress)
      for key in speakerList { try await prepareVoice(key, progress: progress) }
      guard let base else { throw StudioError("Модель озвучки не загружена") }
      let laneVoices = try laneSpeakers.map { speaker -> StudioQwenSpeaker in
        guard let voice = voicesReady[speaker] else { throw StudioError("Не подготовлен голос " + speaker) }
        return voice
      }
      let texts = indices.map { unitTexts[$0] }
      var timings: [String: Double] = [:]
      let waves = try await SpeechRecovery.batch(texts: texts, seeds: indices.map { seeds[units[$0][0]] }, labels: indices.indices.map { ids[$0] + " · " + laneSpeakers[$0] },
        operation: { lanes, attemptSeeds in
          NativeIO.synthesisStage("Пакетная озвучка · \(jobNumber+1)/\(jobs.count) · \(lanes.count) реплик · " + speakerList.joined(separator: ", "), progress)
          return try await base.studioGenerateBatch(texts: lanes.map { texts[$0] }, speakers: lanes.map { laneVoices[$0] },
            seeds: attemptSeeds.map { UInt64($0) },
            generationParameters: GenerateParameters(maxTokens: 4096, temperature: 0.9, topP: 1, topK: 50, repetitionPenalty: 1.05),
            timing: { name, seconds in timings[name, default: 0] += seconds },
            uncertainEnd: { lane in
              NativeIO.emit("log", ["message": "Конец реплики без уверенного завершения — стоит послушать · " + ids[lanes[lane]]])
            })
        }, accepted: { lane, samples in
          let unit = units[indices[lane]]
          // The 16-bit cache clips at full scale. Measured peaks stay below 0.8; log any overshoot.
          let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
          if peak > 1 {
            NativeIO.emit("log", ["message": String(format: "Реплика %@ · пик %.3f выше 0 dBFS обрезан в кеше", ids[lane], Double(peak))])
          }
          // A shared call is cut between its lines at the natural pauses.
          let parts = unit.count == 1 ? [samples] : SpeechGroups.split(samples, weights: unit.map { SpeechGroups.weight(spoken($0)) })
          for (i, part) in zip(unit, parts) {
            try SpeechCache.save(files[i], samples: part, signature: signatures[i])
            framesByID[NativeIO.string(rows[i]["id"])] = part.count
          }
          NativeIO.emit("log", ["message": String(format: "Реплика %@ · %.1f с речи · пакет %d", ids[lane], Double(samples.count) / 24000, jobNumber+1)])
        })
      let duration = waves.reduce(0) { $0 + Double($1.count) / 24000 }
      let elapsed = max(0.001, Date().timeIntervalSince(start))
      let chars = indices.reduce(0) { total, u in units[u].reduce(total) { $0 + weight($1) } }
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
    let result = try SpeechBatch.timeline(rows, frameCounts: framesByID, pauses: SpeechBatch.Pauses(request["pauses"]))
    try SpeechBatch.verifyOrder(rows, timeline: result.0)
    NativeIO.emit("log", ["message": "Полнота озвучки проверена: \(rows.count)/\(rows.count) реплик · исходный порядок и голоса сохранены"])
    return result
  }

}
