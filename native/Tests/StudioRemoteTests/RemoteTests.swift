import Foundation
import Darwin
import XCTest
import CryptoKit
@testable import StudioRemote

final class MemorySecrets: RemoteSecrets {
    var values: [String: String] = [:]
    func read(_ account: String) throws -> String { values[account] ?? "" }
    func write(_ account: String, _ value: String) throws { values[account] = value }
}
final class MockHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, headers, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class RemoteTests: XCTestCase {
    @MainActor func testSemanticQueueCorruptionNeverDeletesOrOverwrites() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let victim = f.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data([1]).write(to: victim.appendingPathComponent("sentinel"))
        var state = RemoteState(), job = RemoteJob(chatID: 1, messageID: 1, fileID: "x", name: "x", provider: .dropbox)
        job.id = "../victim"; job.phase = .complete; state.jobs = [job]
        let store = RemoteStateStore(f); try store.save(state)
        let bytes = try Data(contentsOf: f.appendingPathComponent("queue.json"))
        let bot = BotService(folder: f, secrets: MemorySecrets())
        XCTAssertTrue(bot.fatal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(try Data(contentsOf: f.appendingPathComponent("queue.json")), bytes)
        job.id = UUID().uuidString.lowercased(); state.jobs = [job, job]; try store.save(state)
        XCTAssertThrowsError(try store.load())
        state.jobs = [job]; try store.save(state)
        try FileManager.default.createDirectory(at: f.appendingPathComponent("jobs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.jobFolder(job.id), withDestinationURL: victim)
        XCTAssertThrowsError(try store.validateJobFolders(try store.load()))
    }
    @MainActor func testExtremeStatusAndHTMLMessagesStayBounded() throws {
        var job = RemoteJob(chatID: 1, messageID: 1, fileID: "x", name: "x", provider: .dropbox)
        job.completed = Int.max; job.total = 1
        XCTAssertTrue(job.status().contains("100%"))
        let text = "<b>" + String(repeating: "😀&amp;", count: 1500) + "</b> <a href=\"https://example.invalid/a?x=1&amp;y=2\">EPUB</a>"
        let parts = TelegramClient.messageParts(RemoteReply(1, text, parseMode: "HTML"))
        XCTAssertTrue(parts.count > 1)
        XCTAssertTrue(parts.allSatisfy { $0.mode == nil && $0.text.utf16.count <= 3900 })
        let joined = parts.map(\.text).joined()
        XCTAssertTrue(joined.contains("https://example.invalid/a?x=1&y=2"))
        XCTAssertEqual(joined.components(separatedBy: "😀").count - 1, 1500)
        let short = TelegramClient.messageParts(RemoteReply(1, "<b>Готово</b>", parseMode: "HTML"))
        XCTAssertEqual(short[0].text, "<b>Готово</b>"); XCTAssertEqual(short[0].mode, "HTML")
        XCTAssertTrue(CloudClient.bookBase(title: String(repeating: "😀", count: 180), author: "").utf8.count <= 180)
    }
    @MainActor func testHTTPNeverAutomaticallyRepeatsCreationPOST() async throws {
        defer { MockHTTP.handler = nil }
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        var calls = 0
        MockHTTP.handler = { _ in calls += 1; return (503, [:], Data()) }
        var request = URLRequest(url: URL(string: "https://example.invalid/create")!); request.httpMethod = "POST"
        do { _ = try await RemoteHTTP(session: session).send(request); XCTFail("Failed creation must throw") } catch {}
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testDropboxMismatchForcesVerifiedReupload() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f); MockHTTP.handler = nil }
        let file = f.appendingPathComponent("book.m4b"); try Data("content".utf8).write(to: file); let hash = try CloudClient.hashes(file)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        let cloud = CloudClient(provider: .dropbox, config: RemoteConfig(), secrets: MemorySecrets(), http: RemoteHTTP(session: session)); cloud.access = "fixture"; cloud.expires = .distantFuture
        var starts = 0, finishes = 0
        MockHTTP.handler = { request in
            let route = request.url!.lastPathComponent
            if route == "get_metadata" { return (200, [:], try RemoteJSON.data(["id": "foreign", "size": hash.size + 1, "content_hash": "wrong"])) }
            if route == "start" { starts += 1; return (200, [:], try RemoteJSON.data(["session_id": "new-session"])) }
            if route == "finish" { finishes += 1; return (200, [:], try RemoteJSON.data(["id": "new-id", "size": hash.size, "content_hash": hash.dropbox])) }
            return (200, [:], try RemoteJSON.data(["url": "https://example.invalid/new"]))
        }
        var saved = RemoteUpload(); saved.fileID = "old-id"; saved.fingerprint = "\(hash.size):\(hash.dropbox)"
        let result = try await cloud.upload(file: file, folder: "/Test", saved: saved) { _ in }
        XCTAssertEqual(starts, 1); XCTAssertEqual(finishes, 1); XCTAssertEqual(result.fileID, "new-id")
        XCTAssertEqual(result.link, "https://example.invalid/new")
    }
    @MainActor func testUnboundAndDeletedGoogleLinksAreNotTrusted() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f); MockHTTP.handler = nil }
        let file = f.appendingPathComponent("book.m4b"); try Data("content".utf8).write(to: file); let hash = try CloudClient.hashes(file)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        let cloud = CloudClient(provider: .googleDrive, config: RemoteConfig(), secrets: MemorySecrets(), http: RemoteHTTP(session: session)); cloud.access = "fixture"; cloud.expires = .distantFuture
        var confirmations = 0, creations = 0
        MockHTTP.handler = { request in
            if request.httpMethod == "GET" {
                if request.url!.path.hasSuffix("old-id") { confirmations += 1; return (404, [:], Data()) }
                return (200, [:], try RemoteJSON.data(["files": []]))
            }
            if request.httpMethod == "POST" { creations += 1; return (200, ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=test"], Data()) }
            if request.value(forHTTPHeaderField: "Content-Range")?.contains("*") == true { return (308, [:], Data()) }
            return (200, [:], try RemoteJSON.data(["id": "new-id", "size": String(hash.size), "md5Checksum": hash.md5]))
        }
        for fingerprint in ["", "\(hash.size):\(hash.md5)"] {
            var saved = RemoteUpload(); saved.link = "https://example.invalid/old"; saved.fileID = "old-id"; saved.fingerprint = fingerprint
            let result = try await cloud.upload(file: file, folder: "folder", saved: saved) { _ in }
            XCTAssertEqual(result.fileID, "new-id"); XCTAssertFalse(result.link.contains("/old"))
        }
        XCTAssertEqual(creations, 2); XCTAssertEqual(confirmations, 1)
    }
    @MainActor func testGoogleNoProgressFailsWithBoundedRequests() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f); MockHTTP.handler = nil }
        let file = f.appendingPathComponent("book.m4b"); try Data("content".utf8).write(to: file); let hash = try CloudClient.hashes(file)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        let cloud = CloudClient(provider: .googleDrive, config: RemoteConfig(), secrets: MemorySecrets(), http: RemoteHTTP(session: session)); cloud.access = "fixture"; cloud.expires = .distantFuture
        var requests = 0
        MockHTTP.handler = { _ in requests += 1; return (308, ["Range": "bytes=0-0"], Data()) }
        var saved = RemoteUpload(); saved.session = "https://www.googleapis.com/upload/drive/v3/files?upload_id=test"; saved.fingerprint = "\(hash.size):\(hash.md5)"
        do { _ = try await cloud.upload(file: file, folder: "folder", saved: saved) { _ in }; XCTFail("Stalled upload must fail") }
        catch let error as RemoteError { XCTAssertTrue(error.message.contains("не продвигает")) }
        XCTAssertTrue(requests <= 10); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    @MainActor func testCancellationKeepsEveryRegisteredChild() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let helper = Process(); helper.executableURL = URL(fileURLWithPath: "/bin/sh"); helper.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
        helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice; try helper.run()
        defer { if helper.isRunning { kill(-helper.processIdentifier, SIGKILL); kill(helper.processIdentifier, SIGKILL) }; helper.waitUntilExit() }
        let script = f.appendingPathComponent("engine")
        let contents = "#!/bin/sh\ncat >/dev/null\nprintf '{\"type\":\"child\",\"pid\":\(helper.processIdentifier)}\\n'\nprintf '{\"type\":\"child\",\"pid\":999999}\\n'\nprintf '{\"type\":\"child\",\"pid\":999999,\"ended\":true}\\n'\nexec /bin/sleep 30\n"
        try Data(contents.utf8).write(to: script); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let engine = RemoteEngine()
        let task = Task { try await engine.run(executable: script, request: [:], temporary: f.appendingPathComponent("tmp")) { _ in } }
        for _ in 0..<100 { if engine.children == [helper.processIdentifier] { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(engine.children, [helper.processIdentifier]); task.cancel()
        do { try await task.value; XCTFail("Cancelled task returned success") } catch is CancellationError {} catch { XCTFail("Wrong cancellation error") }
        XCTAssertFalse(helper.isRunning); XCTAssertFalse(engine.running)
    }
    func testLegacyCloudConfigPreservesCredentialKeys() throws {
        let data = Data(#"{"enabled":true,"provider":"googleDrive","dropboxID":"old-dropbox","googleID":"old-google","connections":{"googleDrive":"existing"}}"#.utf8)
        let config = try JSONDecoder().decode(RemoteConfig.self, from: data)
        XCTAssertNil(config.customGoogleID)
        XCTAssertEqual(config.clientID(.googleDrive), "old-google")
        XCTAssertEqual(config.credentialKey(.googleDrive, suffix: "Refresh"), "googleDriveRefresh")
        XCTAssertEqual(config.connections["googleDrive"], "existing")
    }
    @MainActor func testCustomCloudSwitchPreservesAndRestoresExistingTokens() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let secrets = MemorySecrets()
        secrets.values["googleDriveRefresh"] = "original-refresh"
        let bot = BotService(folder: f, secrets: secrets)
        bot.config.googleID = "original.apps.googleusercontent.com"
        bot.config.connections["googleDrive"] = "original-connection"
        bot.configureCloud(.googleDrive, customID: "personal.apps.googleusercontent.com", googleSecret: "personal-secret")
        let key = bot.config.credentialKey(.googleDrive, suffix: "Refresh")
        XCTAssertNil(bot.config.connections["googleDrive"])
        XCTAssertEqual(secrets.values["googleDriveRefresh"], "original-refresh")
        XCTAssertEqual(try RemoteOAuth(secrets: secrets).googleSecret(bot.config), "personal-secret")
        secrets.values[key] = "personal-refresh"
        bot.configureCloud(.googleDrive, customID: nil)
        XCTAssertEqual(bot.config.clientID(.googleDrive), "original.apps.googleusercontent.com")
        XCTAssertNotNil(bot.config.connections["googleDrive"])
        XCTAssertEqual(secrets.values[key], "personal-refresh")
        bot.configureCloud(.googleDrive, customID: "personal.apps.googleusercontent.com")
        XCTAssertNotNil(bot.config.connections["googleDrive"])
        XCTAssertEqual(try RemoteOAuth(secrets: secrets).googleSecret(bot.config), "personal-secret")
        let loaded = BotService(folder: f, secrets: secrets)
        XCTAssertEqual(loaded.config.customGoogleID, bot.config.customGoogleID)
        XCTAssertEqual(loaded.config.credentialKey(.googleDrive, suffix: "Refresh"), key)
    }
    @MainActor func testQueuedBookBlocksProjectChange() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let bot = BotService(folder: f, secrets: MemorySecrets())
        _ = bot.state.receive(chatID: 1, messageID: 1, fileID: "book", name: "book.epub", provider: .dropbox)
        bot.configureCloud(.dropbox, customID: "personal-app")
        XCTAssertNil(bot.config.customDropboxID)
        XCTAssertTrue(bot.message.contains("очереди"))
    }
    func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    func testDeduplicateBookAndConfirmation() throws {
        var s = RemoteState()
        let a = s.receive(chatID: 1, messageID: 2, fileID: "x", name: "a.epub", provider: .dropbox)
        let b = s.receive(chatID: 1, messageID: 2, fileID: "x", name: "a.epub", provider: .dropbox)
        XCTAssertEqual(a.id, b.id); XCTAssertNil(s.next)
        XCTAssertTrue(s.confirm(a.id, account: "account")); XCTAssertFalse(s.confirm(a.id, account: "account")); XCTAssertEqual(s.jobs.count, 1)
    }
    func testFIFOAndCloudAccountReset() throws {
        var s = RemoteState()
        let a = s.receive(chatID: 1, messageID: 2, fileID: "a", name: "a.epub", provider: .dropbox)
        let b = s.receive(chatID: 1, messageID: 3, fileID: "b", name: "b.epub", provider: .googleDrive)
        s.confirm(b.id, account: "b", now: Date(timeIntervalSince1970: 1)); s.confirm(a.id, account: "a", now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(s.next?.id, b.id)
        s.jobs[0].phase = .failed; s.jobs[0].cloudFolder = "old"; s.jobs[0].uploads["x"] = RemoteUpload()
        s.confirm(a.id, account: "new"); XCTAssertTrue(s.jobs[0].uploads.isEmpty); XCTAssertEqual(s.jobs[0].cloudFolder, "")
    }
    func testRecoverNeverStartsInterruptedBook() throws {
        var s = RemoteState(); let j = s.receive(chatID: 1, messageID: 1, fileID: "a", name: "a.epub", provider: .dropbox)
        s.confirm(j.id, account: "a"); s.jobs[0].phase = .synthesis; s.recover(); s.recover()
        XCTAssertEqual(s.jobs[0].phase, .paused); XCTAssertNil(s.next); XCTAssertEqual(s.outbox.count, 1)
    }
    func testQueueRoundtripAndCorruptionProtection() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let store = RemoteStateStore(f); var s = RemoteState(); s.ownerID = 12; s.offset = 94
        _ = s.receive(chatID: 12, messageID: 3, fileID: "a", name: "a.epub", provider: .googleDrive)
        s.outbox = [RemoteReply(12, "pending")]; try store.save(s)
        let loaded = try store.load(); XCTAssertEqual(loaded.offset, 94); XCTAssertEqual(loaded.jobs[0].id, s.jobs[0].id); XCTAssertEqual(loaded.outbox.count, 1)
        let file = f.appendingPathComponent("queue.json"); try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }
    func testStatusTimeAndHonestETA() throws {
        var j = RemoteJob(chatID: 1, messageID: 1, fileID: "a", name: "a", provider: .dropbox)
        j.phase = .synthesis; j.started = Date(timeIntervalSince1970: 0); j.measuredAt = Date(timeIntervalSince1970: 10); j.eta = 120
        let text = j.status(now: Date(timeIntervalSince1970: 40))
        XCTAssertTrue(text.contains("40 с")); XCTAssertTrue(text.contains("1 мин 30 с")); XCTAssertTrue(text.contains("дополнительное время"))
        j.phase = .uploading; XCTAssertFalse(j.status().contains("Осталось озвучивания"))
    }
    func testCommandAliasesAndCallbackLength() throws {
        XCTAssertEqual(RemoteState.command("/status@my_bot"), "status"); XCTAssertEqual(RemoteState.command("сколько осталось"), "status")
        XCTAssertEqual(RemoteState.command("/cancel"), "cancel"); XCTAssertEqual(RemoteState.command("очередь"), "queue")
        XCTAssertTrue(("status:" + UUID().uuidString).utf8.count < 64)
    }
    func testSessionURLAndRangeValidation() throws {
        XCTAssertTrue(CloudClient.safeGoogleSession("https://www.googleapis.com/upload/drive/v3/files?upload_id=a"))
        XCTAssertFalse(CloudClient.safeGoogleSession("https://evil.test/upload/drive/a")); XCTAssertFalse(CloudClient.safeGoogleSession("http://www.googleapis.com/upload/drive/a"))
        XCTAssertEqual(try CloudClient.googleOffset("bytes=0-262143", size: 400000), 262144)
        XCTAssertEqual(try CloudClient.googleOffset(nil, size: 5), 0)
        XCTAssertThrowsError(try CloudClient.googleOffset("bytes=1-3", size: 4)); XCTAssertThrowsError(try CloudClient.googleOffset("bytes=0-4", size: 4))
    }
    func testStreamingContentHashes() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let file = f.appendingPathComponent("fixture"); let data = Data(repeating: 37, count: 4 * 1024 * 1024 + 13); try data.write(to: file)
        let h = try CloudClient.hashes(file)
        var combined = Data(SHA256.hash(data: data.prefix(4 * 1024 * 1024))); combined.append(Data(SHA256.hash(data: data.suffix(13))))
        XCTAssertEqual(h.size, Int64(data.count)); XCTAssertEqual(h.dropbox, SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(h.md5, Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    @MainActor func testPrivateOwnerAndCancellationIsolation() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let bot = BotService(folder: f, secrets: MemorySecrets()); bot.state.ownerID = 12; bot.config.connections["dropbox"] = "account"
        func message(_ user: Int64, _ mid: Int64) -> [String: Any] { ["message": ["chat": ["id": user, "type": "private"], "from": ["id": user], "message_id": mid, "document": ["file_name": "book.epub", "file_size": 10, "file_id": "file"]]] }
        try await bot.handle(message(99, 1)); XCTAssertTrue(bot.state.jobs.isEmpty)
        try await bot.handle(message(12, 1)); try await bot.handle(message(12, 2)); XCTAssertEqual(bot.state.jobs.count, 2); XCTAssertNil(bot.state.next)
        let id = bot.state.jobs[0].id
        func callback(_ action: String) -> [String: Any] { ["callback_query": ["from": ["id": 12], "data": action + ":" + id, "message": ["chat": ["id": 12, "type": "private"]]]] }
        try await bot.handle(callback("run")); XCTAssertEqual(bot.state.jobs[0].phase, .queued)
        try await bot.handle(callback("cancel")); XCTAssertEqual(bot.state.jobs[0].phase, .queued)
        try await bot.handle(callback("stop")); XCTAssertEqual(bot.state.jobs[0].phase, .cancelled); XCTAssertEqual(bot.state.jobs[1].phase, .confirmation)
    }
    @MainActor func testCatalogKeepsNewestButtonsAndAnswersStaleOnes() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let bot = BotService(folder: f, secrets: MemorySecrets()); bot.state.ownerID = 12
        var tokens: [String] = []
        for i in 0..<501 { tokens.append(bot.catalogToken(RemoteCatalogTarget(.dropbox, "id\(i)", created: Date(timeIntervalSince1970: Double(i))))) }
        XCTAssertEqual(bot.state.catalogActions?.count, 400)
        XCTAssertNotNil(bot.state.catalogActions?[tokens.last!]); XCTAssertNil(bot.state.catalogActions?[tokens[0]])
        try await bot.handle(["callback_query": ["from": ["id": 12], "data": "catalog-delete:" + tokens[0],
            "message": ["chat": ["id": 12, "type": "private"]]]])
        XCTAssertTrue(bot.state.outbox.last?.text.contains("устарела") == true)
        XCTAssertTrue(RemoteError("x", status: 403).rejected); XCTAssertFalse(RemoteError("x", status: 429).rejected)
        XCTAssertFalse(RemoteError("x", status: 502).rejected); XCTAssertFalse(RemoteError("x").rejected)
    }
    @MainActor func testFinishedJobsKeepNoLocalCopy() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let store = RemoteStateStore(f)
        var state = RemoteState()
        let done = state.receive(chatID: 1, messageID: 1, fileID: "a", name: "a.fb2", provider: .dropbox)
        let open = state.receive(chatID: 1, messageID: 2, fileID: "b", name: "b.epub", provider: .dropbox)
        state.jobs[0].phase = .complete; state.jobs[1].phase = .failed
        try store.save(state)
        for job in [done, open] {
            try FileManager.default.createDirectory(at: store.jobFolder(job.id).appendingPathComponent("projects/x"), withIntermediateDirectories: true)
            try Data("m4b".utf8).write(to: store.jobFolder(job.id).appendingPathComponent("projects/x/audiobook.m4b"))
        }
        _ = BotService(folder: f, secrets: MemorySecrets())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.jobFolder(done.id).path))   // in the cloud: removed
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.jobFolder(open.id).path))    // unfinished: kept to resume
        XCTAssertEqual(BotService.bookExtension("Книга.FB2.zip"), "fb2.zip"); XCTAssertNil(BotService.bookExtension("a.pdf"))
    }
    @MainActor func testUploadedBookIsSavedCompleteWhenLocalCopyIsRemoved() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        defer { MockHTTP.handler = nil }
        let secrets = MemorySecrets(); secrets.values["dropboxRefresh"] = "fixture"
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        let hash = try CloudClient.hashes({ let file = f.appendingPathComponent("hash-fixture"); try Data("{}".utf8).write(to: file); return file }())
        MockHTTP.handler = { request in
            if request.url!.path == "/oauth2/token" { return (200, [:], try RemoteJSON.data(["access_token": "fixture"])) }
            if request.url!.path.hasSuffix("get_metadata") { return (200, [:], try RemoteJSON.data(["id": "verified", "size": hash.size, "content_hash": hash.dropbox])) }
            // Decode JSON streamed by URLSession to keep links deterministic for both files.
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
            }
            let path = RemoteJSON.string(try RemoteJSON.object(data), "path")
            return (200, [:], try RemoteJSON.data(["url": "https://dropbox.test/" + URL(fileURLWithPath: path).lastPathComponent]))
        }
        let bot = BotService(folder: f, secrets: secrets, http: RemoteHTTP(session: session)); bot.config.connections["dropbox"] = "account"
        var job = RemoteJob(chatID: 1, messageID: 1, fileID: "x", name: "book.epub", provider: .dropbox)
        job.account = "account"; job.phase = .uploading; job.cloudFolder = "/Audiobook Studio/book"; job.project = "/p"
        for name in ["audiobook.m4b", "audiobook.epub"] { var upload = RemoteUpload(); upload.link = "https://dropbox.test/" + name; job.uploads[name] = upload }
        bot.state.jobs = [job]
        let export = bot.store.jobFolder(job.id).appendingPathComponent("export")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        for name in ["audiobook.m4b", "audiobook.epub", "remote-complete.json"] { try Data("{}".utf8).write(to: export.appendingPathComponent(name)) }
        try await bot.execute(job.id)
        // The queue on disk already says complete (with the links) once the local files are gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: bot.store.jobFolder(job.id).path))
        let saved = try RemoteStateStore(f).load().jobs[0]
        XCTAssertEqual(saved.phase, .complete); XCTAssertEqual(saved.project, ""); XCTAssertEqual(saved.result, "")
        XCTAssertEqual(saved.uploads["audiobook.m4b"]?.link, "https://dropbox.test/book.m4b")
    }
    @MainActor func testOnlySideEffectFreeTelegramCallsAreRetried() async throws {
        defer { MockHTTP.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockHTTP.self]
        var calls = 0
        MockHTTP.handler = { _ in
            calls += 1
            return calls == 1 ? (503, ["Retry-After": "1"], Data()) : (200, [:], try RemoteJSON.data(["ok": true, "result": []]))
        }
        let telegram = TelegramClient(token: "1:abc", http: RemoteHTTP(session: URLSession(configuration: configuration)))
        _ = try await telegram.call("getUpdates", ["offset": 0])
        XCTAssertEqual(calls, 2)   // read-only: a 503 is retried
        calls = 0
        do { _ = try await telegram.call("sendMessage", ["chat_id": 1, "text": "x"]); XCTFail("503 must surface") } catch {}
        XCTAssertEqual(calls, 1)   // a message is never sent twice by the HTTP layer
    }
    @MainActor func testSameBookTwiceGetsItsOwnCloudFolder() async throws {
        defer { MockHTTP.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockHTTP.self]
        let secrets = MemorySecrets(); secrets.values["googleDriveRefresh"] = "refresh"; secrets.values["googleSecret"] = "s"
        var existing: Set<String> = ["Audiobook Studio", "Ницше - Мораль", "Ницше - Мораль (2)"], created: [String] = []
        MockHTTP.handler = { request in
            if request.url!.host == "oauth2.googleapis.com" { return (200, [:], try RemoteJSON.data(["access_token": "t"])) }
            if request.httpMethod == "POST" {
                // URLProtocol receives the POST body as a stream.
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
                }
                let name = RemoteJSON.string(try RemoteJSON.object(body), "name")
                created.append(name); existing.insert(name)
                return (200, [:], try RemoteJSON.data(["id": "id-" + name]))
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            let name = query.components(separatedBy: "name='").dropFirst().first?.components(separatedBy: "'").first ?? ""
            return (200, [:], try RemoteJSON.data(["files": existing.contains(name) ? [["id": "id-" + name]] : []]))
        }
        var config = RemoteConfig(); config.googleID = "g.apps.googleusercontent.com"
        let client = CloudClient(provider: .googleDrive, config: config, secrets: secrets, http: RemoteHTTP(session: URLSession(configuration: configuration)))
        let folder = try await client.folder(jobID: "j", title: "Мораль", author: "Ницше")
        XCTAssertEqual(folder, "id-Ницше - Мораль (3)")
        XCTAssertEqual(created, ["Ницше - Мораль (3)"])
        let dropbox = Data(#"{"metadata":{"path_display":"/Audiobook Studio/Ницше - Мораль (2)"}}"#.utf8)
        XCTAssertEqual(CloudClient.createdPath(dropbox), "/Audiobook Studio/Ницше - Мораль (2)")
    }
    @MainActor func testGoogleResumeUsesServerOffsetAndVerifiesHash() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f); MockHTTP.handler = nil }
        let file = f.appendingPathComponent("audiobook.m4b"); let bytes = Data(repeating: 7, count: 300000); try bytes.write(to: file)
        let hash = try CloudClient.hashes(file); var ranges: [String] = []
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockHTTP.self]
        let secrets = MemorySecrets(); secrets.values["googleDriveRefresh"] = "refresh"
        MockHTTP.handler = { request in
            if request.url!.host == "oauth2.googleapis.com" { return (200, [:], try RemoteJSON.data(["access_token": "test"])) }
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""; ranges.append(range)
            if range.hasPrefix("bytes */") { return (308, ["Range": "bytes=0-262143"], Data()) }
            XCTAssertEqual(range, "bytes 262144-299999/300000")
            return (200, [:], try RemoteJSON.data(["id": "result", "size": "300000", "md5Checksum": hash.md5]))
        }
        var saved = RemoteUpload(); saved.session = "https://www.googleapis.com/upload/drive/v3/files?upload_id=test"; saved.offset = 42
        let cloud = CloudClient(provider: .googleDrive, config: RemoteConfig(), secrets: secrets, http: RemoteHTTP(session: URLSession(configuration: configuration)))
        let result = try await cloud.upload(file: file, folder: "folder", saved: saved) { _ in }
        XCTAssertEqual(result.offset, 300000); XCTAssertEqual(result.link, "https://drive.google.com/file/d/result/view"); XCTAssertEqual(ranges.count, 2)
    }
    @MainActor func testDropboxResumeCorrectOffsetAndContentVerification() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f); MockHTTP.handler = nil }
        let file = f.appendingPathComponent("audiobook.epub"); try Data(repeating: 3, count: 101).write(to: file); let hash = try CloudClient.hashes(file)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockHTTP.self]
        let secrets = MemorySecrets(); secrets.values["dropboxRefresh"] = "refresh"; var finishes = 0
        MockHTTP.handler = { request in
            let path = request.url!.path
            if path == "/oauth2/token" { return (200, [:], try RemoteJSON.data(["access_token": "test"])) }
            if path.hasSuffix("get_metadata") { return (409, [:], try RemoteJSON.data(["error": "not_found"])) }
            if path.hasSuffix("finish") {
                finishes += 1
                if finishes == 1 { return (409, [:], try RemoteJSON.data(["error": ["lookup_failed": ["correct_offset": 50]]])) }
                let args = try RemoteJSON.object(Data(request.value(forHTTPHeaderField: "Dropbox-API-Arg")!.utf8))
                XCTAssertEqual((args["cursor"] as? [String: Any])?["offset"] as? Int, 50)
                return (200, [:], try RemoteJSON.data(["id": "file", "size": 101, "content_hash": hash.dropbox]))
            }
            return (200, [:], try RemoteJSON.data(["url": "https://dropbox.test/result"]))
        }
        var saved = RemoteUpload(); saved.session = "session"; saved.offset = 0
        let cloud = CloudClient(provider: .dropbox, config: RemoteConfig(), secrets: secrets, http: RemoteHTTP(session: URLSession(configuration: configuration)))
        let result = try await cloud.upload(file: file, folder: "/job", saved: saved) { _ in }
        XCTAssertEqual(finishes, 2); XCTAssertEqual(result.offset, 101); XCTAssertFalse(result.link.isEmpty)
    }
    @MainActor func testGeneralStatusKeepsFinishedCloudLinks() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let bot = BotService(folder: f, secrets: MemorySecrets()); bot.state.ownerID = 12
        var ready = RemoteJob(chatID: 12, messageID: 1, fileID: "x", name: "finished.epub", provider: .dropbox)
        ready.phase = .complete; var upload = RemoteUpload(); upload.link = "https://example.test/book"; ready.uploads["audiobook.m4b"] = upload
        var current = RemoteJob(chatID: 12, messageID: 2, fileID: "y", name: "current.epub", provider: .googleDrive); current.phase = .synthesis
        bot.state.jobs = [ready, current]
        try await bot.handle(["message": ["chat": ["id": 12, "type": "private"], "from": ["id": 12], "text": "/status"]])
        XCTAssertTrue(bot.state.outbox.contains { $0.text.contains("current.epub") })
        XCTAssertTrue(bot.state.outbox.contains { $0.text.contains("https://example.test/book") })
        try bot.persist(); XCTAssertEqual(try RemoteStateStore(f).load().jobs[0].uploads["audiobook.m4b"]?.link, upload.link)
    }
    @MainActor func testCorruptQueueBlocksServiceWithoutOverwriting() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let file = f.appendingPathComponent("queue.json"); try Data("broken".utf8).write(to: file)
        let bot = BotService(folder: f, secrets: MemorySecrets())
        XCTAssertTrue(bot.fatal); bot.start(); bot.kick(); XCTAssertNil(bot.worker)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }
    @MainActor func testEngineDrainsFinalEventBeforeReturning() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let script = f.appendingPathComponent("fixture.sh")
        try Data("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"type\":\"result\",\"path\":\"fixture\"}'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = RemoteEngine(); var events: [String] = []
        try await runner.run(executable: script, request: ["action": "fixture"], temporary: f.appendingPathComponent("temp")) { events.append($0["type"] as? String ?? "") }
        XCTAssertEqual(events, ["result"]); XCTAssertFalse(runner.running); XCTAssertFalse(FileManager.default.fileExists(atPath: f.appendingPathComponent("temp").path))
    }

    @MainActor func testCancelledEngineTerminatesBeforeReservationRelease() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let script = f.appendingPathComponent("wait.sh")
        try Data("#!/bin/sh\ncat >/dev/null\nexec /bin/sleep 20\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = RemoteEngine()
        let task = Task { try await runner.run(executable: script, request: ["fixture": true], temporary: f.appendingPathComponent("temp")) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(runner.running); task.cancel()
        do { try await task.value; XCTFail("Cancelled engine must throw") } catch is CancellationError {} catch { XCTFail("Wrong cancellation error") }
        XCTAssertFalse(runner.running); XCTAssertFalse(FileManager.default.fileExists(atPath: f.appendingPathComponent("temp").path))
    }

    @MainActor func testAlbumRejectedEntirelyAndOnceEvenAfterRestart() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let bot = BotService(folder: f, secrets: MemorySecrets()); bot.state.ownerID = 12
        func doc(_ mid: Int) -> [String: Any] { ["message": ["chat": ["id": 12, "type": "private"], "from": ["id": 12], "message_id": mid, "media_group_id": "group", "document": ["file_name": "book.epub", "file_size": 10, "file_id": "file"]]] }
        try await bot.handle(doc(1)); try await bot.handle(doc(2)); try bot.persist()
        XCTAssertTrue(bot.state.jobs.isEmpty); XCTAssertEqual(bot.state.outbox.count, 1)
        let restarted = BotService(folder: f, secrets: MemorySecrets()); try await restarted.handle(doc(3))
        XCTAssertTrue(restarted.state.jobs.isEmpty); XCTAssertEqual(restarted.state.outbox.count, 1)
    }
    @MainActor func testBusyQueueRequiresAddThenOneBookAndConfirmation() async throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let bot = BotService(folder: f, secrets: MemorySecrets()); bot.state.ownerID = 12
        var current = RemoteJob(chatID: 12, messageID: 1, fileID: "current", name: "current.epub", provider: .dropbox); current.phase = .synthesis; bot.state.jobs = [current]
        let doc: [String: Any] = ["message": ["chat": ["id": 12, "type": "private"], "from": ["id": 12], "message_id": 2, "document": ["file_name": "new.epub", "file_size": 10, "file_id": "new"]]]
        try await bot.handle(doc); XCTAssertEqual(bot.state.jobs.count, 1); XCTAssertTrue(bot.state.outbox.last!.text.contains("/add"))
        try await bot.handle(["message": ["chat": ["id": 12, "type": "private"], "from": ["id": 12], "text": "/add"]])
        try bot.persist()
        // Admission intent survives restart, but does not authorize actual synthesis.
        let restarted = BotService(folder: f, secrets: MemorySecrets()); try await restarted.handle(doc)
        XCTAssertEqual(restarted.state.jobs.count, 2); XCTAssertEqual(restarted.state.jobs[1].phase, .confirmation); XCTAssertNil(restarted.state.addRequestedAt)
        var third = doc["message"] as! [String: Any]; third["message_id"] = 3
        restarted.state.jobs[0].phase = .queued
        try await restarted.handle(["message": third]); XCTAssertEqual(restarted.state.jobs.count, 2)
    }

}
