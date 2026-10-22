import Foundation
import os

nonisolated let attachmentLog = Logger(subsystem: "ru.klotze.NoteDesk", category: "attachments")

/// Проверяет, является ли ошибка отменой операции (пользователь нажал отмену, Task отменен).
public func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
    if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return true }
    return false
}

/// Дисковый кеш для вложений заметки (файлы, видео, документы).
/// Хранит файлы в Library/Caches/Attachments, скачивает их потоково без загрузки целиком в RAM.
actor AttachmentCache {
    static let shared = AttachmentCache()

    private let cacheDir: URL
    private var activeTasks: [String: Task<URL, Error>] = [:]

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("Attachments", isDirectory: true)
        cacheDir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Безопасный локальный URL файла в кеше.
    nonisolated func targetURL(fileID: String, filename: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("Attachments", isDirectory: true)
        let cleanName = filename.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = cleanName.isEmpty ? "file" : cleanName
        return dir.appendingPathComponent("\(fileID)_\(name)")
    }

    /// Проверяет, скачан ли файл в кеш, и возвращает его URL.
    nonisolated func cachedFileURL(fileID: String, filename: String) -> URL? {
        let url = targetURL(fileID: fileID, filename: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 0 else {
            return nil
        }
        return url
    }

    /// Быстрое чтение данных из кеша (например, для коротких роликов-гифок в webView).
    nonisolated func cachedData(fileID: String, filename: String) -> Data? {
        guard let url = cachedFileURL(fileID: fileID, filename: filename) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Проверяет статус наличия в кеше.
    nonisolated func isCached(fileID: String, filename: String) -> Bool {
        cachedFileURL(fileID: fileID, filename: filename) != nil
    }

    /// Потоковое скачивание вложения на диск с отслеживанием прогресса.
    /// Не держит файл целиком в памяти. Повторные вызовы для одного fileID объединяются.
    func download(
        fileID: String,
        filename: String,
        from remoteURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let dest = targetURL(fileID: fileID, filename: filename)
        if cachedFileURL(fileID: fileID, filename: filename) != nil {
            onProgress?(1.0)
            return dest
        }

        if let existing = activeTasks[fileID] {
            return try await existing.value
        }

        let task = Task<URL, Error> {
            let tempURL = self.cacheDir.appendingPathComponent("\(fileID)_\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            attachmentLog.debug("downloading \(fileID, privacy: .public): \(filename, privacy: .public)")
            let (bytes, response) = try await URLSession.shared.bytes(from: remoteURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }

            let expected = response.expectedContentLength
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }

            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(65536)

            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                received += 1

                if buffer.count >= 65536 {
                    handle.write(buffer)
                    buffer.removeAll(keepingCapacity: true)
                    if expected > 0 {
                        let frac = min(1.0, max(0.0, Double(received) / Double(expected)))
                        onProgress?(frac)
                    }
                }
            }

            if !buffer.isEmpty {
                handle.write(buffer)
            }

            onProgress?(1.0)
            _ = try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            attachmentLog.debug("downloaded \(fileID, privacy: .public) to \(dest.path, privacy: .public)")
            return dest
        }

        activeTasks[fileID] = task
        do {
            let result = try await task.value
            activeTasks.removeValue(forKey: fileID)
            return result
        } catch {
            activeTasks.removeValue(forKey: fileID)
            throw error
        }
    }

    /// Отмена скачивания вложения.
    nonisolated func cancel(fileID: String) {
        Task { await self.cancelInternal(fileID: fileID) }
    }

    private func cancelInternal(fileID: String) {
        activeTasks.removeValue(forKey: fileID)?.cancel()
    }

    /// Удаление файла из дискового кеша (например, при удалении вложения).
    nonisolated func remove(fileID: String, filename: String) {
        let url = targetURL(fileID: fileID, filename: filename)
        try? FileManager.default.removeItem(at: url)
        Task { await self.cancel(fileID: fileID) }
    }

    /// Очистить весь дисковый кеш вложений.
    func clearAll() {
        for (_, t) in activeTasks { t.cancel() }
        activeTasks.removeAll()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}
