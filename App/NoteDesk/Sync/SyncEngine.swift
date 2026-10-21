import Foundation
import Observation
import SwiftData
import NoteStationKit
import CoreGraphics
import os

let syncLog = Logger(subsystem: "ru.klotze.NoteDesk", category: "sync")

/// Состояние приложения и синхронизация локальной базы с Note Station.
///
/// Схема простая: сначала отправляем локальные правки (push), потом
/// забираем изменения с сервера (pull). Конфликт — сервер вернул 1064 —
/// решается без потерь: локальная версия сохраняется отдельной заметкой
/// «… (конфликт)», а исходная получает серверную версию.
@Observable
final class SyncEngine {
    enum Phase: Equatable { case loggedOut, idle, syncing, error(String) }

    private(set) var phase: Phase = .loggedOut
    private(set) var lastSync: Date?
    private(set) var conflictsResolved = 0
    private(set) var account: Account?
    /// Счётчики для сайдбара. Считаются после синхронизации, а не в body вьюхи:
    /// перебор 2000 моделей на каждую перерисовку грузил главный поток.
    struct Stats { var total = 0; var counts: [String: Int] = [:]; var tags: [String] = []; var tagCounts: [String: Int] = [:] }
    private(set) var stats = Stats()

    /// Ярлык «Избранного» из Note Station.
    struct Shortcut: Codable, Hashable { var category: String; var id: String }
    private(set) var shortcuts: [Shortcut] = {
        guard let d = UserDefaults.standard.data(forKey: "shortcuts") else { return [] }
        return (try? JSONDecoder().decode([Shortcut].self, from: d)) ?? []
    }()

    /// Сколько тел заметок скачано в текущей синхронизации.
    private(set) var contentProgress: (done: Int, total: Int)?

    private let context: ModelContext
    private var dsm: DSMClient?
    private var api: NoteStation?
    private var pendingSync: Task<Void, Never>?
    private var resyncRequested = false

    #if os(macOS)
    private let deviceKind = "desktop"
    #else
    private let deviceKind = "mobile"
    #endif

    init(context: ModelContext) {
        self.context = context
        if let saved = Keychain.load() {
            account = saved
            connect(saved)
            phase = .idle
        }
        refreshStats()
    }

    func refreshStats() {
        var d = FetchDescriptor<LocalNote>(predicate: #Predicate { !$0.isTrashedLocally })
        d.propertiesToFetch = [\.notebookID, \.tags]
        let notes = (try? context.fetch(d)) ?? []
        var s = Stats(total: notes.count)
        for n in notes {
            if let nb = n.notebookID { s.counts[nb, default: 0] += 1 }
            for t in n.tags { s.tagCounts[t, default: 0] += 1 }
        }
        s.tags = s.tagCounts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        stats = s
    }

    var isLoggedIn: Bool { account != nil }
    var isSyncing: Bool { phase == .syncing }

    // MARK: Вход / выход

    /// Возвращает true, если сервер просит код 2FA.
    func login(server: String, username: String, password: String, otp: String?) async throws -> Bool {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s), url.host() != nil else { throw DSMError.badURL }
        let client = DSMClient(baseURL: url)
        do {
            let session = try await client.login(account: username, password: password, otp: otp)
            let acc = Account(serverURL: url, username: username, password: password, session: session)
            Keychain.save(acc)
            account = acc
            dsm = client
            api = NoteStation(dsm: client, device: deviceKind)
            phase = .idle
            await sync()
            return false
        } catch let e as DSMError where e.code == 403 && (otp ?? "").isEmpty {
            return true
        }
    }

    func logout() async {
        await dsm?.logout()
        Keychain.delete()
        account = nil
        dsm = nil
        api = nil
        try? context.delete(model: LocalNote.self)
        try? context.delete(model: LocalNotebook.self)
        try? context.delete(model: PendingAttachment.self)
        shortcuts = []
        UserDefaults.standard.removeObject(forKey: "shortcuts")
        try? context.save()
        phase = .loggedOut
        lastSync = nil
        stats = Stats()
    }

