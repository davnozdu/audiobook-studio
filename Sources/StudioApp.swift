import SwiftUI
import AppKit
import Foundation
import Sparkle

struct Character: Identifiable {
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
    @Published var output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Audiobook Studio").path
    @Published var characters: [Character] = []
    @Published var selected: String?
    @Published var busy = false
    @Published var status = "Выберите книгу, чтобы начать"
    @Published var fraction = 0.0
    @Published var speed: Double?
    @Published var eta: Double?
    @Published var completed = ""
    @Published var log = ""
    @Published var error: String?
    @Published var key = ""
    @Published var model = "deepseek-v4.1-flash"
    @Published var webSearch = false
    @Published var cloudStress = false
    @Published var musicEnabled = true
    @Published var music = ""
    @Published var musicVolume = 5.0
    @Published var settings = false
    @Published var dirty = false
    @Published var showLog = false
    private var process: Process?
    private var pending: (() -> Void)?
    private var cancelling = false
    private var receivedError = false
    private var buffer = Data()
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var resources: URL { Bundle.main.resourceURL! }
    var python: String { resources.appendingPathComponent("runtime/python/bin/python3").path }
    var runtime: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audiobook Studio/Engine")
    }

    func chooseBook() {
        let panel = NSOpenPanel(); panel.allowedFileTypes = ["epub"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        book = url.path; project = ""; characters = []; selected = nil; dirty = false
        status = "Книга выбрана · можно определить персонажей"
    }

    func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { output = panel.url!.path }
    }

    func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project = url.path; book = url.appendingPathComponent("book.epub").path
        do { try loadProject(); status = "Проект открыт" }
        catch { self.error = "В этой папке нет готового проекта книги"; project = "" }
    }

    func chooseMusic() {
        let panel = NSOpenPanel(); panel.allowedFileTypes = ["mp3", "wav", "m4a", "flac", "aiff", "ogg"]
        if panel.runModal() == .OK { music = panel.url!.path }
    }

    func loadProject() throws {
        let url = URL(fileURLWithPath: project).appendingPathComponent("roles/manifest.json")
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        characters = (data["voices"] as! [[String: Any]]).map { v in
            let p = v["character_profile"] as? [String: Any] ?? [:]
            let sample = v["custom_reference"] as? [String: Any] ?? [:]
            return Character(id: v["id"] as! String, name: v["name"] as! String,
                age: v["age"] as? String ?? "unknown", personality: p["personality"] as? String ?? "",
                habits: p["habits"] as? String ?? "", speakingStyle: p["speaking_style"] as? String ?? "",
                voice: v["voice_description"] as? String ?? "", certainty: p["certainty"] as? String ?? "low",
                assumptions: p["assumptions"] as? [String] ?? [], evidence: p["evidence"] as? [[String: String]] ?? [],
                sample: sample["path"] as? String ?? "", sampleText: sample["text"] as? String ?? "")
        }
        if selected == nil || !characters.contains(where: { $0.id == selected }) { selected = characters.first?.id }
        dirty = false
    }

    func request(_ action: String) -> [String: Any] {
        ["action": action, "book": book, "project": project, "output": output,
         "runtime": runtime.path, "python": python, "key": key, "model": model,
         "web_search": webSearch, "cloud_stress": cloudStress,
         "music": music, "music_enabled": musicEnabled, "music_volume": musicVolume]
    }

    func prepare() { launch(request("prepare")) }
    func analyze() { saveThen { self.launch(self.request("characters")) } }

    func saveThen(_ continuation: @escaping () -> Void) {
        if dirty { save(after: continuation) } else { continuation() }
    }

    func save(after: (() -> Void)? = nil) {
        do {
            let url = URL(fileURLWithPath: project).appendingPathComponent("roles/manifest.json")
            let m = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let book = m["book"] as! [String: Any]
            var r = request("save")
            r["profiles"] = ["input_sha256": book["input_sha256"]!, "characters": characters.map(\.profile)]
            launch(r, after: after)
        } catch { self.error = error.localizedDescription }
    }

    func build() {
        saveThen {
            // Setup checks all files and downloads only missing models. No pip/install on client.
            self.launch(self.request("setup"), after: { self.launch(self.request("build")) })
        }
    }

    func uploadSample(_ index: Int) {
        guard !characters[index].sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Сначала введите точный текст, произнесённый в образце"; return
        }
        let panel = NSOpenPanel(); panel.allowedFileTypes = ["wav", "mp3", "m4a", "flac", "aiff"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cid = characters[index].id, text = characters[index].sampleText
        saveThen {
            var r = self.request("sample"); r["character"] = cid; r["text"] = text; r["sample"] = url.path
            self.launch(r)
        }
    }

    func removeSample(_ index: Int) {
        var r = request("sample"); r["character"] = characters[index].id; r["remove"] = true
        launch(r)
    }

    func launch(_ request: [String: Any], after: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true; cancelling = false; receivedError = false; pending = after
        fraction = 0; speed = nil; eta = nil; completed = ""; buffer = Data()
        status = "Подготовка…"
        let p = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-u", resources.appendingPathComponent("backend/worker.py").path]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "OLLAMA_API_KEY")
        env["AUDIOBOOK_FFMPEG"] = resources.appendingPathComponent("runtime/bin/ffmpeg").path
        env["AUDIOBOOK_FFPROBE"] = resources.appendingPathComponent("runtime/bin/ffprobe").path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env; p.standardInput = input; p.standardOutput = output; p.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { DispatchQueue.main.async { self.consume(data) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { self.appendLog(text.replacingOccurrences(of: self.key.isEmpty ? "\u{0}" : self.key, with: "[REDACTED]")) }
            }
        }
        p.terminationHandler = { process in
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.consume(rest)
                self.busy = false; self.process = nil
                let next = self.pending; self.pending = nil
                if self.cancelling { self.status = "Операция остановлена"; return }
                if process.terminationStatus != 0 {
                    if !self.receivedError { self.error = "Движок завершился с ошибкой. См. журнал." }
                    return
                }
                self.fraction = 1
                if !self.project.isEmpty { try? self.loadProject() }
                next?()
            }
        }
        do {
            try p.run(); process = p
            let data = try JSONSerialization.data(withJSONObject: request)
            try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
            try input.fileHandleForWriting.close()
        } catch {
            p.terminate(); busy = false; pending = nil
            self.error = "Не удалось запустить встроенный движок: \(error.localizedDescription)"
        }
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "project": project = event["path"] as? String ?? project
            case "progress": status = event["message"] as? String ?? status; fraction = event["fraction"] as? Double ?? 0; speed = nil; eta = nil
            case "metrics":
                status = event["message"] as? String ?? status
                speed = event["speed"] as? Double; eta = event["eta"] as? Double
                fraction = event["fraction"] as? Double ?? 0
                completed = "\(event["completed"] ?? 0) / \(event["total"] ?? 0) фрагментов"
            case "log": appendLog(event["message"] as? String ?? "")
            case "error": receivedError = true; error = event["message"] as? String; status = "Требуется внимание"
            case "done": status = event["message"] as? String ?? "Готово"; project = event["path"] as? String ?? project
            default: break
            }
        }
    }

    func appendLog(_ text: String) { log = String((log + text + "\n").suffix(24000)) }
    func cancel() {
        cancelling = true; pending = nil
        if let p = process { kill(-p.processIdentifier, SIGTERM); p.terminate() }
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
                    if !c.sample.isEmpty {
                        Button("Прослушать", systemImage: "play.fill") { NSWorkspace.shared.open(URL(fileURLWithPath: c.sample)) }
                        Button("Сгенерировать вместо образца") { studio.removeSample(index) }
                    }
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
        .onChange(of: studio.characters[index].age) { _ in studio.dirty = true }
        .onChange(of: studio.characters[index].personality) { _ in studio.dirty = true }
        .onChange(of: studio.characters[index].habits) { _ in studio.dirty = true }
        .onChange(of: studio.characters[index].speakingStyle) { _ in studio.dirty = true }
        .onChange(of: studio.characters[index].voice) { _ in studio.dirty = true }
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
                    step("4", "Аудиокнига и EPUB", done: FileManager.default.fileExists(atPath: studio.project + "/result/book.m4b"))
                }
                Divider()
                Text("ПЕРСОНАЖИ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(studio.characters) { c in
                            Button { studio.selected = c.id } label: {
                                HStack {
                                    Image(systemName: c.id == "narrator" ? "book" : "person")
                                    Text(c.name).lineLimit(1)
                                    Spacer()
                                    if !c.sample.isEmpty { Image(systemName: "waveform").font(.caption) }
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(studio.selected == c.id ? Color.indigo.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button("Настройки LLM", systemImage: "slider.horizontal.3") { studio.settings = true }
                Text("Apple Silicon · локальная озвучка").font(.caption2).foregroundStyle(.secondary)
            }.padding(22).frame(minWidth: 235, idealWidth: 245, maxWidth: 285)
                .background(.ultraThinMaterial)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("У каждой истории — свои голоса").font(.largeTitle.bold())
                                Text("От книги к многоголосной аудиокниге").font(.title3).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Открыть проект…") { studio.openProject() }
                        }.padding(.bottom, 4)
                        Card {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: "books.vertical.fill").font(.system(size: 34)).foregroundStyle(.indigo)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(studio.book.isEmpty ? "Выберите вашу историю" : URL(fileURLWithPath: studio.book).deletingPathExtension().lastPathComponent).font(.title2.bold())
                                        Text("EPUB · оригинальный текст и структура книги сохраняются").foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Выбрать книгу…") { studio.chooseBook() }
                                }
                                HStack {
                                    Button("Определить персонажей и расставить роли", systemImage: "person.2") { studio.prepare() }
                                        .buttonStyle(.borderedProminent).tint(.indigo).disabled(studio.book.isEmpty || !studio.project.isEmpty)
                                    Button("Определить характеры персонажей", systemImage: "sparkles") { studio.analyze() }
                                        .disabled(studio.characters.isEmpty)
                                }
                                if studio.project.isEmpty {
                                    HStack {
                                        Text("Результаты: \(studio.output)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Button("Изменить…") { studio.chooseOutput() }
                                    }
                                }
                            }
                        }
                        if let index = studio.characters.firstIndex(where: { $0.id == studio.selected }) {
                            Card { CharacterEditor(studio: studio, index: index) }
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
                                        Text(studio.music.isEmpty ? "Свет лампы и страницы" : URL(fileURLWithPath: studio.music).lastPathComponent).font(.subheadline.weight(.semibold))
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
                                Text("Два результата: отдельный M4B и EPUB со встроенным аудио. Модели скачиваются автоматически при первой сборке.")
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
                    if studio.busy {
                        ProgressView(value: studio.fraction).tint(.indigo)
                        Text(studio.completed.isEmpty ? "Один запрос к LLM за раз" : studio.completed + " · оценка по последним фрагментам").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(studio.showLog ? "Скрыть журнал" : "Журнал") { studio.showLog.toggle() }
                        Spacer()
                        if !studio.project.isEmpty {
                            Button("Папка проекта", systemImage: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: studio.project)) }
                        }
                    }.font(.caption)
                    if studio.showLog { ScrollView { Text(studio.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 130) }
                }.padding(20).background(.bar)
            }.frame(minWidth: 760)
        }.frame(minWidth: 1050, minHeight: 780)
            .sheet(isPresented: $studio.settings) { SettingsView(studio: studio) }
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

