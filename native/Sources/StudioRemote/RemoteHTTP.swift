import Foundation
import CryptoKit
import Security

public enum RemoteJSON {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteError("Некорректный ответ сервиса") }
        return object
    }
    public static func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    public static func string(_ object: [String: Any], _ key: String) -> String { object[key] as? String ?? "" }
    public static func integer(_ object: [String: Any], _ key: String) -> Int64 { (object[key] as? NSNumber)?.int64Value ?? 0 }
    public static func form(_ fields: [String: String]) -> Data {
        var components = URLComponents(); components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RemoteError("Не удалось создать код подключения") }
        return base64(Data(bytes))
    }
    public static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
public protocol RemoteSecrets: AnyObject {
    func read(_ account: String) throws -> String
    func write(_ account: String, _ value: String) throws
}
public final class RemoteKeychain: RemoteSecrets {
    public init() {}
    private func identity(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.davnozdu.audiobook-studio.remote",
         kSecAttrAccount as String: account]
    }
    public func read(_ account: String) throws -> String {
        var query = identity(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return "" }
        guard code == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw RemoteError("Не удалось прочитать данные подключения из Связки ключей") }
        return text
    }
    public func write(_ account: String, _ value: String) throws {
        let query = identity(account)
        if value.isEmpty {
            let code = SecItemDelete(query as CFDictionary)
            guard code == errSecSuccess || code == errSecItemNotFound else { throw RemoteError("Не удалось удалить данные подключения") }; return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var code = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound { var item = query; attributes.forEach { item[$0] = $1 }; code = SecItemAdd(item as CFDictionary, nil) }
        guard code == errSecSuccess else { throw RemoteError("Не удалось сохранить подключение в Связке ключей") }
    }
}
public final class RemoteHTTP {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var last: Error = RemoteError("Сервис временно недоступен")
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw RemoteError("Некорректный HTTP-ответ") }
                if http.statusCode != 429 && http.statusCode < 500 { return (data, http) }
                last = RemoteError("Сервис временно недоступен (HTTP \(http.statusCode))")
                if attempt < 3 {
                    let delay = min(30, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); continue
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                // Never surface request URLs: Telegram URLs contain the bot token.
                last = RemoteError("Сетевая ошибка. Задание и готовые файлы сохранены.")
                if attempt < 3 { try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000) }
            }
        }
        throw last
    }
    public func json(_ url: URL, _ body: [String: Any], bearer: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 60
        request.httpBody = try RemoteJSON.data(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw RemoteError("Сервис вернул HTTP \(response.statusCode)") }
        return try RemoteJSON.object(data)
    }
}
public final class TelegramClient {
    let token: String, http: RemoteHTTP
    public init(token: String, http: RemoteHTTP = RemoteHTTP()) { self.token = token; self.http = http }
    public func call(_ method: String, _ body: [String: Any] = [:]) async throws -> Any {
        guard token.range(of: #"^[0-9]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw RemoteError("Некорректный токен Telegram-бота") }
        let object = try await http.json(URL(string: "https://api.telegram.org/bot" + token + "/" + method)!, body)
        guard object["ok"] as? Bool == true else { throw RemoteError("Telegram отклонил запрос. Проверьте подключение бота.") }
        return object["result"] ?? [:]
    }
    public func send(_ reply: RemoteReply) async throws {
        var body: [String: Any] = ["chat_id": reply.chatID, "text": String(reply.text.prefix(3900)), "link_preview_options": ["is_disabled": true]]
        if !reply.buttons.isEmpty {
            body["reply_markup"] = ["inline_keyboard": reply.buttons.map { $0.map { ["text": $0.text, "callback_data": $0.data] } }]
        }
        _ = try await call("sendMessage", body)
    }
    public func download(_ fileID: String, to destination: URL) async throws {
        let file = try await call("getFile", ["file_id": fileID]) as? [String: Any] ?? [:]
        let path = RemoteJSON.string(file, "file_path")
        guard !path.isEmpty, !path.contains(".."), RemoteJSON.integer(file, "file_size") <= 20 * 1024 * 1024 else { throw RemoteError("Telegram Bot API принимает EPUB до 20 МБ") }
        guard let url = URL(string: "https://api.telegram.org/file/bot" + token + "/" + path) else { throw RemoteError("Не удалось получить книгу") }
        let temporary: URL, response: URLResponse
        do { (temporary, response) = try await http.session.download(from: url) }
        catch { if Task.isCancelled { throw CancellationError() }; throw RemoteError("Не удалось скачать книгу из Telegram") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard (response as? HTTPURLResponse)?.statusCode == 200, size > 0, size <= 20 * 1024 * 1024 else { throw RemoteError("Не удалось скачать EPUB до 20 МБ") }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
