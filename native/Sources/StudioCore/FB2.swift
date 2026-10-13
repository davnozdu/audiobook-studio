import Foundation

/// FictionBook 2 → EPUB 3. The result is an ordinary book.epub, so roles, speech and the
/// read-along EPUB work exactly as for EPUB input. Notes bodies and note references are left
/// out (they would be read aloud mid-sentence); images, tables and comments are skipped.
public enum NativeFB2 {
  public static let extensions = ["fb2", "fbz"]
  public static func accepts(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return name.hasSuffix(".fb2") || name.hasSuffix(".fb2.zip") || name.hasSuffix(".fbz")
  }
  /// File name without ".fb2", ".fb2.zip" or ".fbz".
  public static func baseName(_ url: URL) -> String {
    var name = url.lastPathComponent
    for suffix in [".fb2.zip", ".fbz", ".fb2", ".epub"] where name.lowercased().hasSuffix(suffix) {
      name = String(name.dropLast(suffix.count)); break
    }
    return name
  }

  public static func convert(_ input: URL, to output: URL) throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: work) }
    var source = input
    if !input.lastPathComponent.lowercased().hasSuffix(".fb2") {
      try NativeIO.unpack(input, to: work.appendingPathComponent("archive"))
      let files = FileManager.default.enumerator(at: work.appendingPathComponent("archive"),
        includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
      guard let fb2 = files.first(where: { $0.pathExtension.lowercased() == "fb2" }) else {
        throw StudioError("В архиве нет файла FB2")
      }
      source = fb2
    }
    // libxml2 honours the declared encoding (FB2 is often windows-1251).
    let document: XMLDocument
    do { document = try XMLDocument(contentsOf: source, options: []) }
    catch { throw StudioError("Не удалось прочитать FB2: файл повреждён или не является FictionBook") }
    guard let root = document.rootElement(), root.localName == "FictionBook" else {
      throw StudioError("Файл не является книгой FB2")
    }
    let book = try build(root)
    let epub = work.appendingPathComponent("epub")
    try write(book, to: epub)
    if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
    try NativeIO.zip(epub, to: output, epub: true)
  }

  struct Chapter { var title: String; var blocks: [String] }
  struct Book {
    var title = "", author = "", language = "ru"
    var cover: (data: Data, ext: String)?
    var chapters: [Chapter] = []
  }

  static func children(_ node: XMLElement, _ name: String) -> [XMLElement] {
    (node.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
  }
  static func first(_ node: XMLElement?, _ path: [String]) -> XMLElement? {
    var current = node
    for name in path { current = current.flatMap { children($0, name).first } }
    return current
  }
  static func attribute(_ node: XMLElement, _ local: String) -> String? {
    (node.attributes ?? []).first { $0.localName == local }?.stringValue
  }
  static func clean(_ text: String) -> String {
    NativeIO.replace("\\s+", text, " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }
  /// Inline text without note references (`<a type="note">` or links to the notes body).
  static func inline(_ node: XMLNode, notes: Set<String>) -> String {
    if let element = node as? XMLElement {
      if element.localName == "a" {
        let href = (attribute(element, "href") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if attribute(element, "type") == "note" || notes.contains(href) { return "" }
      }
      if element.localName == "image" { return "" }
      return (element.children ?? []).map { inline($0, notes: notes) }.joined()
    }
    return node.kind == .text ? node.stringValue ?? "" : ""
  }

  static func build(_ root: XMLElement) throws -> Book {
    var book = Book()
    let info = first(root, ["description", "title-info"])
    book.title = clean(first(info, ["book-title"])?.stringValue ?? "")
    if let author = info.flatMap({ children($0, "author").first }) {
      book.author = clean(["first-name", "middle-name", "last-name"]
        .compactMap { first(author, [$0])?.stringValue }.joined(separator: " "))
    }
    let language = clean(first(info, ["lang"])?.stringValue ?? "")
    if !language.isEmpty { book.language = language }
    let binaries = Dictionary(children(root, "binary").compactMap { binary -> (String, XMLElement)? in
      guard let id = attribute(binary, "id") else { return nil }
      return (id, binary)
    }, uniquingKeysWith: { first, _ in first })
    if let image = first(info, ["coverpage", "image"]),
      let id = attribute(image, "href")?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
      let binary = binaries[id],
      let data = Data(base64Encoded: binary.stringValue ?? "", options: .ignoreUnknownCharacters),
      !data.isEmpty, data.count < 20_000_000 {
      let type = attribute(binary, "content-type") ?? ""
      if type.contains("png") { book.cover = (data, "png") }
      else if type.contains("jpeg") || type.contains("jpg") { book.cover = (data, "jpg") }
    }
    let bodies = children(root, "body")
    let notesBodies = bodies.filter { ["notes", "comments"].contains(attribute($0, "name") ?? "") }
    // IDs inside notes bodies: links to them are note references even without type="note".
    var notes = Set<String>()
    for body in notesBodies {
      for element in NativeBook.elements(body) { if let id = attribute(element, "id") { notes.insert(id) } }
    }
    for body in bodies where !notesBodies.contains(where: { $0 === body }) {
      var lead: [String] = []
      if let title = children(body, "title").first { lead += heading(title, level: 1, notes: notes) }
      for epigraph in children(body, "epigraph") { lead += blocks(epigraph, level: 2, notes: notes) }
      let sections = children(body, "section")
      if sections.isEmpty {
        let content = blocks(body, level: 1, notes: notes, skip: ["title", "epigraph"])
        if !(lead + content).isEmpty { book.chapters.append(Chapter(title: book.title, blocks: lead + content)) }
        continue
      }
      // The body title (author, book name) is its own short opening chapter.
      if !lead.isEmpty { book.chapters.append(Chapter(title: book.title.isEmpty ? "Титул" : book.title, blocks: lead)) }
      for section in sections {
        let title = children(section, "title").first.map { clean(inline($0, notes: notes)) } ?? ""
        let content = blocks(section, level: 2, notes: notes)
        guard !content.isEmpty else { continue }
        book.chapters.append(Chapter(title: title.isEmpty ? "Глава \(book.chapters.count + 1)" : title, blocks: content))
      }
    }
    guard !book.chapters.isEmpty else { throw StudioError("В FB2 нет читаемого текста") }
    if book.title.isEmpty { book.title = book.chapters[0].title }
    return book
  }

  static func paragraph(_ tag: String, _ node: XMLNode, notes: Set<String>) -> [String] {
    let text = clean(inline(node, notes: notes))
    return text.isEmpty ? [] : ["<\(tag)>" + NativeIO.xml(text) + "</\(tag)>"]
  }
  static func heading(_ title: XMLElement, level: Int, notes: Set<String>) -> [String] {
    let tag = "h\(min(6, max(1, level)))"
    let lines = children(title, "p")
    return lines.isEmpty ? paragraph(tag, title, notes: notes) : lines.flatMap { paragraph(tag, $0, notes: notes) }
  }
  /// Block content of a section in reading order. Every leaf is a p/h*/blockquote-p block,
  /// which the EPUB reader extracts without loss.
  static func blocks(_ node: XMLElement, level: Int, notes: Set<String>, skip: Set<String> = []) -> [String] {
    var result: [String] = []
    for child in (node.children ?? []).compactMap({ $0 as? XMLElement }) where !skip.contains(child.localName ?? "") {
      switch child.localName ?? "" {
      case "title": result += heading(child, level: level, notes: notes)
      case "subtitle": result += paragraph("h\(min(6, level + 1))", child, notes: notes)
      case "p", "text-author", "v": result += paragraph("p", child, notes: notes)
      case "section": result += blocks(child, level: level + 1, notes: notes)
      case "epigraph", "cite":
        let inner = blocks(child, level: level + 1, notes: notes)
        if !inner.isEmpty { result.append("<blockquote>" + inner.joined() + "</blockquote>") }
      case "poem", "stanza": result += blocks(child, level: level + 1, notes: notes)
      case "table":
        for row in children(child, "tr") {
          let cells = (row.children ?? []).compactMap { $0 as? XMLElement }.map { clean(inline($0, notes: notes)) }
            .filter { !$0.isEmpty }
          if !cells.isEmpty { result.append("<p>" + NativeIO.xml(cells.joined(separator: " · ")) + "</p>") }
        }
      default: continue  // image, empty-line, annotation and unknown markup carry no spoken text
      }
    }
    return result
  }

  static func write(_ book: Book, to folder: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: folder.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try fm.createDirectory(at: folder.appendingPathComponent("EPUB"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: folder.appendingPathComponent("mimetype"))
    try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"EPUB/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)
      .write(to: folder.appendingPathComponent("META-INF/container.xml"))
    let language = NativeIO.xml(book.language)
    var items = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
    var spine = "", nav = ""
    if let cover = book.cover {
      try cover.data.write(to: folder.appendingPathComponent("EPUB/cover." + cover.ext))
      items += "<item id=\"cover-image\" href=\"cover.\(cover.ext)\" media-type=\"image/\(cover.ext == "png" ? "png" : "jpeg")\" properties=\"cover-image\"/>"
    }
    for (index, chapter) in book.chapters.enumerated() {
      let id = String(format: "ch%03d", index + 1)
      let title = NativeIO.xml(chapter.title)
      try Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"\(language)\"><head><title>\(title)</title></head><body>"
        + chapter.blocks.joined(separator: "\n") + "</body></html>").utf8)
        .write(to: folder.appendingPathComponent("EPUB/\(id).xhtml"))
      items += "<item id=\"\(id)\" href=\"\(id).xhtml\" media-type=\"application/xhtml+xml\"/>"
      spine += "<itemref idref=\"\(id)\"/>"
      nav += "<li><a href=\"\(id).xhtml\">\(title)</a></li>"
    }
    try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>\(NativeIO.xml(book.title))</title></head><body><nav epub:type=\"toc\"><ol>\(nav)</ol></nav></body></html>".utf8)
      .write(to: folder.appendingPathComponent("EPUB/nav.xhtml"))
    let author = book.author.isEmpty ? "" : "<dc:creator>\(NativeIO.xml(book.author))</dc:creator>"
    try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier><dc:title>\(NativeIO.xml(book.title))</dc:title>\(author)<dc:language>\(language)</dc:language><meta property=\"dcterms:modified\">2026-01-01T00:00:00Z</meta></metadata><manifest>\(items)</manifest><spine>\(spine)</spine></package>".utf8)
      .write(to: folder.appendingPathComponent("EPUB/package.opf"))
  }
}
