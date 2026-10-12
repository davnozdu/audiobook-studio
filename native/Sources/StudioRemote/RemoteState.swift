import Foundation

public enum RemoteProvider: String, Codable, CaseIterable, Identifiable {
    case dropbox, googleDrive
    public var id: String { rawValue }
    public var title: String { self == .dropbox ? "Dropbox" : "Google Drive" }
}
public enum RemotePhase: String, Codable {
    case confirmation, queued, downloading, preparing, synthesis, uploading, complete, cancelled, failed, paused
    public var active: Bool { [.downloading, .preparing, .synthesis, .uploading].contains(self) }
    public var title: String {
        switch self {
        case .confirmation: return "Ожидает подтверждения"
        case .queued: return "В очереди"
        case .downloading: return "Загрузка книги"
        case .preparing: return "Подготовка книги и голосов"
        case .synthesis: return "Озвучивание и сборка"
        case .uploading: return "Загрузка результата в хранилище"
        case .complete: return "Готово"
        case .cancelled: return "Отменено"
        case .failed: return "Требуется внимание"
        case .paused: return "Приостановлено после перезапуска"
        }
    }
}
public struct RemoteUpload: Codable, Equatable {
    public var session = "", offset: Int64 = 0, fileID = "", link = "", fingerprint = ""
    public init() {}
}
public struct RemoteJob: Codable, Identifiable {
    public var id = UUID().uuidString.lowercased()
    public var chatID: Int64, messageID: Int64, fileID: String, name: String
    public var provider: RemoteProvider, phase = RemotePhase.confirmation
    public var created = Date(), queuedAt: Date?, started: Date?, finished: Date?
    public var stage = "", project = "", result = "", error = "", account = "", cloudFolder = ""
    public var completed = 0, total = 0, fraction: Double = 0, speed: Double?
    public var eta: Double?, measuredAt: Date?
    public var uploads: [String: RemoteUpload] = [:]
    public init(chatID: Int64, messageID: Int64, fileID: String, name: String, provider: RemoteProvider) {
        self.chatID = chatID; self.messageID = messageID; self.fileID = fileID
        self.name = name; self.provider = provider
    }
    public var shortID: String { String(id.prefix(8)) }
    public func status(now: Date = Date()) -> String {
        var lines = ["\(name) · \(shortID)", phase.title]
        if !stage.isEmpty { lines.append(stage) }
        if let started { lines.append("С начала: " + Self.duration((finished ?? now).timeIntervalSince(started))) }
        if total > 0 { lines.append("Реплики: \(completed)/\(total)") }
        if let eta, eta.isFinite, eta >= 0, phase == .synthesis {
            let remaining = max(0, eta - now.timeIntervalSince(measuredAt ?? now))
            lines.append("Осталось озвучивания ≈ " + Self.duration(remaining))
            lines.append("Упаковка и загрузка результата займут дополнительное время.")
        } else if phase.active { lines.append("Оценка остатка появится по замерам этого этапа.") }
        if let speed, speed.isFinite { lines.append(String(format: "Скорость озвучки: %.2f×", speed)) }
        if !error.isEmpty { lines.append(error) }
        if phase == .complete {
            for name in uploads.keys.sorted() {
                if let link = uploads[name]?.link, !link.isEmpty { lines.append("\(name): \(link)") }
            }
        }
        return lines.joined(separator: "\n")
    }
    public static func duration(_ seconds: Double) -> String {
        let n = max(0, Int(min(seconds.isFinite ? seconds : 0, 31_536_000)))
        return n >= 3600 ? String(format: "%d ч %02d мин", n / 3600, n % 3600 / 60)
            : n >= 60 ? "\(n / 60) мин \(n % 60) с" : "\(n) с"
    }
}
public struct RemoteButton: Codable, Equatable {
    public var text: String, data: String
    public init(_ text: String, _ data: String) { self.text = text; self.data = data }
}
public struct RemoteReply: Codable, Identifiable {
    public var id = UUID().uuidString
    public var chatID: Int64, text: String, buttons: [[RemoteButton]]
    public init(_ chatID: Int64, _ text: String, _ buttons: [[RemoteButton]] = []) {
        self.chatID = chatID; self.text = text; self.buttons = buttons
    }
}
public struct RemoteState: Codable {
    public var offset: Int64 = 0, ownerID: Int64?
    public var jobs: [RemoteJob] = [], outbox: [RemoteReply] = []
    public var rejectedGroups: [String] = []
    public var addRequestedAt: Date?
    public init() {}
    public var active: RemoteJob? { jobs.first { $0.phase.active } }
    public var next: RemoteJob? {
        jobs.filter { $0.phase == .queued }.min { ($0.queuedAt ?? $0.created) < ($1.queuedAt ?? $1.created) }
    }
    public mutating func receive(chatID: Int64, messageID: Int64, fileID: String, name: String,
        provider: RemoteProvider) -> RemoteJob {
        if let existing = jobs.first(where: { $0.chatID == chatID && $0.messageID == messageID }) { return existing }
        let job = RemoteJob(chatID: chatID, messageID: messageID, fileID: fileID, name: name, provider: provider)
        jobs.append(job); return job
    }
    @discardableResult public mutating func confirm(_ id: String, account: String, now: Date = Date()) -> Bool {
        guard let i = jobs.firstIndex(where: { $0.id == id }),
            [.confirmation, .paused, .failed, .cancelled].contains(jobs[i].phase) else { return false }
        if jobs[i].account != account {
            jobs[i].account = account; jobs[i].uploads = [:]; jobs[i].cloudFolder = ""
        }
        jobs[i].phase = .queued; jobs[i].queuedAt = now; jobs[i].finished = nil; jobs[i].error = ""
        return true
    }
    public mutating func recover() {
        for i in jobs.indices where jobs[i].phase.active {
            jobs[i].phase = .paused; jobs[i].eta = nil; jobs[i].speed = nil
            outbox.append(RemoteReply(jobs[i].chatID, "Приложение перезапущено. Продолжить книгу «\(jobs[i].name)»?",
                [[RemoteButton("Да, продолжить", "run:" + jobs[i].id), RemoteButton("Позже", "status:" + jobs[i].id)]]))
        }
    }
    public static func command(_ text: String) -> String {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let first = (t.split(separator: " ").first ?? "").split(separator: "@").first ?? ""
        if ["/status", "статус", "сколько осталось", "сколько времени осталось", "что делается", "как дела"].contains(t)
            || first == "/status" { return "status" }
        if first == "/add" || t == "добавить книгу" { return "add" }
        if ["ссылки", "скачать", "готовые книги"].contains(t) || ["/links", "/downloads"].contains(first) { return "links" }
        if t == "очередь" || first == "/queue" { return "queue" }
        if ["отмена", "отмени", "отменить", "отменить текущую", "останови"].contains(t) || first == "/cancel" { return "cancel" }
        return "help"
    }
}
public final class RemoteStateStore {
    public let folder: URL
    public init(_ folder: URL) { self.folder = folder }
    public func load() throws -> RemoteState {
        let file = folder.appendingPathComponent("queue.json")
        if !FileManager.default.fileExists(atPath: file.path) { return RemoteState() }
        return try JSONDecoder().decode(RemoteState.self, from: Data(contentsOf: file))
    }
    public func save(_ state: RemoteState) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("queue.json")
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func jobFolder(_ id: String) -> URL { folder.appendingPathComponent("jobs/" + id) }
}
public struct RemoteError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
