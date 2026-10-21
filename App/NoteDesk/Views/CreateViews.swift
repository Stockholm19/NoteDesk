import SwiftUI
import SwiftData

/// Меню «Создать» — как кнопка «+ Создать ▾» в Note Station.
struct CreateMenu: View {
    @Query(sort: [SortDescriptor(\LocalNotebook.title, comparator: .localizedStandard)]) private var notebooks: [LocalNotebook]
    var newNote: () -> Void
    var newNoteIn: (String) -> Void
    var create: (CreateRequest) -> Void

    var body: some View {
        Menu {
            Button("Создать заметку", systemImage: "square.and.pencil", action: newNote)
            Menu("Создать заметку в…", systemImage: "book.closed") {
                ForEach(stacks, id: \.self) { stack in
                    Menu(stack) {
                        ForEach(active.filter { $0.stack == stack }) { book($0) }
                    }
                }
                if !stacks.isEmpty { Divider() }
                ForEach(active.filter { $0.stack == nil }) { book($0) }
            }
            Divider()
            Button("Создать полку…", systemImage: "books.vertical") { create(.shelf) }
            Button("Создать записную книгу…", systemImage: "book.closed") { create(.notebook) }
        } label: {
            Label("Создать", systemImage: "square.and.pencil")
        } primaryAction: {
            newNote()
        }
        .help("Новая заметка (⌘N); стрелка — другие варианты")
    }

    private func book(_ nb: LocalNotebook) -> some View {
        Button(nb.title, systemImage: nb.isPreset ? "star.square" : "book.closed") { newNoteIn(nb.remoteID) }
    }

    private var active: [LocalNotebook] { notebooks.filter { !$0.isArchived } }

    private var stacks: [String] {
        Set(active.compactMap(\.stack)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// «Создать записную книгу»: название и полка.
struct NewNotebookSheet: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\LocalNotebook.title, comparator: .localizedStandard)]) private var notebooks: [LocalNotebook]
    @State private var title = ""
    @State private var shelf = ""          // "" — без полки
    @State private var newShelf = ""
    @State private var busy = false
    private static let newTag = "\u{1}new"

    var body: some View {
        Form {
            TextField("Название", text: $title)
            Picker("Полка", selection: $shelf) {
                Text("Без полки").tag("")
                ForEach(stacks, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("Новая полка…").tag(Self.newTag)
            }
            if shelf == Self.newTag {
                TextField("Название полки", text: $newShelf)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Новая записная книга")
        .frame(minWidth: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Создать") { submit() }
                    .disabled(trimmed(title).isEmpty || busy || (shelf == Self.newTag && trimmed(newShelf).isEmpty))
            }
        }
    }

    private var stacks: [String] {
        Set(notebooks.compactMap(\.stack)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func submit() {
        busy = true
        let stack = shelf == Self.newTag ? trimmed(newShelf) : shelf
        let t = trimmed(title)
        Task {
            await engine.createNotebook(title: t, stack: stack.isEmpty ? nil : stack)
            dismiss()
        }
    }
}

/// «Создать полку»: в Note Station полка не бывает пустой — выбираем книги, которые в неё лягут.
struct NewShelfSheet: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\LocalNotebook.title, comparator: .localizedStandard)]) private var notebooks: [LocalNotebook]
    @State private var name = ""
    @State private var picked: Set<String> = []
    @State private var busy = false

    var body: some View {
        Form {
            TextField("Название полки", text: $name)
            Section("Записные книги") {
                ForEach(notebooks.filter { !$0.isArchived }) { nb in
                    Toggle(isOn: Binding(
                        get: { picked.contains(nb.remoteID) },
                        set: { if $0 { picked.insert(nb.remoteID) } else { picked.remove(nb.remoteID) } })) {
                        HStack {
                            Text(nb.title)
                            if let s = nb.stack { Text(s).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Новая полка")
        .frame(minWidth: 380, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Создать") {
                    busy = true
                    let n = trimmed(name), ids = Array(picked)
                    Task { await engine.createShelf(name: n, notebookIDs: ids); dismiss() }
                }
                .disabled(trimmed(name).isEmpty || picked.isEmpty || busy)
                .help(picked.isEmpty ? "Выберите хотя бы одну книгу — пустых полок в Note Station нет" : "")
            }
        }
    }
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
