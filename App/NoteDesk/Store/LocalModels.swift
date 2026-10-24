import Foundation
import SwiftData

/// Локальная копия блокнота Note Station.
@Model
final class LocalNotebook {
    @Attribute(.unique) var remoteID: String
    var title: String
    var ver: String?
    /// Стопка (группа блокнотов) в Note Station; nil — блокнот без стопки.
    var stack: String?
    /// Записная книжка по умолчанию.
    var isPreset: Bool = false
    /// В архиве Note Station.
    var isArchived: Bool = false

    init(remoteID: String, title: String, ver: String?, stack: String? = nil) {
        self.remoteID = remoteID
        self.title = title
        self.ver = ver
        self.stack = stack
    }
}

/// Локальная копия заметки. Источник правды — сервер; локальные правки
/// помечаются isDirty и уходят на сервер при следующей синхронизации.
@Model
final class LocalNote {
    @Attribute(.unique) var localID: UUID
    /// object_id на сервере; nil — заметка создана здесь и ещё не отправлена.
    var remoteID: String?
    var notebookID: String?
    var title: String
    /// Тело — отдельной сущностью: список из ~2000 заметок не должен тянуть
    /// в память весь HTML при каждом обновлении.
    @Relationship(deleteRule: .cascade) var body: NoteBody?
    var brief: String
    var tags: [String]
    /// Теги изменены здесь и ещё не отправлены (теги уходят на сервер только тогда,
    /// чтобы не затереть теги, изменённые в Note Station).
    var tagsEdited: Bool = false
    /// Версия на сервере, от которой сделаны локальные правки.
    var remoteVer: String?
    var ctime: Date
    var mtime: Date
    var isEncrypted: Bool
    /// Есть неотправленные правки.
    var isDirty: Bool
    /// Удалена здесь, нужно отправить в корзину на сервере.
    var isTrashedLocally: Bool
    /// На сервере новая версия — тело нужно перекачать.
    var needsContent: Bool
    /// ref → file_id для картинок внутри HTML.
    var imageRefs: [String: String]
    /// md5 превью-картинки от Note Station; nil — превью нет.
    var thumbMD5: String?
    /// JSON-список вложений заметки (файлы, видео) для мгновенного показа без сетевых запросов.
    var attachmentsJSON: String?

    init(remoteID: String? = nil, notebookID: String?, title: String, html: String?, brief: String = "",
         tags: [String] = [], remoteVer: String? = nil, ctime: Date = .now, mtime: Date = .now,
         isEncrypted: Bool = false, isDirty: Bool = false, needsContent: Bool = false,
         attachmentsJSON: String? = nil) {
        self.localID = UUID()
        self.remoteID = remoteID
        self.notebookID = notebookID
        self.title = title
        self.body = html.map { NoteBody(html: $0) }
        self.brief = brief
        self.tags = tags
        self.remoteVer = remoteVer
        self.ctime = ctime
        self.mtime = mtime
        self.isEncrypted = isEncrypted
        self.isDirty = isDirty
        self.isTrashedLocally = false
        self.needsContent = needsContent
        self.imageRefs = [:]
        self.attachmentsJSON = attachmentsJSON
    }

    var displayTitle: String { title.isEmpty ? "Без названия" : title }

    /// HTML-тело в формате Note Station. nil — ещё не скачано.
    var html: String? {
        get { body?.html }
        set {
            guard let newValue else { body = nil; return }
            if let body { body.html = newValue } else { body = NoteBody(html: newValue) }
        }
    }

    var cachedAttachments: [LocalAttachmentMeta] {
        get {
            guard let attachmentsJSON, let data = attachmentsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([LocalAttachmentMeta].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                attachmentsJSON = String(data: data, encoding: .utf8)
            } else {
                attachmentsJSON = nil
            }
        }
    }
}

/// Метаданные вложения, сохранённые локально.
struct LocalAttachmentMeta: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var ref: String?
    var name: String?
    var type: String?
    var size: Int?
    var md5: String?

    var isVideo: Bool {
        let ext = ((name ?? "") as NSString).pathExtension.lowercased()
        return ["mp4", "m4v", "mov", "webm"].contains(ext) || (type?.lowercased().hasPrefix("video/") ?? false)
    }

    var mimeType: String {
        if let type, !type.isEmpty { return type }
        let ext = ((name ?? "") as NSString).pathExtension.lowercased()
        return ["mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"][ext] ?? "application/octet-stream"
    }

    var formattedSize: String? {
        size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}

@Model
final class NoteBody {
    var html: String
    var note: LocalNote?

    init(html: String) { self.html = html }
}

/// Картинка, вставленная здесь и ещё не загруженная на сервер.
/// Уходит вместе с заметкой при следующей синхронизации.
@Model
final class PendingAttachment {
    var noteLocalID: UUID
    var ref: String
    var filename: String
    var mimeType: String
    @Attribute(.externalStorage) var data: Data
    var created: Date

    init(noteLocalID: UUID, ref: String, filename: String, mimeType: String, data: Data) {
        self.noteLocalID = noteLocalID
        self.ref = ref
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.created = .now
    }
}
