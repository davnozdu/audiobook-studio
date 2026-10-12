import SwiftUI
import AppKit

@MainActor final class BotSettingsForm: ObservableObject {
    @Published var token = ""
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
    }
}
