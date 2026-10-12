import SwiftUI
import AppKit

@MainActor final class BotSettingsForm: ObservableObject {
    @Published var token = ""
    @Published var googleSecret = ""
    @Published var setup = false
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
                    Button("Подключить") { Task { await bot.connectCloud(provider, googleSecret: form.googleSecret); form.googleSecret = "" } }
                        .disabled(bot.connecting || bot.running)
                }
            }
            DisclosureGroup("Первичная настройка API", isExpanded: $form.setup) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Один раз создайте приложения API в своих аккаунтах. Пароли Dropbox и Google вводятся только в браузере.").font(.caption)
                    TextField("Dropbox App key", text: $bot.config.dropboxID).textFieldStyle(.roundedBorder)
                    Text("Dropbox: Scoped access → App folder. Разрешения: files.metadata.read, files.content.write, sharing.write, sharing.read. Redirect URI: http://127.0.0.1:53682/oauth").font(.caption).textSelection(.enabled)
                    Link("Dropbox App Console", destination: URL(string: "https://www.dropbox.com/developers/apps")!)
                    TextField("Google OAuth Client ID (Desktop app)", text: $bot.config.googleID).textFieldStyle(.roundedBorder)
                    SecureField("Google Client secret (из JSON Desktop client)", text: $form.googleSecret).textFieldStyle(.roundedBorder)
                    Text("Google: включите Drive API, создайте OAuth client типа Desktop app и добавьте себя в Test users. Доступ — только к файлам приложения (drive.file). В режиме Testing подключение Google может потребовать повторного входа через 7 дней.").font(.caption)
                    Link("Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    Text("Ссылки Dropbox доступны получателю ссылки. Google Drive сохраняет файлы закрытыми: скачивание под вашим Google-аккаунтом.").font(.caption)
                }.padding(.top, 8)
            }.disabled(bot.running)
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
    }
}