    private func connect(_ acc: Account) {
        let client = DSMClient(baseURL: acc.serverURL, session: acc.session)
        dsm = client
        api = NoteStation(dsm: client, device: deviceKind)
    }

    /// Выполнить запрос; если сессия истекла — тихо перелогиниться и повторить.
    private func authed<T: Sendable>(_ op: (NoteStation) async throws -> T) async throws -> T {
        guard let api, let dsm, var acc = account else { throw DSMError.notLoggedIn }
        do {
            if await dsm.session == nil { throw DSMError.notLoggedIn }
            return try await op(api)
        } catch let e as DSMError where e.isSessionError {
            let session = try await dsm.login(account: acc.username, password: acc.password)
            acc.session = session
            account = acc
            Keychain.save(acc)
            return try await op(api)
        }
    }

    /// URL картинки для редактора (с актуальным _sid).
    func imageURL(noteID: String, fileID: String) async -> URL? {
        try? await api?.attachmentURL(noteID: noteID, fileID: fileID)
    }

    // MARK: Синхронизация

    /// Отложенная синхронизация — после правок, чтобы не слать запрос на каждый символ.
    func scheduleSync(after seconds: Double = 3) {
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // Отдельная задача: отмена следующим scheduleSync должна снимать только
            // ожидание, а не обрывать уже идущие запросы (иначе ответ на запись
            // теряется, версия устаревает и следующая запись даёт ложный конфликт).
            Task { await self?.sync() }
        }
    }

    func sync() async {
        guard isLoggedIn else { return }
        if isSyncing { resyncRequested = true; return }
        phase = .syncing
        do {
            try await push()
            try await pull()
            try context.save()
            lastSync = .now
            phase = .idle
            refreshStats()
        } catch let e as DSMError where e.code == 403 || e.code == 400 {
            // Пароль сменили или включили 2FA без доверенного устройства
            syncLog.error("auth: \(e.localizedDescription, privacy: .public)")
            phase = .error("Нужно войти заново: \(e.localizedDescription)")
        } catch {
            syncLog.error("sync: \(String(describing: error), privacy: .public)")
            try? context.save()
            phase = .error(Self.describe(error))
        }
        if resyncRequested {
            resyncRequested = false
            await sync()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .cannotFindHost:
                return "Нет связи с NAS — работаем офлайн"
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: Push

    private func push() async throws {
        let pending = try context.fetch(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.isDirty || $0.isTrashedLocally }))

        for note in pending {
            if note.isTrashedLocally {
                if let id = note.remoteID {
                    do {
                        try await authed { try await $0.trashNote(id: id) }
                    } catch let e as DSMError where e.code != nil && !e.isSessionError {
                        // Заметки уже нет на сервере — удаляем локально
                    }
                }
                pendingAttachments(for: note.localID).forEach { context.delete($0) }
                context.delete(note)
                continue
            }

            let title = note.title
            let html = note.html ?? ""
            let notebookID = note.notebookID
            let files = uploadableAttachments(for: note, html: html)

            guard let id = note.remoteID else {
                let r = try await authed { try await $0.createNote(title: title, notebookID: notebookID, html: html) }
                note.remoteID = r.id
                try await markPushed(note, id: r.id, sentTitle: title, sentHTML: html)
                // Картинки — вторым запросом: в create Note Station вложения не принимает
                if !files.isEmpty {
                    let ver = note.remoteVer
                    _ = try await authed {
                        try await $0.updateNote(id: r.id, ver: ver, .init(html: html), attachments: files.map(\.upload))
                    }
                    files.forEach { context.delete($0.model) }
                    try await markPushed(note, id: r.id, sentTitle: title, sentHTML: html)
                }
                try context.save()
                continue
            }

            let ver = note.remoteVer
            do {
                _ = try await authed {
                    try await $0.updateNote(id: id, ver: ver, .init(title: title, html: html, notebookID: notebookID),
                                            attachments: files.map(\.upload))
                }
                files.forEach { context.delete($0.model) }
                try await markPushed(note, id: id, sentTitle: title, sentHTML: html)
            } catch let e as DSMError where e.code == 1064 {
                try await resolveConflict(note, id: id)
            }
            try context.save()
        }
    }

    private func pendingAttachments(for noteID: UUID) -> [PendingAttachment] {
        (try? context.fetch(FetchDescriptor<PendingAttachment>(
            predicate: #Predicate { $0.noteLocalID == noteID }))) ?? []
    }

    /// Неотправленные картинки, которые всё ещё есть в тексте. Удалённые
    /// из заметки до синхронизации выбрасываем, чтобы не грузить лишнее.
    private func uploadableAttachments(for note: LocalNote, html: String)
        -> [(model: PendingAttachment, upload: NoteStation.NewAttachment)] {
        var out: [(model: PendingAttachment, upload: NoteStation.NewAttachment)] = []
        for a in pendingAttachments(for: note.localID) {
            if html.contains(a.ref) {
                out.append((model: a, upload: .init(ref: a.ref, filename: a.filename, mimeType: a.mimeType, data: a.data)))
            } else {
                context.delete(a)
            }
        }
        return out
    }

    /// Правку с другого устройства не трогаем; наша версия становится отдельной заметкой.
    private func resolveConflict(_ note: LocalNote, id: String) async throws {
        let stamp = Date.now.formatted(date: .numeric, time: .shortened)
        let copy = LocalNote(
            notebookID: note.notebookID,
            title: "\(note.displayTitle) (конфликт \(stamp))",
            html: note.html, brief: note.brief, tags: note.tags, isDirty: true)
        context.insert(copy)
        // Неотправленные картинки уезжают вместе с нашей версией
        pendingAttachments(for: note.localID).forEach { $0.noteLocalID = copy.localID }
        try await refreshFromServer(note, id: id)

        let r = try await authed { [copy] api in
            try await api.createNote(title: copy.title, notebookID: copy.notebookID, html: copy.html ?? "")
        }
        copy.remoteID = r.id
        try await markPushed(copy, id: r.id, sentTitle: copy.title, sentHTML: copy.html ?? "")
        let files = uploadableAttachments(for: copy, html: copy.html ?? "")
        if !files.isEmpty {
            let ver = copy.remoteVer
            let html = copy.html ?? ""
            _ = try await authed { try await $0.updateNote(id: r.id, ver: ver, .init(html: html), attachments: files.map(\.upload)) }
            files.forEach { context.delete($0.model) }
            try await markPushed(copy, id: r.id, sentTitle: copy.title, sentHTML: html)
        }
        conflictsResolved += 1
    }

    /// Целиком заменить локальную заметку серверной версией (при конфликте).
    private func refreshFromServer(_ note: LocalNote, id: String) async throws {
        let remote = try await authed { try await $0.note(id: id) }
        apply(remote, to: note, includeContent: true)
        note.isDirty = false
    }

    /// После успешной записи берём с сервера только новую версию, а тело не трогаем:
    /// пока шёл запрос, пользователь мог продолжать печатать, и перезапись
    /// серверным HTML стёрла бы эти символы и перезагрузила редактор.
    private func markPushed(_ note: LocalNote, id: String, sentTitle: String, sentHTML: String) async throws {
        let remote = try await authed { try await $0.note(id: id) }
        note.remoteVer = Self.version(remote)
        if let m = remote.mtime { note.mtime = m }
        var refs: [String: String] = [:]
        for a in remote.attachments { if let ref = a.ref { refs[ref] = a.id } }
        if refs != note.imageRefs { note.imageRefs = refs }
        note.needsContent = false
        // Правили во время запроса — остаёмся «грязными», уйдёт следующим заходом
        note.isDirty = note.title != sentTitle || (note.html ?? "") != sentHTML
    }

    // MARK: Pull

    private func pull() async throws {
        // Блокноты
        let remoteBooks = try await authed { try await $0.notebooks() }
        let localBooks = try context.fetch(FetchDescriptor<LocalNotebook>())
        var booksByID = Dictionary(localBooks.map { ($0.remoteID, $0) }, uniquingKeysWith: { a, _ in a })
        for rb in remoteBooks {
            let stack = (rb.stack?.isEmpty ?? true) ? nil : rb.stack
            let lb: LocalNotebook
            if let existing = booksByID.removeValue(forKey: rb.id) {
                lb = existing
                if lb.title != rb.title { lb.title = rb.title }
                if lb.ver != rb.ver { lb.ver = rb.ver }
                if lb.stack != stack { lb.stack = stack }
            } else {
                lb = LocalNotebook(remoteID: rb.id, title: rb.title, ver: rb.ver, stack: stack)
                context.insert(lb)
            }
            if lb.isPreset != rb.preset { lb.isPreset = rb.preset }
            if lb.isArchived != rb.archive { lb.isArchived = rb.archive }
        }
        booksByID.values.forEach { context.delete($0) }

        // Избранное — не критично: ошибка не должна ломать синхронизацию
        if let sc = try? await authed({ try await $0.shortcuts() }) {
            let list = sc.map { Shortcut(category: $0.category, id: $0.id) }
            if list != shortcuts {
                shortcuts = list
                try? UserDefaults.standard.set(JSONEncoder().encode(list), forKey: "shortcuts")
            }
        }

        // Заметки: список без тела
        let remoteNotes = try await authed { try await $0.allNotes() }
            .filter { !$0.recycle && !$0.archive }
        let remoteByID = Dictionary(remoteNotes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let localNotes = try context.fetch(FetchDescriptor<LocalNote>())
        var localByID: [String: LocalNote] = [:]
        for n in localNotes {
            guard let rid = n.remoteID else { continue }
            if remoteByID[rid] == nil {
                if n.isDirty {
                    n.remoteID = nil   // удалили на сервере, а здесь правили — создадим заново
                } else {
                    context.delete(n)
                }
            } else {
                localByID[rid] = n
            }
        }

        for r in remoteNotes {
            if let local = localByID[r.id] {
                guard !local.isDirty else { continue }   // наши правки уйдут при следующем push
                // Метаданные из списка (заголовок, превью, даты) — всегда; apply пишет только изменения
                apply(r, to: local, includeContent: false)
                if Self.version(r) != local.remoteVer || local.body == nil {
                    local.needsContent = !r.encrypt
                }
            } else {
                let n = LocalNote(remoteID: r.id, notebookID: r.parentID, title: r.title, html: nil)
                apply(r, to: n, includeContent: false)
                n.needsContent = !r.encrypt
                context.insert(n)
            }
        }
        try context.save()
        refreshStats()

        // Тела изменившихся заметок — по несколько параллельно
        let toFetch = try context.fetch(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.needsContent && !$0.isDirty }))
        contentProgress = (0, toFetch.count)
        defer { contentProgress = nil }
        var failed = 0
        for (i, chunk) in stride(from: 0, to: toFetch.count, by: 8)
            .map({ Array(toFetch[$0..<min($0 + 8, toFetch.count)]) }).enumerated() {
            let ids = chunk.compactMap(\.remoteID)
            // Ошибка одной заметки не должна останавливать всю синхронизацию
            let results = try await authed { api in
                await withTaskGroup(of: (String, Result<NSNote, Error>).self) { group in
                    for id in ids {
                        group.addTask {
                            do { return (id, .success(try await api.note(id: id))) }
                            catch { return (id, .failure(error)) }
                        }
                    }
                    var out: [(String, Result<NSNote, Error>)] = []
                    for await r in group { out.append(r) }
                    return out
                }
            }
            for (id, result) in results {
                switch result {
                case .success(let remote):
                    guard let local = chunk.first(where: { $0.remoteID == id }), !local.isDirty else { continue }
                    apply(remote, to: local, includeContent: true)
                case .failure(let e as DSMError) where e.isSessionError:
                    throw e   // authed перелогинится на следующем круге
                case .failure(let e):
                    failed += 1
                    syncLog.error("note \(id, privacy: .public): \(e.localizedDescription, privacy: .public)")
                }
            }
            contentProgress = (min((i + 1) * 8, toFetch.count), toFetch.count)
            // Каждое сохранение перерисовывает списки — сохраняем пачками по ~100 заметок
            if (i + 1) % 12 == 0 { try context.save() }
        }
        try context.save()
        if failed > 0 { syncLog.error("не загрузилось заметок: \(failed, privacy: .public)") }
    }

    /// Скачать тело одной заметки вне очереди — когда её открыли до окончания синхронизации.
    /// Возвращает текст ошибки, если заметку получить не удалось.
    func loadContent(_ note: LocalNote) async -> String? {
        guard let id = note.remoteID, note.html == nil || note.needsContent else { return nil }
        do {
            let remote = try await authed { try await $0.note(id: id) }
            if !note.isDirty { apply(remote, to: note, includeContent: true) }
            try? context.save()
            return nil
        } catch {
            syncLog.error("loadContent \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return Self.describe(error)
        }
    }

    private static func version(_ n: NSNote) -> String? {
        n.ver ?? n.mtime.map { String(Int($0.timeIntervalSince1970)) }
    }

    /// Записываем только изменившиеся поля: каждое присваивание в @Model
    /// перерисовывает строки списка, даже если значение то же.
    private func apply(_ r: NSNote, to n: LocalNote, includeContent: Bool) {
        func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<LocalNote, T>, _ v: T) {
            if n[keyPath: kp] != v { n[keyPath: kp] = v }
        }
        set(\.title, r.title)
        set(\.notebookID, r.parentID)
        set(\.brief, r.brief)
        if let tags = r.tags { set(\.tags, tags) }
        set(\.isEncrypted, r.encrypt)
        set(\.thumbMD5, r.thumbMD5)
        if let c = r.ctime { set(\.ctime, c) }
        if let m = r.mtime { set(\.mtime, m) }
        if includeContent {
            set(\.html, r.content ?? "")
            set(\.remoteVer, Self.version(r))
            set(\.needsContent, false)
            var refs: [String: String] = [:]
            for a in r.attachments { if let ref = a.ref { refs[ref] = a.id } }
            set(\.imageRefs, refs)
        }
    }

    // MARK: Локальные действия из UI

    func createNote(in notebookID: String?) -> LocalNote {
        // Без выбранного блокнота — в записную книжку по умолчанию, как в Note Station
        let books = (try? context.fetch(FetchDescriptor<LocalNotebook>())) ?? []
        let defaultBook = notebookID ?? (books.first { $0.isPreset } ?? books.first)?.remoteID
        let n = LocalNote(notebookID: defaultBook, title: "", html: "<p><br></p>", isDirty: true)
        context.insert(n)
        try? context.save()
        refreshStats()
        return n
    }

    func edit(_ note: LocalNote, title: String? = nil, html: String? = nil) {
        if let title, title != note.title { note.title = title }
        if let html, html != note.html {
            note.html = html
            note.brief = HTMLText.brief(from: html)
        }
        note.isDirty = true
        note.mtime = .now
        try? context.save()
        scheduleSync()
    }

    func noteTitle(remoteID: String) -> String? {
        note(remoteID: remoteID)?.displayTitle
    }

    func noteLocalID(remoteID: String) -> UUID? {
        note(remoteID: remoteID)?.localID
    }

    private func note(remoteID: String) -> LocalNote? {
        var d = FetchDescriptor<LocalNote>(predicate: #Predicate { $0.remoteID == remoteID })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: Превью

    private let thumbnails = ThumbnailStore()

    func thumbnail(noteID: String, md5: String) async -> CGImage? {
        await thumbnails.image(md5: md5) { [weak self] in
            guard let self else { throw DSMError.notLoggedIn }
            return try await self.authed { try await $0.thumbnailData(noteID: noteID, md5: md5) }
        }
    }

    // MARK: Избранное

    /// uid владельца — префикс id объектов («1026_…»); нужен для id стопок и тегов в ярлыках.
    private var ownerUID: String? {
        var d = FetchDescriptor<LocalNotebook>()
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.remoteID.split(separator: "_").first.map(String.init)
    }

    /// id ярлыка в формате Note Station: стопка «Название#uid», тег «Название@uid».
    func shortcutID(category: String, key: String) -> String {
        guard let uid = ownerUID else { return key }
        switch category {
        case "stack": return "\(key)#\(uid)"
        case "tag": return "\(key)@\(uid)"
        default: return key
        }
    }

    func isFavorite(category: String, key: String) -> Bool {
        let id = shortcutID(category: category, key: key)
        return shortcuts.contains { $0.category == category && $0.id == id }
    }

    func setFavorite(_ on: Bool, category: String, key: String) async {
        let id = shortcutID(category: category, key: key)
        do {
            try await authed { api in
                if on { try await api.addShortcut(category: category, id: id) }
                else { try await api.removeShortcut(category: category, id: id) }
            }
            let list = try await authed { try await $0.shortcuts() }.map { Shortcut(category: $0.category, id: $0.id) }
            shortcuts = list
            try? UserDefaults.standard.set(JSONEncoder().encode(list), forKey: "shortcuts")
        } catch {
            phase = .error(Self.describe(error))
        }
    }

    /// Вставленная в редактор картинка: хранится локально до загрузки на сервер.
    func addImage(to note: LocalNote, ref: String, filename: String, mimeType: String, data: Data) {
        context.insert(PendingAttachment(noteLocalID: note.localID, ref: ref, filename: filename,
                                         mimeType: mimeType, data: data))
        note.isDirty = true
        try? context.save()
        scheduleSync()
    }

    /// Неотправленные картинки заметки как data:-URL — чтобы редактор показывал их до загрузки.
    func pendingImageURLs(for note: LocalNote) -> [String: String] {
        var out: [String: String] = [:]
        for a in pendingAttachments(for: note.localID) {
            out[a.ref] = "data:\(a.mimeType);base64,\(a.data.base64EncodedString())"
        }
        return out
    }

    func move(_ note: LocalNote, to notebookID: String) {
        note.notebookID = notebookID
        note.isDirty = true
        try? context.save()
        refreshStats()
        scheduleSync(after: 0.5)
    }

    func trash(_ note: LocalNote) {
        if note.remoteID == nil {
            pendingAttachments(for: note.localID).forEach { context.delete($0) }
            context.delete(note)
        } else {
            note.isTrashedLocally = true
        }
        try? context.save()
        refreshStats()
        scheduleSync(after: 0.5)
    }

    // MARK: Блокноты и стопки — действия из контекстного меню

    /// Выполнить действие на сервере и сразу подтянуть изменения.
    private func notebookAction(_ op: @escaping (NoteStation) async throws -> Void) async {
        do {
            try await authed(op)
            await sync()
        } catch {
            phase = .error(Self.describe(error))
        }
    }

    private func notebooks(inStack name: String) -> [String] {
        ((try? context.fetch(FetchDescriptor<LocalNotebook>())) ?? []).filter { $0.stack == name }.map(\.remoteID)
    }

    func renameNotebook(id: String, title: String) async {
        await notebookAction { try await $0.renameNotebook(id: id, title: title) }
    }

    /// stack: название стопки (новой или существующей); nil — «Удалить с полки».
    func moveNotebook(id: String, toStack stack: String?) async {
        await notebookAction { try await $0.setNotebookStack(id: id, stack: stack ?? "") }
    }

    func renameStack(_ name: String, to newName: String) async {
        let ids = notebooks(inStack: name)
        await notebookAction { api in for id in ids { try await api.setNotebookStack(id: id, stack: newName) } }
    }

    /// «Разобрать»: блокноты остаются, стопка исчезает.
    func ungroupStack(_ name: String) async {
        let ids = notebooks(inStack: name)
        await notebookAction { api in for id in ids { try await api.setNotebookStack(id: id, stack: "") } }
    }

    func setPresetNotebook(id: String) async {
        await notebookAction { try await $0.setPresetNotebook(id: id) }
    }

    func archiveNotebook(id: String, _ enable: Bool) async {
        await notebookAction { try await $0.archiveNotebook(id: id, enable: enable) }
    }

    /// Заметки блокнота уходят в корзину Note Station.
    func deleteNotebook(id: String) async {
        await notebookAction { try await $0.deleteNotebook(id: id) }
    }

    /// Новая записная книга; stack — сразу положить на полку.
    @discardableResult
    func createNotebook(title: String, stack: String? = nil) async -> String? {
        do {
            let nb = try await authed { try await $0.createNotebook(title: title) }
            if let stack, !stack.isEmpty {
                try await authed { try await $0.setNotebookStack(id: nb.id, stack: stack) }
            }
            context.insert(LocalNotebook(remoteID: nb.id, title: nb.title, ver: nb.ver, stack: stack))
            try? context.save()
            await sync()
            return nb.id
        } catch {
            phase = .error(Self.describe(error))
            return nil
        }
    }

    /// «Создать полку»: в Note Station полка живёт, пока в ней есть книги,
    /// поэтому создаём её, перекладывая выбранные книги.
    func createShelf(name: String, notebookIDs: [String]) async {
        await notebookAction { api in for id in notebookIDs { try await api.setNotebookStack(id: id, stack: name) } }
    }

    // MARK: Корзина — живёт на сервере, локально не хранится

    func trashedNotes() async throws -> [NSNote] {
        try await authed { try await $0.trashedNotes() }
    }

    func restore(_ ids: [String]) async throws {
        try await authed { api in for id in ids { try await api.restoreNote(id: id) } }
        await sync()
    }

    func deleteForever(_ ids: [String]) async throws {
        try await authed { api in for id in ids { try await api.deleteNotePermanently(id: id) } }
    }

    /// Тело заметки из корзины — только для просмотра.
    func remoteNote(id: String) async throws -> NSNote {
        try await authed { try await $0.note(id: id) }
    }

    // MARK: Вложения

    /// Список вложений заметки с сервера (картинки в тексте и прочие файлы).
    func attachments(for note: LocalNote) async -> [NSAttachment] {
        guard let id = note.remoteID else { return [] }
        return (try? await authed { try await $0.note(id: id) })?.attachments ?? []
    }

    func attachmentURL(noteID: String, fileID: String) async -> URL? {
        try? await authed { try await $0.attachmentURL(noteID: noteID, fileID: fileID) }
    }

    /// Файл картинки или вложения — для копирования и сохранения.
    /// ref — картинка из текста; fileID — вложение по id.
    func fileData(note: LocalNote, ref: String?, fileID: String?) async -> Data? {
        if let ref, let p = pendingAttachments(for: note.localID).first(where: { $0.ref == ref }) { return p.data }
        guard let noteID = note.remoteID, let fid = fileID ?? ref.flatMap({ note.imageRefs[$0] }) else { return nil }
        return try? await authed { try await $0.attachmentData(noteID: noteID, fileID: fid) }
    }
}
