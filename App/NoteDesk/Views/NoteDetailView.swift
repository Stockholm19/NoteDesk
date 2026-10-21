import SwiftUI
import SwiftData
import NoteStationKit
import UniformTypeIdentifiers
import QuickLook
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    @State private var attachments: [NSAttachment] = []
    @State private var files: [EditorFile] = []
    @State private var importing = false
    @State private var uploading = false
    @State private var fileError: String?
    @State private var previewURL: URL?
    @State private var deletingFile: String?
    @AppStorage("editorFontSize") private var fontSize = 16
    @AppStorage("spellcheck") private var spellcheck = true
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .toolbar { formattingToolbar }
        .focusedSceneValue(\.editorController, controller)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await attach(urls) } }
        }
        .quickLookPreview($previewURL)
        .alert("Не получилось", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("OK") { fileError = nil }
        } message: { Text(fileError ?? "") }
        .confirmationDialog("Удалить вложение «\(attachments.first { $0.id == deletingFile }?.name ?? "файл")»?",
                            isPresented: Binding(get: { deletingFile != nil }, set: { if !$0 { deletingFile = nil } }),
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let id = deletingFile { Task { await removeFile(id) } }
                deletingFile = nil
            }
        }
        .onAppear {
            title = note.title
            if note.remoteID == nil && note.title.isEmpty { titleFocused = true }
        }
        .onChange(of: note.title) { _, new in
            if !titleFocused { title = new }   // обновилось с сервера
        }
        .task(id: note.imageRefs) {
            await loadImageURLs()
            await loadAttachments()
        }
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
                       prefs: EditorPrefs(fontSize: fontSize, spellcheck: spellcheck),
                       files: files,
                       onImage: { ref, name, mime, data in
                           engine.addImage(to: note, ref: ref, filename: name, mimeType: mime, data: data)
                       },
                       onFileAction: { action, ref, fileID in
                           Task { await fileAction(action, ref: ref, fileID: fileID) }
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
            Button("Прикрепить файл", systemImage: uploading ? "arrow.up.circle" : "paperclip") { importing = true }
                .disabled(uploading || note.isEncrypted)
                .help(uploading ? "Загружаю файлы…" : "Прикрепить файл")
        }
    }

    private func fmt(_ title: String, _ icon: String, _ cmd: String) -> some View {
        Button(title, systemImage: icon) { controller.exec(cmd) }
            .symbolVariant(controller.state[cmd] == true ? .fill : .none)
    }

    /// Вложения вне текста. Так Note Station хранит «гифки» из Telegram:
    /// статичная картинка в тексте и mp4 отдельным файлом.
    private func loadAttachments() async {
        guard note.remoteID != nil else { return }
        let all = await engine.attachments(for: note)
        attachments = all
        let html = note.html ?? ""
        var out: [EditorFile] = []
        for a in all where !(a.ref.map { html.contains($0) } ?? false) {
            let ext = ((a.name ?? "") as NSString).pathExtension.lowercased()
            let mime = ["mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"][ext]
            // Короткие ролики (Telegram-«гифки») крутятся прямо в заметке, как GIF;
            // длинные — плашкой, по клику открываются в просмотре со звуком
            var data: Data?
            if mime != nil, let size = a.size, size < 8_000_000 {
                data = await engine.fileData(note: note, ref: nil, fileID: a.id)
            }
            out.append(EditorFile(id: a.id, name: a.name ?? "Файл", video: data != nil,
                                  data: data?.base64EncodedString(), mime: mime,
                                  size: a.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }))
        }
        files = out
    }

    private func fileName(ref: String?, fileID: String?, data: Data) -> String {
        let fid = fileID ?? ref.flatMap { note.imageRefs[$0] }
        if let name = attachments.first(where: { $0.id == fid })?.name, !name.isEmpty { return name }
        return "image." + (FileKind.sniff(data)?.preferredFilenameExtension ?? "png")
    }

    private func fileAction(_ action: EditorFileAction, ref: String?, fileID: String?) async {
        if action == .delete { deletingFile = fileID; return }
        guard let data = await engine.fileData(note: note, ref: ref, fileID: fileID) else {
            fileError = "Не удалось скачать файл с NAS."
            return
        }
        let name = fileName(ref: ref, fileID: fileID, data: data)
        switch action {
        case .copy: FileKind.copy(data, name: name)
        case .save: FileKind.save(data, name: name)
        case .open: FileKind.open(data, name: name)
        case .preview: previewURL = FileKind.tempFile(data, name: name)
        case .delete: break
        }
    }

    /// Файлы с диска — в заметку отдельными вложениями, как «Загрузить файл» в Note Station.
    private func attach(_ urls: [URL]) async {
        var files: [(name: String, mime: String, data: Data)] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { fileError = "Не удалось прочитать «\(url.lastPathComponent)»."; return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            files.append((url.lastPathComponent, mime, data))
        }
        guard !files.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        do {
            try await engine.attachFiles(to: note, files)
            await loadAttachments()
        } catch {
            fileError = error.localizedDescription
        }
    }

    private func removeFile(_ id: String) async {
        do {
            try await engine.deleteAttachment(of: note, fileID: id)
            await loadAttachments()
        } catch {
            fileError = error.localizedDescription
        }
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

/// Копирование, сохранение и открытие файлов картинок и вложений.
enum FileKind {
    /// Тип по первым байтам: GIF должен остаться GIF, а не стать PNG.
    static func sniff(_ d: Data) -> UTType? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x47, 0x49, 0x46]) { return .gif }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if b.starts(with: [0xFF, 0xD8]) { return .jpeg }
        if b.count >= 12, b[8...11].elementsEqual(Array("WEBP".utf8)) { return .webP }
        if b.count >= 12, b[4...7].elementsEqual(Array("ftyp".utf8)) {
            return String(decoding: b[8...11], as: UTF8.self).hasPrefix("hei") ? .heic : .mpeg4Movie
        }
        return nil
    }

    static func type(_ data: Data, name: String) -> UTType {
        sniff(data) ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    static func copy(_ data: Data, name: String) {
        let t = type(data, name: name)
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        if t.conforms(to: .image), let img = NSImage(data: data) {
            // Сама картинка (для любых приложений) плюс исходный файл — GIF останется анимированным
            pb.writeObjects([img])
            pb.setData(data, forType: NSPasteboard.PasteboardType(t.identifier))
        } else {
            let url = tempFile(data, name: name)
            pb.writeObjects([url as NSURL])
        }
        #else
        UIPasteboard.general.setData(data, forPasteboardType: t.identifier)
        #endif
    }

    static func save(_ data: Data, name: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
        #else
        copy(data, name: name)
        #endif
    }

    static func open(_ data: Data, name: String) {
        #if os(macOS)
        NSWorkspace.shared.open(tempFile(data, name: name))
        #endif
    }

    static func tempFile(_ data: Data, name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NoteDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
        try? data.write(to: url)
        return url
    }
}
