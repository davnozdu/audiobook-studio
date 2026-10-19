import SwiftUI
import AppKit
import Foundation
import Sparkle
import UniformTypeIdentifiers
import AVFoundation
import Darwin
import Security
import IOKit.ps

enum CredentialStore {
    /// One Keychain item per service: "ollama-api-key" (existing installs) or "deepseek-api-key".
    static func identity(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.davnozdu.audiobook-studio.credentials",
         kSecAttrAccount as String: account]
    }
    static func read(_ account: String = "ollama-api-key") throws -> String {
        var query = identity(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }
    static func write(_ value: String, account: String = "ollama-api-key", label: String = "Audiobook Studio — Ollama") throws {
        let identity = identity(account)
        if value.isEmpty {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity; item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrLabel as String] = label
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

final class PlaybackCompletion: NSObject, AVAudioPlayerDelegate {
    var finished: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.finished?() }
    }
}

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    static weak var studio: Studio?
    private var lockFD: Int32 = -1
    func applicationWillFinishLaunching(_ notification: Notification) {
        let identifier = Bundle.main.bundleIdentifier ?? "com.davnozdu.audiobook-studio"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Audiobook Studio")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        lockFD = Darwin.open(folder.appendingPathComponent(identifier + ".lock").path, O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first(where: { $0.processIdentifier != getpid() })?.activate(options: [.activateAllWindows])
            NSApplication.shared.terminate(nil)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let studio = Self.studio else { return .terminateNow }
        guard studio.confirmApplicationExit() else { return .terminateCancel }
        return studio.shutdown() ? .terminateLater : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        Self.studio?.removeMenuBar()
        if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
    }
}

struct MusicTrack: Codable, Identifiable {
    var filename: String
    var title: String
    var id: String { filename }
}

struct ProjectWindowCloseHandler: NSViewRepresentable {
    let studio: Studio
    func makeCoordinator() -> Coordinator { Coordinator(studio) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, window.delegate !== context.coordinator else { return }
            context.coordinator.previous = window.delegate
            window.delegate = context.coordinator
        }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        weak var studio: Studio?
        weak var previous: NSWindowDelegate?
        private var approved = false
        init(_ studio: Studio) { self.studio = studio }
        func windowShouldClose(_ window: NSWindow) -> Bool {
            if approved { approved = false; return previous?.windowShouldClose?(window) ?? true }
            guard let studio, studio.hasBook else { return previous?.windowShouldClose?(window) ?? true }
            studio.closeProject {
                DispatchQueue.main.async { self.approved = true; window.performClose(nil) }
            }
            return false
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previous?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
        }
    }
}

@MainActor final class QuietUpdateDriver: SPUStandardUserDriver {
    var report: ((String) -> Void)?
    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        report?("Не удалось проверить обновления: " + error.localizedDescription)
        acknowledgement()
    }
    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        report?("Установлена актуальная версия")
        acknowledgement()
    }
    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        report?("Проверяем обновления…")
    }
}

@MainActor final class UpdateController: NSObject, SPUUpdaterDelegate {
    private let driver = QuietUpdateDriver(hostBundle: .main, delegate: nil)
    lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    var report: ((String) -> Void)? { didSet { driver.report = report } }
    private var started = false
    func start() {
        guard !started else { return }
        do { try updater.start(); started = true }
        catch { report?("Проверка обновлений недоступна: " + error.localizedDescription) }
    }
    func checkForUpdates(_ sender: Any?) {
        start()
        if started && updater.canCheckForUpdates { updater.checkForUpdates() }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle reports a successful check with no newer release through this callback too.
        if (error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == 1001 {
            report?("Установлена актуальная версия"); return
        }
        report?("Проверка обновлений: " + error.localizedDescription)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { report?("Установлена актуальная версия") }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
}

final class MenuBarController: NSObject {
    var item: NSStatusItem?
    var open: (() -> Void)?
    var cancel: (() -> Void)?
    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
    func update(visible: Bool, status: String, busy: Bool) {
        if !visible {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil; return
        }
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 18, height: 18); item?.button?.image = image
        } else { item?.button?.image = NSImage(systemSymbolName: "book.circle", accessibilityDescription: "Audiobook Studio") }
        item?.button?.toolTip = "Audiobook Studio · " + status
        let menu = NSMenu()
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: ""); statusItem.isEnabled = false; menu.addItem(statusItem)
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Открыть Audiobook Studio", action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self; menu.addItem(openItem)
        if busy {
            let stop = NSMenuItem(title: "Остановить сборку", action: #selector(stopJob), keyEquivalent: "")
            stop.target = self; menu.addItem(stop)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Завершить Audiobook Studio", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item?.menu = menu
    }
    @objc func openWindow() { open?() }
    @objc func stopJob() { cancel?() }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}

struct RoleSegment: Identifiable {
    var id: String
    var text: String
    var speaker: String
    var originalSpeaker: String
    var needsReview: Bool
}

struct StoryCharacter: Identifiable {
    var id: String
    var name: String
    var age: String
    var personality: String
    var habits: String
    var speakingStyle: String
    var voice: String
    var certainty: String
    var assumptions: [String]
    var evidence: [[String: String]]
    var sample: String
    var sampleText: String
    var voiceGender: String
    var seed: Int

