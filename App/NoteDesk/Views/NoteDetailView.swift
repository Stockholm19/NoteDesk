import SwiftUI
import SwiftData

struct NoteDetailView: View {
    @Query private var match: [LocalNote]

    init(noteID: UUID) {
        _match = Query(filter: #Predicate<LocalNote> { $0.localID == noteID && !$0.isTrashedLocally })
    }

    var body: some View {
        if let note = match.first {
            NoteEditorView(note: note)
                .id(note.localID)
        } else {
            ContentUnavailableView("Заметка удалена", systemImage: "trash")
        }
    }
}

struct NoteEditorView: View {
    @Environment(SyncEngine.self) private var engine
    @Bindable var note: LocalNote
    @Query(sort: \LocalNotebook.title) private var notebooks: [LocalNotebook]
    @State private var controller = EditorController()
    @State private var title = ""
    @State private var images: [String: String] = [:]
    @State private var loadError: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .toolbar { formattingToolbar }
        .onAppear {
            title = note.title
            if note.remoteID == nil && note.title.isEmpty { titleFocused = true }
        }
        .onChange(of: note.title) { _, new in
            if !titleFocused { title = new }   // обновилось с сервера
        }
        .task(id: note.imageRefs) { await loadImageURLs() }
        .onDisappear {
            Task {
                // flush вернёт nil, если правок не было
                if let html = await controller.flush(), html != note.html, !note.isDeleted {
                    engine.edit(note, html: html)
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Заголовок", text: $title)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onSubmit { controller.exec("focus") }
                .onChange(of: title) { _, new in
                    if new != note.title { engine.edit(note, title: new) }
                }
                .disabled(note.isEncrypted)
            HStack(spacing: 10) {
                Menu {
                    ForEach(notebooks) { nb in
                        Button(nb.title) { engine.move(note, to: nb.remoteID) }
                    }
                } label: {
                    Label(notebooks.first { $0.remoteID == note.notebookID }?.title ?? "Без блокнота",
                          systemImage: "book.closed")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                ForEach(note.tags, id: \.self) { t in
                    Text("#\(t)").foregroundStyle(.secondary)
                }
                Spacer()
                Text(note.mtime, format: .dateTime.day().month().hour().minute())
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        if note.isEncrypted {
            ContentUnavailableView("Зашифрованная заметка",
                                   systemImage: "lock",
                                   description: Text("Откройте её в Note Station — расшифровка здесь пока не поддерживается."))
        } else if let html = note.html {
            HTMLEditor(documentKey: note.localID, html: html, images: images, editable: true,
                       baseURL: engine.account?.serverURL, controller: controller,
                       onImage: { ref, name, mime, data in
                           engine.addImage(to: note, ref: ref, filename: name, mimeType: mime, data: data)
                       }) { newHTML in
                engine.edit(note, html: newHTML)
            }
        } else if let loadError {
            ContentUnavailableView("Не удалось открыть", systemImage: "exclamationmark.triangle",
                                   description: Text(loadError))
        } else {
            ProgressView("Загружаю…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { loadError = await engine.loadContent(note) }
        }
    }

    @ToolbarContentBuilder private var formattingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .secondaryAction) {
            fmt("Жирный", "bold", "bold")
            fmt("Курсив", "italic", "italic")
            fmt("Подчёркнутый", "underline", "underline")
            fmt("Зачёркнутый", "strikethrough", "strikeThrough")
            Menu {
                Button("Заголовок 1") { controller.exec("heading", "H1") }
                Button("Заголовок 2") { controller.exec("heading", "H2") }
                Button("Заголовок 3") { controller.exec("heading", "H3") }
                Button("Обычный текст") { controller.exec("heading", "P") }
                Button("Цитата") { controller.exec("heading", "BLOCKQUOTE") }
                Button("Код (выйти из блока — ⌘↩)") { controller.exec("heading", "PRE") }
            } label: {
                Label("Стиль", systemImage: "textformat.size")
            }
            fmt("Список", "list.bullet", "insertUnorderedList")
            fmt("Нумерованный список", "list.number", "insertOrderedList")
            Button("Чекбокс", systemImage: "checkmark.square") { controller.exec("checkbox") }
        }
    }

    private func fmt(_ title: String, _ icon: String, _ cmd: String) -> some View {
        Button(title, systemImage: icon) { controller.exec(cmd) }
            .symbolVariant(controller.state[cmd] == true ? .fill : .none)
    }

    private func loadImageURLs() async {
        // Ещё не загруженные картинки — из локальной очереди, остальные — с NAS
        var map = engine.pendingImageURLs(for: note)
        if let id = note.remoteID {
            for (ref, fileID) in note.imageRefs where map[ref] == nil {
                if let u = await engine.imageURL(noteID: id, fileID: fileID) { map[ref] = u.absoluteString }
            }
        }
        images = map
    }
}
