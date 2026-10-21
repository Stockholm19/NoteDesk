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

    var body: some View {
        List(selection: $selection) {
            if !favorites.isEmpty {
                Section("Избранное", isExpanded: sectionBinding("fav")) {
                    ForEach(favorites, id: \.item) { f in
                        Label(f.title, systemImage: f.icon).tag(f.item)
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
                        }
                    case .notebook(let nb):
                        notebookRow(nb)
                    }
                }
            }

            if !engine.stats.tags.isEmpty {
                Section("Теги", isExpanded: sectionBinding("tags")) {
                    ForEach(engine.stats.tags, id: \.self) { t in
                        Label(t, systemImage: "tag").tag(SidebarItem.tag(t))
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
        .confirmationDialog("Выйти из аккаунта? Локальная копия заметок будет удалена, неотправленные правки пропадут.",
                            isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { Task { await engine.logout() } }
        }
    }

    private func notebookRow(_ nb: LocalNotebook) -> some View {
        Label(nb.title, systemImage: "book.closed")
            .badge(engine.stats.counts[nb.remoteID] ?? 0)
            .tag(SidebarItem.notebook(nb.remoteID))
    }

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
        for nb in notebooks {
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

    private struct Favorite { var item: SidebarItem; var title: String; var icon: String }

    private var favorites: [Favorite] {
        engine.shortcuts.compactMap { s in
            switch s.category {
            case "notebook":
                guard let nb = notebooks.first(where: { $0.remoteID == s.id }) else { return nil }
                return Favorite(item: .notebook(s.id), title: nb.title, icon: "book.closed")
            case "stack":
                // id стопки — «Название#uid владельца»
                let name = s.id.range(of: "#", options: .backwards).map { String(s.id[..<$0.lowerBound]) } ?? s.id
                return Favorite(item: .stack(name), title: name, icon: "books.vertical")
            case "tag":
                let title = s.id.split(separator: "@").first.map(String.init) ?? s.id
                return Favorite(item: .tag(title), title: title, icon: "tag")
            case "note":
                guard let t = engine.noteTitle(remoteID: s.id) else { return nil }
                return Favorite(item: .note(s.id), title: t, icon: "doc.text")
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