    var profile: [String: Any] {
        ["id": id, "age": age, "personality": personality.isEmpty ? "Не определён" : personality,
         "habits": habits.isEmpty ? "Не определены" : habits,
         "speaking_style": speakingStyle.isEmpty ? "Не определена" : speakingStyle,
         "voice_description": voice, "certainty": certainty,
         "assumptions": assumptions, "evidence": evidence]
    }
}

@MainActor final class Studio: ObservableObject {
    @Published var book = ""
    @Published var project = ""
    @Published var output = UserDefaults.standard.string(forKey: "outputFolder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Audiobook Studio").path {
        didSet { UserDefaults.standard.set(output, forKey: "outputFolder") }
    }
    @Published var characters: [StoryCharacter] = []
    @Published var selected: String?
    @Published var busy = false
    var remoteBusy = false
    lazy var bot: BotService = {
        let service = BotService(folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audiobook Studio/Remote"))
        service.canStart = { [weak self] in self.map { !$0.busy && !$0.shuttingDown && !$0.activeKey.isEmpty } ?? false }
        service.makeRequest = { [weak self] action in self?.request(action) ?? [:] }
        service.executable = { [weak self] in self?.engine ?? URL(fileURLWithPath: "/nonexistent") }
        service.activity = { [weak self] active, message in
            guard let self else { return }; self.remoteBusy = active; self.busy = active; self.status = message
            self.syncWake()
            if !active, let continuation = self.afterStop {
                self.afterStop = nil; self.cancelling = false; continuation()
            }
        }
        return service
    }()
    @Published var status = "Выберите книгу, чтобы начать" { didSet { updateMenuBar() } }
    @Published var fraction = 0.0
    @Published var speed: Double?
    @Published var eta: Double?
    @Published var completed = ""
    @Published var bookCharacterCount = 0
    @Published var remainingSynthesisSeconds: Double?
    var estimatedSecondsPerCharacter: Double? {
        let value = UserDefaults.standard.double(forKey: "nativeSynthesisSecondsPerCharacter")
        return value.isFinite && value > 0 && value < 60 ? value : nil
    }
    private func approximateMinutes(_ seconds: Double) -> String {
        "\(max(1, Int(ceil(seconds / 60)))) мин"
    }
    var bookEstimate: String {
        guard bookCharacterCount > 0 else { return "" }
        let speech = Double(bookCharacterCount) / 12
        let prefix = "Длительность аудиокниги ≈ " + approximateMinutes(speech)
        if let remainingSynthesisSeconds {
            if remainingSynthesisSeconds <= 0 { return prefix + " · Синтез завершён" }
            return prefix + " · Осталось ≈ " + approximateMinutes(remainingSynthesisSeconds) + " озвучивания"
        }
        if let rate = estimatedSecondsPerCharacter {
            return prefix + " · Озвучивание ≈ " + approximateMinutes(Double(bookCharacterCount) * rate) + " по последним замерам"
        }
        return prefix + " · Озвучивание ориентировочно " + approximateMinutes(speech / 2) + "–" + approximateMinutes(speech * 2) + " до первых замеров"
    }
    @Published var resultPath = ""
    @Published var log = ""
    @Published var error: String?
    @Published var key = "" { didSet { scheduleCredentialSave() } }
    @Published var keyStorageStatus = "Ключ сохраняется в Связке ключей macOS и используется после обновлений."
    @Published var model = UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek-v4.1-flash" {
        didSet { UserDefaults.standard.set(model, forKey: "llmModel") }
    }
    @Published var llmProvider = UserDefaults.standard.string(forKey: "llmProvider") ?? "ollama" {
        didSet { UserDefaults.standard.set(llmProvider, forKey: "llmProvider") }
    }
    @Published var deepseekKey = "" { didSet { scheduleCredentialSave() } }
    @Published var deepseekModel = UserDefaults.standard.string(forKey: "deepseekModel") ?? "deepseek-flash" {
        didSet { UserDefaults.standard.set(deepseekModel, forKey: "deepseekModel") }
    }
    /// Key of the selected chat provider; analysis and the Telegram queue need it.
    var activeKey: String { llmProvider == "deepseek" ? deepseekKey : key }
    @Published var webSearch = UserDefaults.standard.bool(forKey: "webSearch") {
        didSet { UserDefaults.standard.set(webSearch, forKey: "webSearch") }
    }
    // On by default: the LLM check fixes confidently wrong homographs (за́мок, бе́лки, все/всё).
    @Published var cloudStress = UserDefaults.standard.object(forKey: "cloudStress") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cloudStress, forKey: "cloudStress") }
    }
    /// Every line levelled to its speaker (a shout keeps a moderate +3 dB, a whisper its usual
    /// loudness); off keeps the model's own loudness of each line.
    /// The user's own stresses, one word per line (за́мок or ё), for every book.
    @Published var stressDictionary = UserDefaults.standard.string(forKey: "stressDictionary") ?? "" {
        didSet { UserDefaults.standard.set(stressDictionary, forKey: "stressDictionary") }
    }
    @Published var levelEmotions = UserDefaults.standard.object(forKey: "levelEmotions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(levelEmotions, forKey: "levelEmotions") }
    }
    @Published var musicEnabled = UserDefaults.standard.object(forKey: "musicEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(musicEnabled, forKey: "musicEnabled") }
    }
    @Published var music = UserDefaults.standard.string(forKey: "customMusic") ?? "" {
        didSet { UserDefaults.standard.set(music, forKey: "customMusic") }
    }
    @Published var bundledMusic = UserDefaults.standard.string(forKey: "bundledMusic") ?? "Lamplight_and_Paper.mp3" {
        didSet { UserDefaults.standard.set(bundledMusic, forKey: "bundledMusic") }
    }
    let musicTracks: [MusicTrack] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("engine/resources/music_catalog.json"),
              let data = try? Data(contentsOf: url), let tracks = try? JSONDecoder().decode([MusicTrack].self, from: data) else { return [] }
        return tracks
    }()
    // Silence after a line by boundary kind, in milliseconds (about 0.3 s of the line's own edge
    // silence is heard on top). Changing them rebuilds only the montage, not the speech.
    static let pauseDefaults = ["comma": 100, "sentence": 450, "paragraph": 800, "chapter": 2000, "speaker": 350]
    @Published var pauses: [String: Int] = (UserDefaults.standard.dictionary(forKey: "pauses") as? [String: Int])
        .map { Studio.pauseDefaults.merging($0) { _, saved in saved } } ?? Studio.pauseDefaults {
        didSet { UserDefaults.standard.set(pauses, forKey: "pauses") }
    }
    @Published var musicVolume = UserDefaults.standard.object(forKey: "musicVolume") as? Double ?? 5.0 {
        didSet { UserDefaults.standard.set(musicVolume, forKey: "musicVolume") }
    }
    @Published var settings = false
    @Published var dirty = false
    @Published var showLog = false
    @Published var updateStatus = ""
    @Published var segments: [RoleSegment] = []
    @Published var roleSearch = ""
    @Published var reviewOnly = true
    @Published var rolesDirty = false
    @Published var voiceLabOpen = false
    @Published var voiceDescription = UserDefaults.standard.string(forKey: "voiceDescription") ?? "Warm mature Russian narrator, mid-low resonant baritone, clear diction, calm natural delivery." {
        didSet { UserDefaults.standard.set(voiceDescription, forKey: "voiceDescription") }
    }
    @Published var voiceTestText = UserDefaults.standard.string(forKey: "voiceTestText") ?? "Сегодня тихое утро. Я открываю новую книгу и приглашаю вас послушать эту историю." {
        didSet { UserDefaults.standard.set(voiceTestText, forKey: "voiceTestText") }
    }
    @Published var generatedSample = ""
    @Published var generatedText = ""
    @Published var generatedDescription = ""
    @Published var voiceSeed = UserDefaults.standard.object(forKey: "voiceSeed") as? Int ?? 17001 {
        didSet { UserDefaults.standard.set(voiceSeed, forKey: "voiceSeed") }
    }
    @Published var previewByCharacter: [String: String] = [:]
    @Published var showDock = UserDefaults.standard.object(forKey: "showDock") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showDock, forKey: "showDock"); updatePresence() }
    }
    @Published var showMenuBar = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBar, forKey: "showMenuBar"); updatePresence() }
    }
    /// Build mode: "normal"; "gentle" — the engine pauses the GPU after every step so the screen
    /// and other apps stay smooth (about a third slower); "background" — macOS background policy
    /// on the efficiency cores (measured 2–2.5× slower). Old "background priority" carries over.
    @Published var priorityMode = UserDefaults.standard.string(forKey: "priorityMode")
        ?? (UserDefaults.standard.bool(forKey: "backgroundPriority") ? "background" : "normal") {
        didSet { UserDefaults.standard.set(priorityMode, forKey: "priorityMode"); applyPriority() }
    }
    private let menuBar = MenuBarController()
    private var childPIDs: Set<Int32> = []
    private var audioPlayer: AVAudioPlayer?
    private var playbackCompletion: PlaybackCompletion?
    private var playingAudio = ""
    private var process: Process?
    private var pending: (() -> Void)?
    private var afterStop: (() -> Void)?
    private var quitConfirmed = false
    private var cancelling = false
    private var shuttingDown = false
    private var receivedError = false
    private var restoringCredential = true
    private var credentialDirty = false
    private var credentialSave: DispatchWorkItem?
    private var buffer = Data()
    /// Keeps the Mac awake (display may sleep) while a book is processed on mains power: an idle
    /// sleep would pause an overnight 10–20 hour book. On battery normal sleep stays allowed.
    private var wakeActivity: NSObjectProtocol?
    private var powerCheck: Timer?
    let updater = UpdateController()

    init() {
        do { key = try CredentialStore.read(); deepseekKey = try CredentialStore.read("deepseek-api-key") }
        catch { keyStorageStatus = "Не удалось прочитать ключ из Связки ключей macOS. Сохранённый ключ не удалён." }
        restoringCredential = false
        AppLifecycle.studio = self
        menuBar.open = { [weak self] in self?.showWindow() }
        menuBar.cancel = { [weak self] in self?.cancel() }
        updater.report = { [weak self] message in
            self?.updateStatus = message.contains("актуальная") || message.contains("Проверяем") ? message : "Обновления временно недоступны"
            self?.appendLog(message)
        }
        DispatchQueue.main.async {
            if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let image = NSImage(contentsOfFile: path) {
                NSApplication.shared.applicationIconImage = image
            }
            self.updatePresence()
            self.updater.start()
            self.bot.start()
        }
    }

    func scheduleCredentialSave() {
        guard !restoringCredential else { return }
        credentialDirty = true; credentialSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveCredential() }
        credentialSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func saveCredential() {
        guard credentialDirty else { return }
        do {
            try CredentialStore.write(key.trimmingCharacters(in: .whitespacesAndNewlines))
            try CredentialStore.write(deepseekKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                      account: "deepseek-api-key", label: "Audiobook Studio — DeepSeek")
            credentialDirty = false
            keyStorageStatus = activeKey.isEmpty ? "Ключ выбранного сервиса не задан." : "Ключи сохранены в Связке ключей macOS."
        } catch {
            keyStorageStatus = "Не удалось сохранить ключ в Связке ключей macOS."
            appendLog(keyStorageStatus)
        }
    }

    func updatePresence() {
        if !showDock && !showMenuBar { showMenuBar = true }
        NSApplication.shared.setActivationPolicy(showDock ? .regular : .accessory)
        updateMenuBar()
    }

    func updateMenuBar() { menuBar.update(visible: showMenuBar && !shuttingDown, status: status, busy: busy) }

    func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    /// macOS background policy, set by the system call itself (the one taskpolicy -b makes; the
    /// tool moved from /usr/bin to /usr/sbin and the setting silently did nothing): lowest CPU
    /// priority on the efficiency cores and throttled disk. Children started later inherit it.
    /// The Telegram engine follows the same setting.
    func applyPriority() {
        writePace()
        let background = priorityMode == "background"
        for pid in [process?.processIdentifier ?? 0] + Array(childPIDs) where pid > 1 {
            if setpriority(PRIO_DARWIN_PROCESS, id_t(pid), background ? PRIO_DARWIN_BG : 0) != 0 {
                appendLog("Не удалось изменить приоритет движка: " + String(cString: strerror(errno)))
            }
        }
        bot.engine.background = background
    }
    /// The gentle mode reaches a running engine (window or Telegram) through this file.
    var paceFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audiobook Studio/engine-pace")
    }
    func writePace() {
        try? FileManager.default.createDirectory(at: paceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((priorityMode == "gentle" ? "gentle" : "normal").utf8).write(to: paceFile, options: .atomic)
    }

    var resources: URL { Bundle.main.resourceURL! }
    var engine: URL { Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("StudioEngine") }
    var runtime: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audiobook Studio/Engine")
    }

    var hasBook: Bool { !book.isEmpty || !project.isEmpty }
    var canSaveProject: Bool {
        !project.isEmpty && FileManager.default.fileExists(atPath: project + "/roles/manifest.json")
    }
    private func closeDecision() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Сохранить текущий проект перед закрытием?"
        alert.informativeText = canSaveProject
            ? "Сохраните книгу, персонажей, голоса и готовое аудио в один файл, чтобы продолжить позже. Уже сохранённые файлы на диске не удаляются."
            : "Распознавание проекта ещё не завершено. Исходная книга и созданные файлы останутся на диске, но сохранить готовый проект пока нельзя."
        alert.addButton(withTitle: "Сохранить проект…").isEnabled = canSaveProject
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal()
    }
    private func stopThen(_ continuation: @escaping () -> Void) {
        if busy {
            afterStop = continuation
            cancel()
            status = "Остановка обработки перед закрытием проекта…"
        } else { continuation() }
    }
    func closeProject(after: (() -> Void)? = nil) {
        guard hasBook else { after?(); return }
        stopThen {
            switch self.closeDecision() {
            case .alertFirstButtonReturn:
                self.saveProject(after: { self.clearProject(); after?() })
            case .alertSecondButtonReturn:
                self.clearProject(); after?()
            default: break
            }
        }
    }
    private func clearProject() {
        audioPlayer?.stop(); audioPlayer = nil; playbackCompletion = nil; playingAudio = ""
        book = ""; project = ""; characters = []; segments = []; selected = nil
        dirty = false; rolesDirty = false; roleSearch = ""
        previewByCharacter = [:]; generatedSample = ""; generatedText = ""; generatedDescription = ""
        resultPath = ""; fraction = 0; speed = nil; eta = nil; completed = ""; error = nil
        bookCharacterCount = 0; remainingSynthesisSeconds = nil
        status = "Проект закрыт · выберите другую книгу"
    }
    func confirmApplicationExit() -> Bool {
        guard hasBook && !quitConfirmed else { return true }
        if busy {
            stopThen { NSApplication.shared.terminate(nil) }
            return false
        }
        switch closeDecision() {
        case .alertFirstButtonReturn:
            saveProject(after: { self.quitConfirmed = true; NSApplication.shared.terminate(nil) })
            return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func chooseBook() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        // EPUB, FB2 and zipped FB2 (.fb2.zip, .fbz); the engine checks the archive contents.
        panel.allowedContentTypes = ["epub", "fb2", "fbz"].compactMap { UTType(filenameExtension: $0) } + [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        closeProject {
            self.clearProject(); self.book = url.path
            self.status = "Книга выбрана · можно определить персонажей"
        }
    }

    func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { output = panel.url!.path }
    }

    func openProject() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        closeProject { self.openSelectedProject(url) }
    }
    private func openSelectedProject(_ url: URL) {
        if url.pathExtension == "audiobookstudio" {
            var r = request("project-open"); r["archive"] = url.path
            previewByCharacter = [:]; audioPlayer?.stop()
            launch(r); return
        }
        self.project = url.path; self.book = url.appendingPathComponent("book.epub").path
        previewByCharacter = [:]; audioPlayer?.stop()
        do { try loadProject(); status = "Проект открыт" }
        catch { self.error = "В этой папке нет готового проекта книги"; project = "" }
    }

    func saveProject(after: (() -> Void)? = nil) {
        guard canSaveProject, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "com.davnozdu.audiobook-studio.project", conformingTo: .zip)]
        panel.nameFieldStringValue = URL(fileURLWithPath: project).lastPathComponent + ".audiobookstudio"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveThen {
            var r = self.request("project-export"); r["destination"] = url.path
            r["settings"] = ["music": r["music"]!, "music_enabled": self.musicEnabled,
                "music_volume": self.musicVolume, "cloud_stress": self.cloudStress, "pauses": self.pauses]
            self.launch(r, after: after)
        }
    }

    func chooseMusic() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK { music = panel.url!.path }
    }

    func loadProject() throws {
        let url = URL(fileURLWithPath: project).appendingPathComponent("roles/manifest.json")
        let invalid = NSError(domain: "AudiobookStudio.Project", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Файл ролей проекта повреждён"])
        guard let data = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let voices = data["voices"] as? [[String: Any]], let roleRows = data["segments"] as? [[String: Any]],
              voices.allSatisfy({ $0["id"] is String && $0["name"] is String }),
              roleRows.allSatisfy({ $0["id"] is String && $0["text"] is String }) else { throw invalid }
        characters = voices.map { v in
            let p = v["character_profile"] as? [String: Any] ?? [:]
            let sample = v["custom_reference"] as? [String: Any] ?? [:]
            return StoryCharacter(id: v["id"] as! String, name: v["name"] as! String,
                age: v["age"] as? String ?? "unknown", personality: p["personality"] as? String ?? "",
                habits: p["habits"] as? String ?? "", speakingStyle: p["speaking_style"] as? String ?? "",
                voice: v["voice_description"] as? String ?? "", certainty: p["certainty"] as? String ?? "low",
                assumptions: p["assumptions"] as? [String] ?? [], evidence: p["evidence"] as? [[String: String]] ?? [],
                sample: sample["path"] as? String ?? "", sampleText: sample["text"] as? String ?? "",
                voiceGender: v["voice_gender"] as? String ?? "male", seed: v["seed"] as? Int ?? 17001)
        }
        bookCharacterCount = roleRows.reduce(0) { $0 + ( $1["text"] as? String ?? "").count }
        segments = roleRows.map { s in
            RoleSegment(id: s["id"] as! String, text: s["text"] as! String,
                speaker: s["speaker"] as? String ?? "", originalSpeaker: s["speaker"] as? String ?? "",
                needsReview: s["needs_review"] as? Bool ?? false)
        }
        if selected == nil || !characters.contains(where: { $0.id == selected }) { selected = characters.first?.id }
        dirty = false; rolesDirty = false
    }

    func request(_ action: String) -> [String: Any] {
        writePace()
        return ["action": action, "pace_file": paceFile.path, "book": book, "project": project, "output": output,
         "runtime": runtime.path, "resources": resources.appendingPathComponent("engine").path,
         "ffmpeg": resources.appendingPathComponent("runtime/bin/ffmpeg").path, "ffprobe": resources.appendingPathComponent("runtime/bin/ffprobe").path, "key": key, "model": model,
         "llm_provider": llmProvider, "deepseek_key": deepseekKey, "deepseek_model": deepseekModel,
         "web_search": webSearch, "cloud_stress": cloudStress,
         "music": music.isEmpty ? resources.appendingPathComponent("engine/resources/" + bundledMusic).path : music,
         "music_enabled": musicEnabled, "music_volume": musicVolume, "pauses": pauses, "level_emotions": levelEmotions,
         "stress_dictionary": stressDictionary]
    }

    func prepare() { launch(request("prepare")) }
    func automaticBuild() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            settings = true; status = "Укажите ключ LLM для автоматической сборки"; return
        }
        guard let destination = chooseBuildDestination() else { return }
        if project.isEmpty {
            var r = request("prepare"); r["automatic"] = true
            launch(r, after: { self.build(destination: destination) })
        } else if segments.contains(where: { $0.speaker.isEmpty }) || characters.contains(where: { $0.age.isEmpty || $0.voice.isEmpty || $0.personality.isEmpty || $0.habits.isEmpty || $0.speakingStyle.isEmpty }) {
            saveThen {
                var r = self.request("characters"); r["automatic"] = true
                self.launch(r, after: { self.build(destination: destination) })
            }
        } else { build(destination: destination) }
    }
    func analyze() { saveThen { self.launch(self.request("characters")) } }

    func saveThen(_ continuation: @escaping () -> Void) {
        if dirty || rolesDirty { save(after: continuation) } else { continuation() }
    }

    func saveRoles(after: (() -> Void)? = nil) {
        if dirty { save(after: after); return }
        var r = request("roles-save")
        r["edits"] = Dictionary(uniqueKeysWithValues: segments.filter { $0.speaker != $0.originalSpeaker }.map { ($0.id, $0.speaker) })
        launch(r, after: after)
    }

    func save(after: (() -> Void)? = nil) {
        do {
            let url = URL(fileURLWithPath: project).appendingPathComponent("roles/manifest.json")
            let m = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let book = m["book"] as! [String: Any]
            var r = request("save")
            r["edits"] = Dictionary(uniqueKeysWithValues: segments.filter { $0.speaker != $0.originalSpeaker }.map { ($0.id, $0.speaker) })
            r["profiles"] = ["input_sha256": book["input_sha256"]!, "characters": characters.map(\.profile)]
            launch(r, after: after)
        } catch { self.error = error.localizedDescription }
    }

    func chooseBuildDestination() -> String? {
        let panel = NSSavePanel()
        panel.title = "Куда сохранить аудиокнигу?"
        panel.message = "Будет создана папка с двумя файлами: M4B и EPUB, названными по автору и названию книги. Укажите имя папки и место сохранения."
        panel.prompt = "Создать папку и собрать"
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "buildOutputFolder") ?? output)
        panel.nameFieldStringValue = bookBase().isEmpty
            ? URL(fileURLWithPath: book).deletingPathExtension().lastPathComponent + " — аудиокнига" : bookBase()
        // An existing folder was confirmed with «Заменить» in the panel; the engine moves it to the
        // Trash only after the new book is assembled, so a failed build keeps it.
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "buildOutputFolder")
        resultPath = url.path
        return url.path
    }

    /// "Автор - Название" from the project's book metadata, as the files will be named.
    func bookBase() -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: project).appendingPathComponent("roles/manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let book = manifest["book"] as? [String: Any] else { return "" }
        return CloudClient.bookBase(title: book["title"] as? String ?? "", author: book["author"] as? String ?? "")
    }

    func build(destination: String? = nil) {
        guard let destination = destination ?? chooseBuildDestination() else { return }
        saveThen {
            var r = self.request("build"); r["destination"] = destination; r["named_files"] = true
            r["replace"] = FileManager.default.fileExists(atPath: destination)
            self.launch(r)
        }
    }

    func uploadSample(_ index: Int) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = characters[index].sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty,
           let data = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")),
           let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            text = metadata["text"] as? String ?? ""
            characters[index].sampleText = text
        }
        guard !text.isEmpty else { error = "Введите точный текст, произнесённый в образце, и повторите загрузку"; return }
        let cid = characters[index].id
        saveThen {
            var r = self.request("sample"); r["character"] = cid; r["text"] = text; r["sample"] = url.path
            self.launch(r)
        }
    }

    func removeSample(_ index: Int) {
        var r = request("sample"); r["character"] = characters[index].id; r["remove"] = true
        launch(r)
    }

    func generateVoice(character: String = "", description: String? = nil, text: String? = nil, seed: Int? = nil, autoplay: Bool = false) {
        generatedSample = ""
        var r = request("voice-preview")
        r["description"] = description ?? voiceDescription
        r["text"] = text ?? voiceTestText
        r["character"] = character; r["seed"] = voiceSeed
        if let c = characters.first(where: { $0.id == character }) { r["seed"] = seed ?? c.seed }
        launch(r, after: autoplay ? { [weak self] in self?.listenGenerated() } : nil)
    }

    /// Variant 0 is the voice the build uses; other variants are kept only via «Использовать для персонажа».
    var previewVariants: [String: Int] = [:]
    func previewCharacter(_ index: Int, another: Bool = false) {
        let c = characters[index]
        let variant = another ? (previewVariants[c.id] ?? 0) + 1 : 0
        previewVariants[c.id] = variant
        saveThen {
            if let current = self.characters.first(where: { $0.id == c.id }) {
                self.generateVoice(character: current.id, description: current.voice,
                                   seed: current.seed + variant * 7919, autoplay: true)
            }
        }
    }

    func listenGenerated() {
        if !generatedSample.isEmpty { playAudio(generatedSample) }
    }

    func playAudio(_ path: String) {
        if playingAudio == path, audioPlayer?.isPlaying == true {
            audioPlayer?.stop(); audioPlayer = nil; playbackCompletion = nil; playingAudio = ""
            status = "Воспроизведение остановлено"; return
        }
        do {
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            playingAudio = path
            guard let player = audioPlayer, player.prepareToPlay(), player.play() else {
                throw NSError(domain: "AudiobookStudio.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Аудиоустройство не начало воспроизведение"])
            }
            let completion = PlaybackCompletion()
            completion.finished = { [weak self, weak player] in
                guard let self, let player, self.audioPlayer === player else { return }
                self.audioPlayer = nil; self.playbackCompletion = nil; self.playingAudio = ""
                if !self.busy { self.status = "Образец прослушан · аудиобуфер освобождён" }
            }
            playbackCompletion = completion; player.delegate = completion
            status = "Воспроизведение образца · \(Int(ceil(player.duration))) секунд"
            appendLog("Воспроизведение образца: " + URL(fileURLWithPath: path).lastPathComponent)
        } catch { self.error = "Не удалось воспроизвести образец: \(error.localizedDescription)"; status = self.error!; appendLog(status) }
    }

    func usePreview(_ index: Int, sample: String) {
        do {
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sample).deletingPathExtension().appendingPathExtension("json"))) as! [String: Any]
            let text = metadata["text"] as! String, cid = characters[index].id
            saveThen {
                var r = self.request("sample"); r["character"] = cid; r["text"] = text; r["sample"] = sample
                self.launch(r)
            }
        } catch { self.error = "Не найден текст пробы голоса" }
    }

    func saveGenerated() {
        guard !generatedSample.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]; panel.nameFieldStringValue = "Мой голос.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: generatedSample))
            try data.write(to: url, options: .atomic)
            let sidecar = try JSONSerialization.data(withJSONObject: ["text": generatedText, "description": generatedDescription], options: [.prettyPrinted, .sortedKeys])
            try sidecar.write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            status = "Образец WAV и текст сохранены на диск"
        } catch { self.error = error.localizedDescription }
    }

    func launch(_ request: [String: Any], after: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true; cancelling = false; receivedError = false; pending = after
        childPIDs.removeAll(); updateMenuBar()
        fraction = 0; speed = nil; eta = nil; completed = ""; buffer = Data()
        if request["action"] as? String == "build" { remainingSynthesisSeconds = nil }
        syncWake()
        status = "Подготовка…"
        let p = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let eventReadLock = NSLock()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookStudio-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true) }
        catch { busy = false; pending = nil; syncWake(); self.error = error.localizedDescription; return }
        p.executableURL = engine
        p.qualityOfService = .userInitiated
        p.arguments = []
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "OLLAMA_API_KEY")
        env["TMPDIR"] = temporary.path + "/"
        env["AUDIOBOOK_FFMPEG"] = resources.appendingPathComponent("runtime/bin/ffmpeg").path
        env["AUDIOBOOK_FFPROBE"] = resources.appendingPathComponent("runtime/bin/ffprobe").path
        p.environment = env; p.standardInput = input; p.standardOutput = output; p.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in
            eventReadLock.lock(); defer { eventReadLock.unlock() }
            let data = handle.availableData
            if !data.isEmpty { DispatchQueue.main.async { self.consume(data) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { self.appendLog(self.redacted(text)) }
            }
        }
        p.terminationHandler = { process in
            try? FileManager.default.removeItem(at: temporary)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.1) {
                try? FileManager.default.removeItem(at: temporary)
            }
            if request["action"] as? String == "build", let path = request["project"] as? String, !path.isEmpty {
                for name in ["audio-normalized", "audio-music", "audio/sample.wav", "result/chapters.txt"] {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).appendingPathComponent(name))
                }
            }
            eventReadLock.lock(); defer { eventReadLock.unlock() }
            output.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            errors.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.consume(rest)
                self.busy = false; self.process = nil; self.childPIDs.removeAll(); self.updateMenuBar()
                self.syncWake()
                self.appendLog("Движок завершён · память моделей и GPU освобождена")
                let next = self.pending; self.pending = nil
                if self.shuttingDown { return }
                if let continuation = self.afterStop {
                    self.afterStop = nil; self.cancelling = false
                    continuation(); return
                }
                if self.cancelling { self.status = "Операция остановлена"; return }
                if process.terminationStatus != 0 {
                    if !self.receivedError { self.error = "Движок завершился с ошибкой. См. журнал." }
                    return
                }
                self.fraction = 1
                if !self.project.isEmpty && ["prepare", "characters", "save", "roles-save", "sample"].contains(request["action"] as? String ?? "") { try? self.loadProject() }
                if request["action"] as? String == "project-open" {
                    do {
                        try self.loadProject()
                        self.book = URL(fileURLWithPath: self.project).appendingPathComponent("book.epub").path
                        let url = URL(fileURLWithPath: self.project).appendingPathComponent("studio-settings.json")
                        if let data = try? Data(contentsOf: url), let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            self.music = settings["music"] as? String ?? ""
                            self.musicEnabled = settings["music_enabled"] as? Bool ?? true
                            self.musicVolume = settings["music_volume"] as? Double ?? 5
                            self.cloudStress = settings["cloud_stress"] as? Bool ?? false
                            if let saved = settings["pauses"] as? [String: Int] { self.pauses = Studio.pauseDefaults.merging(saved) { _, v in v } }
                        }
                    } catch { self.error = "Не удалось открыть проект: \(error.localizedDescription)" }
                }
                next?()
            }
        }
        do {
            try p.run(); process = p; applyPriority()
            let data = try JSONSerialization.data(withJSONObject: request)
            try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
            try input.fileHandleForWriting.close()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            pending = nil; receivedError = true
            self.error = "Не удалось запустить встроенный движок: \(error.localizedDescription)"
            if p.processIdentifier > 0 {
                // A launched worker owns busy until its termination handler drains the pipes.
                stopProcessGroup()
            } else {
                p.terminationHandler = nil
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                for pipe in [input, output, errors] {
                    try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
                }
                process = nil; busy = false; syncWake()
            }
        }
    }
    static func onMainsPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMACPowerKey
    }
    /// Re-evaluated every 30 s while busy, so unplugging releases the assertion and plugging in restores it.
    func syncWake() {
        let hold = busy && Self.onMainsPower()
        if hold, wakeActivity == nil {
            wakeActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                 reason: "Audiobook Studio: обработка книги от сети")
        } else if !hold, let activity = wakeActivity {
            ProcessInfo.processInfo.endActivity(activity); wakeActivity = nil
        }
        if busy, powerCheck == nil {
            powerCheck = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.syncWake() }
            }
        } else if !busy { powerCheck?.invalidate(); powerCheck = nil }
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "sample":
                generatedSample = event["path"] as? String ?? ""
                generatedText = event["text"] as? String ?? ""
                generatedDescription = event["description"] as? String ?? ""
                if let cid = event["character"] as? String, !cid.isEmpty { previewByCharacter[cid] = generatedSample }
            case "child":
                if let n = event["pid"] as? NSNumber, n.int64Value > 1, n.int64Value <= Int64(Int32.max) {
                    if event["ended"] as? Bool == true { childPIDs.remove(n.int32Value) }
                    else { childPIDs.insert(n.int32Value) }
                }
                applyPriority()
            case "project": project = event["path"] as? String ?? project
            case "progress":
                status = event["message"] as? String ?? status; fraction = event["fraction"] as? Double ?? 0
                // Synthesis steps keep the last measured speed and remaining time on screen.
                if event["synthesis"] as? Bool != true { speed = nil; eta = nil }
            case "estimate":
                bookCharacterCount = event["characters"] as? Int ?? bookCharacterCount
            case "metrics":
                if let rate = event["seconds_per_character"] as? Double, rate.isFinite, rate > 0, rate < 60 {
                    UserDefaults.standard.set(rate, forKey: "nativeSynthesisSecondsPerCharacter")
                }
                remainingSynthesisSeconds = event["eta"] as? Double
                status = event["message"] as? String ?? status
                speed = event["speed"] as? Double; eta = event["eta"] as? Double
                fraction = event["fraction"] as? Double ?? 0
                completed = "\(event["completed"] ?? 0) / \(event["total"] ?? 0) фрагментов"
            case "log": appendLog(event["message"] as? String ?? "")
            case "error": receivedError = true; error = event["message"] as? String; status = "Требуется внимание"; appendLog(error ?? "Ошибка движка")
            case "result": resultPath = event["path"] as? String ?? resultPath
            case "done": status = event["message"] as? String ?? "Готово"; project = event["path"] as? String ?? project
            default: break
            }
        }
    }

    /// Keys never reach the visible log, whichever service they belong to.
    func redacted(_ text: String) -> String {
        [key, deepseekKey].filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") }
    }
    func appendLog(_ text: String) { log = String((log + text + "\n").suffix(24000)) }
    func cancel() {
        if remoteBusy { bot.cancelActive(); return }
        cancelling = true; pending = nil
        stopProcessGroup()
    }
    func stopProcessGroup() {
        guard let p = process, p.isRunning else { return }
        let pid = p.processIdentifier
        let children = childPIDs
        for child in children { kill(-child, SIGTERM); kill(child, SIGTERM) }
        kill(-pid, SIGTERM); p.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // NSTask creates separate process groups for the worker and its active child.
            for child in children { if kill(-child, 0) == 0 { kill(-child, SIGKILL) }; if kill(child, 0) == 0 { kill(child, SIGKILL) } }
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            if p.isRunning { p.interrupt(); kill(pid, SIGKILL) }
        }
    }
    func removeMenuBar() { menuBar.remove() }
    func shutdown() -> Bool {
        credentialSave?.cancel(); saveCredential()
        let remoteStopping = bot.shutdown()
        shuttingDown = true; cancelling = true; pending = nil
        audioPlayer?.stop(); audioPlayer = nil; playbackCompletion = nil
        removeMenuBar()
        guard process?.isRunning == true || remoteStopping else { return false }
        stopProcessGroup()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return true
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.07)))
    }
}

