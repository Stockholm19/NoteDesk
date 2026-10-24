import Foundation
import Observation
import SwiftData
import os

/// Only allowlisted error metadata is safe to copy; userInfo may contain paths or content.
enum StorageDiagnostic {
    static let log = Logger(subsystem: "ru.klotze.NoteDesk", category: "storage")

    static func describe(_ error: Error) -> String {
        var result = ["NoteDesk storage diagnostic", "Store: NoteDesk-v2"]
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let value = current else { break }
            let known = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain, "NSSQLiteErrorDomain"]
            let domain = known.contains(value.domain) ? value.domain : "OtherErrorDomain"
            result.append("\(domain) code=\(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result.joined(separator: "\n")
    }
}

@MainActor @Observable
final class StoreOpening {
    private(set) var container: ModelContainer?
    private(set) var diagnostic: String?
    private let open: @MainActor () throws -> ModelContainer

    init(open: @escaping @MainActor () throws -> ModelContainer = StoreOpening.openDefault) {
        self.open = open
    }

    static func openDefault() throws -> ModelContainer {
        let schema = Schema([LocalNote.self, NoteBody.self, LocalNotebook.self, PendingAttachment.self])
        let config = ModelConfiguration("NoteDesk-v2", schema: schema)
        return try ModelContainer(for: schema, configurations: config)
    }

    func retry() {
        guard container == nil else { return }
        do {
            let opened = try open()
            opened.mainContext.autosaveEnabled = false
            container = opened
            diagnostic = nil
        } catch {
            let safe = StorageDiagnostic.describe(error)
            diagnostic = safe
            StorageDiagnostic.log.error("\(safe, privacy: .public)")
        }
    }
}

/// Keep failed changes in the same context. Never rollback or replay the user action.
@MainActor @Observable
final class LocalPersistence {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "Local changes are not saved. Retry local saving before syncing."
        }
    }

    private(set) var diagnostic: String?
    private let write: () throws -> Void
    var hasFailure: Bool { diagnostic != nil }

    init(context: ModelContext, write: (() throws -> Void)? = nil) {
        context.autosaveEnabled = false
        self.write = write ?? { try context.save() }
    }

    func save() throws {
        guard !hasFailure else { throw Failure() }
        try attempt()
    }

    @discardableResult
    func retry() -> Bool {
        do { try attempt(); return true }
        catch { return false }
    }

    private func attempt() throws {
        do {
            try write()
            diagnostic = nil
        } catch {
            let safe = StorageDiagnostic.describe(error)
            diagnostic = safe
            StorageDiagnostic.log.error("\(safe, privacy: .public)")
            throw Failure()
        }
    }
}
