import SwiftUI

/// Настройки приложения. Серверные (импорт/экспорт, администрирование) остаются в веб-версии Note Station.
struct SettingsView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("editorFontSize") private var fontSize = 16
    @AppStorage("spellcheck") private var spellcheck = true
    @AppStorage("syncInterval") private var syncInterval = 60
    @State private var confirmLogout = false

    var body: some View {
        Form {
            Section("Аккаунт") {
                if let acc = engine.account {
                    LabeledContent("Пользователь", value: acc.username)
                    LabeledContent("Сервер", value: acc.serverURL.absoluteString)
                    Button("Выйти…", role: .destructive) { confirmLogout = true }
                } else {
                    Text("Не выполнен вход").foregroundStyle(.secondary)
                }
            }
            Section("Редактор") {
                Picker("Размер шрифта", selection: $fontSize) {
                    ForEach([13, 14, 15, 16, 17, 18, 20, 22], id: \.self) { Text($0 == 16 ? "\($0) (по умолчанию)" : "\($0)").tag($0) }
                }
                Toggle("Проверять орфографию", isOn: $spellcheck)
            }
            Section {
                Picker("Синхронизировать", selection: $syncInterval) {
                    Text("Каждые 30 секунд").tag(30)
                    Text("Каждую минуту").tag(60)
                    Text("Каждые 5 минут").tag(300)
                    Text("Только вручную").tag(0)
                }
            } header: {
                Text("Синхронизация")
            } footer: {
                Text("Правки отправляются сразу после ввода, а при открытии приложения заметки обновляются всегда. Вручную — ⌘R.")
            }
            Section {
                Text("Импорт и экспорт, общий доступ и администрирование — в веб-версии Note Station.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Настройки")
        #if os(macOS)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        #else
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
        }
        #endif
        .confirmationDialog("Выйти из аккаунта? Локальная копия заметок будет удалена, неотправленные правки пропадут.",
                            isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) {
                Task { await engine.logout(); dismiss() }
            }
        }
    }
}
