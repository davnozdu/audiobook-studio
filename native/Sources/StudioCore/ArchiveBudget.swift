import Foundation

public struct ArchiveBudget {
  public var expandedBytes: UInt64, memberBytes: UInt64, members: Int
  public init(expandedBytes: UInt64, memberBytes: UInt64, members: Int) {
    self.expandedBytes = expandedBytes; self.memberBytes = memberBytes; self.members = members
  }
  public static let book = ArchiveBudget(expandedBytes: 8 * 1024 * 1024 * 1024, memberBytes: 8 * 1024 * 1024 * 1024, members: 50_000)
  public static let project = ArchiveBudget(expandedBytes: 64 * 1024 * 1024 * 1024, memberBytes: 16 * 1024 * 1024 * 1024, members: 200_000)
}

extension NativeIO {
  static func verifyArchiveOutput(_ folder: URL, budget: ArchiveBudget) throws {
    var actual: UInt64 = 0; var count = 0
    guard let iterator = FileManager.default.enumerator(at: folder,
      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { throw StudioError("Не удалось проверить распаковку") }
    for case let file as URL in iterator {
      let values: URLResourceValues
      do { values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) }
      catch { if !FileManager.default.fileExists(atPath: file.path) { continue }; throw error }
      guard values.isSymbolicLink != true else { throw StudioError("Символическая ссылка в распакованной книге") }
      count += 1
      guard count <= budget.members else { throw StudioError("Слишком много файлов после распаковки") }
      if values.isRegularFile == true {
        let bytes = UInt64(max(0, values.fileSize ?? 0))
        guard bytes <= budget.memberBytes, bytes <= budget.expandedBytes - actual else { throw StudioError("Распаковка превышает лимит размера") }
        actual += bytes
      }
    }
  }
  /// Read the bounded central directory before running any extraction (including ZIP64 projects).
  static func archiveSize(_ file: URL, budget: ArchiveBudget) throws -> UInt64 {
    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
    let size = try handle.seekToEnd()
    func read(_ offset: UInt64, _ count: Int) throws -> Data {
      guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw StudioError("Оборванный каталог ZIP") }
      try handle.seek(toOffset: offset)
      let data = try handle.read(upToCount: count) ?? Data()
      guard data.count == count else { throw StudioError("Оборванный каталог ZIP") }
      return data
    }
    func number(_ data: Data, _ offset: Int, _ bytes: Int) throws -> UInt64 {
      guard offset >= 0, bytes <= data.count, offset <= data.count - bytes else { throw StudioError("Оборванный каталог ZIP") }
      var result: UInt64 = 0
      for i in 0..<bytes { result |= UInt64(data[offset + i]) << (8 * i) }
      return result
    }
    let tailStart = size > 65_557 ? size - 65_557 : 0
    let tail = try read(tailStart, Int(size - tailStart))
    guard tail.count >= 22 else { throw StudioError("Некорректный ZIP") }
    var end: Int?
    for p in stride(from: tail.count - 22, through: 0, by: -1) {
      if try number(tail, p, 4) == 0x06054b50, p + 22 + Int(try number(tail, p + 20, 2)) == tail.count { end = p; break }
    }
    guard let end, try number(tail, end + 4, 2) == 0, try number(tail, end + 6, 2) == 0 else {
      throw StudioError("Многотомный или повреждённый ZIP не поддерживается")
    }
    var count = try number(tail, end + 10, 2), bytes = try number(tail, end + 12, 4), offset = try number(tail, end + 16, 4)
    if count == 0xffff || bytes == 0xffffffff || offset == 0xffffffff {
      guard tailStart + UInt64(end) >= 20 else { throw StudioError("Оборванный ZIP64") }
      let locator = try read(tailStart + UInt64(end) - 20, 20)
      guard try number(locator, 0, 4) == 0x07064b50, try number(locator, 4, 4) == 0,
        try number(locator, 16, 4) == 1 else { throw StudioError("Некорректный ZIP64") }
      let record = try read(number(locator, 8, 8), 56)
      guard try number(record, 0, 4) == 0x06064b50, try number(record, 16, 4) == 0,
        try number(record, 20, 4) == 0 else { throw StudioError("Некорректный ZIP64") }
      count = try number(record, 32, 8); bytes = try number(record, 40, 8); offset = try number(record, 48, 8)
    }
    guard count > 0, count <= UInt64(max(0, budget.members)), bytes <= 64 * 1024 * 1024,
      offset <= size, bytes <= size - offset else { throw StudioError("Архив превышает лимит каталога или файлов") }
    let directory = try read(offset, Int(bytes))
    var cursor = 0, total: UInt64 = 0
    for _ in 0..<Int(count) {
      guard try number(directory, cursor, 4) == 0x02014b50 else { throw StudioError("Повреждённый каталог ZIP") }
      let nameSize = Int(try number(directory, cursor + 28, 2)), extraSize = Int(try number(directory, cursor + 30, 2)), commentSize = Int(try number(directory, cursor + 32, 2))
      let length = 46 + nameSize + extraSize + commentSize
      guard cursor <= directory.count, length <= directory.count - cursor else { throw StudioError("Оборванный каталог ZIP") }
      var expanded = try number(directory, cursor + 24, 4)
      if expanded == 0xffffffff {
        var p = cursor + 46 + nameSize; let limit = p + extraSize; var found = false
        while p + 4 <= limit {
          let tag = try number(directory, p, 2), n = Int(try number(directory, p + 2, 2)); p += 4
          guard n <= limit - p else { throw StudioError("Оборванный ZIP64 member") }
          if tag == 1 { guard n >= 8 else { throw StudioError("Оборванный ZIP64 size") }; expanded = try number(directory, p, 8); found = true; break }
          p += n
        }
        guard found else { throw StudioError("Нет размера ZIP64 member") }
      }
      guard expanded <= budget.memberBytes, total <= budget.expandedBytes,
        expanded <= budget.expandedBytes - total else { throw StudioError("Распакованная книга превышает лимит размера") }
      total += expanded; cursor += length
    }
    return total
  }
}
