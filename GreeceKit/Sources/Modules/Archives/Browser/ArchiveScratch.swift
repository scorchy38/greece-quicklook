import Foundation

/// Where files extracted for a preview live: a private folder in the extension's own temporary
/// directory, removed when the archive's preview closes.
final class ArchiveScratch: @unchecked Sendable {
    static let base = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceArchives", isDirectory: true)
    let folder: URL
    private let lock = NSLock()
    private var counter = 0

    init() {
        ArchiveScratch.sweepOnce
        folder = ArchiveScratch.base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// Leftovers from previews that ended abruptly (the extension was killed) go after a few hours.
    private static let sweepOnce: Void = {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let old = Date().addingTimeInterval(-6 * 3600)
        for folder in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: Array(keys))) ?? [] {
            if let modified = try? folder.resourceValues(forKeys: keys).contentModificationDate, modified < old {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }()

    /// A fresh location for an extracted file, keeping its (sanitised) name so its type is recognised.
    func location(for name: String) -> URL {
        lock.lock()
        counter += 1
        let number = counter
        lock.unlock()
        let directory = folder.appendingPathComponent(String(number), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(ArchiveScratch.safeName(name))
    }

    /// A single path component that can't escape the folder, at most 200 bytes, keeping the extension.
    static func safeName(_ name: String) -> String {
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar -> Unicode.Scalar in
            scalar.value < 0x20 || scalar == "/" || scalar == ":" || scalar == "\\" || scalar.value == 0x7F ? "_" : scalar
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "file" }
        if cleaned.utf8.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            let keep = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
            var stem = cleaned
            while stem.utf8.count + keep.utf8.count > 200 { stem.removeLast() }
            cleaned = stem + keep
        }
        return cleaned
    }
}

extension ArchiveSession {
    /// The largest member Greece extracts to show inside the archive.
    static let previewLimit: UInt64 = 256 * 1024 * 1024

    /// Extracts an entry to a file in `scratch`, keeping its name and date. Throws `.tooLarge` past `limit`.
    func extract(_ entry: ArchiveEntry, to scratch: ArchiveScratch, limit: UInt64 = ArchiveSession.previewLimit,
                 cancel: CancelToken? = nil) throws -> URL {
        if entry.size > limit { throw ArchiveError.tooLarge }
        let destination = scratch.location(for: (entry.path as NSString).lastPathComponent)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw ArchiveError.unsupported(String(localized: "Greece couldn’t make room to preview this file.", bundle: .greeceKit))
        }
        do {
            let (_, complete) = try extract(entry, limit: limit, cancel: cancel) { chunk in
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            guard complete else { throw ArchiveError.tooLarge }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        if let modified = entry.modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
        }
        return destination
    }
}
