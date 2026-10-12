import SwiftUI
import AppKit

@MainActor final class BotSettingsForm: ObservableObject {
    @Published var token = ""
    @Published var dropboxID = ""
    @Published var googleID = ""
    @Published var googleSecret = ""
    @Published var showCloudGuide = false
}
struct BotSettingsView: View {
    @ObservedObject var bot: BotService
    @StateObject private var form = BotSettingsForm()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Telegram и облако").font(.headline)
            Text("Отправьте EPUB боту, подтвердите озвучивание и получите ссылки на M4B и EPUB. Mac должен быть включён, приложение открыто. Готовые файлы остаются в облаке до вашего ручного удаления.").font(.caption).foregroundStyle(.secondary)
            SecureField("Токен бота от @BotFather", text: $form.token).textFieldStyle(.roundedBorder)
            Button("Подключить бота / получить ссылку привязки") {
                Task { await bot.connectBot(form.token); form.token = "" }
            }.disabled(bot.connecting || bot.running || form.token.isEmpty)
            if let url = URL(string: bot.pairingLink), !bot.pairingLink.isEmpty {
                Link("Открыть личную привязку в Telegram", destination: url)
            }
            Toggle("Принимать книги из Telegram", isOn: Binding(get: { bot.config.enabled }, set: { bot.setEnabled($0) }))
            Text(bot.message).font(.caption).textSelection(.enabled)
            Picker("Хранилище для новых книг", selection: $bot.config.provider) {
                ForEach(RemoteProvider.allCases) { Text($0.title).tag($0) }
            }.onChange(of: bot.config.provider) { _, _ in try? bot.saveConfig() }
            ForEach(RemoteProvider.allCases) { provider in
                HStack {
                    Text(provider.title + (bot.config.connections[provider.rawValue] == nil ? " · не подключён" : " · подключён"))
                    Spacer()
                    Button("Подключить") { Task { await bot.connectCloud(provider) } }
                        .disabled(bot.connecting || bot.running || bot.config.clientID(provider).isEmpty)
                }
            }
            if RemoteProvider.allCases.contains(where: { bot.config.clientID($0).isEmpty }) {
                Text("Подключение облака ещё не настроено в этой тестовой сборке. После настройки приложения вход выполняется кнопкой «Подключить» в браузере.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Собственные проекты Google и Dropbox") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Необязательно. Используйте свои OAuth-приложения, чтобы самостоятельно управлять доступом. Текущие подключения сохраняются; вернуться можно кнопкой «Встроенный проект».").font(.caption)
                    Button("Инструкция: создать и подключить свой проект") { form.showCloudGuide = true }
                    Text("Dropbox: " + (bot.config.customDropboxID == nil ? "встроенный проект" : "собственный проект")).font(.caption)
                    TextField("Dropbox App key", text: $form.dropboxID).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Использовать свой Dropbox") { bot.configureCloud(.dropbox, customID: form.dropboxID) }
                            .disabled(form.dropboxID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Встроенный проект Dropbox") { bot.configureCloud(.dropbox, customID: nil) }
                            .disabled(bot.config.customDropboxID == nil)
                    }
                    Text("Google Drive: " + (bot.config.customGoogleID == nil ? "встроенный проект" : "собственный проект")).font(.caption)
                    TextField("Google Desktop Client ID", text: $form.googleID).textFieldStyle(.roundedBorder)
                    SecureField("Google Client Secret (пусто — оставить сохранённый)", text: $form.googleSecret).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Использовать свой Google") {
                            bot.configureCloud(.googleDrive, customID: form.googleID, googleSecret: form.googleSecret)
                            form.googleSecret = ""
                        }.disabled(form.googleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Встроенный проект Google") { bot.configureCloud(.googleDrive, customID: nil) }
                            .disabled(bot.config.customGoogleID == nil)
                    }
                    Text("После сохранения нажмите «Подключить» у нужного хранилища. Смена проекта доступна при пустой очереди. В Google новый OAuth-проект видит файлы, разрешённые этому проекту; прежняя медиатека остаётся в облаке и доступна через прежний проект.").font(.caption).foregroundStyle(.secondary)
                }.disabled(bot.connecting || bot.running)
            }
            Text("Ссылки Dropbox доступны получателю ссылки. Google Drive сохраняет файлы закрытыми: скачивание под вашим Google-аккаунтом.").font(.caption).foregroundStyle(.secondary)
            if !bot.state.jobs.isEmpty {
                Text("Книги в боте: \(bot.state.jobs.filter { ![.complete, .cancelled].contains($0.phase) }.count)").font(.caption)
                if let job = bot.state.active ?? bot.state.jobs.last {
                    Text(job.status()).font(.caption).textSelection(.enabled)
                    if !job.result.isEmpty {
                        Button("Открыть готовые файлы") { NSWorkspace.shared.open(URL(fileURLWithPath: job.result)) }
                    }
                }
            }
        }
        .onAppear {
            form.dropboxID = bot.config.customDropboxID ?? ""
            form.googleID = bot.config.customGoogleID ?? ""
        }
        .sheet(isPresented: $form.showCloudGuide) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Собственные облачные проекты").font(.title2)
                ScrollView { Text(CloudSetupGuide.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Link("Google Cloud", destination: URL(string: "https://console.cloud.google.com/")!)
                    Link("Dropbox App Console", destination: URL(string: "https://www.dropbox.com/developers/apps")!)
                    Spacer()
                    Button("Готово") { form.showCloudGuide = false }
                }
            }.padding(24).frame(width: 650, height: 600)
        }
    }
}