struct CharacterEditor: View {
    @ObservedObject var studio: Studio
    let index: Int
    var body: some View {
        let c = studio.characters[index]
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: c.id == "narrator" ? "book.closed.fill" : "person.fill")
                    .font(.title2).foregroundStyle(.indigo).padding(14).background(.indigo.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.name).font(.title2.bold())
                    Text(c.id == "narrator" ? "Голос повествования" : "Персонаж книги").foregroundStyle(.secondary)
                }
                Spacer()
                Text(c.certainty == "high" ? "Подтверждено" : c.certainty == "medium" ? "Есть предположения" : "Требует проверки")
                    .font(.caption).padding(8).background(.orange.opacity(0.12), in: Capsule())
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                GridRow {
                    field("Возраст", text: $studio.characters[index].age)
                    field("Характер", text: $studio.characters[index].personality)
                }
                GridRow {
                    field("Привычки", text: $studio.characters[index].habits)
                    field("Манера говорить", text: $studio.characters[index].speakingStyle)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Режиссура голоса · VoiceDesign").font(.subheadline.weight(.semibold))
                TextEditor(text: $studio.characters[index].voice).font(.body).frame(height: 85)
                    .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("Свой образец голоса", systemImage: "waveform").font(.headline)
                Text("Один голос без музыки, 3–30 секунд. Укажите точный текст записи.").font(.caption).foregroundStyle(.secondary)
                TextField("Текст, произнесённый в образце", text: $studio.characters[index].sampleText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                HStack {
                    Button("Загрузить свой образец…", systemImage: "arrow.up.doc") { studio.uploadSample(index) }
                    Button("Прослушать образец", systemImage: "play.fill") { studio.previewCharacter(index) }
                    if c.sample.isEmpty {
                        Button("Другой вариант голоса", systemImage: "dice") { studio.previewCharacter(index, another: true) }
                            .help("Тот же характер, другой голос. Понравившийся закрепите кнопкой «Использовать для персонажа»")
                    }
                    if !c.sample.isEmpty {
                        Button("Сгенерировать вместо образца") { studio.removeSample(index) }
                    }
                }
                if let sample = studio.previewByCharacter[c.id] {
                    HStack {
                        Button("Прослушать последнюю пробу") { studio.playAudio(sample) }
                        Button("Использовать для персонажа") { studio.usePreview(index, sample: sample) }
                        Button("Сохранить пробу на диск…") {
                            studio.generatedSample = sample
                            if let metadata = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sample).deletingPathExtension().appendingPathExtension("json"))) as? [String: Any] {
                                studio.generatedText = metadata["text"] as? String ?? ""
                                studio.generatedDescription = metadata["description"] as? String ?? ""
                            }
                            studio.saveGenerated()
                        }
                    }.font(.caption)
                }
                Text(c.sample.isEmpty ? "Голос будет создан нейросетью по описанию" : "Используется ваш образец: \(URL(fileURLWithPath: c.sample).lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !c.evidence.isEmpty {
                DisclosureGroup("Основания и предположения") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(c.evidence.enumerated()), id: \.offset) { _, item in
                            Text("\(item["reference"] ?? ""): \(item["note"] ?? "")").font(.caption).textSelection(.enabled)
                        }
                        ForEach(c.assumptions, id: \.self) { Text("Предположение: \($0)").font(.caption).foregroundStyle(.orange) }
                    }.padding(.top, 8)
                }
            }
        }
        .onChange(of: studio.characters[index].age) { studio.dirty = true }
        .onChange(of: studio.characters[index].personality) { studio.dirty = true }
        .onChange(of: studio.characters[index].habits) { studio.dirty = true }
        .onChange(of: studio.characters[index].speakingStyle) { studio.dirty = true }
        .onChange(of: studio.characters[index].voice) { studio.dirty = true }
    }

    func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold))
            TextField("Определит LLM", text: text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...3)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ContentView: View {
    @ObservedObject var studio: Studio
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Audiobook Studio", systemImage: "waveform.circle.fill").font(.title3.bold()).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 18) {
                    step("1", "Книга", done: !studio.book.isEmpty)
                    step("2", "Персонажи и роли", done: !studio.characters.isEmpty)
                    step("3", "Характеры и голоса", done: studio.characters.contains { !$0.personality.isEmpty })
                    step("4", "Аудиокнига и EPUB", done: FileManager.default.fileExists(atPath: studio.project + "/result/audiobook.m4b"))
                }
                Divider()
                Text(studio.characters.isEmpty ? "Персонажи появятся после анализа книги" : "\(studio.characters.count) персонажей · карточки в основном списке")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Автоматическая сборка проходит все этапы. Для подробной настройки раскройте карточку нужного персонажа.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Генератор голосов", systemImage: "waveform.badge.mic") { studio.voiceLabOpen = true }.disabled(studio.busy)
                Button("Настройки LLM", systemImage: "slider.horizontal.3") { studio.settings = true }
                Text("Apple Silicon · локальная озвучка").font(.caption2).foregroundStyle(.secondary)
            }.padding(22).frame(minWidth: 235, idealWidth: 245, maxWidth: 285)
                .background(.ultraThinMaterial)
            VStack(spacing: 0) {
                if studio.hasBook {
                    HStack {
                        Label(URL(fileURLWithPath: studio.book).deletingPathExtension().lastPathComponent, systemImage: "book.closed")
                            .font(.subheadline).lineLimit(1)
                        Spacer()
                        Button("Закрыть проект", systemImage: "xmark.circle") { studio.closeProject() }
                    }.padding(.horizontal, 28).padding(.vertical, 12).background(.bar)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("У каждой истории — свои голоса").font(.largeTitle.bold())
                                Text("От книги к многоголосной аудиокниге").font(.title3).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Открыть проект…") { studio.openProject() }
                            Button("Сохранить проект…") { studio.saveProject() }.disabled(studio.project.isEmpty || studio.busy)
                        }.padding(.bottom, 4)
                        Card {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: "books.vertical.fill").font(.system(size: 34)).foregroundStyle(.indigo)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(studio.book.isEmpty ? "Выберите вашу историю" : URL(fileURLWithPath: studio.book).deletingPathExtension().lastPathComponent).font(.title2.bold())
                                        Text("EPUB · многоголосная озвучка и синхронное чтение").foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Выбрать книгу…") { studio.chooseBook() }
                                }
                                if !studio.bookEstimate.isEmpty {
                                    Label(studio.bookEstimate, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                                    Text("Оценка относится к синтезу речи. Загрузка моделей, создание голосов и упаковка занимают дополнительное время.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Собрать автоматически", systemImage: "wand.and.stars") { studio.automaticBuild() }
                                    .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.large).disabled(studio.book.isEmpty)
                                Text("Персонажи, характеры, голоса, M4B и EPUB — по очереди, без ручного заполнения карточек.")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Определить персонажей и расставить роли", systemImage: "person.2") { studio.prepare() }
                                        .buttonStyle(.borderedProminent).tint(.indigo).disabled(studio.book.isEmpty || !studio.project.isEmpty)
                                    Button("Определить характеры персонажей", systemImage: "sparkles") { studio.analyze() }
                                        .disabled(studio.characters.isEmpty)
                                }
                                if studio.project.isEmpty {
                                    HStack {
                                        Text("Рабочие проекты: \(studio.output)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Button("Изменить…") { studio.chooseOutput() }
                                    }
                                }
                            }
                        }
                        if !studio.segments.isEmpty {
                            Card {
                                DisclosureGroup("Проверить и уточнить говорящих · \(studio.segments.count) фрагментов") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            TextField("Найти реплику…", text: $studio.roleSearch).textFieldStyle(.roundedBorder)
                                            Toggle("Требуют проверки", isOn: $studio.reviewOnly)
                                        }
                                        let indices = studio.segments.indices.filter {
                                            (!studio.reviewOnly || studio.segments[$0].needsReview || studio.segments[$0].speaker.isEmpty) &&
                                            (studio.roleSearch.isEmpty || studio.segments[$0].text.localizedCaseInsensitiveContains(studio.roleSearch))
                                        }
                                        ForEach(Array(indices.prefix(100)), id: \.self) { i in
                                            HStack(alignment: .top, spacing: 12) {
                                                Text(studio.segments[i].text).font(.subheadline).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                                Picker("Говорящий", selection: $studio.segments[i].speaker) {
                                                    Text("Не определён").tag("")
                                                    ForEach(studio.characters) { Text($0.name).tag($0.id) }
                                                }.labelsHidden().frame(width: 190)
                                                    .onChange(of: studio.segments[i].speaker) { studio.rolesDirty = true }
                                            }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                                        }
                                        if indices.isEmpty { Text("Фрагментов для проверки нет").foregroundStyle(.secondary) }
                                        if indices.count > 100 { Text("Показаны первые 100. Уточните поиск, чтобы найти нужную реплику.").font(.caption).foregroundStyle(.secondary) }
                                        Button("Сохранить назначения ролей") { studio.saveRoles() }.disabled(!studio.rolesDirty)
                                    }.padding(.top, 12)
                                }
                            }
                        }
                        if !studio.characters.isEmpty {
                            Text("Персонажи и голоса · \(studio.characters.count)").font(.title2.bold())
                            Text("Карточки заполняются автоматически. Раскройте персонажа, чтобы уточнить характер или изменить голос.").foregroundStyle(.secondary)
                            ForEach(studio.characters.indices, id: \.self) { index in
                                Card {
                                    DisclosureGroup {
                                        CharacterEditor(studio: studio, index: index).padding(.top, 16)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: studio.characters[index].id == "narrator" ? "book.closed.fill" : "person.fill").foregroundStyle(.indigo)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(studio.characters[index].name).font(.headline)
                                                Text(studio.characters[index].personality.isEmpty ? "Описание голоса готово · характер ещё не определён" : studio.characters[index].personality)
                                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            Spacer()
                                            Text(studio.characters[index].sample.isEmpty ? "Голос нейросети" : "Свой образец").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            HStack {
                                Text(studio.dirty ? "Есть несохранённые изменения" : "Карточки сохранены в проекте книги").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Сохранить карточки") { studio.save() }.disabled(!studio.dirty)
                            }
                        } else {
                            Card {
                                VStack(spacing: 12) {
                                    Image(systemName: "person.crop.rectangle.stack").font(.system(size: 42)).foregroundStyle(.indigo.opacity(0.65))
                                    Text("Здесь появятся персонажи книги").font(.title3.bold())
                                    Text("LLM сопоставит реплики, сохранит роли и подготовит голоса. Затем вы сможете уточнить характеры и загрузить свои образцы.")
                                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 550)
                                }.frame(maxWidth: .infinity).padding(.vertical, 28)
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Label("Фоновая музыка", systemImage: "music.note").font(.headline)
                                    Spacer()
                                    Toggle("Включена", isOn: $studio.musicEnabled).toggleStyle(.switch)
                                }
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Picker("Композиция", selection: $studio.bundledMusic) {
                                            ForEach(studio.musicTracks) { track in Text(track.title).tag(track.filename) }
                                        }.labelsHidden().frame(minWidth: 240)
                                            .onChange(of: studio.bundledMusic) { studio.music = "" }
                                        if !studio.music.isEmpty { Text(URL(fileURLWithPath: studio.music).lastPathComponent).font(.subheadline.weight(.semibold)) }
                                        Text("Зацикливается до конца книги").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Загрузить свой трек…") { studio.chooseMusic() }
                                    if !studio.music.isEmpty { Button("Штатный трек") { studio.music = "" } }
                                }.disabled(!studio.musicEnabled)
                                HStack {
                                    Text("Громкость фона").font(.caption)
                                    Slider(value: $studio.musicVolume, in: 0...25, step: 1).frame(maxWidth: 280)
                                    Text("\(Int(studio.musicVolume))%") .monospacedDigit()
                                }.disabled(!studio.musicEnabled)
                                Divider()
                                HStack(alignment: .top) {
                                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                                    Text("Словарь + Silero · нормализация громкости · синхронизация по предложениям").font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Собрать аудиокнигу и наложить на EPUB", systemImage: "waveform.badge.plus") { studio.build() }
                                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.indigo).disabled(studio.characters.isEmpty)
                                Text(studio.resultPath.isEmpty ? "Перед сборкой выберите, где создать папку с M4B и EPUB. Модели скачиваются автоматически." : "Аудиокнига и EPUB: " + studio.resultPath)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(28).disabled(studio.busy)
                }.background(Color(nsColor: .windowBackgroundColor))
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        if studio.busy { ProgressView().controlSize(.small) }
                        Text(studio.status).font(.subheadline.weight(.medium)).lineLimit(2)
                        Spacer()
                        if let speed = studio.speed { Text(String(format: "%.2f×", speed)).font(.title3.bold()).monospacedDigit() }
                        if let eta = studio.eta { Text("Осталось ≈ \(Int(ceil(eta / 60))) мин синтеза").foregroundStyle(.secondary).monospacedDigit() }
                        if studio.busy { Button("Остановить") { studio.cancel() } }
                    }
                    HStack {
                        Text("Приоритет").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
                        Picker("Приоритет", selection: $studio.priorityMode) {
                            Text("Обычный").tag("normal")
                            Text("Щадящий").tag("gentle")
                            Text("Фоновый").tag("background")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                        Spacer()
                    }
                    if studio.busy {
                        ProgressView(value: studio.fraction).tint(.indigo)
                        Text(studio.completed.isEmpty ? "Один запрос к LLM за раз" : studio.completed + " · оценка по последним фрагментам").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(studio.showLog ? "Скрыть журнал" : "Журнал") { studio.showLog.toggle() }
                        if !studio.updateStatus.isEmpty {
                            Text(studio.updateStatus).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(studio.updateStatus)
                        }
                        Spacer()
                        if !studio.project.isEmpty {
                            if !studio.resultPath.isEmpty {
                                Button("Папка аудиокниги", systemImage: "folder.fill") { NSWorkspace.shared.open(URL(fileURLWithPath: studio.resultPath)) }
                            }
                            Button("Папка проекта", systemImage: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: studio.project)) }
                        }
                    }.font(.caption)
                    if studio.showLog { ScrollView { Text(studio.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 130) }
                }.padding(20).background(.bar)
            }.frame(minWidth: 760)
        }.frame(minWidth: 1050, minHeight: 780)
            .background(ProjectWindowCloseHandler(studio: studio).frame(width: 0, height: 0))
            .sheet(isPresented: $studio.settings) { SettingsView(studio: studio) }
            .sheet(isPresented: $studio.voiceLabOpen) { VoiceLabView(studio: studio) }
            .alert("Требуется внимание", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
                Button("Понятно") { studio.error = nil }
            } message: { Text(studio.error ?? "") }
    }
    func step(_ number: String, _ title: String, done: Bool) -> some View {
        HStack(spacing: 12) {
            Text(done ? "✓" : number).font(.caption.bold()).frame(width: 26, height: 26)
                .background(done ? Color.indigo : Color.secondary.opacity(0.15), in: Circle()).foregroundStyle(done ? .white : .primary)
            Text(title).font(.subheadline.weight(.medium))
        }
    }
}

