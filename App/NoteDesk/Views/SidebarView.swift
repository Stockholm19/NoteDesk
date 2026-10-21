import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(SyncEngine.self) private var engine
    @Binding var selection: SidebarItem?
    @Query(sort: [SortDescriptor(\LocalNotebook.title, comparator: .localizedStandard)]) private var notebooks: [LocalNotebook]
    @AppStorage("expandedStacks") private var expandedRaw = ""
    @AppStorage("expandedSections") private var sectionsRaw = "books,fav,tags"
    @State private var newNotebook = false
    @State private var newNotebookTitle = ""
    @State private var confirmLogout = false
    // Диалоги контекстного меню
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var deleting: LocalNotebook?

    /// Диалог с полем ввода: переименование блокнота/стопки или новая стопка.
    private enum Prompt: Identifiable {
        case renameNotebook(id: String)
        case renameStack(String)
        case newStack(notebookID: String)

        var id: String {
            switch self {
            case .renameNotebook(let id): "rn:" + id
            case .renameStack(let n): "rs:" + n
            case .newStack(let id): "ns:" + id
            }
        }
        var title: String {
            switch self {
            case .renameNotebook: "Переименовать записную книгу"
            case .renameStack: "Переименовать стопку"
            case .newStack: "Новая стопка"
            }
        }
    }

    var body: some View {
        List(selection: $selection) {
            if !favorites.isEmpty {
                Section("Избранное", isExpanded: sectionBinding("fav")) {
                    ForEach(favorites, id: \.item) { f in
                        Label(f.title, systemImage: f.icon)
                            .tag(f.item)
                            .entryContextMenu {
                                [.action("Убрать из Избранного", "star.slash") {
                                    Task { await engine.setFavorite(false, category: f.category, key: f.key) }
                                }]
                            }
                    }
                }
            }

            Section {
                Label("Все заметки", systemImage: "note.text")
                    .badge(engine.stats.total)
                    .tag(SidebarItem.all)
            }

            Section("Записные книги", isExpanded: sectionBinding("books")) {
                ForEach(shelf, id: \.id) { entry in
                    switch entry {
                    case .stack(let name, let books):
                        DisclosureGroup(isExpanded: stackBinding(name)) {
                            ForEach(books) { notebookRow($0) }
                        } label: {
                            Label(name, systemImage: "books.vertical")
                                .badge(books.count)
                                .tag(SidebarItem.stack(name))
                                .entryContextMenu { stackMenu(name) }
                        }
                    case .notebook(let nb):
                        notebookRow(nb)
                    }
                }
            }

            if !archived.isEmpty {
                Section("Архив", isExpanded: sectionBinding("archive")) {
                    ForEach(archived) { nb in
                        Label(nb.title, systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                            .entryContextMenu {
                                [.action("Вернуть из архива", "tray.and.arrow.up") {
                                    Task { await engine.archiveNotebook(id: nb.remoteID, false) }
                                }]
                            }
                    }
                }
            }

            if !engine.stats.tags.isEmpty {
                Section("Теги", isExpanded: sectionBinding("tags")) {
                    ForEach(engine.stats.tags, id: \.self) { t in
                        Label(t, systemImage: "tag")
                            .tag(SidebarItem.tag(t))
                            .entryContextMenu { [favoriteEntry(category: "tag", key: t)] }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SyncStatusLine() }
        .navigationTitle("NoteDesk")
        .toolbar {
            ToolbarItem { SyncStatusButton() }
            ToolbarItem {
                Menu {
                    Button("Новый блокнот…", systemImage: "book.closed") { newNotebook = true }
                    Divider()
                    if let acc = engine.account {
                        Text("\(acc.username) @ \(acc.serverURL.host() ?? "")")
                    }
                    if case .error(let m) = engine.phase { Text(m) }
                    if engine.conflictsResolved > 0 {
                        Text("Конфликтов разрешено: \(engine.conflictsResolved)")
                    }
                    Button("Выйти", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmLogout = true
                    }
                } label: {
                    Label("Ещё", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Новый блокнот", isPresented: $newNotebook) {
            TextField("Название", text: $newNotebookTitle)
            Button("Создать") {
                let t = newNotebookTitle.trimmingCharacters(in: .whitespaces)
                newNotebookTitle = ""
                guard !t.isEmpty else { return }
                Task { await engine.createNotebook(title: t) }
            }
            Button("Отмена", role: .cancel) { newNotebookTitle = "" }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Название", text: $promptText)
            Button("Готово") { submitPrompt() }
            Button("Отмена", role: .cancel) { prompt = nil }
        }
        .confirmationDialog(deleting.map { "Удалить «\($0.title)»? Заметки из неё попадут в корзину Note Station." } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let nb = deleting { Task { await engine.deleteNotebook(id: nb.remoteID) } }
                deleting = nil
            }
        }
        .confirmationDialog("Выйти из аккаунта? Локальная копия заметок будет удалена, неотправленные правки пропадут.",
                            isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { Task { await engine.logout() } }
        }
    }

    private func notebookRow(_ nb: LocalNotebook) -> some View {
        // Звезда — записная книжка по умолчанию, как в Note Station
        Label(nb.title, systemImage: nb.isPreset ? "star.square" : "book.closed")
            .badge(engine.stats.counts[nb.remoteID] ?? 0)
            .tag(SidebarItem.notebook(nb.remoteID))
            .entryContextMenu { notebookMenu(nb) }
    }

    // MARK: Контекстные меню — как в Note Station

    private func notebookMenu(_ nb: LocalNotebook) -> [MenuEntry] {
        let id = nb.remoteID
        var move: [MenuEntry] = stackNames.filter { $0 != nb.stack }.map { name in
            .action(name, "books.vertical") { Task { await engine.moveNotebook(id: id, toStack: name) } }
        }
        if !move.isEmpty { move.append(.divider) }
        move.append(.action("Новая стопка…", "plus") { promptText = ""; prompt = .newStack(notebookID: id) })

        var items: [MenuEntry] = [
            .action("Переименовать…", "pencil") { promptText = nb.title; prompt = .renameNotebook(id: id) },
            favoriteEntry(category: "notebook", key: id),
            .submenu("Переместить в", "folder", move),
        ]
        if nb.stack != nil {
            items.append(.action("Удалить с полки", "tray.and.arrow.up") {
                Task { await engine.moveNotebook(id: id, toStack: nil) }
            })
        }
        items += [
            .action("Удалить…", "trash", disabled: nb.isPreset) { deleting = nb },
            .divider,
            .action("Установить как записную книжку по умолчанию", "star", disabled: nb.isPreset) {
                Task { await engine.setPresetNotebook(id: id) }
            },
            .action("Архивировать", "archivebox", disabled: nb.isPreset) {
                Task { await engine.archiveNotebook(id: id, true) }
            },
        ]
        return items
    }

    private func stackMenu(_ name: String) -> [MenuEntry] {
        [
            .action("Переименовать…", "pencil") { promptText = name; prompt = .renameStack(name) },
            favoriteEntry(category: "stack", key: name),
            .action("Разобрать", "square.stack.3d.down.right") { Task { await engine.ungroupStack(name) } },
        ]
    }

    /// «Добавить в Избранное» / «Убрать из Избранного» — как звёздочка в Note Station.
    private func favoriteEntry(category: String, key: String) -> MenuEntry {
        let fav = engine.isFavorite(category: category, key: key)
        return .action(fav ? "Убрать из Избранного" : "Добавить в Избранное", fav ? "star.slash" : "star") {
            Task { await engine.setFavorite(!fav, category: category, key: key) }
        }
    }

    private func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespaces)
        defer { prompt = nil }
        guard !text.isEmpty, let p = prompt else { return }
        Task {
            switch p {
            case .renameNotebook(let id): await engine.renameNotebook(id: id, title: text)
            case .renameStack(let old):
                await engine.renameStack(old, to: text)
                if selection == .stack(old) { selection = .stack(text) }
            case .newStack(let id): await engine.moveNotebook(id: id, toStack: text)
            }
        }
    }

    private var stackNames: [String] {
        Set(notebooks.compactMap(\.stack)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var archived: [LocalNotebook] { notebooks.filter(\.isArchived) }

    // MARK: Стопки — как «Записные книги» в Note Station

    private enum ShelfEntry {
        case stack(String, [LocalNotebook])
        case notebook(LocalNotebook)

        var id: String {
            switch self {
            case .stack(let n, _): "stack:" + n
            case .notebook(let nb): "nb:" + nb.remoteID
            }
        }
        var title: String {
            switch self {
            case .stack(let n, _): n
            case .notebook(let nb): nb.title
            }
        }
    }

    /// Стопки и блокноты без стопки вперемешку, по названию — как в Note Station.
    private var shelf: [ShelfEntry] {
        var stacks: [String: [LocalNotebook]] = [:]
        var loose: [ShelfEntry] = []
        for nb in notebooks where !nb.isArchived {
            if let s = nb.stack { stacks[s, default: []].append(nb) } else { loose.append(.notebook(nb)) }
        }
        let all = stacks.map { ShelfEntry.stack($0.key, $0.value) } + loose
        return all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var expanded: Set<String> { Set(expandedRaw.split(separator: "\n").map(String.init)) }

    private func stackBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(name) },
            set: { on in
                var s = expanded
                if on { s.insert(name) } else { s.remove(name) }
                expandedRaw = s.sorted().joined(separator: "\n")
            })
    }

    private func sectionBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { sectionsRaw.split(separator: ",").contains(Substring(key)) },
            set: { on in
                var s = Set(sectionsRaw.split(separator: ",").map(String.init))
                if on { s.insert(key) } else { s.remove(key) }
                sectionsRaw = s.sorted().joined(separator: ",")
            })
    }

    // MARK: Избранное — ярлыки из Note Station

    /// key — то, что передаётся в setFavorite: id блокнота/заметки или название стопки/тега.
    private struct Favorite { var item: SidebarItem; var title: String; var icon: String; var category: String; var key: String }

    private var favorites: [Favorite] {
        engine.shortcuts.compactMap { s in
            switch s.category {
            case "notebook":
                guard let nb = notebooks.first(where: { $0.remoteID == s.id }) else { return nil }
                return Favorite(item: .notebook(s.id), title: nb.title, icon: "book.closed", category: "notebook", key: s.id)
            case "stack":
                // id стопки — «Название#uid владельца»
                let name = s.id.range(of: "#", options: .backwards).map { String(s.id[..<$0.lowerBound]) } ?? s.id
                return Favorite(item: .stack(name), title: name, icon: "books.vertical", category: "stack", key: name)
            case "tag":
                let title = s.id.split(separator: "@").first.map(String.init) ?? s.id
                return Favorite(item: .tag(title), title: title, icon: "tag", category: "tag", key: title)
            case "note":
                guard let t = engine.noteTitle(remoteID: s.id) else { return nil }
                return Favorite(item: .note(s.id), title: t, icon: "doc.text", category: "note", key: s.id)
            default:
                return nil
            }
        }
    }
}

/// Отдельная вьюха: прогресс обновляется часто и не должен перерисовывать весь сайдбар.
struct SyncStatusLine: View {
    @Environment(SyncEngine.self) private var engine

    var body: some View {
        Group {
            if let p = engine.contentProgress, p.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(p.done), total: Double(p.total))
                    Text("Загружено \(p.done) из \(p.total)")
                }
            } else if case .error(let m) = engine.phase {
                Label(m, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            } else if let d = engine.lastSync {
                Text("Синхронизировано \(d.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
