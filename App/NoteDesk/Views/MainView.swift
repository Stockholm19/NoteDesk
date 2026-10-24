import SwiftUI
import SwiftData

enum SidebarItem: Hashable {
    case all
    case notebook(String)
    /// Стопка блокнотов по названию
    case stack(String)
    case tag(String)
    /// Заметка из «Избранного» (remote id)
    case note(String)
    /// Корзина Note Station — читается с сервера
    case trash
}

/// Что создать из меню «Создать» / «Ещё».
enum CreateRequest: String, Identifiable {
    case notebook, shelf
    var id: String { rawValue }
}

struct MainView: View {
    @Environment(SyncEngine.self) private var engine
    @State private var selection: SidebarItem? = .all
    @State private var selectedNote: UUID?
    @State private var selectedTrash: String?
    @State private var trashVersion = 0
    @State private var creating: CreateRequest?
    @State private var columns = NavigationSplitViewVisibility.all
    @AppStorage("noteSort") private var sort = NoteSort.modifiedNewest

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(selection: $selection, onCreate: { creating = $0 }, onNewNote: newNote(in:))
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } content: {
            if selection == .trash {
                TrashListView(selection: $selectedTrash, version: $trashVersion)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            } else {
                NoteListView(filter: selection ?? .all, selection: $selectedNote, sort: $sort,
                             onCreate: { creating = $0 }, onNewNoteIn: newNote(in:))
                    .id(sort)   // новый порядок — новый @Query
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            }
        } detail: {
            if selection == .trash {
                if let id = selectedTrash {
                    TrashDetailView(noteID: id, version: $trashVersion, selection: $selectedTrash)
                        .id(id)
                } else {
                    ContentUnavailableView("Корзина", systemImage: "trash",
                                           description: Text("Удалённые заметки можно вернуть или удалить навсегда."))
                }
            } else if let id = selectedNote {
                NoteDetailView(noteID: id)
            } else {
                ContentUnavailableView("Выберите заметку", systemImage: "note.text")
            }
        }
        .onChange(of: selection) { _, item in
            // Заметка из «Избранного» — сразу открываем её
            if case .note(let rid) = item, let id = engine.noteLocalID(remoteID: rid) { selectedNote = id }
        }
        .sheet(item: $creating) { kind in
            NavigationStack {
                switch kind {
                case .notebook: NewNotebookSheet()
                case .shelf: NewShelfSheet()
                }
            }
        }
    }

    /// «Создать заметку в…»: открываем эту книгу и новую заметку в ней.
    /// nil — записная книжка по умолчанию (как «+» в Note Station).
    private func newNote(in notebookID: String?) {
        let n = engine.createNote(in: notebookID)
        selection = n.notebookID.map { .notebook($0) } ?? .all
        selectedNote = n.localID
    }
}

struct SyncStatusButton: View {
    @Environment(SyncEngine.self) private var engine

    var body: some View {
        Button {
            Task { await engine.sync() }
        } label: {
            switch engine.phase {
            case .syncing:
                ProgressView().controlSize(.small)
            case .error:
                Label("Ошибка синхронизации", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            default:
                Label("Синхронизировать", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .help(helpText)
        .disabled(engine.isSyncing)
    }

    private var helpText: String {
        switch engine.phase {
        case .error(let m): return m
        case .syncing: return "Синхронизация…"
        default:
            if let d = engine.lastSync { return "Синхронизировано \(d.formatted(date: .omitted, time: .shortened))" }
            return "Синхронизировать"
        }
    }
}