struct VoiceLabView: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Генератор голосов", systemImage: "waveform.badge.mic").font(.title2.bold())
                Spacer()
                Button("Закрыть") { studio.voiceLabOpen = false }
            }
            Text("Создайте голос отдельно от книги. Опишите возраст, тембр, высоту и манеру говорить, затем введите свой текст. Английское описание передаётся модели напрямую; русское сначала переводится через LLM.").foregroundStyle(.secondary)
            Text("Описание голоса").font(.headline)
            TextEditor(text: $studio.voiceDescription).font(.body).frame(height: 110).padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10)).disabled(studio.busy)
            Text("Тестовый текст · 20–1000 символов").font(.headline)
            TextEditor(text: $studio.voiceTestText).font(.body).frame(height: 90).padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10)).disabled(studio.busy)
            HStack {
                Button("Запустить конструктор для генерации", systemImage: "sparkles") { studio.generateVoice() }
                    .buttonStyle(.borderedProminent).tint(.indigo).disabled(studio.busy)
                Stepper("Вариант \(studio.voiceSeed)", value: $studio.voiceSeed, in: 1...99999).disabled(studio.busy)
            }
            if studio.busy {
                HStack { ProgressView().controlSize(.small); Text(studio.status); Spacer(); Button("Остановить") { studio.cancel() } }
            }
            if !studio.generatedSample.isEmpty {
                Divider()
                HStack {
                    Button("Прослушать образец", systemImage: "play.fill") { studio.listenGenerated() }
                    Button("Сохранить образец на диск…", systemImage: "square.and.arrow.down") { studio.saveGenerated() }
                }.disabled(studio.busy)
                Text("При сохранении создаются WAV и JSON с точным текстом. Затем загрузите WAV в карточку нужного персонажа.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Загружается только VoiceDesign. Основная модель озвучки не запускается; после генерации модель выгружается.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(30).frame(width: 680)
    }
}

