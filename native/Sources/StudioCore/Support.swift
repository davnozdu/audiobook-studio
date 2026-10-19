import CryptoKit
import Darwin
import Foundation

public typealias Object = [String: Any]
public struct StudioError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
public enum NativeIO {
  private static var logFile: FileHandle?
  public static func beginLog(_ folder: URL) throws {
    let file = folder.appendingPathComponent("run.log")
    if !FileManager.default.fileExists(atPath: file.path) {
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    logFile = try FileHandle(forWritingTo: file)
    try logFile?.seekToEnd()
  }
  public static let eventOutput: FileHandle = {
    let descriptor = dup(STDOUT_FILENO)
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }()
  public static func object(_ value: Any?) -> Object { value as? Object ?? [:] }
  public static func objects(_ value: Any?) -> [Object] { value as? [Object] ?? [] }
  public static func string(_ value: Any?) -> String { value as? String ?? "" }
  public static func load(_ url: URL) throws -> Object {
    object(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
  }
  public static func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed])
  }
  public static func write(_ url: URL, _ value: Any) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json(value).write(to: url, options: .atomic)
  }
  public static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public static func emit(_ kind: String, _ data: Object = [:]) {
    var event = data
    event["type"] = kind
    if let encoded = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
      var line = String(data: encoded, encoding: .utf8)
    {
      line += "\n"
      eventOutput.write(Data(line.utf8))
      try? logFile?.write(contentsOf: Data(line.utf8))
    }
  }
  public static func stage(_ message: String, _ fraction: Double = 0) {
    emit("progress", ["message": message, "fraction": fraction])
  }
  /// A step inside book synthesis: the GUI keeps the measured speed and remaining time.
  public static func synthesisStage(_ message: String, _ fraction: Double) {
    emit("progress", ["message": message, "fraction": fraction, "synthesis": true])
  }
  private static let regexLock = NSLock()
  private static var compiledRegex: [String: NSRegularExpression] = [:]
  /// Patterns are reused per word and per book block, so each is compiled once.
  static func compiled(_ pattern: String) -> NSRegularExpression? {
    regexLock.lock()
    defer { regexLock.unlock() }
    if let regex = compiledRegex[pattern] { return regex }
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    if compiledRegex.count >= 4096 { compiledRegex.removeAll() }
    compiledRegex[pattern] = regex
    return regex
  }
  public static func regex(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
    compiled(pattern)?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
  }
  public static func replace(_ pattern: String, _ text: String, _ replacement: String) -> String {
    compiled(pattern)?.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement) ?? text
  }
  public static func scalarSlice(_ text: String, _ start: Int, _ end: Int) throws -> String {
    let scalars = Array(text.unicodeScalars)
    guard start >= 0, end >= start, end <= scalars.count else {
      throw StudioError("Разметка роли выходит за границы текста")
    }
    return String(String.UnicodeScalarView(scalars[start..<end]))
  }
  /// Reserve room for extensions/suffixes; both UTF-8 and UTF-16 stay within FS limits.
  public static func fileStem(_ text: String, maxBytes: Int = 180) -> String {
    var result = ""
    for character in text {
      let part = String(character)
      if result.utf8.count + part.utf8.count > maxBytes { break }
      result += part
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public static func xml(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  public static func capture(
    _ executable: URL, _ arguments: [String], cwd: URL? = nil, events: Bool = true,
    monitor: (() throws -> Void)? = nil
  ) throws -> (Data, Data) {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    let lock = NSLock()
    var capturedError = Data()
    defer {
      errors.fileHandleForReading.readabilityHandler = nil
      lock.lock(); defer { lock.unlock() }
      for pipe in [output, errors] {
        try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
      }
    }
    errors.fileHandleForReading.readabilityHandler = { handle in
      lock.lock()
      defer { lock.unlock() }
      let data = handle.availableData
      if !data.isEmpty {
        capturedError.append(data)
      }
    }
    try process.run()
    let monitorLock = NSLock()
    var monitorFinished = false, monitorError: Error?
    let timer = monitor == nil ? nil : DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer?.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer?.setEventHandler {
      monitorLock.lock(); defer { monitorLock.unlock() }
      guard !monitorFinished else { return }
      do { try monitor?() } catch {
        monitorError = error
        if process.isRunning { kill(-process.processIdentifier, SIGKILL); kill(process.processIdentifier, SIGKILL) }
      }
    }
    timer?.resume()
    defer { monitorLock.lock(); monitorFinished = true; monitorLock.unlock(); timer?.cancel() }
    if events { emit("child", ["pid": process.processIdentifier]) }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    lock.lock()
    errors.fileHandleForReading.readabilityHandler = nil
    capturedError.append(errors.fileHandleForReading.readDataToEndOfFile())
    lock.unlock()
    if events { emit("child", ["pid": process.processIdentifier, "ended": true]) }
    monitorLock.lock(); let failure = monitorError; monitorFinished = true; monitorLock.unlock()
    if let failure { throw failure }
    guard process.terminationStatus == 0 else {
      let detail = String(data: capturedError, encoding: .utf8) ?? ""
      throw StudioError(executable.lastPathComponent + ": " + String(detail.suffix(1500)))
    }
    return (data, capturedError)
  }
  @discardableResult public static func run(
    _ executable: URL, _ arguments: [String], cwd: URL? = nil, events: Bool = true
  ) throws -> Data { try capture(executable, arguments, cwd: cwd, events: events).0 }
  public static func archiveMembers(_ url: URL) throws -> [String] {
    let text =
      String(
        data: try run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", url.path]), encoding: .utf8)
      ?? ""
    let members = text.split(separator: "\n").map(String.init)
    guard !members.isEmpty else { throw StudioError("Архив пуст") }
    for name in members {
      guard !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains("..")
      else { throw StudioError("Недопустимый путь в архиве") }
    }
    let metadata =
      String(
        data: try run(URL(fileURLWithPath: "/usr/bin/zipinfo"), ["-l", url.path]), encoding: .utf8)
      ?? ""
    guard !metadata.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else {
      throw StudioError("Символические ссылки в архиве не поддерживаются")
    }
    return members
  }
  public static func unpack(_ url: URL, to folder: URL, budget: ArchiveBudget = .book) throws {
    let expanded = try archiveSize(url, budget: budget)
    _ = try archiveMembers(url)
    let fm = FileManager.default
    var ancestor = folder.deletingLastPathComponent()
    while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
    let free = (try fm.attributesOfFileSystem(forPath: ancestor.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
    guard expanded <= free, free - expanded >= 256 * 1024 * 1024 else { throw StudioError("Недостаточно места для распаковки книги") }
    guard !fm.fileExists(atPath: folder.path) else { throw StudioError("Папка распаковки уже существует") }
    do {
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      // Darwin sh expresses RLIMIT_FSIZE in KiB; only this child receives the hard per-file limit.
      let limit = min(budget.memberBytes, expanded)
      let blocks = limit / 1024 + (limit % 1024 == 0 ? 0 : 1)
      let actualBudget = ArchiveBudget(expandedBytes: expanded, memberBytes: limit, members: budget.members)
      _ = try capture(URL(fileURLWithPath: "/bin/sh"),
        ["-c", "ulimit -f \"$1\" || exit 1; exec /usr/bin/ditto -x -k \"$2\" \"$3\"", "archive", String(max(1, blocks)), url.path, folder.path],
        monitor: { try verifyArchiveOutput(folder, budget: actualBudget) })
      try verifyArchiveOutput(folder, budget: actualBudget)
    } catch { try? fm.removeItem(at: folder); throw error }
  }
  public static func zip(_ folder: URL, to url: URL, epub: Bool = false) throws {
    let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
    defer { try? FileManager.default.removeItem(at: temp) }
    if epub {
      try run(
        URL(fileURLWithPath: "/usr/bin/zip"), ["-q", "-X", "-0", temp.path, "mimetype"], cwd: folder
      )
    }
    // Already compressed media is stored, not deflated again: same size, far less CPU on hours of AAC.
    try run(
      URL(fileURLWithPath: "/usr/bin/zip"),
      ["-q", "-X", "-r", "-n", ".m4a:.m4b:.mp3:.aac:.jpg:.jpeg:.png:.zip:.epub:.spcm", temp.path, ".", "-x", "mimetype"],
      cwd: folder)
    if !epub, FileManager.default.fileExists(atPath: folder.appendingPathComponent("mimetype").path)
    {
      try run(URL(fileURLWithPath: "/usr/bin/zip"), ["-q", temp.path, "mimetype"], cwd: folder)
    }
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    } else {
      try FileManager.default.moveItem(at: temp, to: url)
    }
  }
}
