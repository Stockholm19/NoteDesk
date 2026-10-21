import SwiftUI
import SwiftData

@main
struct NoteDeskApp: App {
    let container: ModelContainer
    @State private var engine: SyncEngine
    @AppStorage("noteSort") private var sort = NoteSort.modifiedNewest

    init() {
        // Локальная база — это кэш сервера: при несовместимой схеме просто начинаем заново.
        let schema = Schema([LocalNote.self, NoteBody.self, LocalNotebook.self, PendingAttachment.self])
        let config = ModelConfiguration("NoteDesk-v2", schema: schema)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: config.url.path + suffix))
            }
            container = try! ModelContainer(for: schema, configurations: config)
        }
        self.container = container
        _engine = State(initialValue: SyncEngine(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif
        .commands {
            #if os(macOS)
            EditCommands()
            #endif
            CommandGroup(after: .newItem) {
                Button("Синхронизировать") { Task { await engine.sync() } }
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
            SettingsView()
                .environment(engine)
                .modelContainer(container)
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
