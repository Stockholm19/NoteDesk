#if os(macOS)
import SwiftUI
import SwiftData

struct MCPSettingsView: View {
    @Environment(SyncEngine.self) private var engine
    @Query(sort: \LocalNotebook.title) private var notebooks: [LocalNotebook]
    var body: some View {
        if let mcp = engine.mcp {
            Section("MCP - доступ только для чтения") {
                Toggle("Включить локальный MCP", isOn: Binding(get: { mcp.enabled }, set: { mcp.setEnabled($0) }))
                Text(mcp.status).font(.caption)
                Text(MCPController.endpoint).font(.caption.monospaced()).textSelection(.enabled)
                DisclosureGroup("Разрешенные блокноты (\(mcp.allowed.count))") {
                    ForEach(notebooks) { notebook in
                        Toggle(notebook.title, isOn: Binding(get: { mcp.allowed.contains(notebook.remoteID) }, set: { mcp.setAllowed(notebook.remoteID, $0) }))
                    }
                }
                HStack {
                    Button("Копировать токен") { mcp.copyToken() }
                    Button("Конфигурация Claude") { mcp.copyConfiguration() }
                }.disabled(!engine.isLoggedIn)
                Text("Без выбора блокнотов заметки недоступны. Буфер содержит секрет и очищается через 60 секунд, если не изменен. Конфигурация запускает сторонний mcp-remote; ничего не устанавливается сейчас. Переданные клиенту тексты могут попасть к его AI-провайдеру.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
