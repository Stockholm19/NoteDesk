import Testing
import SwiftData
import Foundation
import NoteDeskMCP

@MainActor struct ReadTests {
    @Test func testRealStorePermissionsAndMissingBody() throws {
        let schema = Schema([LocalNotebook.self, LocalNote.self, NoteBody.self, PendingAttachment.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.insert(LocalNotebook(remoteID: "allowed", title: "Allowed", ver: nil))
        context.insert(LocalNotebook(remoteID: "hidden", title: "Hidden", ver: nil))
        let visible = LocalNote(notebookID: "allowed", title: "Visible", html: nil, needsContent: true)
        let hidden = LocalNote(notebookID: "hidden", title: "SECRET", html: "SECRET")
        let locked = LocalNote(notebookID: "allowed", title: "LOCKED", html: "SECRET", isEncrypted: true)
        let trashed = LocalNote(notebookID: "allowed", title: "TRASHED", html: "SECRET"); trashed.isTrashedLocally = true
        for note in [visible, hidden, locked, trashed] { context.insert(note) }
        try context.save()
        let service = MCPReadService(context: context)
        func text(_ reply: ReadReply) -> String { if case .json(let s) = reply { return s }; return "DENIED" }
        let search = try ReadRequest(name: "search_notes", arguments: [:])
        let result = text(service.read(search, allowed: ["allowed"], sync: [:]))
        #expect(result.contains("Visible")); #expect(!result.contains("SECRET")); #expect(!result.contains("LOCKED")); #expect(!result.contains("TRASHED"))
        #expect(!text(service.read(search, allowed: [], sync: [:])).contains("Visible"))
        for note in [hidden, locked, trashed] {
            let request = try ReadRequest(name: "get_note", arguments: ["id": .string(note.localID.uuidString)])
            #expect(text(service.read(request, allowed: ["allowed"], sync: [:])) == "DENIED")
        }
        let request = try ReadRequest(name: "get_note", arguments: ["id": .string(visible.localID.uuidString)])
        #expect(text(service.read(request, allowed: ["allowed"], sync: [:])).contains("not_downloaded"))
        visible.html = "<p>Hello</p><img src='http://nas/webapi/entry.cgi?_sid=SECRET'>"
        let body = text(service.read(request, allowed: ["allowed"], sync: [:]))
        #expect(body.contains("Hello")); #expect(body.contains("stale")); #expect(!body.contains("SECRET"))
        #expect(text(service.read(request, allowed: [], sync: [:])) == "DENIED")
        let books = text(service.read(try ReadRequest(name: "list_notebooks", arguments: [:]), allowed: ["allowed"], sync: [:]))
        #expect(books.contains("Allowed")); #expect(!books.contains("Hidden"))
        let paged = try ReadRequest(name: "get_note", arguments: ["id": .string(visible.localID.uuidString), "offset": .int(1), "limit": .int(2)])
        let page = text(service.read(paged, allowed: ["allowed"], sync: [:]))
        #expect(page.contains("next_offset"))
        visible.html = String(repeating: "a", count: 1_000_001)
        #expect(text(service.read(request, allowed: ["allowed"], sync: [:])).contains("too_large"))
        let unmatched = try ReadRequest(name: "search_notes", arguments: ["query": .string("does not exist")])
        #expect(!text(service.read(unmatched, allowed: ["allowed"], sync: [:])).contains("Visible"))

    }
}
