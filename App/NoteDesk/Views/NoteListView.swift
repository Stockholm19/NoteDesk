import SwiftUI
import SwiftData

/// Порядок заметок в списке. Выбор запоминается между запусками.
enum NoteSort: String, CaseIterable, Identifiable {
    case modifiedNewest, modifiedOldest, createdNewest, createdOldest, titleAZ

    var id: Self { self }

    var label: String {
        switch self {
        case .modifiedNewest: "Изменённые: сначала новые"
        case .modifiedOldest: "Изменённые: сначала старые"
        case .createdNewest: "Созданные: сначала новые"
        case .createdOldest: "Созданные: сначала старые"
        case .titleAZ: "По названию (А–Я)"
        }
    }

    var byCreation: Bool { self == .createdNewest || self == .createdOldest }

    var descriptors: [SortDescriptor<LocalNote>] {
        switch self {
        case .modifiedNewest: [SortDescriptor(\.mtime, order: .reverse)]
        case .modifiedOldest: [SortDescriptor(\.mtime)]
        case .createdNewest: [SortDescriptor(\.ctime, order: .reverse)]
        case .createdOldest: [SortDescriptor(\.ctime)]
        case .titleAZ: [SortDescriptor(\.title, comparator: .localizedStandard), SortDescriptor(\.mtime, order: .reverse)]
        }
    }
}

struct NoteListView: View {
    @Environment(SyncEngine.self) private var engine
    let filter: SidebarItem
    @Binding var selection: UUID?
    @Binding var sort: NoteSort
    @Query private var allNotes: [LocalNote]
    @Query(sort: \LocalNotebook.title) private var notebooks: [LocalNotebook]
    @State private var search = ""

    init(filter: SidebarItem, selection: Binding<UUID?>, sort: Binding<NoteSort>) {
        self.filter = filter
        _selection = selection
        _sort = sort
        _allNotes = Query(filter: #Predicate<LocalNote> { !$0.isTrashedLocally }, sort: sort.wrappedValue.descriptors)
    }

    var body: some View {
        List(selection: $selection) {
            if sort == .titleAZ {
                ForEach(visible) { row($0) }
            } else {
                // Как в Note Station: разделы по месяцам
                ForEach(months, id: \.title) { month in
                    Section(month.title) {
                        ForEach(month.notes) { row($0) }
                    }
                }
            }
        }
        .overlay {
            if visible.isEmpty {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if engine.isSyncing && allNotes.isEmpty {
                    ProgressView("Загружаю заметки…")
                } else {
                    ContentUnavailableView("Нет заметок", systemImage: "note.text")
                }
            }
        }
        .searchable(text: $search, prompt: "Поиск")
        .onChange(of: filter) {
            // Сменили блокнот — не показываем справа заметку, которой нет в списке
            if let id = selection, !visible.contains(where: { $0.localID == id }) { selection = nil }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Сортировка", selection: $sort) {
                        ForEach(NoteSort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Сортировка", systemImage: "arrow.up.arrow.down")
                }
                .help(sort.label)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Новая заметка", systemImage: "square.and.pencil") { newNote() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        #if os(macOS)
        .onDeleteCommand {
            if let id = selection, let note = allNotes.first(where: { $0.localID == id }) { delete(note) }
        }
        #endif
    }

    private func row(_ note: LocalNote) -> some View {
        NoteRow(note: note, notebook: showNotebook ? notebookTitle(note.notebookID) : nil,
                showCreated: sort.byCreation)
            .tag(note.localID)
            .contextMenu { menu(for: note) }
            .swipeActions {
                Button("Удалить", systemImage: "trash", role: .destructive) { delete(note) }
            }
    }

    private struct Month { var title: String; var notes: [LocalNote] }

    private static let monthFormat: Date.FormatStyle = .dateTime.month(.wide).year()

    /// Заметки, разбитые по месяцам изменения (или создания — по выбранной сортировке).
    private var months: [Month] {
        var out: [Month] = []
        let cal = Calendar.current
        var lastKey: DateComponents?
        for n in visible {
            let d = sort.byCreation ? n.ctime : n.mtime
            let key = cal.dateComponents([.year, .month], from: d)
            if key != lastKey {
                // «Октябрь 2026» — с заглавной, как в Note Station
                let t = d.formatted(Self.monthFormat.locale(Locale(identifier: "ru_RU")))
                out.append(Month(title: t.prefix(1).uppercased() + t.dropFirst(), notes: []))
                lastKey = key
            }
            out[out.count - 1].notes.append(n)
        }
        return out
    }

    private var showNotebook: Bool { if case .notebook = filter { false } else { true } }

    private var visible: [LocalNote] {
        let scoped: [LocalNote]
        switch filter {
        case .all: scoped = allNotes
        case .notebook(let id): scoped = allNotes.filter { $0.notebookID == id }
        case .stack(let name):
            let ids = Set(notebooks.filter { $0.stack == name }.map(\.remoteID))
            scoped = allNotes.filter { $0.notebookID.map(ids.contains) ?? false }
        case .tag(let t): scoped = allNotes.filter { $0.tags.contains(t) }
        case .note(let rid): scoped = allNotes.filter { $0.remoteID == rid }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return scoped }
        return scoped.filter {
            $0.title.localizedStandardContains(q) || $0.brief.localizedStandardContains(q)
                || ($0.html.map { HTMLSearch.text($0).localizedStandardContains(q) } ?? false)
        }
    }

    private var title: String {
        switch filter {
        case .all: "Все заметки"
        case .notebook(let id): notebookTitle(id) ?? "Блокнот"
        case .stack(let name): name
        case .tag(let t): "#\(t)"
        case .note: "Избранное"
        }
    }

    private func notebookTitle(_ id: String?) -> String? {
        guard let id else { return nil }
        return notebooks.first { $0.remoteID == id }?.title
    }

    @ViewBuilder private func menu(for note: LocalNote) -> some View {
        Menu("Переместить в блокнот") {
            ForEach(notebooks) { nb in
                Button(nb.title) { engine.move(note, to: nb.remoteID) }
                    .disabled(nb.remoteID == note.notebookID)
            }
        }
        Button("Удалить", systemImage: "trash", role: .destructive) { delete(note) }
    }

    private func newNote() {
        var nb: String? = nil
        if case .notebook(let id) = filter { nb = id }
        let n = engine.createNote(in: nb)
        selection = n.localID
    }

    private func delete(_ note: LocalNote) {
        if selection == note.localID { selection = nil }
        engine.trash(note)
    }
}

struct NoteRow: View {
    let note: LocalNote
    let notebook: String?
    var showCreated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.isEncrypted { Image(systemName: "lock.fill").font(.caption) }
                Text(note.displayTitle).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                if note.isDirty {
                    Image(systemName: "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Ещё не отправлено на сервер")
                }
            }
            if !note.brief.isEmpty {
                Text(note.brief).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 4) {
                if showCreated {
                    Text("создана \(note.ctime.formatted(date: .abbreviated, time: .omitted))")
                } else {
                    Text(note.mtime, format: .relative(presentation: .named))
                }
                if let notebook { Text("· \(notebook)") }
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// Плоский текст HTML для поиска — с кэшем, чтобы не разбирать HTML на каждый символ.
enum HTMLSearch {
    private static var cache: [Int: String] = [:]

    static func text(_ html: String) -> String {
        let key = html.hashValue
        if let t = cache[key] { return t }
        let t = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = t
        return t
    }
}