struct SettingsView: View {
    @ObservedObject var studio: Studio
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("Режиссёр вашей аудиокниги").font(.title2.bold())
            Picker("Сервис LLM", selection: $studio.llmProvider) {
                Text("Ollama Cloud").tag("ollama")
                Text("DeepSeek · официальный API").tag("deepseek")
            }.pickerStyle(.segmented)
            Text("Запросы выполняются последовательно.").foregroundStyle(.secondary)
            if studio.llmProvider == "deepseek" {
                SecureField("DeepSeek API key", text: $studio.deepseekKey).textFieldStyle(.roundedBorder)
                TextField("Модель DeepSeek", text: $studio.deepseekModel).textFieldStyle(.roundedBorder)
                Text("deepseek-flash — быстрая, deepseek-v4-pro — сильнее и дороже. Режим рассуждений отключён.").font(.caption).foregroundStyle(.secondary)
                SecureField("Ollama API key (только для веб-поиска, необязательно)", text: $studio.key).textFieldStyle(.roundedBorder)
            } else {
                SecureField("Ollama API key", text: $studio.key).textFieldStyle(.roundedBorder)
                TextField("Модель", text: $studio.model).textFieldStyle(.roundedBorder)
            }
            Text(studio.keyStorageStatus).font(.caption).foregroundStyle(.secondary)
            Toggle("Разрешить веб-поиск при анализе характеров", isOn: $studio.webSearch)
            Toggle("LLM проверяет спорные ударения", isOn: $studio.cloudStress)
            Text("Мой словарь ударений").font(.subheadline)
            TextEditor(text: $studio.stressDictionary)
                .font(.body.monospaced()).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            Text("По слову в строке, со знаком ударения над гласной (за́мок) или с буквой ё. Эти ударения важнее словаря и модели во всех книгах.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Для ролей и характеров текст книги отправляется в " + (studio.llmProvider == "deepseek" ? "DeepSeek" : "Ollama") + ". Озвучка выполняется локально на Mac.").font(.caption).foregroundStyle(.secondary)
            Divider()
            BotSettingsView(bot: studio.bot)
            Divider()
            Text("Громкость").font(.headline)
            Toggle("Ровная громкость реплик", isOn: $studio.levelEmotions)
            Text(studio.levelEmotions
                 ? "Каждая реплика звучит на обычной громкости своего персонажа: тихие фразы не проваливаются, шёпот слышен как шёпот, но разборчиво, крик чуть громче (+3 дБ)."
                 : "Громкость каждой реплики как у модели: крик может быть заметно громче, шёпот — тише. Голоса персонажей между собой выравниваются всегда.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Паузы при чтении").font(.headline)
            Text("Тишина, которую приложение добавляет между фрагментами. Внутри фразы паузы на запятых делает сама модель; её собственная тишина на краях реплики звучит сверх этих значений.").font(.caption).foregroundStyle(.secondary)
            ForEach([("comma", "Внутри предложения одного голоса (запятая)"), ("speaker", "Смена голоса, не меньше («— сказал он, —»)"),
                     ("sentence", "Между предложениями"), ("paragraph", "Между абзацами"), ("chapter", "После главы")], id: \.0) { key, title in
                Stepper(value: Binding(get: { studio.pauses[key] ?? Studio.pauseDefaults[key]! },
                                       set: { studio.pauses[key] = $0 }), in: 0...5000, step: 50) {
                    Text("\(title): \(studio.pauses[key] ?? Studio.pauseDefaults[key]!) мс")
                }
            }
            Text("Когда один персонаж сменяет другого, пауза не бывает короче значения «Смена голоса»; после двоеточия перед чужой репликой — как между предложениями. Изменение пауз не требует новой озвучки: при следующей сборке пересобирается только монтаж.").font(.caption).foregroundStyle(.secondary)
            Button("Паузы по умолчанию") { studio.pauses = Studio.pauseDefaults }.disabled(studio.pauses == Studio.pauseDefaults)
            Divider()
            Text("Поведение приложения").font(.headline)
            Toggle("Показывать значок в Dock", isOn: $studio.showDock)
            Toggle("Показывать значок в верхней панели", isOn: $studio.showMenuBar)
            Text("Один значок всегда остаётся доступным, чтобы вернуться к приложению.").font(.caption).foregroundStyle(.secondary)
            Picker("Режим сборки", selection: $studio.priorityMode) {
                Text("Обычный").tag("normal")
                Text("Щадящий").tag("gentle")
                Text("Фоновый").tag("background")
            }.pickerStyle(.segmented)
            Text(studio.priorityMode == "gentle"
                 ? "Щадящий: во время озвучки движок после каждого шага ненадолго отдаёт видеокарту экрану и другим программам. Работать комфортнее, озвучка примерно на треть медленнее."
                 : studio.priorityMode == "background"
                 ? "Фоновый: движок уходит на энергоэффективные ядра с низшим приоритетом. Озвучка в 2–2,5 раза медленнее; память и видеокарта заняты как обычно."
                 : "Обычный: полная скорость озвучки.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Режим действует только пока идёт сборка и переключается на ходу; в простое ничего не происходит.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Обновления").font(.headline)
            if !studio.updateStatus.isEmpty { Text(studio.updateStatus).font(.caption).foregroundStyle(.secondary) }
            Toggle("Автоматически проверять обновления", isOn: Binding(get: { studio.updater.updater.automaticallyChecksForUpdates }, set: { studio.updater.updater.automaticallyChecksForUpdates = $0 }))
            Button("Проверить обновления…") { studio.updater.checkForUpdates(nil) }
            HStack { Spacer(); Button("Готово") { studio.settings = false }.buttonStyle(.borderedProminent) }
        }.padding(30)
        }.frame(width: 560, height: 690)
    }
}

@main struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var studio = Studio()
    var body: some Scene {
        WindowGroup { ContentView(studio: studio).tint(.indigo) }
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Открыть проект…") { studio.openProject() }.keyboardShortcut("o").disabled(studio.busy)
                    Button("Сохранить проект…") { studio.saveProject() }.keyboardShortcut("s").disabled(!studio.canSaveProject || studio.busy)
                    Button("Закрыть проект") { studio.closeProject() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(!studio.hasBook)
                }
                CommandGroup(after: .appInfo) {
                    Button("Проверить обновления…") { studio.updater.checkForUpdates(nil) }.disabled(studio.busy)
                }
            }
    }
}
