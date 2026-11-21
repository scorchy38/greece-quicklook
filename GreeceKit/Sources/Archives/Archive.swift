import Foundation

public enum ArchiveFormat: String, Equatable, Sendable {
    case zip, tar, gzip, bzip2, xz

    static func sniff(_ bytes: [UInt8], name: String) -> ArchiveFormat? {
        func starts(_ magic: [UInt8]) -> Bool { bytes.count >= magic.count && Array(bytes.prefix(magic.count)) == magic }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if starts([0x1F, 0x8B]) { return .gzip }
        if starts([0x42, 0x5A, 0x68]) { return .bzip2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if bytes.count >= 262, Array(bytes[257..<262]) == Array("ustar".utf8) { return .tar }
        if name.hasSuffix(".tar"), bytes.count >= 512, TarReader.isValidHeader(bytes[0..<512]) { return .tar }
        return nil
    }
}

public struct ArchiveEntry: Sendable {
    public var path: String
    public var isDirectory: Bool
    public var isSymlink = false
    public var size: UInt64
    public var compressedSize: UInt64?
    public var modified: Date?
    public var isEncrypted = false
}

public struct ArchiveListing: Sendable {
    public enum Container: Sendable { case zip, tar, compressedFile }
    public var format: ArchiveFormat
    public var container: Container
    public var entries: [ArchiveEntry]
    public var archiveSize: UInt64
    /// Stopped early because the archive is huge.
    public var truncated = false
    /// For a single compressed file: its first bytes, so text can be previewed directly.
    public var innerPrefix: Data?

    public var fileCount: Int { entries.lazy.filter { !$0.isDirectory }.count }
    public var totalSize: UInt64 { entries.reduce(0) { $1.isDirectory ? $0 : $0.saturatingAdd($1.size) } }
    public var isEncrypted: Bool { entries.contains { $0.isEncrypted } }

    public var title: String {
        switch (format, container) {
        case (.zip, _): return "ZIP Archive"
        case (.tar, _): return "Tar Archive"
        case (.gzip, .tar): return "Tar Archive · gzip"
        case (.bzip2, .tar): return "Tar Archive · bzip2"
        case (.xz, .tar): return "Tar Archive · xz"
        case (.gzip, _): return "gzip Compressed File"
        case (.bzip2, _): return "bzip2 Compressed File"
        case (.xz, _): return "xz Compressed File"
        }
    }
}

extension UInt64 {
    /// Archive sizes come from untrusted headers: add without ever trapping.
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

public enum ArchiveError: LocalizedError {
    case corrupt(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .corrupt(let reason): return "This archive appears to be damaged (\(reason))."
        case .unsupported(let reason): return reason
        }
    }
}

public enum ArchiveReader {
    public static let entryLimit = 200_000

    public static func read(_ url: URL, format: ArchiveFormat) throws -> ArchiveListing {
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        switch format {
        case .zip:
            return try ZIPReader.read(url, archiveSize: size)
        case .tar:
            let reader = try TarReader(source: FileSource(url: url))
            var listing = try reader.listing()
            listing.format = .tar
            listing.archiveSize = size
            return listing
        case .gzip, .bzip2, .xz:
            let source: ByteSource
            switch format {
            case .gzip: source = try GzipSource(url: url)
            case .bzip2: source = try Bzip2Source(url: url)
            default: source = try XZSource(url: url)
            }
            let buffered = BufferedReader(source)
            let first = try buffered.peek(512)
            if first.count == 512, TarReader.isValidHeader(first[first.startIndex...]) {
                var listing = try TarReader(reader: buffered).listing()
                listing.format = format
                listing.archiveSize = size
                return listing
            }
            return try singleFile(url: url, format: format, reader: buffered, archiveSize: size)
        }
    }

    private static func singleFile(url: URL, format: ArchiveFormat, reader: BufferedReader, archiveSize: UInt64) throws -> ArchiveListing {
        var name = url.deletingPathExtension().lastPathComponent
        if format == .gzip, let original = GzipSource.originalName(url) { name = original }
        // Keep the beginning for an inline text preview, then count the rest.
        var prefix = Data()
        while prefix.count < TextFile.defaultLimit {
            let chunk = try reader.read(upTo: min(1 << 20, TextFile.defaultLimit - prefix.count))
            if chunk.isEmpty { break }
            prefix.append(chunk)
        }
        var total = UInt64(prefix.count)
        if format == .gzip, let isize = GzipSource.trailerSize(url), isize >= total {
            total = isize
        } else {
            while true {
                let chunk = try reader.read(upTo: 1 << 20)
                if chunk.isEmpty { break }
                total = total.saturatingAdd(UInt64(chunk.count))
            }
        }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let entry = ArchiveEntry(path: name, isDirectory: false, size: total, compressedSize: archiveSize, modified: modified)
        return ArchiveListing(format: format, container: .compressedFile, entries: [entry], archiveSize: archiveSize, innerPrefix: prefix)
    }
}
