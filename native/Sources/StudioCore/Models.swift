import Foundation
import Darwin

public struct NativeModels {
  public let root: URL, resources: URL
  public init(root: URL, resources: URL) {
    self.root = root
    self.resources = resources
  }
  public func ensure(design: Bool) throws -> URL {
    let name =
      design ? "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit" : "Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-source"
    let spec = try NativeIO.load(
      resources.appendingPathComponent(
        design ? "design_model_files.json" : "stress_model_files.json"))
    let files = NativeIO.objects(spec["files"])
    let target = root.appendingPathComponent("models/" + name)
    let total = files.reduce(0) { $0 + ($1["size"] as? Int ?? 0) }
    let validationURL = root.appendingPathComponent("model-validation.json")
    var validations = (try? NativeIO.load(validationURL)) ?? [:]
    func record(_ path: URL, key: String, size: Int, sha: String) {
      guard let identity = try? fileIdentity(path, size: size, sha: sha) else { return }
      validations[key] = identity
      try? NativeIO.write(validationURL, validations)
    }
    func valid(_ path: URL, key: String, size: Int, sha: String) -> Bool {
      guard let before = try? fileIdentity(path, size: size, sha: sha) else { return false }
      if NativeIO.string(validations[key]) == before { return true }
      guard (try? validate(path, size: size, sha: sha)) != nil,
        let after = try? fileIdentity(path, size: size, sha: sha), before == after
      else { return false }
      record(path, key: key, size: size, sha: sha)
      return true
    }
    var done = 0
    for item in files {
      let relative = NativeIO.string(item["path"])
      let size = item["size"] as? Int ?? 0
      let sha = NativeIO.string(item["sha256"])
      let key = name + "/" + relative
      let path = target.appendingPathComponent(relative)
      NativeIO.stage(
        "Проверка модели · " + name + " · " + relative, Double(done) / Double(max(1, total)))
      if FileManager.default.fileExists(atPath: path.path) {
        if valid(path, key: key, size: size, sha: sha) {
          done += size
          continue
        }
        NativeIO.stage("Повреждённый файл модели · загружаю заново · " + relative)
        try FileManager.default.removeItem(at: path)
      }
      let old = root.deletingLastPathComponent().appendingPathComponent(
        "models/" + name + "/" + relative)
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: old.path),
        valid(old, key: "legacy/" + key, size: size, sha: sha)
      {
        try FileManager.default.copyItem(at: old, to: path)
        record(path, key: key, size: size, sha: sha)
        done += size
        continue
      }
      let partial = path.appendingPathExtension("partial")
      let remote =
        "https://huggingface.co/" + NativeIO.string(spec["repo"]) + "/resolve/"
        + NativeIO.string(spec["revision"]) + "/" + relative
      try download(remote, to: partial, size: size, sha: sha, done: done, total: total,
        design: design, relative: relative)
      try FileManager.default.moveItem(at: partial, to: path)
      record(path, key: key, size: size, sha: sha)
      done += size
    }
    return target
  }
  func fileIdentity(_ path: URL, size: Int, sha: String) throws -> String {
    var info = stat()
    guard fstatat(AT_FDCWD, path.path, &info, 0) == 0, info.st_size == size else {
      throw StudioError("Файл модели отсутствует или изменён")
    }
    // ctime detects replacement or edits even when mtime was preserved.
    let identity = "v1|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|"
      + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)|"
      + "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)|\(sha)"
    return NativeIO.hash(Data(identity.utf8))
  }
  private func download(_ remote: String, to partial: URL, size: Int, sha: String,
    done: Int, total: Int, design: Bool, relative: String) throws
  {
    // A previous interrupted run may already have downloaded the complete file.
    if fileSize(partial) >= size, FileManager.default.fileExists(atPath: partial.path) {
      NativeIO.stage("Проверка завершённой загрузки · " + relative)
      if (try? validate(partial, size: size, sha: sha)) != nil { return }
      try FileManager.default.removeItem(at: partial)
    }
    for attempt in 0..<2 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
      process.arguments = [
        "-fsSL", "--connect-timeout", "30", "--speed-limit", "1024", "--speed-time", "90",
        "--retry", "3", "-C", "-", remote, "-o", partial.path,
      ]
      let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      FileManager.default.createFile(atPath: errorURL.path, contents: nil)
      let errorHandle = try FileHandle(forWritingTo: errorURL)
      defer {
        try? errorHandle.close()
        try? FileManager.default.removeItem(at: errorURL)
      }
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errorHandle
      let start = Date()
      let initial = fileSize(partial)
      try process.run()
      NativeIO.emit("child", ["pid": process.processIdentifier])
      repeat {
        let current = fileSize(partial)
        let rate = Double(max(0, current - initial)) / max(0.01, Date().timeIntervalSince(start))
        NativeIO.stage(
          String(format: "Скачивание %@ · %@ · %.0f / %.0f МБ · %.1f МБ/с",
            design ? "VoiceDesign" : "модели озвучки", relative,
            Double(done + current) / 1_048_576, Double(total) / 1_048_576, rate / 1_048_576),
          min(1, Double(done + current) / Double(max(1, total))))
        Thread.sleep(forTimeInterval: 1)
      } while process.isRunning
      process.waitUntilExit()
      NativeIO.emit("child", ["pid": 0])
      if process.terminationStatus != 0 {
        // curl 33: server rejected resuming; 416: stale range beyond the remote file.
        let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        if attempt == 0, process.terminationStatus == 33 || detail.contains("416") {
          try? FileManager.default.removeItem(at: partial)
          NativeIO.stage("Повторная загрузка модели с начала · " + relative)
          continue
        }
        throw StudioError("Не удалось скачать модель. Проверьте соединение и повторите: загрузка продолжится")
      }
      NativeIO.stage("Проверка контрольной суммы · " + relative,
        Double(done + size) / Double(max(1, total)))
      do {
        try validate(partial, size: size, sha: sha)
        return
      } catch {
        try? FileManager.default.removeItem(at: partial)
        if attempt == 1 { throw error }
        NativeIO.stage("Проверка загрузки не пройдена · повторяю · " + relative)
      }
    }
  }
  func fileSize(_ path: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
  }
  func validate(_ path: URL, size: Int, sha: String) throws {
    guard fileSize(path) == size, try sha.isEmpty || NativeIO.hashFile(path) == sha else {
      throw StudioError("Файл модели повреждён: " + path.lastPathComponent)
    }
  }
  public func setup() throws {
    _ = try ensure(design: false)
    _ = try ensure(design: true)
    NativeIO.stage("Проверка встроенных словарей и нативных движков")
    let dictionary = resources.appendingPathComponent("resources/russian_accents_full.sacc")
    guard
      try NativeIO.hashFile(dictionary)
        == "a1ac32606e99f6d8ab8e8ce796b0005b0693908555460656976c54e171658b27"
    else { throw StudioError("Повреждён встроенный словарь") }
  }
}
