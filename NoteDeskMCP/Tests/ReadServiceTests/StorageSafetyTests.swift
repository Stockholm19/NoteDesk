import Foundation
import SwiftData
import Testing

@MainActor struct StorageSafetyTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NoteDesk-safety-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func open(_ url: URL) throws -> ModelContainer {
        let schema = Schema([LocalNote.self, NoteBody.self, LocalNotebook.self, PendingAttachment.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration("SafetyTests", schema: schema, url: url))
    }

    @Test func failedOpenLeavesFilesUntouchedAndRetryUsesSameStore() throws {
        let root = try directory()
        let url = root.appendingPathComponent("test.store")
        let sentinels = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        for file in sentinels { try Data("synthetic-sentinel".utf8).write(to: file) }
        var attempts = 0
        let opening = StoreOpening {
            attempts += 1
            throw NSError(domain: NSCocoaErrorDomain, code: 134100,
                          userInfo: [NSLocalizedDescriptionKey: "SECRET", NSFilePathErrorKey: url.path])
        }
        opening.retry(); opening.retry()
        #expect(attempts == 2)
        #expect(opening.container == nil)
        #expect(opening.diagnostic?.contains("SECRET") == false)
        #expect(opening.diagnostic?.contains(root.path) == false)
        for file in sentinels { #expect(try Data(contentsOf: file) == Data("synthetic-sentinel".utf8)) }

        let goodURL = root.appendingPathComponent("good.store")
        var retryAttempts = 0
        let retrying = StoreOpening {
            retryAttempts += 1
            if retryAttempts == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
            return try open(goodURL)
        }
        retrying.retry()
        #expect(retrying.container == nil)
        retrying.retry()
        let first = try #require(retrying.container)
        #expect(retrying.diagnostic == nil)
        #expect(!first.mainContext.autosaveEnabled)
        retrying.retry()
        #expect(retrying.container === first)
    }

    @Test func diagnosticNeverCopiesArbitraryDomainsOrUserInfo() {
        let error = NSError(domain: "SECRET-domain", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "SECRET-content",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28,
                                          userInfo: [NSFilePathErrorKey: "/SECRET/path"])
        ])
        let text = StorageDiagnostic.describe(error)
        #expect(!text.contains("SECRET"))
        #expect(text.contains("OtherErrorDomain code=7"))
        #expect(text.contains("NSPOSIXErrorDomain code=28"))
    }

    @Test func actualOpenFailureDoesNotReplaceInvalidStore() throws {
        let url = try directory().appendingPathComponent("invalid.store")
        let bytes = Data("This is a synthetic invalid SQLite file".utf8)
        try bytes.write(to: url)
        let opening = StoreOpening { try open(url) }
        opening.retry()
        #expect(opening.container == nil)
        #expect(opening.diagnostic != nil)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func failedSaveRetainsChangesAndAcknowledgementUntilExplicitRetry() throws {
        let url = try directory().appendingPathComponent("test.store")
        let payload = Data(repeating: 0xA5, count: 1_200_000)
        var id: UUID!
        do {
            let container = try open(url)
            let context = container.mainContext
            var fail = true
            var attempts = 0
            let persistence = LocalPersistence(context: context) {
                attempts += 1
                if fail { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
                try context.save()
            }
            let note = LocalNote(notebookID: nil, title: "Synthetic", html: "<img ref='image'>", tags: ["test"], isDirty: true)
            id = note.localID
            context.insert(note)
            context.insert(PendingAttachment(noteLocalID: note.localID, ref: "image", filename: "synthetic.bin", mimeType: "application/octet-stream", data: payload))
            #expect(throws: LocalPersistence.Failure.self) { try persistence.save() }
            #expect(persistence.hasFailure)
            #expect(context.hasChanges)
            #expect(throws: LocalPersistence.Failure.self) { try persistence.save() }
            #expect(attempts == 1)
            fail = false
            #expect(persistence.retry())
            #expect(!persistence.hasFailure)
            #expect(!context.hasChanges)
            // Model a successful server reply whose local acknowledgement cannot yet save.
            note.remoteID = "synthetic-remote-id"
            note.remoteVer = "2"
            note.isDirty = false
            fail = true
            #expect(throws: LocalPersistence.Failure.self) { try persistence.save() }
            #expect(note.remoteID == "synthetic-remote-id")
            #expect(!persistence.retry())
            fail = false
            #expect(persistence.retry())
        }
        let reopened = try open(url)
        let notes = try reopened.mainContext.fetch(FetchDescriptor<LocalNote>())
        let note = try #require(notes.first)
        #expect(notes.count == 1)
        #expect(note.localID == id)
        #expect(note.title == "Synthetic")
        #expect(note.html == "<img ref='image'>")
        #expect(note.tags == ["test"])
        #expect(note.remoteID == "synthetic-remote-id")
        #expect(note.remoteVer == "2")
        #expect(!note.isDirty)
        let attachments = try reopened.mainContext.fetch(FetchDescriptor<PendingAttachment>())
        #expect(attachments.count == 1)
        #expect(attachments.first?.noteLocalID == id)
        #expect(attachments.first?.data == payload)
    }
}
