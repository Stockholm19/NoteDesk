import Foundation
import Observation
import SwiftData
import NoteStationKit
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
    struct Stats { var total = 0; var counts: [String: Int] = [:]; var tags: [String] = [] }
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
        var tags = Set<String>()
        for n in notes {
            if let nb = n.notebookID { s.counts[nb, default: 0] += 1 }
            tags.formUnion(n.tags)
        }
        s.tags = tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
            if let lb = booksByID.removeValue(forKey: rb.id) {
                if lb.title != rb.title { lb.title = rb.title }
                if lb.ver != rb.ver { lb.ver = rb.ver }
                if lb.stack != stack { lb.stack = stack }
            } else {
                context.insert(LocalNotebook(remoteID: rb.id, title: rb.title, ver: rb.ver, stack: stack))
            }
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
                if Self.version(r) != local.remoteVer || local.body == nil {
                    apply(r, to: local, includeContent: false)
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
        let defaultBook = notebookID ?? (try? context.fetch(FetchDescriptor<LocalNotebook>()))?.first?.remoteID
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

    func createNotebook(title: String) async {
        do {
            let nb = try await authed { try await $0.createNotebook(title: title) }
            context.insert(LocalNotebook(remoteID: nb.id, title: nb.title, ver: nb.ver))
            try? context.save()
        } catch {
            phase = .error(Self.describe(error))
        }
    }
}
