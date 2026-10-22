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
    @State private var currentNoteID: UUID?
    @State private var loadTask: Task<Void, Never>?
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
            currentNoteID = note.localID
            title = note.title
            if note.remoteID == nil && note.title.isEmpty { titleFocused = true }
            loadInitialFiles()
            loadTask = Task {
                await loadImageURLs()
                await loadAttachments()
            }
        }
        .onChange(of: note.localID) { oldID, newID in
            guard oldID != newID else { return }
            loadTask?.cancel()
            let prevID = oldID
            Task {
                if let html = await controller.flush() {
                    engine.saveHTMLIfChanged(noteID: prevID, html: html)
                }
            }
            currentNoteID = newID
            title = note.title
            previewURL = nil
            fileError = nil
            loadError = nil
            loadInitialFiles()
            loadTask = Task {
                await loadImageURLs()
                await loadAttachments()
            }
        }
        .onChange(of: note.title) { _, new in
            if !titleFocused { title = new }   // обновилось с сервера
        }
        .onDisappear {
            loadTask?.cancel()
            Task {
                // flush вернет nil, если правок не было
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
                       },
                       onChange: { key, newHTML in
                           engine.saveHTMLIfChanged(noteID: key, html: newHTML)
                       })
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

    /// Проверяет, упоминается ли вложение уже внутри HTML-тела заметки.
    /// Исключает дублирование плашек для файлов/видео, которые уже есть в тексте.
    private func isAttachmentInHTML(ref: String?, fileID: String, filename: String?, html: String) -> Bool {
        if let ref, !ref.isEmpty, html.contains(ref) { return true }
        if !fileID.isEmpty && html.contains(fileID) { return true }
        if let filename, !filename.isEmpty, html.contains(filename) { return true }
        return false
    }

    /// Мгновенная инициализация файлов из локального кеша (0 мс, не ждем сеть).
    private func loadInitialFiles() {
        let html = note.html ?? ""
        var seen = Set<String>()
        var out: [EditorFile] = []
        for a in note.cachedAttachments {
            guard !isAttachmentInHTML(ref: a.ref, fileID: a.id, filename: a.name, html: html) else { continue }
            guard seen.insert(a.id).inserted else { continue }
            let name = a.name ?? "Файл"
            let isCached = AttachmentCache.shared.isCached(fileID: a.id, filename: name)
            var dataStr: String?
            if a.isVideo, (a.size ?? 0) < 8_000_000, isCached,
               let data = AttachmentCache.shared.cachedData(fileID: a.id, filename: name) {
                dataStr = data.base64EncodedString()
            }
            out.append(EditorFile(
                id: a.id,
                name: name,
                video: dataStr != nil,
                data: dataStr,
                mime: a.mimeType,
                size: a.formattedSize,
                isCached: isCached,
                isLoading: false,
                progress: nil,
                error: nil
            ))
        }
        files = out
    }

    /// Вложения вне текста: загрузка актуального списка с сервера и потоковое кеширование.
    private func loadAttachments() async {
        guard let remoteID = note.remoteID else { return }
        let all = await engine.refreshAttachments(for: note)
        guard !Task.isCancelled else { return }
        attachments = all
        let html = note.html ?? ""
        var seen = Set<String>()
        var out: [EditorFile] = []

        for a in all {
            guard !isAttachmentInHTML(ref: a.ref, fileID: a.id, filename: a.name, html: html) else { continue }
            guard seen.insert(a.id).inserted else { continue }
            let name = a.name ?? "Файл"
            let ext = ((a.name ?? "") as NSString).pathExtension.lowercased()
            let mime = ["mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"][ext]
                ?? a.type ?? "application/octet-stream"
            let isVideo = ["mp4", "m4v", "mov", "webm"].contains(ext) || mime.hasPrefix("video/")

            var isCached = AttachmentCache.shared.isCached(fileID: a.id, filename: name)
            var dataStr: String?

            if isVideo, let size = a.size, size < 8_000_000 {
                if let data = AttachmentCache.shared.cachedData(fileID: a.id, filename: name) {
                    dataStr = data.base64EncodedString()
                    isCached = true
                }
            }

            out.append(EditorFile(
                id: a.id,
                name: name,
                video: dataStr != nil,
                data: dataStr,
                mime: mime,
                size: a.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                isCached: isCached,
                isLoading: false,
                progress: nil,
                error: nil
            ))
        }

        await MainActor.run {
            self.files = out
        }

        // Для коротких видео, которых ещё нет в кеше, запускаем фоновую загрузку в кеш
        for item in out where item.video == false && item.mime?.hasPrefix("video/") == true {
            guard let att = all.first(where: { $0.id == item.id }),
                  let size = att.size, size < 8_000_000,
                  !AttachmentCache.shared.isCached(fileID: item.id, filename: item.name) else { continue }
            await autoDownloadShortVideo(fileID: item.id, filename: item.name, remoteNoteID: remoteID)
        }
    }

    private func autoDownloadShortVideo(fileID: String, filename: String, remoteNoteID: String) async {
        guard let remoteURL = await engine.attachmentURL(noteID: remoteNoteID, fileID: fileID) else { return }
        await MainActor.run {
            self.updateFileState(id: fileID) { $0.isLoading = true; $0.progress = 0 }
        }
        do {
            _ = try await AttachmentCache.shared.download(fileID: fileID, filename: filename, from: remoteURL) { progress in
                Task { @MainActor in
                    self.updateFileState(id: fileID) { $0.progress = progress }
                }
            }
            if let data = AttachmentCache.shared.cachedData(fileID: fileID, filename: filename) {
                await MainActor.run {
                    self.updateFileState(id: fileID) {
                        $0.isLoading = false
                        $0.isCached = true
                        $0.video = true
                        $0.data = data.base64EncodedString()
                    }
                }
            }
        } catch {
            if Task.isCancelled || isCancellation(error) {
                await MainActor.run {
                    self.updateFileState(id: fileID) {
                        $0.isLoading = false
                        $0.progress = nil
                        $0.error = nil
                    }
                }
                return
            }
            await MainActor.run {
                self.updateFileState(id: fileID) {
                    $0.isLoading = false
                    $0.error = "Ошибка"
                }
            }
        }
    }

    private func updateFileState(id: String, mutate: (inout EditorFile) -> Void) {
        if let idx = files.firstIndex(where: { $0.id == id }) {
            var f = files[idx]
            mutate(&f)
            files[idx] = f
        }
    }

    private func fileName(ref: String?, fileID: String?) -> String {
        let fid = fileID ?? ref.flatMap { note.imageRefs[$0] }
        if let name = attachments.first(where: { $0.id == fid })?.name, !name.isEmpty { return name }
        if let name = note.cachedAttachments.first(where: { $0.id == fid })?.name, !name.isEmpty { return name }
        return "file"
    }

    private func fileAction(_ action: EditorFileAction, ref: String?, fileID: String?) async {
        if action == .delete { deletingFile = fileID; return }
        if action == .cancel, let fileID {
            AttachmentCache.shared.cancel(fileID: fileID)
            updateFileState(id: fileID) {
                $0.isLoading = false
                $0.progress = nil
                $0.error = nil
            }
            return
        }
        if action == .retry, let fileID {
            await downloadAndOpen(fileID: fileID)
            return
        }
        if action == .download, let fileID {
            await downloadAndOpen(fileID: fileID)
            return
        }

        guard let fid = fileID ?? ref.flatMap({ note.imageRefs[$0] }) else { return }
        let name = fileName(ref: ref, fileID: fid)

        if let cachedURL = AttachmentCache.shared.cachedFileURL(fileID: fid, filename: name) {
            handleLocalFile(action, url: cachedURL, name: name)
            return
        }

        guard let localURL = await downloadAndOpen(fileID: fid) else {
            return
        }
        handleLocalFile(action, url: localURL, name: name)
    }

    @discardableResult
    private func downloadAndOpen(fileID: String) async -> URL? {
        guard let remoteID = note.remoteID else { return nil }
        let name = fileName(ref: nil, fileID: fileID)
        guard let downloadURL = await engine.attachmentURL(noteID: remoteID, fileID: fileID) else {
            fileError = "Не удалось получить ссылку на файл с NAS."
            return nil
        }
        await MainActor.run {
            self.updateFileState(id: fileID) { $0.isLoading = true; $0.progress = 0; $0.error = nil }
        }
        do {
            let localURL = try await AttachmentCache.shared.download(fileID: fileID, filename: name, from: downloadURL) { progress in
                Task { @MainActor in
                    self.updateFileState(id: fileID) { $0.progress = progress }
                }
            }
            await MainActor.run {
                let ext = ((name as NSString).pathExtension).lowercased()
                let isVideo = ["mp4", "m4v", "mov", "webm"].contains(ext)
                var dataStr: String?
                if isVideo, let data = AttachmentCache.shared.cachedData(fileID: fileID, filename: name), data.count < 8_000_000 {
                    dataStr = data.base64EncodedString()
                }

                self.updateFileState(id: fileID) {
                    $0.isLoading = false
                    $0.isCached = true
                    $0.progress = nil
                    $0.error = nil
                    if let dataStr {
                        $0.video = true
                        $0.data = dataStr
                    }
                }
            }
            return localURL
        } catch {
            if Task.isCancelled || isCancellation(error) {
                await MainActor.run {
                    self.updateFileState(id: fileID) {
                        $0.isLoading = false
                        $0.progress = nil
                        $0.error = nil
                    }
                }
                return nil
            }
            await MainActor.run {
                self.updateFileState(id: fileID) {
                    $0.isLoading = false
                    $0.error = "Ошибка"
                }
                self.fileError = "Не удалось скачать файл: \(error.localizedDescription)"
            }
            return nil
        }
    }

    private func handleLocalFile(_ action: EditorFileAction, url: URL, name: String) {
        switch action {
        case .preview:
            previewURL = url
        case .open:
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            previewURL = url
            #endif
        case .copy:
            if let data = try? Data(contentsOf: url) {
                FileKind.copy(data, name: name)
            }
        case .save:
            if let data = try? Data(contentsOf: url) {
                FileKind.save(data, name: name)
            }
        default:
            break
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
