#if os(macOS)
import Foundation
import SwiftData
import NoteDeskMCP

/// Thin read-only service. No Account, API client, downloads, saves, or sync triggers.
@MainActor
struct MCPReadService {
    let context: ModelContext
    func read(_ call: ReadRequest, allowed: Set<String>, sync: [String: Any]) -> ReadReply {
        do {
            let payload: [String: Any]
            switch call.name {
            case "get_sync_status":
                payload = sync
            case "list_notebooks":
                let ids = allowed.sorted()
                var descriptor = FetchDescriptor<LocalNotebook>(predicate: #Predicate { ids.contains($0.remoteID) }, sortBy: [SortDescriptor(\.remoteID)])
                descriptor.fetchOffset = call.offset; descriptor.fetchLimit = call.limit + 1
                let rows = try context.fetch(descriptor)
                payload = ["notebooks": rows.prefix(call.limit).map { ["id": $0.remoteID, "title": clean($0.title, limit: 512)] }, "next_offset": rows.count > call.limit ? call.offset + call.limit : NSNull()]
            case "search_notes":
                let ids: [String?] = allowed.sorted().map { Optional($0) }
                var descriptor = FetchDescriptor<LocalNote>(predicate: #Predicate {
                    !$0.isEncrypted && !$0.isTrashedLocally && ids.contains($0.notebookID)
                }, sortBy: [SortDescriptor(\.localID)])
                // A page scans at most 50 allowed metadata rows. No body faulting/full-store scan.
                descriptor.fetchOffset = call.offset; descriptor.fetchLimit = call.limit + 1
                let rows = try context.fetch(descriptor)
                let notes = rows.prefix(call.limit).filter { note in
                    ReadPolicy.permits(notebook: note.notebookID, allowed: allowed, encrypted: note.isEncrypted, trashed: note.isTrashedLocally) &&
                    (call.query.isEmpty || clean(note.title, limit: 4096).localizedStandardContains(call.query) || clean(note.brief, limit: 4096).localizedStandardContains(call.query))
                }
                payload = ["notes": notes.map(metadata), "next_offset": rows.count > call.limit ? call.offset + call.limit : NSNull(), "search_scope": "local_title_and_brief", "source": "local_cache"]
            case "get_note":
                guard let uuid = UUID(uuidString: call.id) else { return .unavailable }
                let ids: [String?] = allowed.sorted().map { Optional($0) }
                var descriptor = FetchDescriptor<LocalNote>(predicate: #Predicate {
                    $0.localID == uuid && !$0.isEncrypted && !$0.isTrashedLocally && ids.contains($0.notebookID)
                })
                descriptor.fetchLimit = 1
                guard let note = try context.fetch(descriptor).first,
                    ReadPolicy.permits(notebook: note.notebookID, allowed: allowed, encrypted: note.isEncrypted, trashed: note.isTrashedLocally) else { return .unavailable }
                var item = metadata(note)
                if let html = note.html {
                    // Cap CPU/memory work on the UI actor. Oversized bodies are not partially sanitized.
                    guard html.utf8.count <= 1_000_000 else {
                        item["body_status"] = "too_large"; item["text"] = NSNull()
                        return json(item)
                    }
                    let text = ReadPolicy.safeText(html)
                    let part = String(text.dropFirst(call.offset).prefix(call.limit))
                    item["text"] = part
                    item["body_status"] = note.needsContent ? "stale" : "available"
                    item["next_offset"] = call.offset + part.count < text.count ? call.offset + part.count : NSNull()
                } else { item["body_status"] = "not_downloaded"; item["text"] = NSNull(); item["next_offset"] = NSNull() }
                payload = item
            default: return .unavailable
            }
            return json(payload)
        } catch { return .unavailable } // never leak SwiftData/server error descriptions
    }
    private func metadata(_ note: LocalNote) -> [String: Any] {
        ["id": note.localID.uuidString, "notebook_id": note.notebookID ?? "", "title": clean(note.title, limit: 512), "brief": clean(note.brief, limit: 1024), "modified": ISO8601DateFormatter().string(from: note.mtime), "pending_local_changes": note.isDirty, "needs_content": note.needsContent]
    }
    private func clean(_ value: String, limit: Int) -> String { String(ReadPolicy.safeText(String(value.prefix(8192))).prefix(limit)) }
    private func json(_ value: [String: Any]) -> ReadReply {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 256_000 else { return .unavailable }
        return .json(String(decoding: data, as: UTF8.self))
    }
}
#endif
