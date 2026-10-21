import Foundation
import ImageIO

/// Превью заметок: память (ограниченно) + диск (Caches/Thumbnails/<md5>).
/// md5 меняется вместе с картинкой, поэтому кэш никогда не устаревает.
final class ThumbnailStore {
    private let memory = NSCache<NSString, CGImage>()
    private var inflight: [String: Task<CGImage?, Never>] = [:]
    private let dir: URL

    init() {
        memory.countLimit = 400
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func image(md5: String, fetch: @escaping () async throws -> Data) async -> CGImage? {
        if let img = memory.object(forKey: md5 as NSString) { return img }
        if let task = inflight[md5] { return await task.value }
        let file = dir.appending(path: md5)
        let task = Task<CGImage?, Never> {
            let data: Data
            if let d = try? Data(contentsOf: file) {
                data = d
            } else {
                guard let d = try? await fetch() else { return nil }
                try? d.write(to: file, options: .atomic)
                data = d
            }
            return Self.decode(data, maxPixels: 160)
        }
        inflight[md5] = task
        let img = await task.value
        inflight[md5] = nil
        if let img { memory.setObject(img, forKey: md5 as NSString) }
        return img
    }

    /// Уменьшаем при декодировании — в списке превью 56 pt.
    private static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
