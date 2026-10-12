import Foundation
import CryptoKit
import Network
import AppKit

public enum RemoteRegistration {
    // Installed-app client identity belongs to the developer, never to the end user.
    // Google Desktop client_secret is not a confidential server credential; PKCE protects the code exchange.
    static var values: [String: String] {
        guard let url = Bundle.main.url(forResource: "RemoteClients", withExtension: "json"),
              let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }
}
public struct RemoteConfig: Codable {
    public var enabled = false, provider = RemoteProvider.dropbox
    public var dropboxID = "", googleID = "", connections: [String: String] = [:]
    public init() { dropboxID = RemoteRegistration.values["dropboxID"] ?? ""; googleID = RemoteRegistration.values["googleID"] ?? "" }
    public func clientID(_ p: RemoteProvider) -> String { p == .dropbox ? dropboxID : googleID }
}
@MainActor public final class RemoteOAuth {
    let secrets: RemoteSecrets, http: RemoteHTTP
    public init(secrets: RemoteSecrets, http: RemoteHTTP = RemoteHTTP()) { self.secrets = secrets; self.http = http }
    public func token(_ provider: RemoteProvider, config: RemoteConfig) async throws -> String {
        let refresh = try secrets.read(provider.rawValue + "Refresh")
        guard !refresh.isEmpty else { throw RemoteError("Подключите " + provider.title + " в настройках приложения") }
        var fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": config.clientID(provider)]
        if provider == .googleDrive { fields["client_secret"] = try googleSecret() }
        return try await exchange(provider, fields)["access_token"] as? String ?? ""
    }
    func googleSecret() throws -> String {
        let saved = try secrets.read("googleSecret")
        return saved.isEmpty ? RemoteRegistration.values["googleSecret"] ?? "" : saved
    }
    func exchange(_ p: RemoteProvider, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: p == .dropbox ? "https://api.dropboxapi.com/oauth2/token" : "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.httpBody = RemoteJSON.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else { throw RemoteError("Не удалось авторизоваться в " + p.title + ". Подключите аккаунт заново.") }
        let result = try RemoteJSON.object(data)
        guard !(result["access_token"] as? String ?? "").isEmpty else { throw RemoteError("Сервис не выдал токен доступа") }
        return result
    }
    public func connect(_ p: RemoteProvider, config: RemoteConfig) async throws {
        guard !config.clientID(p).isEmpty else { throw RemoteError("Подключение ещё не настроено в этой сборке: " + p.title) }
        let verifier = try RemoteJSON.random(), state = try RemoteJSON.random()
        let redirect = "http://127.0.0.1:53682/oauth"
        var components = URLComponents(string: p == .dropbox ? "https://www.dropbox.com/oauth2/authorize" : "https://accounts.google.com/o/oauth2/v2/auth")!
        var fields = ["client_id": config.clientID(p), "response_type": "code", "redirect_uri": redirect, "state": state,
                      "code_challenge": RemoteJSON.base64(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256"]
        if p == .dropbox { fields["token_access_type"] = "offline" }
        else { fields["scope"] = "https://www.googleapis.com/auth/drive.file"; fields["access_type"] = "offline"; fields["prompt"] = "consent" }
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let receiver = OAuthLoopback()
        let code = try await receiver.receive(authorization: components.url!, state: state)
        var tokenFields = ["grant_type": "authorization_code", "code": code, "client_id": config.clientID(p), "redirect_uri": redirect, "code_verifier": verifier]
        if p == .googleDrive { tokenFields["client_secret"] = try googleSecret() }
        let result = try await exchange(p, tokenFields)
        guard let refresh = result["refresh_token"] as? String, !refresh.isEmpty else { throw RemoteError("Сервис не выдал постоянное подключение. Повторите вход с разрешением доступа.") }
        try secrets.write(p.rawValue + "Refresh", refresh)
    }
}
// Listener is confined to loopback. Invalid requests never consume the authorization attempt.
@MainActor final class OAuthLoopback {
    var listener: NWListener?, continuation: CheckedContinuation<String, Error>?, timeout: Task<Void, Never>?
    func finish(_ result: Result<String, Error>) {
        guard let c = continuation else { return }
        continuation = nil; timeout?.cancel(); listener?.cancel(); c.resume(with: result)
    }
    func receive(authorization: URL, state: String) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { c in
                continuation = c
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 53682)
                    let server = try NWListener(using: parameters); listener = server
                    server.stateUpdateHandler = { [weak self] status in Task { @MainActor in
                        switch status {
                        case .ready: NSWorkspace.shared.open(authorization)
                        case .failed: self?.finish(.failure(RemoteError("Не удалось открыть локальный порт 53682 для входа")))
                        default: break
                        }
                    } }
                    server.newConnectionHandler = { [weak self] connection in
                        connection.start(queue: .main)
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                            Task { @MainActor in
                                guard let self else { connection.cancel(); return }
                                let line = String(data: data ?? Data(), encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
                                let parts = line.split(separator: " ")
                                let url = parts.count == 3 && parts[0] == "GET" ? URLComponents(string: "http://127.0.0.1" + parts[1]) : nil
                                let items = url?.queryItems ?? []
                                let valid = url?.path == "/oauth" && items.first(where: { $0.name == "state" })?.value == state
                                let code = items.first(where: { $0.name == "code" })?.value ?? ""
                                let text = valid ? "Подключение получено. Вернитесь в Audiobook Studio." : "Неверный запрос авторизации."
                                let body = Data(text.utf8)
                                var response = Data("HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8); response.append(body)
                                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                                if valid { self.finish(code.isEmpty ? .failure(RemoteError("Авторизация отменена")) : .success(code)) }
                            }
                        }
                    }
                    server.start(queue: .main)
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 300_000_000_000); self?.finish(.failure(RemoteError("Время подключения истекло"))) } catch {}
                    }
                } catch { finish(.failure(RemoteError("Не удалось начать авторизацию"))) }
            }
        }, onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } })
    }
}