struct SettingsView: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Режиссёр вашей аудиокниги").font(.title2.bold())
            Text("DeepSeek через Ollama Cloud. Запросы выполняются последовательно.").foregroundStyle(.secondary)
            SecureField("Ollama API key", text: $studio.key).textFieldStyle(.roundedBorder)
            Text("Ключ используется только в текущем сеансе и не сохраняется на диск.").font(.caption).foregroundStyle(.secondary)
            TextField("Модель", text: $studio.model).textFieldStyle(.roundedBorder)
            Toggle("Разрешить веб-поиск при анализе характеров", isOn: $studio.webSearch)
            Toggle("LLM проверяет спорные ударения", isOn: $studio.cloudStress)
            Text("Для ролей и характеров текст книги отправляется в Ollama. Озвучка выполняется локально на Mac.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Обновления").font(.headline)
            Toggle("Автоматически проверять обновления", isOn: Binding(get: { studio.updater.updater.automaticallyChecksForUpdates }, set: { studio.updater.updater.automaticallyChecksForUpdates = $0 }))
            Button("Проверить обновления…") { studio.updater.checkForUpdates(nil) }
            HStack { Spacer(); Button("Готово") { studio.settings = false }.buttonStyle(.borderedProminent) }
        }.padding(30).frame(width: 520)
    }
}

@main struct StudioApp: App {
    @StateObject private var studio = Studio()
    var body: some Scene {
        WindowGroup { ContentView(studio: studio).tint(.indigo) }
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Проверить обновления…") { studio.updater.checkForUpdates(nil) }.disabled(studio.busy)
                }
            }
    }
}
