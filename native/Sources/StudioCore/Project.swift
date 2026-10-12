import Foundation

public enum NativeProject {
  public static func cleanupBuildIntermediates(_ project: URL) {
    for name in ["audio-normalized", "audio-music", "audio/sample.wav", "result/chapters.txt"] {
      try? FileManager.default.removeItem(at: project.appendingPathComponent(name))
    }
  }
  /// Own voice samples are stored relative to the project, so a moved project keeps them.
  /// Older projects stored absolute paths; a missing absolute file is looked up in voice-samples.
  public static func sampleURL(_ path: String, project: URL) -> URL {
    if path.hasPrefix("/") {
      let absolute = URL(fileURLWithPath: path)
      if FileManager.default.fileExists(atPath: absolute.path) { return absolute }
      return project.appendingPathComponent("voice-samples/" + absolute.lastPathComponent)
    }
    let parts = path.split(separator: "/").filter { $0 != "." && $0 != ".." }
    return project.appendingPathComponent(parts.joined(separator: "/"))
  }
  public static func verify(_ folder: URL) throws -> (Object, Object) {
    let manifest = try NativeIO.load(folder.appendingPathComponent("roles/manifest.json"))
    let source = try NativeIO.load(folder.appendingPathComponent("roles/source.json"))
    guard
      NativeIO.string(NativeIO.object(manifest["book"])["input_sha256"])
        == (try NativeIO.hashFile(folder.appendingPathComponent("book.epub")))
    else { throw StudioError("Книга не соответствует проекту") }
    let voices = NativeIO.objects(manifest["voices"])
    let rows = NativeIO.objects(source["paragraphs"])
    let voiceIDs = Set(voices.map { NativeIO.string($0["id"]) })
    guard voiceIDs.count == voices.count, !voiceIDs.isEmpty,
      voiceIDs.allSatisfy({ !NativeIO.regex("^[a-z][a-z0-9_]*$", $0).isEmpty }),
      Set(rows.map { NativeIO.string($0["id"]) }).count == rows.count
    else { throw StudioError("Некорректный реестр ролей или абзацев") }
    let segments = NativeIO.objects(manifest["segments"])
    guard Set(segments.map { NativeIO.string($0["id"]) }).count == segments.count else {
      throw StudioError("Повторяющийся ID реплики")
    }
    var position = 0
    for paragraph in rows {
      let pid = NativeIO.string(paragraph["id"])
      let text = NativeIO.string(paragraph["text"])
      let scalars = Array(text.unicodeScalars)
      var cursor = 0
      while position < segments.count && NativeIO.string(segments[position]["paragraph_id"]) == pid
      {
        let segment = segments[position]
        let anchor = NativeIO.object(segment["source"])
        let speaker = NativeIO.string(segment["speaker"])
        guard !NativeIO.regex("^[a-zA-Z0-9_]+$", NativeIO.string(segment["id"])).isEmpty,
          speaker.isEmpty || voiceIDs.contains(speaker), let start = anchor["char_start"] as? Int,
          let end = anchor["char_end"] as? Int, start >= cursor, end > start, end <= scalars.count,
          NativeIO.string(segment["chapter_id"]) == NativeIO.string(paragraph["chapter_id"]),
          try NativeIO.scalarSlice(text, start, end) == NativeIO.string(segment["text"]),
          try NativeIO.scalarSlice(text, cursor, start).trimmingCharacters(
            in: .whitespacesAndNewlines
          ).isEmpty
        else { throw StudioError("Разметка пропускает, меняет или перекрывает текст книги") }
        cursor = end
        position += 1
      }
      guard
        try NativeIO.scalarSlice(text, cursor, scalars.count).trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty
      else { throw StudioError("В разметке отсутствует конец абзаца " + pid) }
    }
    guard position == segments.count else {
      throw StudioError("Разметка содержит неизвестные или переставленные абзацы")
    }
    return (manifest, source)
  }
  public static func excerpt(_ manifest: Object, character: String, target: Int = 120) throws
    -> String
  {
    var text = ""
    for segment in NativeIO.objects(manifest["segments"])
    where NativeIO.string(segment["speaker"]) == character {
      let part = NativeIO.replace("\\s+", NativeIO.string(segment["text"]), " ").trimmingCharacters(
        in: CharacterSet(charactersIn: " —–\n\t"))
      guard part.count >= 4, part.rangeOfCharacter(from: .letters) != nil else { continue }
      text += (text.isEmpty ? "" : " ") + part
      if text.count >= 150 { break }
    }
    guard text.count >= 20 else { throw StudioError("У персонажа недостаточно реплик для пробы") }
    guard text.count > target else { return text }
    let prefix = String(text.prefix(151))
    let ends = NativeIO.regex("[.!?…](?:[»”\"])?(?=\\s|$)", prefix).map {
      ($0.range.location + $0.range.length)
    }.filter { (110...150).contains($0) }
    if let end = ends.min(by: { abs($0 - target) < abs($1 - target) }) {
      return (prefix as NSString).substring(to: end)
    }
    let words = String(text.prefix(target)).split(separator: " ")
    return words.dropLast().joined(separator: " ").trimmingCharacters(
      in: CharacterSet(charactersIn: " ,;:—–")) + "…"
  }
  static func transform(_ value: Any, _ change: (String) throws -> String) rethrows -> Any {
    if let string = value as? String { return try change(string) }
    if let array = value as? [Any] { return try array.map { try transform($0, change) } }
    if let dict = value as? Object { return try dict.mapValues { try transform($0, change) } }
    return value
  }
  static func rewrite(_ root: URL, _ change: (String) throws -> String) throws {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
    for case let file as URL in enumerator where file.pathExtension == "json" {
      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
      try NativeIO.write(file, transform(value, change))
    }
  }
  public static func export(_ project: URL, destination: URL, settings: Object) throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.copyItem(at: project, to: temporary)
    var manifest = try NativeIO.load(temporary.appendingPathComponent("roles/manifest.json"))
    var voices = NativeIO.objects(manifest["voices"])
    for index in voices.indices {
      var ref = NativeIO.object(voices[index]["custom_reference"])
      guard !ref.isEmpty else { continue }
      let source = sampleURL(NativeIO.string(ref["path"]), project: project)
      let relative =
        "voice-samples/" + NativeIO.string(voices[index]["id"]) + "." + source.pathExtension
      let file = temporary.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
      try FileManager.default.copyItem(at: source, to: file)
      ref["path"] = relative
      voices[index]["custom_reference"] = ref
    }
    manifest["voices"] = voices
    try NativeIO.write(temporary.appendingPathComponent("roles/manifest.json"), manifest)
    var options = settings
    let music = URL(fileURLWithPath: NativeIO.string(settings["music"]))
    if FileManager.default.fileExists(atPath: music.path),
      !NativeIO.string(settings["music"]).isEmpty
    {
      let relative = "music/" + music.lastPathComponent
      let file = temporary.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
      try FileManager.default.copyItem(at: music, to: file)
      options["music"] = "studio-project://" + relative
    }
    try NativeIO.write(temporary.appendingPathComponent("studio-settings.json"), options)
    try rewrite(temporary) { text in
      guard text.hasPrefix("/") else { return text }
      let path = URL(fileURLWithPath: text).resolvingSymlinksInPath().path
      let prefix = project.resolvingSymlinksInPath().path + "/"
      return path.hasPrefix(prefix)
        ? "studio-project://" + String(path.dropFirst(prefix.count)) : text
    }
    try NativeIO.zip(temporary, to: destination)
  }
  public static func open(_ archive: URL, output: URL) throws -> URL {
    let root = output.appendingPathComponent(
      archive.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(8))
    do {
      try NativeIO.unpack(archive, to: root)
      try rewrite(root) { text in
        guard text.hasPrefix("studio-project://") else { return text }
        let relative = String(text.dropFirst("studio-project://".count))
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
          throw StudioError("Недопустимая ссылка в проекте")
        }
        return root.appendingPathComponent(relative).path
      }
      _ = try verify(root)
      return root
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }
}
