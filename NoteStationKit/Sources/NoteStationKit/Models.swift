import Foundation

public struct NSNotebook: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var ver: String?
    public var itemCount: Int?
    public var stack: String?
    public var ctime: Date?
    public var mtime: Date?

    public init?(_ v: JSONValue) {
        guard let id = v["object_id"]?.stringish else { return nil }
        self.id = id
        title = v["title"]?.string ?? ""
        ver = v["ver"]?.stringish
        itemCount = v["item_count"]?.int ?? v["items"]?.array?.count
        stack = v["stack"]?.string
        ctime = v["ctime"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        mtime = v["mtime"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public struct NSTag: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String

    public init?(_ v: JSONValue) {
        guard let id = v["object_id"]?.stringish ?? v["tag_id"]?.stringish else { return nil }
        self.id = id
        title = v["title"]?.string ?? ""
    }
}

public struct NSAttachment: Sendable, Hashable, Identifiable {
    /// file_id — ключ в словаре attachment заметки.
    public var id: String
    /// ref — так вложение упоминается в HTML (`<img ref="...">`).
    public var ref: String?
    public var name: String?
    public var type: String?
    public var md5: String?
    public var size: Int?
    public var width: Int?
    public var height: Int?

    init(id: String, _ v: JSONValue) {
        self.id = id
        ref = v["ref"]?.string
        name = v["name"]?.string
        type = v["type"]?.string ?? v["format"]?.string
        md5 = v["md5"]?.string
        size = v["size"]?.int
        width = v["width"]?.int
        height = v["height"]?.int
    }

    public var isImage: Bool {
        if let t = type?.lowercased(), t.hasPrefix("image") { return true }
        let ext = (name as NSString?)?.pathExtension.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff"].contains(ext)
    }
}

/// Заметка. В списке приходит без content, полная — через Note.get.
public struct NSNote: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var brief: String
    public var parentID: String?
    public var ver: String?
    public var ctime: Date?
    public var mtime: Date?
    /// Теги приходят только в Note.get; в Note.list их нет (nil).
    public var tags: [String]?
    public var recycle: Bool
    public var encrypt: Bool
    public var archive: Bool
    /// md5 превью-картинки (Note Station сам делает thumb из первой картинки); nil — превью нет.
    public var thumbMD5: String?
    /// HTML-тело. nil — не загружено.
    public var content: String?
    public var attachments: [NSAttachment]
    public var raw: JSONValue

    public init?(_ v: JSONValue) {
        guard let id = v["object_id"]?.stringish else { return nil }
        self.id = id
        title = v["title"]?.string ?? ""
        brief = v["brief"]?.string ?? ""
        parentID = v["parent_id"]?.stringish
        ver = v["ver"]?.stringish
        ctime = v["ctime"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        mtime = v["mtime"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        tags = v["tag"]?.array?.compactMap { $0.string ?? $0["title"]?.string }
        recycle = v["recycle"]?.bool ?? false
        encrypt = v["encrypt"]?.bool ?? false
        archive = v["archive"]?.bool ?? false
        thumbMD5 = v["thumb"]?["md5"]?.string
        content = v["content"]?.string
        if let dict = v["attachment"]?.object {
            attachments = dict.map { NSAttachment(id: $0.key, $0.value) }.sorted { $0.id < $1.id }
        } else {
            attachments = []
        }
        raw = v
    }
}

/// Результат записи заметки: новая версия.
public struct NSWriteResult: Sendable, Hashable {
    public var id: String
    public var ver: String?
    public var mtime: Date?
}

extension JSONValue {
    /// Первый массив объектов в ответе — DSM кладёт списки под разными ключами
    /// (notes, notebooks, tags, list…).
    func firstList(preferring keys: [String]) -> [JSONValue] {
        for k in keys { if let a = self[k]?.array { return a } }
        if let a = array { return a }
        if let o = object {
            for (_, v) in o.sorted(by: { $0.key < $1.key }) {
                if let a = v.array, a.first?.object != nil { return a }
            }
        }
        return []
    }
}
