import Foundation
import Combine

@MainActor public final class BotService: ObservableObject {
    @Published public var config = RemoteConfig()
    @Published public var state = RemoteState()
    @Published public var message = "Бот выключен"
    @Published public var pairingLink = ""
    @Published public var connecting = false
    public var canStart: () -> Bool = { false }
    public var makeRequest: (String) -> [String: Any] = { _ in [:] }
    public var executable: () -> URL = { URL(fileURLWithPath: "/nonexistent") }
    public var activity: (Bool, String) -> Void = { _, _ in }
    let store: RemoteStateStore, secrets: RemoteSecrets, http: RemoteHTTP
    let engine = RemoteEngine()
    var poll: Task<Void, Never>?, worker: Task<Void, Never>?, pairing = "", pairingExpires = Date.distantPast
    var fatal = false, shuttingDown = false
    public init(folder: URL, secrets: RemoteSecrets = RemoteKeychain(), http: RemoteHTTP = RemoteHTTP()) {
        store = RemoteStateStore(folder); self.secrets = secrets; self.http = http
        do {
            let file = folder.appendingPathComponent("config.json")
            if FileManager.default.fileExists(atPath: file.path) { config = try JSONDecoder().decode(RemoteConfig.self, from: Data(contentsOf: file)) }
            if config.dropboxID.isEmpty { config.dropboxID = RemoteRegistration.values["dropboxID"] ?? "" }
            if config.googleID.isEmpty { config.googleID = RemoteRegistration.values["googleID"] ?? "" }
            state = try store.load(); state.recover(); try persist()
        } catch { fatal = true; message = "Не удалось прочитать очередь. Файл сохранён; автоматический запуск заблокирован." }
    }
    public var paired: Bool { state.ownerID != nil }
    public var running: Bool { worker != nil }
    public func persist() throws {
        do { try store.save(state) } catch { fatal = true; poll?.cancel(); worker?.cancel(); engine.stop(); throw error }
    }
    public func saveConfig() throws {
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = store.folder.appendingPathComponent("config.json")
        try JSONEncoder().encode(config).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func failStorage(_ error: Error) { fatal = true; poll?.cancel(); worker?.cancel(); engine.stop(); message = "Не удалось сохранить очередь. Обработка остановлена; файлы сохранены." }
    func saveOrStop() { do { try persist() } catch { failStorage(error) } }
    public func start() {
        guard config.enabled, !fatal, poll == nil, !shuttingDown else { return }
        poll = Task { [weak self] in
            guard let self else { return }
            defer { poll = nil }
            do {
                let token = try secrets.read("telegramToken")
                guard !token.isEmpty else { throw RemoteError("Подключите Telegram-бота") }
                let client = TelegramClient(token: token, http: http)
                let webhook = try await client.call("getWebhookInfo") as? [String: Any] ?? [:]
                guard RemoteJSON.string(webhook, "url").isEmpty else { throw RemoteError("Этот бот уже подключён через webhook. Используйте отдельного бота.") }
                message = "Бот подключён · приложение должно оставаться открытым"
                while !Task.isCancelled && config.enabled && !fatal {
                    kick()
                    do {
                        // Poll before flushing replies: status/cancel must stay responsive when delivery fails.
                        let updates = try await client.call("getUpdates", ["offset": state.offset, "timeout": 10, "allowed_updates": ["message", "callback_query"]]) as? [[String: Any]] ?? []
                        for update in updates {
                            try handle(update)
                            state.offset = max(state.offset, RemoteJSON.integer(update, "update_id") + 1)
                            try persist()
                            if let callback = update["callback_query"] as? [String: Any], let id = callback["id"] as? String {
                                _ = try? await client.call("answerCallbackQuery", ["callback_query_id": id])
                            }
                        }
                        var delivered = 0
                        while let reply = state.outbox.first, delivered < 5 {
                            delivered += 1
                            try await client.send(reply)
                            state.outbox.removeAll { $0.id == reply.id }; try persist()
                        }
                        kick()
                    } catch {
                        if Task.isCancelled { break }
                        message = (error as? RemoteError)?.message ?? "Связь с Telegram прервалась. Очередь сохранена."
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                }
            } catch { if !Task.isCancelled { message = (error as? RemoteError)?.message ?? "Не удалось подключить бота" } }
        }
    }
    public func setEnabled(_ enabled: Bool) {
        config.enabled = enabled
        do { try saveConfig() } catch { message = "Не удалось сохранить настройки"; return }
        if enabled { start() }
        else { poll?.cancel(); message = running ? "Приём книг выключен; текущая книга продолжает обрабатываться" : "Бот выключен" }
    }
    public func connectBot(_ token: String) async {
        guard !connecting, !running else { return }; connecting = true; defer { connecting = false }
        do {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let me = try await TelegramClient(token: trimmed, http: http).call("getMe") as? [String: Any] ?? [:]
            guard let username = me["username"] as? String else { throw RemoteError("Не удалось определить бота") }
            let previous = try secrets.read("telegramToken")
            if previous != trimmed && !state.jobs.isEmpty { throw RemoteError("Замена бота заблокирована: сохранены задания с файлами прежнего бота.") }
            poll?.cancel()
            try secrets.write("telegramToken", trimmed)
            if previous != trimmed { state.ownerID = nil; state.offset = 0 }
            pairing = try RemoteJSON.random(); pairingExpires = Date().addingTimeInterval(600)
            pairingLink = "https://t.me/" + username + "?start=" + pairing
            try persist(); config.enabled = true; try saveConfig()
            // The old poll may be unwinding; it owns its slot until cancellation completes.
            if poll != nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            start(); message = paired ? "Бот подключён" : "Откройте ссылку и нажмите Start в Telegram (10 минут)"
        } catch { message = (error as? RemoteError)?.message ?? "Не удалось подключить Telegram" }
    }
    public func connectCloud(_ provider: RemoteProvider) async {
        guard !connecting, !running else { return }; connecting = true; defer { connecting = false }
        do {
            try saveConfig(); try await RemoteOAuth(secrets: secrets, http: http).connect(provider, config: config)
            config.connections[provider.rawValue] = UUID().uuidString; try saveConfig(); message = provider.title + " подключён"
        } catch { message = (error as? RemoteError)?.message ?? "Не удалось подключить хранилище" }
    }
    func reply(_ text: String, chat: Int64, buttons: [[RemoteButton]] = []) { state.outbox.append(RemoteReply(chat, text, buttons)) }
    func buttons(_ job: RemoteJob) -> [[RemoteButton]] {
        [[RemoteButton("Статус", "status:" + job.id), RemoteButton("Отменить", "cancel:" + job.id)]]
    }
    public func handle(_ update: [String: Any]) throws {
        let callback = update["callback_query"] as? [String: Any]
        let incoming = (callback?["message"] as? [String: Any]) ?? (update["message"] as? [String: Any]) ?? [:]
        let chat = incoming["chat"] as? [String: Any] ?? [:]
        let from = (callback?["from"] as? [String: Any]) ?? (incoming["from"] as? [String: Any]) ?? [:]
        let id = RemoteJSON.integer(chat, "id")
        guard id > 0, chat["type"] as? String == "private", RemoteJSON.integer(from, "id") == id else { return }
        let text = incoming["text"] as? String ?? ""
        if state.ownerID == nil {
            guard !pairing.isEmpty, Date() < pairingExpires, text == "/start " + pairing else { return }
            state.ownerID = id; pairing = ""; pairingLink = ""
            reply("Подключено. Отправьте EPUB до 20 МБ. Я спрошу перед озвучиванием. /status — статус, /queue — очередь, /cancel — отмена.", chat: id)
            return
        }
        guard state.ownerID == id else { return }
        if let data = callback?["data"] as? String {
            let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let i = state.jobs.firstIndex(where: { $0.id == parts[1] && $0.chatID == id }) else { return }
            let job = state.jobs[i]
            switch parts[0] {
            case "run":
                guard let account = config.connections[job.provider.rawValue], !account.isEmpty else {
                    reply("Сначала подключите " + job.provider.title + " в настройках Mac.", chat: id, buttons: [[RemoteButton("Повторить", "run:" + job.id)]]); return
                }
                if state.confirm(job.id, account: account) { reply("«\(job.name)» добавлена в очередь. Хранилище: \(job.provider.title).", chat: id, buttons: buttons(state.jobs[i])) }
            case "reject":
                if job.phase == .confirmation { state.jobs[i].phase = .cancelled; state.jobs[i].finished = Date(); reply("Книга не будет озвучена.", chat: id) }
            case "status": reply(job.status(), chat: id, buttons: buttons(job))
            case "cancel": askCancel(job)
            case "stop": cancel(job.id)
            default: break
            }
            return
        }
        if let document = incoming["document"] as? [String: Any] {
            if let group = incoming["media_group_id"] as? String, !group.isEmpty {
                state.addRequestedAt = nil
                if !state.rejectedGroups.contains(group) {
                    state.rejectedGroups.append(group); state.rejectedGroups = Array(state.rejectedGroups.suffix(1000))
                    reply("Пачка файлов отклонена целиком. Отправляйте EPUB по одному. Для добавления в очередь: /add, затем одна книга.", chat: id)
                }
                return
            }
            let authorizedAdd = state.addRequestedAt.map { Date().timeIntervalSince($0) < 600 } ?? false
            if let current = state.active ?? state.next, !authorizedAdd {
                reply("Сейчас \(current.phase == .queued ? "ожидает обработки" : "обрабатывается") «\(current.name)».\nДля добавления новой книги в очередь отправьте /add, затем один EPUB.\nЧтобы остановить текущую книгу, отправьте /cancel и подтвердите отмену.", chat: id)
                return
            }
            let name = document["file_name"] as? String ?? ""
            guard name.lowercased().hasSuffix(".epub"), RemoteJSON.integer(document, "file_size") > 0,
                  RemoteJSON.integer(document, "file_size") <= 20 * 1024 * 1024, let fileID = document["file_id"] as? String else {
                reply("Пришлите книгу EPUB размером до 20 МБ.", chat: id); return
            }
            state.addRequestedAt = nil
            let messageID = RemoteJSON.integer(incoming, "message_id")
            if state.jobs.contains(where: { $0.chatID == id && $0.messageID == messageID }) { return }
            let job = state.receive(chatID: id, messageID: messageID, fileID: fileID, name: String(name.prefix(240)), provider: config.provider)
            let current = state.active ?? state.next
            let queueText = current.map { "Сейчас: «" + $0.name + "» · " + $0.phase.title + ".\nНовая книга будет ждать в очереди. /cancel — остановить текущую.\n" } ?? ""
            reply(queueText + "«\(job.name)»\nНачать озвучивание в автоматическом режиме?\nРезультат: \(job.provider.title).", chat: id,
                  buttons: [[RemoteButton("Да", "run:" + job.id), RemoteButton("Нет", "reject:" + job.id)]])
            return
        }
        switch RemoteState.command(text) {
        case "add":
            state.addRequestedAt = Date()
            let current = state.active ?? state.next
            let prefix = current.map { "Сейчас: «" + $0.name + "» · " + $0.phase.title + ".\n" } ?? ""
            reply(prefix + "Отправьте один EPUB в течение 10 минут. Я предложу добавить его в очередь с подтверждением. Пачка файлов не принимается. /cancel — отменить текущую обработку.", chat: id)
        case "status":
            let waiting = state.jobs.filter { $0.phase == .queued }.count
            reply("Общий статус: " + (state.active == nil ? "озвучивание сейчас не идёт" : "идёт обработка книги") + ".\nВ очереди: \(waiting).\nФайлы в облаке хранятся до вашего ручного удаления. /links — готовые книги со ссылками.", chat: id)
            if let job = state.active ?? state.next { reply(job.status(), chat: id, buttons: buttons(job)) }
            else if let job = state.jobs.last, job.phase != .complete { reply(job.status(), chat: id, buttons: buttons(job)) }
            for job in state.jobs.filter({ $0.phase == .complete }).suffix(3).reversed() { reply(job.status(), chat: id) }
            if state.jobs.isEmpty { reply("Книг пока нет. Отправьте EPUB.", chat: id) }
        case "links":
            let completed = state.jobs.filter { $0.phase == .complete }
            if completed.isEmpty { reply("Пока нет полностью собранных и загруженных книг. /status — текущая обработка.", chat: id) }
            for job in completed.suffix(10).reversed() { reply(job.status(), chat: id) }
        case "queue":
            let jobs = state.jobs.filter { $0.phase != .complete && $0.phase != .cancelled }
            reply(jobs.isEmpty ? "Очередь пуста." : jobs.map { "\($0.shortID) · \($0.name) · \($0.phase.title)" }.joined(separator: "\n"), chat: id,
                  buttons: jobs.prefix(20).map { job in [RemoteButton(String(job.name.prefix(30)), "status:" + job.id), RemoteButton("Отменить", "cancel:" + job.id)] })
        case "cancel":
            if let job = state.active ?? state.next { askCancel(job) } else { reply("Сейчас нечего отменять.", chat: id) }
        default:
            reply("Отправьте EPUB. /status — статус и время; /queue — список книг; /add, затем один EPUB — добавить книгу в очередь; /links — готовые книги и ссылки; /cancel — отменить текущую книгу. После перезапуска продолжение требует подтверждения.", chat: id,
                  buttons: state.jobs.filter { [.paused, .failed, .cancelled].contains($0.phase) }.suffix(10).map { [RemoteButton("Продолжить: " + String($0.name.prefix(25)), "run:" + $0.id)] })
        }
    }
    func askCancel(_ job: RemoteJob) {
        guard job.phase != .complete && job.phase != .cancelled else { reply(job.status(), chat: job.chatID); return }
        reply("Отменить обработку «\(job.name)»? Остальные книги останутся в очереди.", chat: job.chatID,
              buttons: [[RemoteButton("Да, отменить", "stop:" + job.id), RemoteButton("Продолжать", "status:" + job.id)]])
    }
    public func cancelActive() { if let job = state.active { cancel(job.id) } }
    func cancel(_ id: String) {
        guard let i = state.jobs.firstIndex(where: { $0.id == id }), state.jobs[i].phase != .complete else { return }
        if state.jobs[i].phase.active { worker?.cancel(); engine.stop(); state.jobs[i].stage = "Остановка движка…" }
        else { state.jobs[i].phase = .cancelled; state.jobs[i].finished = Date(); reply("Отменено: " + state.jobs[i].name, chat: state.jobs[i].chatID) }
        saveOrStop()
    }
    func mutate(_ id: String, _ change: (inout RemoteJob) -> Void) throws {
        guard let i = state.jobs.firstIndex(where: { $0.id == id }) else { throw RemoteError("Задание не найдено") }
        change(&state.jobs[i]); try persist()
    }
    func job(_ id: String) throws -> RemoteJob {
        guard let j = state.jobs.first(where: { $0.id == id }) else { throw RemoteError("Задание не найдено") }; return j
    }
    public func kick() {
        guard !fatal, !shuttingDown, config.enabled, worker == nil, canStart(), let next = state.next else { return }
        let id = next.id
        do { try mutate(id) { $0.phase = .downloading; $0.started = $0.started ?? Date(); $0.stage = "Получение EPUB" } }
        catch { failStorage(error); return }
        activity(true, "Telegram: " + next.name)
        worker = Task { [weak self] in
            guard let self else { return }
            let wake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Telegram audiobook")
            defer { ProcessInfo.processInfo.endActivity(wake); worker = nil; activity(false, "Telegram: обработка завершена"); kick() }
            do {
                try await execute(id)
                try Task.checkCancellation()
                try mutate(id) { $0.phase = .complete; $0.finished = Date(); $0.stage = "M4B и EPUB загружены и проверены" }
                let j = try job(id); reply(j.status(), chat: j.chatID); try persist()
            } catch {
                let cancelled = Task.isCancelled
                do {
                    try mutate(id) { $0.phase = self.shuttingDown ? .paused : cancelled ? .cancelled : .failed; $0.finished = Date(); $0.eta = nil
                        $0.error = cancelled ? "" : (error as? RemoteError)?.message ?? "Обработка не завершена. Файлы сохранены." }
                    let j = try job(id)
                    if !shuttingDown { reply(j.status(), chat: j.chatID, buttons: [[RemoteButton("Продолжить", "run:" + id), RemoteButton("Статус", "status:" + id)]]); try persist() }
                } catch { failStorage(error) }
            }
        }
    }
    func execute(_ id: String) async throws {
        let folder = store.jobFolder(id), input = folder.appendingPathComponent("input.epub"), result = folder.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let initial = try job(id)
        guard config.connections[initial.provider.rawValue] == initial.account else { throw RemoteError("Аккаунт хранилища изменился. Подтвердите книгу заново.") }
        let completed = result.appendingPathComponent("remote-complete.json")
        if !FileManager.default.fileExists(atPath: completed.path) {
            if !FileManager.default.fileExists(atPath: input.path) {
                try await TelegramClient(token: secrets.read("telegramToken"), http: http).download(initial.fileID, to: input)
            }
            var project = try job(id).project
            let manifest = URL(fileURLWithPath: project).appendingPathComponent("roles/manifest.json")
            let prepared = folder.appendingPathComponent("remote-prepared.json")
            if project.isEmpty || !FileManager.default.fileExists(atPath: manifest.path) || !FileManager.default.fileExists(atPath: prepared.path) {
                try mutate(id) { $0.phase = .preparing; $0.stage = "Анализ книги и подготовка ролей" }
                var request = makeRequest("prepare"); request["book"] = input.path; request["project"] = ""; request["output"] = folder.appendingPathComponent("projects").path; request["automatic"] = true
                try await runEngine(id, request, folder)
                project = try job(id).project
                try RemoteJSON.data(["project": project]).write(to: prepared, options: .atomic)
            }
            try Task.checkCancellation()
            guard !project.isEmpty else { throw RemoteError("Движок не создал проект") }
            try mutate(id) { $0.phase = .synthesis; $0.stage = "Озвучивание" }
            // Incomplete export can only be a copy from an interrupted previous build. Keep the native project cache.
            if FileManager.default.fileExists(atPath: result.path) { try FileManager.default.removeItem(at: result) }
            var request = makeRequest("build"); request["project"] = project; request["destination"] = result.path
            try await runEngine(id, request, folder)
            for name in ["audiobook.m4b", "audiobook.epub", "package-report.json"] {
                guard FileManager.default.fileExists(atPath: result.appendingPathComponent(name).path) else { throw RemoteError("Неполный результат сборки") }
            }
            // Marker is created only after engine exit 0 and its verified export. Never upload an interrupted copy.
            try RemoteJSON.data(["job": id]).write(to: completed, options: .atomic)
            try mutate(id) { $0.result = result.path }
        }
        try mutate(id) { $0.phase = .uploading; $0.eta = nil; $0.speed = nil; $0.stage = "Отправка M4B и EPUB в " + $0.provider.title }
        let j = try job(id), cloud = CloudClient(provider: j.provider, config: config, secrets: secrets, http: http)
        var cloudFolder = j.cloudFolder
        if cloudFolder.isEmpty { cloudFolder = try await cloud.folder(jobID: id); try mutate(id) { $0.cloudFolder = cloudFolder } }
        for name in ["audiobook.m4b", "audiobook.epub"] {
            try Task.checkCancellation()
            let saved = try job(id).uploads[name] ?? RemoteUpload()
            _ = try await cloud.upload(file: result.appendingPathComponent(name), folder: cloudFolder, saved: saved) { checkpoint in
                try self.mutate(id) { $0.uploads[name] = checkpoint; $0.stage = "\(name): загружено \(checkpoint.offset / 1024 / 1024) МБ" }
            }
        }
        // The source already exists in the verified native project and final EPUB; remove only this redundant inbox copy.
        try? FileManager.default.removeItem(at: input)
    }
    func runEngine(_ id: String, _ request: [String: Any], _ folder: URL) async throws {
        var saveError: Error?
        try await engine.run(executable: executable(), request: request, temporary: folder.appendingPathComponent("temporary")) { event in
            guard ["project", "done", "progress", "metrics"].contains(event["type"] as? String ?? "") else { return }
            do {
                try self.mutate(id) { j in
                    switch event["type"] as? String {
                    case "project", "done": if let path = event["path"] as? String { j.project = path }
                    case "progress": j.stage = event["message"] as? String ?? j.stage; j.fraction = event["fraction"] as? Double ?? j.fraction
                        if event["synthesis"] as? Bool != true { j.eta = nil; j.speed = nil }
                    case "metrics": j.stage = event["message"] as? String ?? j.stage; j.eta = event["eta"] as? Double; j.measuredAt = Date(); j.speed = event["speed"] as? Double; j.completed = event["completed"] as? Int ?? 0; j.total = event["total"] as? Int ?? 0
                    default: break
                    }
                }
            } catch { saveError = error; self.engine.stop() }
        }
        if let saveError { throw saveError }
    }
    public func shutdown() -> Bool {
        shuttingDown = true; poll?.cancel(); worker?.cancel(); engine.stop()
        if let id = state.active?.id { do { try mutate(id) { $0.phase = .paused; $0.eta = nil } } catch { failStorage(error) } }
        return running || engine.running
    }
}
