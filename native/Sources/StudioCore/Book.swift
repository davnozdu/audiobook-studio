import Foundation

public enum NativeBook {
  // A container is read as one paragraph only when no other block is nested inside it;
  // text mixed with nested blocks still stops extraction instead of being lost.
  static let blocks: Set<String> = [
    "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "dt", "dd",
    "div", "section", "article", "td", "th", "caption", "figcaption", "pre", "address",
  ]
  static func elements(_ node: XMLNode) -> [XMLElement] {
    var result: [XMLElement] = []
    for child in node.children ?? [] {
      if let element = child as? XMLElement {
        result.append(element)
        result += elements(element)
      }
    }
    return result
  }
  static func package(_ temp: URL) throws -> (URL, [XMLElement], [String: XMLElement]) {
    let container = try XMLDocument(
      contentsOf: temp.appendingPathComponent("META-INF/container.xml"))
    guard
      let file = elements(container).first(where: { $0.localName == "rootfile" })?.attribute(
        forName: "full-path")?.stringValue
    else { throw StudioError("В EPUB нет OPF") }
    let opfURL = temp.appendingPathComponent(file).standardizedFileURL
    guard opfURL.path.hasPrefix(temp.path + "/") else { throw StudioError("Некорректный путь OPF") }
    let nodes = elements(try XMLDocument(contentsOf: opfURL))
    // Malformed books may repeat manifest IDs; the first declaration wins.
    let items = Dictionary(
      nodes.filter { $0.localName == "item" }.compactMap { node -> (String, XMLElement)? in
        guard let id = node.attribute(forName: "id")?.stringValue else { return nil }
        return (id, node)
      }, uniquingKeysWith: { first, _ in first })
    return (opfURL, nodes, items)
  }
  /// The EPUB cover (EPUB 3 cover-image or EPUB 2 meta cover), when it is JPEG or PNG.
  public static func cover(_ epub: URL) -> (data: Data, ext: String)? {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    guard (try? NativeIO.unpack(epub, to: temp)) != nil,
      let (opfURL, nodes, items) = try? package(temp)
    else { return nil }
    let metaID = nodes.first(where: {
      $0.localName == "meta" && $0.attribute(forName: "name")?.stringValue == "cover"
    })?.attribute(forName: "content")?.stringValue
    let item =
      items.values.first(where: {
        ($0.attribute(forName: "properties")?.stringValue ?? "").split(separator: " ")
          .contains("cover-image")
      }) ?? items[metaID ?? ""]
    let types = ["image/jpeg": "jpg", "image/png": "png"]
    guard let item, let ext = types[item.attribute(forName: "media-type")?.stringValue ?? ""],
      let href = item.attribute(forName: "href")?.stringValue?.removingPercentEncoding
    else { return nil }
    let url = opfURL.deletingLastPathComponent().appendingPathComponent(href).standardizedFileURL
    guard url.path.hasPrefix(temp.path + "/"), let data = try? Data(contentsOf: url),
      !data.isEmpty, data.count < 20_000_000
    else { return nil }
    return (data, ext)
  }
  public static func read(_ epub: URL) throws -> Object {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    try NativeIO.unpack(epub, to: temp)
    let (opfURL, nodes, items) = try package(temp)
    let title =
      nodes.first(where: { $0.localName == "title" })?.stringValue
      ?? epub.deletingPathExtension().lastPathComponent
    let author = nodes.first(where: { $0.localName == "creator" })?.stringValue ?? ""
    var paragraphs: [Object] = []
    var chapters: [Object] = []
    for ref in nodes.filter({ $0.localName == "itemref" }) {
      guard let item = items[ref.attribute(forName: "idref")?.stringValue ?? ""],
        item.attribute(forName: "media-type")?.stringValue == "application/xhtml+xml"
      else { continue }
      let href =
        (item.attribute(forName: "href")?.stringValue ?? "").components(separatedBy: "#")[0]
        .removingPercentEncoding ?? ""
      let url = opfURL.deletingLastPathComponent().appendingPathComponent(href).standardizedFileURL
      guard url.path.hasPrefix(temp.path + "/") else {
        throw StudioError("Некорректный путь главы EPUB")
      }
      let doc = try XMLDocument(contentsOf: url, options: [.documentTidyXML])
      for node in elements(doc).filter({ ["script", "style"].contains($0.localName ?? "") }) {
        node.detach()
      }
      let body: XMLNode = elements(doc).first(where: { $0.localName == "body" }) ?? doc
      let leaf = elements(body).filter {
        blocks.contains($0.localName ?? "")
          && !elements($0).contains(where: { blocks.contains($0.localName ?? "") })
      }
      let visible = NativeIO.replace("\\s+", body.stringValue ?? "", "")
      let extracted = NativeIO.replace("\\s+", leaf.map { $0.stringValue ?? "" }.joined(), "")
      guard visible == extracted else {
        throw StudioError(
          "В главе есть текст вне поддерживаемых блоков. Извлечение остановлено, чтобы не потерять его"
        )
      }
      let cid = String(format: "ch%03d", chapters.count + 1)
      let name =
        elements(body).first(where: {
          ($0.localName ?? "").range(of: "^h[1-6]$", options: .regularExpression) != nil
        })?.stringValue ?? url.deletingPathExtension().lastPathComponent
      let member = String(url.path.dropFirst(temp.path.count + 1))
      let before = paragraphs.count
      for (index, tag) in leaf.enumerated() {
        let text = NativeIO.replace("\\s+", tag.stringValue ?? "", " ").trimmingCharacters(
          in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        paragraphs.append([
          "id": String(format: "p%05d", paragraphs.count + 1), "chapter_id": cid, "text": text,
          "source": [
            "href": member, "block_index": index, "tag": tag.localName ?? "p",
            "element_id": tag.attribute(forName: "id")?.stringValue as Any? ?? NSNull(),
          ],
        ])
      }
      if paragraphs.count > before { chapters.append(["id": cid, "title": name, "href": member]) }
    }
    guard !paragraphs.isEmpty else { throw StudioError("В книге нет читаемого текста") }
    return [
      "title": title, "author": author, "input_sha256": try NativeIO.hashFile(epub),
      "normalization": "Unicode whitespace collapsed; original text preserved",
      "paragraphs": paragraphs, "chapters": chapters,
    ]
  }
  public static func split(_ text: String, maximum: Int = 240) -> [(Int, Int)] {
    let scalars = Array(text.unicodeScalars)
    var start = 0
    var result: [(Int, Int)] = []
    while start < scalars.count {
      while start < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[start]) {
        start += 1
      }
      guard start < scalars.count else { break }
      var end = min(start + maximum, scalars.count)
      let sentence = (start..<end).filter {
        ".!?…".unicodeScalars.contains(scalars[$0])
          && ($0 + 1 == scalars.count
            || CharacterSet.whitespacesAndNewlines.contains(scalars[$0 + 1]))
      }
      if end < scalars.count, let cut = sentence.last {
        end = cut + 1
      } else if end < scalars.count,
        let cut = (start..<end).last(where: {
          CharacterSet.whitespacesAndNewlines.contains(scalars[$0])
        })
      {
        end = cut
      }
      while end > start, CharacterSet.whitespacesAndNewlines.contains(scalars[end - 1]) { end -= 1 }
      if end <= start { end = min(start + maximum, scalars.count) }
      result.append((start, end))
      start = end
    }
    return result
  }
  public static func epub(
    _ manifest: Object, source: Object, timeline: [Object], audio: URL, output: URL,
    cover: (data: Data, ext: String)? = nil
  ) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    try FileManager.default.createDirectory(
      at: temp.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: temp.appendingPathComponent("EPUB/audio"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: temp.appendingPathComponent("mimetype"))
    try Data(
      "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"EPUB/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
        .utf8
    ).write(to: temp.appendingPathComponent("META-INF/container.xml"))
    try FileManager.default.copyItem(
      at: audio, to: temp.appendingPathComponent("EPUB/audio/book.m4a"))
    let book = NativeIO.object(manifest["book"])
    let segments = NativeIO.objects(manifest["segments"])
    let chapters = NativeIO.objects(source["chapters"])
    let title = NativeIO.xml(NativeIO.string(book["title"]))
    let original = Dictionary(
      uniqueKeysWithValues: NativeIO.objects(source["paragraphs"]).map {
        (NativeIO.string($0["id"]), NativeIO.string($0["text"]))
      })
    let timing = Dictionary(
      uniqueKeysWithValues: timeline.map { (NativeIO.string($0["segment_id"]), $0) })
    var items =
      "<item id=\"audio\" href=\"audio/book.m4a\" media-type=\"audio/mp4\"/><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"style\" href=\"style.css\" media-type=\"text/css\"/>"
    if let cover {
      try cover.data.write(to: temp.appendingPathComponent("EPUB/cover." + cover.ext))
      items +=
        "<item id=\"cover-image\" href=\"cover.\(cover.ext)\" media-type=\"image/\(cover.ext == "png" ? "png" : "jpeg")\" properties=\"cover-image\"/>"
    }
    var spine = ""
    var nav = ""
    var durations = ""
    let total = (timeline.last?["clip_end"] as? Double) ?? 0
    for chapter in chapters {
      let cid = NativeIO.string(chapter["id"])
      let chapterTitle = NativeIO.xml(NativeIO.string(chapter["title"]))
      let own = segments.filter { NativeIO.string($0["chapter_id"]) == cid }
      guard !own.isEmpty else { continue }
      var body = ""
      var overlay = ""
      var lastParagraph = ""
      var cursor = 0
      for segment in own {
        let pid = NativeIO.string(segment["paragraph_id"])
        let sid = NativeIO.string(segment["id"])
        let anchor = NativeIO.object(segment["source"])
        let start = anchor["char_start"] as? Int ?? 0
        let end = anchor["char_end"] as? Int ?? 0
        if pid != lastParagraph {
          if !lastParagraph.isEmpty { body += "</p>" }
          body += "<p id=\"\(pid)\">"
          cursor = 0
          lastParagraph = pid
        }
        if start >= cursor {
          body += NativeIO.xml(try NativeIO.scalarSlice(original[pid] ?? "", cursor, start))
        }
        body += "<span id=\"\(sid)\">\(NativeIO.xml(NativeIO.string(segment["text"])))</span>"
        cursor = end
        guard let row = timing[sid], let begin = row["audio_start"] as? Double,
          let finish = row["clip_end"] as? Double
        else { throw StudioError("Нет времени для реплики \(sid)") }
        overlay +=
          "<par id=\"par-\(sid)\"><text src=\"\(cid).xhtml#\(sid)\"/><audio src=\"audio/book.m4a\" clipBegin=\"\(String(format: "%.3f", begin))s\" clipEnd=\"\(String(format: "%.3f", finish))s\"/></par>"
      }
      body += "</p>"
      let html =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"ru\"><head><title>\(title)</title><link rel=\"stylesheet\" href=\"style.css\"/></head><body>\(body)</body></html>"
      try Data(html.utf8).write(to: temp.appendingPathComponent("EPUB/\(cid).xhtml"))
      let smil =
        "<?xml version=\"1.0\"?><smil xmlns=\"http://www.w3.org/ns/SMIL\" xmlns:epub=\"http://www.idpf.org/2007/ops\" version=\"3.0\"><body><seq epub:textref=\"\(cid).xhtml\">\(overlay)</seq></body></smil>"
      try Data(smil.utf8).write(to: temp.appendingPathComponent("EPUB/\(cid).smil"))
      items +=
        "<item id=\"\(cid)\" href=\"\(cid).xhtml\" media-type=\"application/xhtml+xml\" media-overlay=\"overlay-\(cid)\"/><item id=\"overlay-\(cid)\" href=\"\(cid).smil\" media-type=\"application/smil+xml\"/>"
      spine += "<itemref idref=\"\(cid)\"/>"
      nav += "<li><a href=\"\(cid).xhtml\">\(chapterTitle)</a></li>"
      let first = timing[NativeIO.string(own.first?["id"])]?["audio_start"] as? Double ?? 0
      let last = timing[NativeIO.string(own.last?["id"])]?["clip_end"] as? Double ?? first
      durations +=
        "<meta property=\"media:duration\" refines=\"#overlay-\(cid)\">\(last-first)s</meta>"
    }
    let opf =
      "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" prefix=\"media: http://www.idpf.org/epub/vocab/overlays/#\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book-id\">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(title)</dc:title><dc:creator>\(NativeIO.xml(NativeIO.string(book["author"])))</dc:creator><dc:language>ru</dc:language><meta property=\"dcterms:modified\">\(ISO8601DateFormatter().string(from: Date()))</meta><meta property=\"media:duration\">\(total)s</meta><meta property=\"media:active-class\">tts-active</meta>\(cover == nil ? "" : "<meta name=\"cover\" content=\"cover-image\"/>")\(durations)</metadata><manifest>\(items)</manifest><spine>\(spine)</spine></package>"
    try Data(opf.utf8).write(to: temp.appendingPathComponent("EPUB/package.opf"))
    let navigation =
      "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>\(title)</title></head><body><nav epub:type=\"toc\"><ol>\(nav)</ol></nav></body></html>"
    try Data(navigation.utf8).write(to: temp.appendingPathComponent("EPUB/nav.xhtml"))
    try Data(
      "body{max-width:42em;margin:auto;padding:2em;font:1.1em Georgia;line-height:1.6}.tts-active{background:#e9d9a6;border-radius:3px}"
        .utf8
    ).write(to: temp.appendingPathComponent("EPUB/style.css"))
    try NativeIO.zip(temp, to: output, epub: true)
  }
}
