import Foundation
import NoteStationKit

// nsctl — консольный клиент для отладки Note Station API.
//
//   swift run nsctl login http://192.168.1.10:5000 admin   (спросит пароль и, при 2FA, код)
//   swift run nsctl notebooks
//   swift run nsctl notes 20
//   swift run nsctl note <object_id>
//   swift run nsctl raw SYNO.NoteStation.Tag list '{}'
//   swift run nsctl logout
//
// Сессия (sid) хранится в ~/Library/Application Support/NoteDesk/nsctl-session.json (chmod 600).

let sessionURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "NoteDesk", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: "nsctl-session.json")
}()

func loadSession() -> DSMSession? {
    guard let d = try? Data(contentsOf: sessionURL) else { return nil }
    return try? JSONDecoder().decode(DSMSession.self, from: d)
}

func saveSession(_ s: DSMSession?) throws {
    guard let s else { try? FileManager.default.removeItem(at: sessionURL); return }
    try JSONEncoder().encode(s).write(to: sessionURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)
}

func readSecret(_ prompt: String) -> String {
    var buf = [CChar](repeating: 0, count: 512)
    guard let p = readpassphrase(prompt, &buf, buf.count, 0) else { return "" }
    return String(cString: p)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func client() -> (DSMClient, NoteStation) {
    guard let s = loadSession() else { fail("Сначала: nsctl login <url> <user>") }
    let dsm = DSMClient(baseURL: s.baseURL, session: s)
    return (dsm, NoteStation(dsm: dsm))
}

func fmt(_ d: Date?) -> String {
    guard let d else { return "—" }
    return d.formatted(date: .numeric, time: .shortened)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("Команды: login <url> <user> | logout | apis | notebooks | tags | notes [N] | note <id> | raw <api> <method> [json] [version]")
    exit(0)
}
args.removeFirst()

do {
    switch cmd {
    case "login":
        guard args.count >= 2, let url = URL(string: args[0]) else { fail("nsctl login <url> <user>") }
        let dsm = DSMClient(baseURL: url, session: loadSession())
        let pass = readSecret("Пароль DSM для \(args[1]): ")
        do {
            let s = try await dsm.login(account: args[1], password: pass)
            try saveSession(s)
        } catch let e as DSMError where e.code == 403 {
            let otp = readSecret("Код 2FA: ")
            let s = try await dsm.login(account: args[1], password: pass, otp: otp)
            try saveSession(s)
        }
        print("Вошли. Сессия сохранена в \(sessionURL.path)")

    case "logout":
        let (dsm, _) = client()
        await dsm.logout()
        try saveSession(nil)
        print("Вышли")

    case "apis":
        let (dsm, _) = client()
        for (k, v) in try await dsm.discover().sorted(by: { $0.key < $1.key }) {
            print("\(k)  v\(v.minVersion)-\(v.maxVersion)  \(v.path)\(v.jsonRequest ? "  JSON" : "")")
        }

    case "notebooks":
        let (_, ns) = client()
        for nb in try await ns.notebooks() {
            print("\(nb.id)  \(nb.title)  (\(nb.itemCount.map(String.init) ?? "?") шт., ver \(nb.ver ?? "—"))")
        }

    case "tags":
        let (_, ns) = client()
        for t in try await ns.tags() { print("\(t.id)  \(t.title)") }

    case "notes":
        let (_, ns) = client()
        let limit = args.first.flatMap(Int.init) ?? 20
        let notes = try await ns.allNotes()
        print("Всего: \(notes.count)")
        for n in notes.prefix(limit) {
            let flags = [n.recycle ? "корзина" : nil, n.encrypt ? "зашифр." : nil, n.archive ? "архив" : nil]
                .compactMap { $0 }.joined(separator: ",")
            print("\(n.id)  [\(n.parentID ?? "—")]  \(fmt(n.mtime))  ver=\(n.ver ?? "—")  \(n.title) \(flags)")
        }

    case "note":
        guard let id = args.first else { fail("nsctl note <object_id>") }
        let (_, ns) = client()
        let n = try await ns.note(id: id)
        print(n.raw.prettyText)

    case "raw":
        guard args.count >= 2 else { fail("nsctl raw <api> <method> [json-params] [version]") }
        let (dsm, _) = client()
        var params: [String: JSONValue] = [:]
        if args.count >= 3, let o = try JSONValue.parse(args[2]).object { params = o }
        let version = args.count >= 4 ? Int(args[3]) : nil
        print(try await dsm.call(args[0], args[1], version: version, params).prettyText)

    case "attachment":
        // nsctl attachment <note_id> <file_id> <out>
        guard args.count >= 3 else { fail("nsctl attachment <note_id> <file_id> <out>") }
        let (_, ns) = client()
        let data = try await ns.attachmentData(noteID: args[0], fileID: args[1])
        try data.write(to: URL(fileURLWithPath: args[2]))
        print("\(data.count) байт → \(args[2])")

    case "thumb":
        // nsctl thumb <note_id> <out.png> — превью заметки
        guard args.count >= 2 else { fail("nsctl thumb <note_id> <out>") }
        let (_, ns) = client()
        let n = try await ns.note(id: args[0])
        guard let md5 = n.thumbMD5 else { fail("У заметки нет превью") }
        let data = try await ns.thumbnailData(noteID: n.id, md5: md5)
        try data.write(to: URL(fileURLWithPath: args[1]))
        print("\(data.count) байт → \(args[1])")

    case "imgtest":
        // nsctl imgtest <note_id> <file.png> — добавить картинку в конец заметки
        guard args.count >= 2 else { fail("nsctl imgtest <note_id> <file.png>") }
        let (_, ns) = client()
        let file = URL(fileURLWithPath: args[1])
        let data = try Data(contentsOf: file)
        var n = try await ns.note(id: args[0])
        let ref = Data("\(Int(Date().timeIntervalSince1970 * 1000))\(file.lastPathComponent)".utf8).base64EncodedString()
        let html = (n.content ?? "") + "<p><img class=\"syno-notestation-image-object\" src=\"webman/3rdparty/NoteStation/images/transparent.gif\" ref=\"\(ref)\" adjust=\"true\"></p>"
        let r = try await ns.updateNote(id: n.id, ver: n.ver, .init(html: html),
                                        attachments: [.init(ref: ref, filename: file.lastPathComponent, mimeType: "image/png", data: data)])
        n = try await ns.note(id: n.id)
        let att = n.attachments.first { $0.ref == ref }
        print("set ver=\(r.ver ?? "—") attachments=\(n.attachments.count) new=\(att.map { "\($0.id) \($0.type ?? "?") \($0.width ?? 0)x\($0.height ?? 0) \($0.size ?? 0)b" } ?? "НЕ НАЙДЕНО") ref in html=\(n.content?.contains(ref) == true)")
        if let att {
            let back = try await ns.attachmentData(noteID: n.id, fileID: att.id)
            print("download: \(back.count) байт, совпадает=\(back == data)")
        }

    case "selftest":
        // Проверка записи в отдельном блокноте: создать → изменить → конфликт → в корзину.
        let (_, ns) = client()
        let books = try await ns.notebooks()
        let book: NSNotebook
        if let existing = books.first(where: { $0.title == "NoteDesk test" }) {
            book = existing
        } else {
            book = try await ns.createNotebook(title: "NoteDesk test")
        }
        print("блокнот: \(book.id)")

        let created = try await ns.createNote(title: "Проверка NoteDesk", notebookID: book.id,
                                              html: "<p>Первая версия <b>жирным</b></p>")
        var n = try await ns.note(id: created.id)
        print("create: id=\(n.id) ver=\(n.ver ?? "—") parent ok=\(n.parentID == book.id) content=\(n.content ?? "nil")")

        let v1 = n.ver
        let upd = try await ns.updateNote(id: n.id, ver: v1, .init(title: "Проверка NoteDesk ✓", html: "<p>Вторая версия</p>"))
        n = try await ns.note(id: n.id)
        print("update: result.ver=\(upd.ver ?? "—") server.ver=\(n.ver ?? "—") title=\(n.title) content=\(n.content ?? "nil") brief=\(n.brief)")

        do {
            _ = try await ns.updateNote(id: n.id, ver: v1, .init(html: "<p>Устаревшая правка</p>"))
            print("conflict: НЕ сработал — сервер принял правку со старой ver")
        } catch let e as DSMError {
            print("conflict: ошибка \(e.code.map(String.init) ?? "?") — \(e.localizedDescription)")
        }

        try await ns.trashNote(id: n.id)
        let after = try await ns.note(id: n.id)
        print("trash: recycle=\(after.recycle)")

    default:
        fail("Неизвестная команда \(cmd)")
    }
} catch {
    fail("Ошибка: \(error.localizedDescription)")
}
