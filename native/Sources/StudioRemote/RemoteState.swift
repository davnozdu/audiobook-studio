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
    public var bookTitle: String?, bookAuthor: String?
    public var completed = 0, total = 0, fraction: Double = 0, speed: Double?
    public var eta: Double?, measuredAt: Date?
    public var uploads: [String: RemoteUpload] = [:]
    /// Chosen when the book is confirmed: emotions levelled (true) or with the model's own loudness;
    /// nil follows the app setting.
    public var levelEmotions: Bool?
    public init(chatID: Int64, messageID: Int64, fileID: String, name: String, provider: RemoteProvider) {
        self.chatID = chatID; self.messageID = messageID; self.fileID = fileID
        self.name = name; self.provider = provider
    }
    public var shortID: String { String(id.prefix(8)) }
    public func status(now: Date = Date()) -> String {
        let icon: String
        switch phase {
        case .confirmation: icon = "📩"
        case .queued: icon = "⏳"
        case .downloading, .preparing, .synthesis, .uploading: icon = "🔄"
        case .complete: icon = "✅"
        case .cancelled: icon = "⏹"
        case .failed: icon = "⚠️"
        case .paused: icon = "⏸"
        }
        var lines = ["📚 <b>\(Self.escapedHTML(name))</b>", "\(icon) \(Self.escapedHTML(phase.title))"]
        if !stage.isEmpty { lines.append("🧭 \(Self.escapedHTML(stage))") }
        if total > 0 {
            let percent = min(100, max(0, Int(min(100, max(0, Double(completed) / Double(total) * 100)))))
            let filled = percent / 10
            lines.append("\(String(repeating: "▰", count: filled))\(String(repeating: "▱", count: 10 - filled))  <b>\(percent)%</b>")
            lines.append("🗣 Реплики: \(completed) из \(total)")
        }
        if let started { lines.append("⏱ С начала: " + Self.duration((finished ?? now).timeIntervalSince(started))) }
        if let eta, eta.isFinite, eta >= 0, phase == .synthesis {
            let remaining = max(0, eta - now.timeIntervalSince(measuredAt ?? now))
            lines.append("⌛ Осталось озвучивания ≈ " + Self.duration(remaining))
            lines.append("📦 Упаковка и загрузка займут дополнительное время.")
        } else if phase.active { lines.append("⌛ Оценка остатка появится по замерам этого этапа.") }
        if let speed, speed.isFinite { lines.append(String(format: "⚡ Скорость озвучки: %.2f×", speed)) }
        if !error.isEmpty { lines.append("⚠️ \(Self.escapedHTML(error))") }
        if phase == .complete {
            for name in uploads.keys.sorted() {
                if let link = uploads[name]?.link, !link.isEmpty {
                    let label = name.lowercased().hasSuffix(".m4b") ? "Скачать аудиокнигу M4B" : "Скачать EPUB"
                    lines.append("📥 <a href=\"\(Self.escapedHTML(link))\">\(label)</a>")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
    public static func escapedHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func duration(_ seconds: Double) -> String {
        let n = max(0, Int(min(seconds.isFinite ? seconds : 0, 31_536_000)))
        return n >= 3600 ? String(format: "%d ч %02d мин", n / 3600, n % 3600 / 60)
            : n >= 60 ? "\(n / 60) мин \(n % 60) с" : "\(n) с"
    }
}
public struct RemoteButton: Codable, Equatable {
    public var text: String, data: String, url: String?
    public init(_ text: String, _ data: String) { self.text = text; self.data = data; self.url = nil }
    public init(_ text: String, url: String) { self.text = text; self.data = ""; self.url = url }
}
public struct RemoteCatalogTarget: Codable {
    public var provider: RemoteProvider, id: String, path: String?
    /// Issue time; the oldest buttons are forgotten first. Optional for saved queues.
    public var created: Date?
    public init(_ provider: RemoteProvider, _ id: String, path: String? = nil, created: Date = Date()) {
        self.provider = provider; self.id = id; self.path = path; self.created = created
    }
}
public struct RemoteReply: Codable, Identifiable {
    public var id = UUID().uuidString
    public var chatID: Int64, text: String, buttons: [[RemoteButton]]
    public var parseMode: String?
    public init(_ chatID: Int64, _ text: String, _ buttons: [[RemoteButton]] = [], parseMode: String? = nil) {
        self.chatID = chatID; self.text = text; self.buttons = buttons; self.parseMode = parseMode
    }
}
public struct RemoteState: Codable {
    public var offset: Int64 = 0, ownerID: Int64?
    public var jobs: [RemoteJob] = [], outbox: [RemoteReply] = []
    public var rejectedGroups: [String] = []
    public var addRequestedAt: Date?
    public var catalogNextToken: String?, catalogQuery: String?, catalogProvider: RemoteProvider?
    public var catalogActions: [String: RemoteCatalogTarget]?
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
        if t == "книги" || first == "/books" { return "books" }
        if t.hasPrefix("поиск ") || first == "/search" { return "search" }
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
        let state = try JSONDecoder().decode(RemoteState.self, from: Data(contentsOf: file))
        guard Set(state.jobs.map(\.id)).count == state.jobs.count,
              state.jobs.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.completed >= 0 && $0.total >= 0 && $0.fraction.isFinite })
        else { throw RemoteError("Некорректные идентификаторы или счётчики очереди") }
        return state
    }
    public func save(_ state: RemoteState) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("queue.json")
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func jobFolder(_ id: String) -> URL {
        let safeID = UUID(uuidString: id)?.uuidString.lowercased() ?? "invalid-id"
        return folder.appendingPathComponent("jobs/" + safeID)
    }
    public func validateJobFolders(_ state: RemoteState) throws {
        let root = folder.resolvingSymlinksInPath().appendingPathComponent("jobs").path + "/"
        for job in state.jobs {
            guard UUID(uuidString: job.id) != nil, jobFolder(job.id).resolvingSymlinksInPath().path.hasPrefix(root) else {
                throw RemoteError("Папка задания выходит за пределы очереди")
            }
        }
    }
}
public struct RemoteError: LocalizedError {
    public var message: String
    /// HTTP status of a definitive service answer, when there was one.
    public var status: Int?
    public init(_ message: String, status: Int? = nil) { self.message = message; self.status = status }
    /// The service rejected this exact request (not throttling); repeating it cannot succeed.
    public var rejected: Bool { status.map { (400..<500).contains($0) && $0 != 429 } ?? false }
    public var errorDescription: String? { message }
}
