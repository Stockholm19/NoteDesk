import SwiftUI
import SwiftData

@main
struct NoteDeskApp: App {
    @State private var startup = AppStartup()
    @AppStorage("noteSort") private var sort = NoteSort.modifiedNewest

    var body: some Scene {
        WindowGroup {
            StartupView(startup: startup) { RootView() }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif
        .commands {
            #if os(macOS)
            EditCommands()
            #endif
            CommandGroup(after: .newItem) {
                Button("Синхронизировать") { Task { await startup.engine?.sync() } }
                    .disabled(startup.engine == nil || startup.engine?.persistence.hasFailure == true)
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Picker("Сортировка заметок", selection: $sort) {
                    ForEach(NoteSort.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        #if os(macOS)
        Settings {
            StartupView(startup: startup) { SettingsView() }
        }
        #endif
    }
}

struct RootView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("syncInterval") private var syncInterval = 60

    var body: some View {
        Group {
            if engine.isLoggedIn {
                MainView()
            } else {
                LoginView()
            }
        }
        .safeAreaInset(edge: .top) { StorageFailureBanner() }
        .task(id: "\(engine.isLoggedIn)-\(syncInterval)") {
            // Фоновая синхронизация с интервалом из настроек, пока приложение на экране
            guard engine.isLoggedIn else { return }
            await engine.sync()
            guard syncInterval > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(syncInterval))
                if !Task.isCancelled && scenePhase == .active { await engine.sync() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await engine.sync() } }
            #if os(iOS)
            // Свернули приложение — успеваем отправить правки (новые заметки, теги),
            // иначе они ждут следующего открытия
            if phase == .background {
                let task = UIApplication.shared.beginBackgroundTask(withName: "NoteDesk sync")
                Task {
                    await engine.sync()
                    UIApplication.shared.endBackgroundTask(task)
                }
            }
            #endif
        }
    }
}

#if os(macOS)
/// «Отменить» и «Повторить» в меню «Правка». У редактора своя история правок
/// (чекбоксы и картинки не попадают в штатную историю WebKit), поэтому, когда фокус
/// в заметке, команда идёт в редактор, иначе — как обычно (поле заголовка и т. п.).
struct EditCommands: Commands {
    @FocusedValue(\.editorController) private var editor

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Отменить") {
                if let editor, editor.hasFocus { editor.undo() }
                else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("Повторить") {
                if let editor, editor.hasFocus { editor.redo() }
                else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}
#endif

@MainActor @Observable
final class AppStartup {
    let store = StoreOpening()
    private(set) var engine: SyncEngine?
    private var didAttemptOpen = false

    func start() {
        guard !didAttemptOpen else { return }
        retry()
    }

    func retry() {
        guard engine == nil else { return }
        didAttemptOpen = true
        store.retry()
        if let container = store.container {
            engine = SyncEngine(context: container.mainContext)
        }
    }
}

struct StartupView<Content: View>: View {
    let startup: AppStartup
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if let container = startup.store.container, let engine = startup.engine {
                content()
                    .environment(engine)
                    .modelContainer(container)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Локальная база недоступна").font(.title2)
                    Text("База не была сброшена или заменена. Синхронизация и MCP не запущены. Повторите открытие; если ошибка остается, сохраните диагностику и обратитесь за помощью.")
                    if let diagnostic = startup.store.diagnostic {
                        Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Копировать диагностику") { copyStorageDiagnostic(diagnostic) }
                    }
                    Button("Повторить открытие") { startup.retry() }
                }
                .padding(24)
                .frame(maxWidth: 600)
            }
        }
        .task { startup.start() }
    }
}

struct StorageFailureBanner: View {
    @Environment(SyncEngine.self) private var engine

    var body: some View {
        if let diagnostic = engine.persistence.diagnostic {
            VStack(alignment: .leading, spacing: 8) {
                Label("Изменения не сохранены на устройстве", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text("Не закрывайте приложение. Изменения остаются в памяти; отправка на сервер приостановлена. Часть уже начатой отправки могла завершиться. Повтор сохраняет только локальную базу.")
                    .font(.caption)
                HStack {
                    Button("Повторить сохранение") { engine.retryLocalSave() }
                    Button("Копировать диагностику") { copyStorageDiagnostic(diagnostic) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15))
        }
    }
}

private func copyStorageDiagnostic(_ value: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    #else
    UIPasteboard.general.string = value
    #endif
}
