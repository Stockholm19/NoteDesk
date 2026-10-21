import Foundation

/// Высокоуровневый клиент Note Station. Методы и версии сняты с веб-интерфейса
/// Note Station 2.6.x (notestation.js): Notebook v2, Note v3, Tag v1.
public actor NoteStation {
    public let dsm: DSMClient
    private let device: String

    public init(dsm: DSMClient, device: String = "desktop") {
        self.dsm = dsm
        self.device = device
    }

    private var commitMsg: JSONValue { ["device": .string(device), "listable": false] }

    // MARK: Блокноты

    public func notebooks() async throws -> [NSNotebook] {
        let data = try await dsm.call("SYNO.NoteStation.Notebook", "list", version: 2)
        return data.firstList(preferring: ["notebooks", "notebook", "list"]).compactMap(NSNotebook.init)
    }

    public func createNotebook(title: String) async throws -> NSNotebook {
        let data = try await dsm.call("SYNO.NoteStation.Notebook", "create", version: 2, [
            "title": .string(title), "commit_msg": commitMsg,
        ])
        guard let id = data["object_id"]?.stringish else { throw DSMError.malformedResponse }
        var obj = data.object ?? [:]
        obj["object_id"] = .string(id)
        obj["title"] = .string(title)
        return NSNotebook(.object(obj))!
    }

    public func renameNotebook(id: String, title: String) async throws {
        _ = try await dsm.call("SYNO.NoteStation.Notebook", "set", version: 2, [
            "object_id": .string(id), "title": .string(title), "commit_msg": commitMsg,
        ])
    }

    // MARK: Избранное

    /// Ярлыки «Избранного»: категория (notebook, note, tag, stack) и id.
    public func shortcuts() async throws -> [(category: String, id: String)] {
        let data = try await dsm.call("SYNO.NoteStation.Shortcut", "list", version: 1)
        return data.firstList(preferring: ["shortcuts", "list"]).compactMap { v in
            guard let c = v["category"]?.string, let id = v["id"]?.stringish ?? v["object_id"]?.stringish else { return nil }
            return (c, id)
        }
    }

    // MARK: Теги

    public func tags() async throws -> [NSTag] {
        let data = try await dsm.call("SYNO.NoteStation.Tag", "list", version: 1)
        return data.firstList(preferring: ["tags", "tag", "list"]).compactMap(NSTag.init)
    }

    // MARK: Заметки

    /// Все заметки (без тела), постранично.
    public func allNotes(pageSize: Int = 200) async throws -> [NSNote] {
        var result: [NSNote] = []
        var offset = 0
        while true {
            let data = try await dsm.call("SYNO.NoteStation.Note", "list", version: 3, [
                "offset": .int(offset), "limit": .int(pageSize),
                "sort_by": "mtime", "sort_direction": "desc",
            ])
            let raw = data.firstList(preferring: ["notes", "note", "list"])
            result += raw.compactMap(NSNote.init)
            offset += raw.count
            // total в ответе — размер страницы, а не общее число, поэтому
            // листаем, пока не придёт неполная страница.
            if raw.count < pageSize { break }
        }
        return result
    }

    public func note(id: String) async throws -> NSNote {
        let data = try await dsm.call("SYNO.NoteStation.Note", "get", version: 3, [
            "object_id": .string(id),
        ])
        guard let n = NSNote(data) else { throw DSMError.malformedResponse }
        return n
    }

    public func createNote(title: String, notebookID: String?, html: String) async throws -> NSWriteResult {
        var p: [String: JSONValue] = [
            "title": .string(title),
            "content": .string(html),
            "brief": .string(HTMLText.brief(from: html)),
            "commit_msg": commitMsg,
        ]
        if let notebookID { p["parent_id"] = .string(notebookID) }
        let data = try await dsm.call("SYNO.NoteStation.Note", "create", version: 3, p)
        return try writeResult(data)
    }

    /// Изменения заметки. nil — поле не меняется.
    public struct Changes: Sendable {
        public var title: String?
        public var html: String?
        public var notebookID: String?
        public var tags: [String]?
        public init(title: String? = nil, html: String? = nil, notebookID: String? = nil, tags: [String]? = nil) {
            self.title = title; self.html = html; self.notebookID = notebookID; self.tags = tags
        }
    }

    /// Новая картинка для заметки. `ref` — тот же, что в `<img ref="…">` в HTML.
    public struct NewAttachment: Sendable {
        public var ref: String
        public var filename: String
        public var mimeType: String
        public var data: Data
        public init(ref: String, filename: String, mimeType: String, data: Data) {
            self.ref = ref; self.filename = filename; self.mimeType = mimeType; self.data = data
        }
    }

    /// Сохранить заметку. С `checkConflict` сервер вернёт ошибку 1064,
    /// если на сервере уже другая версия (заметку правили где-то ещё).
    /// Новые картинки уходят тем же запросом (multipart), как в веб-версии.
    public func updateNote(id: String, ver: String?, _ c: Changes, attachments: [NewAttachment] = [],
                           checkConflict: Bool = true) async throws -> NSWriteResult {
        var p: [String: JSONValue] = [
            "object_id": .string(id),
            "check_conflict": .bool(checkConflict),
            "commit_msg": ["device": .string(device)],
        ]
        if let ver { p["ver"] = .string(ver) }
        if let t = c.title { p["title"] = .string(t) }
        if let h = c.html {
            p["content"] = .string(h)
            p["brief"] = .string(HTMLText.brief(from: h))
        }
        if let nb = c.notebookID { p["parent_id"] = .string(nb) }
        if let tags = c.tags { p["tag"] = .array(tags.map { .string($0) }) }
        if attachments.isEmpty {
            let data = try await dsm.call("SYNO.NoteStation.Note", "set", version: 3, p)
            return try writeResult(data, fallbackID: id)
        }
        var files: [DSMClient.UploadFile] = []
        var meta: [JSONValue] = []
        for (n, a) in attachments.enumerated() {
            let field = "nd_file_\(n)"
            files.append(.init(field: field, filename: a.filename, mimeType: a.mimeType, data: a.data))
            meta.append(["action": "create", "format": "raw", "name": .string(field),
                         "ref": .string(a.ref), "rotate": true])
        }
        p["attachment"] = .array(meta)
        let data = try await dsm.upload("SYNO.NoteStation.Note", "set", version: 3, p, files: files)
        return try writeResult(data, fallbackID: id)
    }

    /// Переместить в корзину (как кнопка «Удалить» в Note Station).
    /// Проверено: Note.set c recycle=true игнорируется, работает Note.delete c recycle=true.
    public func trashNote(id: String) async throws {
        _ = try await dsm.call("SYNO.NoteStation.Note", "delete", version: 3, [
            "object_id": .string(id), "recycle": true,
        ])
    }

    // MARK: Вложения

    /// URL вложения для WKWebView (с _sid в query).
    public func attachmentURL(noteID: String, fileID: String) async throws -> URL {
        try await dsm.url("SYNO.NoteStation.Note", "download", version: 3, [
            "object_id": .string(noteID), "file_id": .string(fileID), "format": "raw",
        ])
    }

    public func attachmentData(noteID: String, fileID: String) async throws -> Data {
        try await dsm.download("SYNO.NoteStation.Note", "download", version: 3, [
            "object_id": .string(noteID), "file_id": .string(fileID), "format": "raw",
        ])
    }

    // MARK: Разбор ответа на запись

    private func writeResult(_ data: JSONValue, fallbackID: String? = nil) throws -> NSWriteResult {
        // Встречаются {object_id, ver}, {data:[{object_id, ver}]} и [{...}]
        let candidates = [data, data["data"]?[0], data[0]].compactMap { $0 }
        for c in candidates {
            if let id = c["object_id"]?.stringish ?? fallbackID, c["ver"] != nil || c["object_id"] != nil {
                return NSWriteResult(
                    id: id, ver: c["ver"]?.stringish,
                    mtime: c["mtime"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) })
            }
        }
        if let fallbackID { return NSWriteResult(id: fallbackID, ver: nil, mtime: nil) }
        throw DSMError.malformedResponse
    }
}

public enum HTMLText {
    /// Короткий текст для превью — Note Station хранит его в поле brief.
    public static func brief(from html: String, limit: Int = 200) -> String {
        var s = html
        for tag in ["</p>", "</div>", "<br>", "<br/>", "<br />", "</li>", "</h1>", "</h2>", "</h3>"] {
            s = s.replacingOccurrences(of: tag, with: " \n", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.prefix(limit))
    }
}
