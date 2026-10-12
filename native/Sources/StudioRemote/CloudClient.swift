import Foundation
import CryptoKit

@MainActor public final class CloudClient {
    let provider: RemoteProvider, config: RemoteConfig, oauth: RemoteOAuth, http: RemoteHTTP
    var access = "", expires = Date.distantPast
    public init(provider: RemoteProvider, config: RemoteConfig, secrets: RemoteSecrets, http: RemoteHTTP = RemoteHTTP()) {
        self.provider = provider; self.config = config; self.http = http; oauth = RemoteOAuth(secrets: secrets, http: http)
    }
    func request(_ url: URL, method: String, data: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<2 {
            if expires < Date() { access = try await oauth.token(provider, config: config); expires = Date().addingTimeInterval(3000) }
            var r = URLRequest(url: url); r.httpMethod = method; r.httpBody = data; r.timeoutInterval = 180
            r.setValue("Bearer " + access, forHTTPHeaderField: "Authorization"); headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            let result = try await http.send(r)
            if result.1.statusCode == 401 && attempt == 0 { expires = .distantPast; continue }
            return result
        }
        throw RemoteError("Переподключите " + provider.title)
    }
    func api(_ route: String, _ body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await request(URL(string: "https://api.dropboxapi.com/2/" + route)!, method: "POST", data: RemoteJSON.data(body), headers: ["Content-Type": "application/json"])
        guard response.statusCode == 200 else { throw RemoteError("Dropbox: HTTP \(response.statusCode)") }
        return try RemoteJSON.object(data)
    }
    public func folder(jobID: String, title: String = "", author: String = "") async throws -> String {
        if provider == .dropbox {
            let root = "/Audiobook Studio"
            try await dropboxCreateFolder(root)
            let base = Self.bookBase(title: title, author: author).isEmpty ? "Книга " + jobID : Self.bookBase(title: title, author: author)
            let path = root + "/" + base
            try await dropboxCreateFolder(path)
            return path
        }
        let root = try await googleRoot(create: true)
        let base = Self.bookBase(title: title, author: author).isEmpty ? "Книга " + jobID : Self.bookBase(title: title, author: author)
        return try await googleFolder(name: base, parent: root)
    }
    public struct CloudBook: Sendable {
        public let id: String, name: String, m4bURL: String?, epubURL: String?, path: String?
        public init(id: String, name: String, m4bURL: String?, epubURL: String?, path: String? = nil) {
            self.id = id; self.name = name; self.m4bURL = m4bURL; self.epubURL = epubURL; self.path = path
        }
    }
    public struct CloudLibraryPage: Sendable {
        public let books: [CloudBook], nextToken: String?
    }
    public func googleBooks(search: String? = nil, pageToken: String? = nil) async throws -> CloudLibraryPage {
        let root = try await googleRoot(create: true)
        let query = "'\(root)' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false"
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "pageSize", value: "10"),
                                 URLQueryItem(name: "orderBy", value: "name_natural"),
                                 URLQueryItem(name: "fields", value: "nextPageToken,files(id,name)")]
        if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let (data, response) = try await request(components.url!, method: "GET")
        guard response.statusCode == 200 else { throw RemoteError("Не удалось прочитать папку Audiobook Studio в Google Drive") }
        let object = try RemoteJSON.object(data)
        let term = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folders = (object["files"] as? [[String: Any]] ?? []).filter {
            term.isEmpty || ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(term)
        }
        var books: [CloudBook] = []
        for folder in folders {
            guard let id = folder["id"] as? String else { continue }
            let children = try await googleChildren(id)
            let m4b = children.first { ($0["name"] as? String ?? "").lowercased().hasSuffix(".m4b") }?["id"] as? String
            let epub = children.first { ($0["name"] as? String ?? "").lowercased().hasSuffix(".epub") }?["id"] as? String
            books.append(CloudBook(id: id, name: folder["name"] as? String ?? "Без названия",
                                   m4bURL: m4b.map { googleDownloadURL(fileID: $0) }, epubURL: epub.map { googleDownloadURL(fileID: $0) }))
        }
        return CloudLibraryPage(books: books, nextToken: object["nextPageToken"] as? String)
    }
    public func dropboxBooks(search: String? = nil, cursor: String? = nil) async throws -> CloudLibraryPage {
        try await dropboxCreateFolder("/Audiobook Studio")
        let object = try await api(cursor == nil ? "files/list_folder" : "files/list_folder/continue",
                                   cursor.map { ["cursor": $0] } ?? ["path": "/Audiobook Studio", "recursive": false, "include_deleted": false, "limit": 10])
        let entries = object["entries"] as? [[String: Any]] ?? []
        let term = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var books: [CloudBook] = []
        for folder in entries where folder[".tag"] as? String == "folder" {
            let name = folder["name"] as? String ?? "Без названия"
            guard term.isEmpty || name.localizedCaseInsensitiveContains(term), let id = folder["id"] as? String,
                  let path = folder["path_display"] as? String else { continue }
            let files = try await api("files/list_folder", ["path": path, "recursive": false, "include_deleted": false])
            let children = files["entries"] as? [[String: Any]] ?? []
            let m4b = children.first { ($0["name"] as? String ?? "").lowercased().hasSuffix(".m4b") }
            let epub = children.first { ($0["name"] as? String ?? "").lowercased().hasSuffix(".epub") }
            let m4bURL = try await dropboxSharedURL(m4b?["path_display"] as? String)
            let epubURL = try await dropboxSharedURL(epub?["path_display"] as? String)
            books.append(CloudBook(id: id, name: name, m4bURL: m4bURL, epubURL: epubURL, path: path))
        }
        return CloudLibraryPage(books: books, nextToken: object["has_more"] as? Bool == true ? object["cursor"] as? String : nil)
    }
    public func deleteDropboxBook(folderID: String) async throws {
        let item = try await api("files/get_metadata", ["path": folderID])
        guard item[".tag"] as? String == "folder", let path = item["path_display"] as? String,
              path.hasPrefix("/Audiobook Studio/"), path.split(separator: "/").count == 2 else {
            throw RemoteError("Можно удалить только папку книги внутри Audiobook Studio")
        }
        let (data, response) = try await request(URL(string: "https://api.dropboxapi.com/2/files/delete_v2")!, method: "POST",
            data: RemoteJSON.data(["path": folderID]), headers: ["Content-Type": "application/json"])
        _ = data
        guard response.statusCode == 200 else { throw RemoteError("Не удалось удалить книгу из Dropbox") }
    }
    func dropboxCreateFolder(_ path: String) async throws {
        let (_, response) = try await request(URL(string: "https://api.dropboxapi.com/2/files/create_folder_v2")!, method: "POST",
            data: RemoteJSON.data(["path": path, "autorename": false]), headers: ["Content-Type": "application/json"])
        if response.statusCode == 200 { return }
        guard response.statusCode == 409 else { throw RemoteError("Не удалось создать папку в Dropbox") }
        let existing = try await api("files/get_metadata", ["path": path])
        guard existing[".tag"] as? String == "folder" else { throw RemoteError("Путь в Dropbox занят файлом") }
    }
    func dropboxSharedURL(_ path: String?) async throws -> String? {
        guard let path else { return nil }
        guard let object = try? await api("sharing/list_shared_links", ["path": path, "direct_only": true]),
              let links = object["links"] as? [[String: Any]], let raw = links.first?["url"] as? String else { return nil }
        return raw.replacingOccurrences(of: "dl=0", with: "dl=1")
    }
    public func deleteGoogleBook(folderID: String) async throws {
        let root = try await googleRoot(create: false)
        guard !root.isEmpty else { throw RemoteError("Папка Audiobook Studio не найдена") }
        var item = URLComponents(string: "https://www.googleapis.com/drive/v3/files/" + folderID)!
        item.queryItems = [URLQueryItem(name: "fields", value: "id,name,mimeType,parents,trashed")]
        let (data, status) = try await request(item.url!, method: "GET")
        guard status.statusCode == 200 else { throw RemoteError("Папка книги не найдена или уже удалена") }
        let folder = try RemoteJSON.object(data)
        let parents = folder["parents"] as? [String] ?? []
        guard parents.contains(root), folder["mimeType"] as? String == "application/vnd.google-apps.folder",
              folder["trashed"] as? Bool != true else { throw RemoteError("Можно удалить только папку книги внутри Audiobook Studio") }
        let (deleted, response) = try await request(URL(string: "https://www.googleapis.com/drive/v3/files/" + folderID)!, method: "DELETE")
        _ = deleted
        guard response.statusCode == 200 || response.statusCode == 204 else { throw RemoteError("Не удалось удалить папку книги из Google Drive") }
    }
    public func googleDownloadURL(fileID: String) -> String { "https://drive.google.com/uc?export=download&id=" + fileID }
    static func driveQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
    static func bookBase(title: String, author: String) -> String {
        func clean(_ value: String) -> String {
            value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\:*?\"<>|".unicodeScalars.contains($0) }
                .map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let t = clean(title), a = clean(author)
        let combined = a.isEmpty ? t : t.isEmpty ? a : a + " - " + t
        return String(combined.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func googleRoot(create: Bool) async throws -> String {
        let name = "Audiobook Studio"
        let id = try await findGoogleFolder(name: name, parent: "root")
        if !id.isEmpty || !create { return id }
        return try await googleFolder(name: name, parent: "root")
    }
    func googleFolder(name: String, parent: String) async throws -> String {
        var query = "name='\(Self.driveQuery(name))' and mimeType='application/vnd.google-apps.folder' and trashed=false"
        query += parent == "root" ? " and 'root' in parents" : " and '\(Self.driveQuery(parent))' in parents"
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [.init(name: "q", value: query), .init(name: "pageSize", value: "2"), .init(name: "fields", value: "files(id)")]
        let (data, response) = try await request(components.url!, method: "GET")
        guard response.statusCode == 200 else { throw RemoteError("Не удалось найти папку Google Drive") }
        if let id = (try RemoteJSON.object(data)["files"] as? [[String: Any]])?.first?["id"] as? String { return id }
        var body: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder"]
        if parent != "root" { body["parents"] = [parent] }
        let (created, status) = try await request(URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!, method: "POST", data: RemoteJSON.data(body), headers: ["Content-Type": "application/json"])
        guard status.statusCode == 200, let id = try RemoteJSON.object(created)["id"] as? String else { throw RemoteError("Не удалось создать папку Google Drive") }
        return id
    }
    func findGoogleFolder(name: String, parent: String) async throws -> String {
        var query = "name='\(Self.driveQuery(name))' and mimeType='application/vnd.google-apps.folder' and trashed=false"
        query += parent == "root" ? " and 'root' in parents" : " and '\(Self.driveQuery(parent))' in parents"
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [.init(name: "q", value: query), .init(name: "pageSize", value: "2"), .init(name: "fields", value: "files(id)")]
        let (data, response) = try await request(components.url!, method: "GET")
        guard response.statusCode == 200 else { throw RemoteError("Не удалось найти папку Google Drive") }
        return (try RemoteJSON.object(data)["files"] as? [[String: Any]])?.first?["id"] as? String ?? ""
    }
    func googleChildren(_ folder: String) async throws -> [[String: Any]] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [.init(name: "q", value: "'\(Self.driveQuery(folder))' in parents and trashed=false"),
                                 .init(name: "pageSize", value: "100"), .init(name: "fields", value: "files(id,name,mimeType)")]
        let (data, response) = try await request(components.url!, method: "GET")
        guard response.statusCode == 200 else { throw RemoteError("Не удалось прочитать файлы книги") }
        return try RemoteJSON.object(data)["files"] as? [[String: Any]] ?? []
    }
    nonisolated public static func hashes(_ file: URL) throws -> (size: Int64, md5: String, dropbox: String) {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var md5 = Insecure.MD5(), blocks = SHA256(), size: Int64 = 0
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            size += Int64(data.count); md5.update(data: data); blocks.update(data: Data(SHA256.hash(data: data)))
        }
        return (size, md5.finalize().map { String(format: "%02x", $0) }.joined(), blocks.finalize().map { String(format: "%02x", $0) }.joined())
    }
    public func upload(file: URL, folder: String, remoteName: String? = nil, saved: RemoteUpload,
                       checkpoint: (RemoteUpload) throws -> Void) async throws -> RemoteUpload {
        let hashing = Task.detached { try Self.hashes(file) }
        let hash = try await withTaskCancellationHandler(operation: { try await hashing.value }, onCancel: { hashing.cancel() })
        guard hash.size > 0 else { throw RemoteError("Пустой файл результата") }
        let fingerprint = String(hash.size) + ":" + (provider == .dropbox ? hash.dropbox : hash.md5)
        var bound = saved
        if !bound.fingerprint.isEmpty && bound.fingerprint != fingerprint { bound = RemoteUpload() }
        bound.fingerprint = fingerprint; try checkpoint(bound)
        if !bound.link.isEmpty { return bound }
        let name = remoteName?.isEmpty == false ? remoteName! : file.lastPathComponent
        if provider == .dropbox { return try await dropbox(file, folder, name, hash, bound, checkpoint) }
        return try await google(file, folder, name, hash, bound, checkpoint)
    }
    func dropbox(_ file: URL, _ folder: String, _ remoteName: String, _ hash: (size: Int64, md5: String, dropbox: String), _ saved: RemoteUpload,
                 _ checkpoint: (RemoteUpload) throws -> Void) async throws -> RemoteUpload {
        var state = saved
        let path = folder + "/" + remoteName
        // Recover a completed commit before starting/restarting a session. Verify content, never accept another file.
        if let metadata = try? await api("files/get_metadata", ["path": path]),
           RemoteJSON.integer(metadata, "size") == hash.size, RemoteJSON.string(metadata, "content_hash") == hash.dropbox {
            state.fileID = RemoteJSON.string(metadata, "id"); state.offset = hash.size
        }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var resets = 0
        while state.fileID.isEmpty {
            try Task.checkCancellation()
            if state.session.isEmpty {
                let (data, status) = try await content("start", ["close": false], Data())
                guard status.statusCode == 200, let session = try RemoteJSON.object(data)["session_id"] as? String else { throw RemoteError("Не удалось начать загрузку Dropbox") }
                state.session = session; state.offset = 0; try checkpoint(state)
            }
            guard state.offset >= 0 && state.offset <= hash.size else { throw RemoteError("Некорректная позиция загрузки Dropbox") }
            try handle.seek(toOffset: UInt64(state.offset))
            let bytes = try handle.read(upToCount: Int(min(8 * 1024 * 1024, hash.size - state.offset))) ?? Data()
            let last = state.offset + Int64(bytes.count) == hash.size
            var args: [String: Any] = ["cursor": ["session_id": state.session, "offset": state.offset]]
            if last { args["commit"] = ["path": path, "mode": "overwrite", "autorename": false, "mute": true] }
            else { args["close"] = false }
            let (data, status) = try await content(last ? "finish" : "append_v2", args, bytes)
            if status.statusCode == 409 {
                let object = try? RemoteJSON.object(data)
                if let offset = Self.correctOffset(object ?? [:]), offset >= 0, offset <= hash.size {
                    state.offset = offset; try checkpoint(state); resets += 1
                } else {
                    // Session may have expired (7 days), or the final response was lost.
                    if let metadata = try? await api("files/get_metadata", ["path": path]),
                       RemoteJSON.integer(metadata, "size") == hash.size, RemoteJSON.string(metadata, "content_hash") == hash.dropbox {
                        state.fileID = RemoteJSON.string(metadata, "id"); state.offset = hash.size
                    } else { state.session = ""; state.offset = 0; resets += 1 }
                    try checkpoint(state)
                }
                guard resets <= 4 else { throw RemoteError("Не удалось восстановить загрузку Dropbox; файлы сохранены") }; continue
            }
            guard status.statusCode == 200 else { throw RemoteError("Загрузка Dropbox: HTTP \(status.statusCode)") }
            state.offset += Int64(bytes.count)
            if last {
                let metadata = try RemoteJSON.object(data)
                guard RemoteJSON.integer(metadata, "size") == hash.size, RemoteJSON.string(metadata, "content_hash") == hash.dropbox else { throw RemoteError("Dropbox: размер или контрольная сумма результата не совпали") }
                state.fileID = RemoteJSON.string(metadata, "id")
            }
            try checkpoint(state)
        }
        let created = try? await api("sharing/create_shared_link_with_settings", ["path": path])
        if let link = created?["url"] as? String { state.link = link }
        else {
            let links = try await api("sharing/list_shared_links", ["path": path, "direct_only": true])
            state.link = (links["links"] as? [[String: Any]])?.first?["url"] as? String ?? ""
        }
        guard !state.link.isEmpty else { throw RemoteError("Файл загружен, но Dropbox не выдал ссылку") }
        try checkpoint(state); return state
    }
    func content(_ action: String, _ args: [String: Any], _ data: Data) async throws -> (Data, HTTPURLResponse) {
        // Dropbox requires non-ASCII characters escaped in this HTTP header.
        let json = String(data: try RemoteJSON.data(args), encoding: .utf8)!
        var escaped = ""
        for scalar in json.unicodeScalars {
            if scalar.value < 128 { escaped.unicodeScalars.append(scalar) }
            else { for unit in String(scalar).utf16 { escaped += String(format: "\\u%04x", unit) } }
        }
        return try await request(URL(string: "https://content.dropboxapi.com/2/files/upload_session/" + action)!, method: "POST", data: data,
                                 headers: ["Content-Type": "application/octet-stream", "Dropbox-API-Arg": escaped])
    }
    static func correctOffset(_ object: [String: Any]) -> Int64? {
        if let n = object["correct_offset"] as? NSNumber { return n.int64Value }
        for value in object.values { if let child = value as? [String: Any], let n = correctOffset(child) { return n } }
        return nil
    }
    func google(_ file: URL, _ folder: String, _ remoteName: String, _ hash: (size: Int64, md5: String, dropbox: String), _ saved: RemoteUpload,
                _ checkpoint: (RemoteUpload) throws -> Void) async throws -> RemoteUpload {
        var state = saved; var restarts = 0
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        func verified(_ data: Data) throws {
            let metadata = try RemoteJSON.object(data)
            guard Int64(metadata["size"] as? String ?? "") == hash.size, RemoteJSON.string(metadata, "md5Checksum") == hash.md5,
                  let id = metadata["id"] as? String else { throw RemoteError("Google Drive: размер или контрольная сумма результата не совпали") }
            state.fileID = id; state.offset = hash.size; state.link = "https://drive.google.com/file/d/" + id + "/view"
            try checkpoint(state)
        }
        while state.link.isEmpty {
            try Task.checkCancellation()
            if state.session.isEmpty {
                // Recover final files by deterministic name and folder, to avoid duplicating a completed upload.
                var query = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
                let name = Self.driveQuery(remoteName)
                query.queryItems = [.init(name: "q", value: "'\(folder)' in parents and name='\(name)' and trashed=false"), .init(name: "fields", value: "files(id,size,md5Checksum)")]
                let (found, response) = try await request(query.url!, method: "GET")
                guard response.statusCode == 200 else { throw RemoteError("Не удалось проверить файлы Google Drive") }
                let files = try RemoteJSON.object(found)["files"] as? [[String: Any]] ?? []
                if let match = files.first(where: { Int64($0["size"] as? String ?? "") == hash.size && $0["md5Checksum"] as? String == hash.md5 }) {
                    try verified(RemoteJSON.data(match)); break
                }
                for old in files {
                    guard let oldID = old["id"] as? String else { continue }
                    let (_, removed) = try await request(URL(string: "https://www.googleapis.com/drive/v3/files/" + oldID)!, method: "DELETE")
                    guard removed.statusCode == 200 || removed.statusCode == 204 else { throw RemoteError("Не удалось заменить прежний файл книги в Google Drive") }
                }
                let mime = remoteName.lowercased().hasSuffix(".epub") ? "application/epub+zip" : "audio/mp4"
                let (data, status) = try await request(URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,size,md5Checksum")!, method: "POST", data: RemoteJSON.data(["name": remoteName, "parents": [folder], "mimeType": mime]), headers: ["Content-Type": "application/json", "X-Upload-Content-Length": String(hash.size), "X-Upload-Content-Type": mime])
                _ = data
                guard status.statusCode == 200, let location = status.value(forHTTPHeaderField: "Location"), Self.safeGoogleSession(location) else { throw RemoteError("Не удалось начать загрузку Google Drive") }
                state.session = location; state.offset = 0; try checkpoint(state)
            }
            guard Self.safeGoogleSession(state.session) else { throw RemoteError("Некорректная сессия Google Drive") }
            let url = URL(string: state.session)!
            // Ask for the actual committed offset on every attempt, including a lost response/restart.
            let (data, status) = try await request(url, method: "PUT", data: Data(), headers: ["Content-Range": "bytes */\(hash.size)"])
            if status.statusCode == 200 || status.statusCode == 201 { try verified(data); break }
            if status.statusCode == 404 || status.statusCode == 410 {
                state.session = ""; state.offset = 0; try checkpoint(state); restarts += 1
                guard restarts <= 2 else { throw RemoteError("Сессия Google Drive истекла; повторите загрузку") }; continue
            }
            guard status.statusCode == 308 else { throw RemoteError("Проверка загрузки Google Drive: HTTP \(status.statusCode)") }
            state.offset = try Self.googleOffset(status.value(forHTTPHeaderField: "Range"), size: hash.size); try checkpoint(state)
            guard state.offset < hash.size else { throw RemoteError("Google Drive не подтвердил готовность файла") }
            try handle.seek(toOffset: UInt64(state.offset))
            let chunk = try handle.read(upToCount: Int(min(8 * 1024 * 1024, hash.size - state.offset))) ?? Data()
            guard !chunk.isEmpty else { throw RemoteError("Не удалось прочитать файл результата") }
            let (result, uploaded) = try await request(url, method: "PUT", data: chunk,
                headers: ["Content-Type": "application/octet-stream", "Content-Range": "bytes \(state.offset)-\(state.offset + Int64(chunk.count) - 1)/\(hash.size)"])
            if uploaded.statusCode == 200 || uploaded.statusCode == 201 { try verified(result); break }
            guard uploaded.statusCode == 308 else { throw RemoteError("Загрузка Google Drive: HTTP \(uploaded.statusCode). Прогресс сохранён.") }
            state.offset = try Self.googleOffset(uploaded.value(forHTTPHeaderField: "Range"), size: hash.size); try checkpoint(state)
        }
        return state
    }
    nonisolated public static func safeGoogleSession(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return url.scheme == "https" && url.host == "www.googleapis.com" && url.path.hasPrefix("/upload/drive/")
    }
    nonisolated public static func googleOffset(_ range: String?, size: Int64) throws -> Int64 {
        guard let range else { return 0 }
        guard range.hasPrefix("bytes=0-"), let end = Int64(range.dropFirst(8)), end >= 0, end < size else { throw RemoteError("Некорректная позиция загрузки Google Drive") }
        return end + 1
    }
}
