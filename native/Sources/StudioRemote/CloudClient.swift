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
    public func folder(jobID: String) async throws -> String {
        if provider == .dropbox {
            let path = "/Audiobook-" + jobID
            let (_, status) = try await request(URL(string: "https://api.dropboxapi.com/2/files/create_folder_v2")!, method: "POST", data: RemoteJSON.data(["path": path, "autorename": false]), headers: ["Content-Type": "application/json"])
            guard status.statusCode == 200 || status.statusCode == 409 else { throw RemoteError("Не удалось создать папку Dropbox") }
            return path
        }
        // A deterministic job name allows recovery if a response was lost after folder creation.
        let name = "Audiobook Studio " + jobID
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [URLQueryItem(name: "q", value: "name='\(name)' and mimeType='application/vnd.google-apps.folder' and trashed=false"), URLQueryItem(name: "fields", value: "files(id)")]
        let (data, response) = try await request(c.url!, method: "GET")
        guard response.statusCode == 200 else { throw RemoteError("Не удалось найти папку Google Drive") }
        if let files = try RemoteJSON.object(data)["files"] as? [[String: Any]], let id = files.first?["id"] as? String { return id }
        let (created, status) = try await request(URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!, method: "POST", data: RemoteJSON.data(["name": name, "mimeType": "application/vnd.google-apps.folder"]), headers: ["Content-Type": "application/json"])
        guard status.statusCode == 200, let id = try RemoteJSON.object(created)["id"] as? String else { throw RemoteError("Не удалось создать папку Google Drive") }
        return id
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
    public func upload(file: URL, folder: String, saved: RemoteUpload,
                       checkpoint: (RemoteUpload) throws -> Void) async throws -> RemoteUpload {
        let hashing = Task.detached { try Self.hashes(file) }
        let hash = try await withTaskCancellationHandler(operation: { try await hashing.value }, onCancel: { hashing.cancel() })
        guard hash.size > 0 else { throw RemoteError("Пустой файл результата") }
        if !saved.link.isEmpty { return saved }
        if provider == .dropbox { return try await dropbox(file, folder, hash, saved, checkpoint) }
        return try await google(file, folder, hash, saved, checkpoint)
    }
    func dropbox(_ file: URL, _ folder: String, _ hash: (size: Int64, md5: String, dropbox: String), _ saved: RemoteUpload,
                 _ checkpoint: (RemoteUpload) throws -> Void) async throws -> RemoteUpload {
        var state = saved
        let path = folder + "/" + file.lastPathComponent
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
    func google(_ file: URL, _ folder: String, _ hash: (size: Int64, md5: String, dropbox: String), _ saved: RemoteUpload,
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
                let name = file.lastPathComponent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                query.queryItems = [.init(name: "q", value: "'\(folder)' in parents and name='\(name)' and trashed=false"), .init(name: "fields", value: "files(id,size,md5Checksum)")]
                let (found, response) = try await request(query.url!, method: "GET")
                guard response.statusCode == 200 else { throw RemoteError("Не удалось проверить файлы Google Drive") }
                let files = try RemoteJSON.object(found)["files"] as? [[String: Any]] ?? []
                if let match = files.first(where: { Int64($0["size"] as? String ?? "") == hash.size && $0["md5Checksum"] as? String == hash.md5 }) {
                    try verified(RemoteJSON.data(match)); break
                }
                let mime = file.pathExtension.lowercased() == "epub" ? "application/epub+zip" : "audio/mp4"
                let (data, status) = try await request(URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,size,md5Checksum")!, method: "POST", data: RemoteJSON.data(["name": file.lastPathComponent, "parents": [folder], "mimeType": mime]), headers: ["Content-Type": "application/json", "X-Upload-Content-Length": String(hash.size), "X-Upload-Content-Type": mime])
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
