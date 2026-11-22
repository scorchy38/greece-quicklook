import Foundation

/// The container or compression format of an archive.
public enum ArchiveFormat: String, Equatable, Sendable, CaseIterable {
    case zip, tar, gzip, bzip2, xz
    case sevenZip = "7z", rar, zstd, lzma, lzip, compress
    case cab, lha, xar, cpio, iso, ar, rpm, deb, warc

    /// Greece's generic detection (used only when no module claimed the file).
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

    /// A stream compressor (one file inside, often a tarball) rather than a container.
    var isCompressor: Bool { [.gzip, .bzip2, .xz, .zstd, .lzma, .lzip, .compress].contains(self) }

    var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .tar: return "Tar"
        case .gzip: return "gzip"
        case .bzip2: return "bzip2"
        case .xz: return "xz"
        case .sevenZip: return "7-Zip"
        case .rar: return "RAR"
        case .zstd: return "Zstandard"
        case .lzma: return "LZMA"
        case .lzip: return "lzip"
        case .compress: return "compress"
        case .cab: return "Cabinet"
        case .lha: return "LHA"
        case .xar: return "XAR"
        case .cpio: return "cpio"
        case .iso: return "ISO"
        case .ar: return "ar"
        case .rpm: return "RPM"
        case .deb: return "Debian"
        case .warc: return "WARC"
        }
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
    /// Position in the archive's own order, used to find the entry again when extracting.
    public var index = 0
    public var linkTarget: String?
    /// Unix permission bits, when the archive records them.
    public var permissions: UInt16?
    /// Compression method, e.g. "Deflate" (ZIP only).
    public var method: String?
    /// Backend detail: a ZIP entry's local header offset and method code.
    var locator: UInt64 = 0
    var methodCode = 0
    var flags = 0
    var crc: UInt32?
}

public struct ArchiveListing: Sendable {
    public enum Container: Sendable { case zip, tar, compressedFile, other }
    public var format: ArchiveFormat
    public var container: Container
    public var entries: [ArchiveEntry]
    public var archiveSize: UInt64
    /// Stopped early because the archive is huge (or the time budget ran out).
    public var truncated = false
    /// For a single compressed file: its first bytes, so text can be previewed directly.
    public var innerPrefix: Data?
    /// The stream compressor around a container (tar.gz is `.tar` inside `.gzip`).
    public var compression: ArchiveFormat?
    /// libarchive's precise name, e.g. "RAR5" or "POSIX pax interchange format".
    public var variant: String?
    public var volumes = 1
    /// Set when file names were decoded from a legacy encoding (e.g. "Shift JIS").
    public var nameEncoding: String?
    /// Even the file list is encrypted: nothing can be listed without the password.
    public var headerEncrypted = false
    /// Reading stopped at damaged data; `entries` holds what came before.
    public var damage: String?
    public var comment: String?

    public init(format: ArchiveFormat, container: Container, entries: [ArchiveEntry], archiveSize: UInt64,
                truncated: Bool = false, innerPrefix: Data? = nil) {
        self.format = format
        self.container = container
        self.entries = entries
        self.archiveSize = archiveSize
        self.truncated = truncated
        self.innerPrefix = innerPrefix
    }

    public var fileCount: Int { entries.lazy.filter { !$0.isDirectory }.count }
    public var totalSize: UInt64 { entries.reduce(0) { $1.isDirectory ? $0 : $0.saturatingAdd($1.size) } }
    public var isEncrypted: Bool { headerEncrypted || entries.contains { $0.isEncrypted } }
    public var hasCompressedSizes: Bool { entries.contains { !$0.isDirectory && $0.compressedSize != nil } }

    /// "ZIP Archive", "Tar Archive · zstd", "gzip Compressed File".
    public var title: String {
        let compressor = compression ?? (format.isCompressor ? format : nil)
        let base: String
        switch container {
        case .compressedFile:
            return String(localized: "\((compressor ?? format).displayName) Compressed File", bundle: .greeceKit,
                          comment: "Info bar title for a lone compressed file; the argument is the compression format, such as “gzip”")
        case .tar: base = String(localized: "Tar Archive", bundle: .greeceKit)
        case .zip: base = String(localized: "ZIP Archive", bundle: .greeceKit)
        case .other:
            switch format {
            case .iso: base = String(localized: "ISO Disk Image", bundle: .greeceKit)
            case .rpm: base = String(localized: "RPM Package", bundle: .greeceKit)
            case .deb: base = String(localized: "Debian Package", bundle: .greeceKit)
            case .cab: base = String(localized: "Cabinet Archive", bundle: .greeceKit)
            default:
                base = String(localized: "\(format.displayName) Archive", bundle: .greeceKit,
                              comment: "Info bar title; the argument is the archive format, such as “7-Zip” or “RAR”")
            }
        }
        return compressor.map { base + " · " + $0.displayName } ?? base
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
    case encrypted
    case tooLarge
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .corrupt(let reason):
            return String(localized: "This archive appears to be damaged (\(reason)).", bundle: .greeceKit,
                          comment: "Error message; the argument says what’s wrong, such as “the file list ends early” (it may come in English from the archive library)")
        case .unsupported(let reason): return reason
        case .encrypted: return String(localized: "This item is encrypted.", bundle: .greeceKit)
        case .tooLarge: return String(localized: "This item is too large to preview.", bundle: .greeceKit)
        case .cancelled: return String(localized: "Cancelled.", bundle: .greeceKit)
        }
    }
}

/// Lists archives in one go. The archive browser lists progressively through `ArchiveSession`.
public enum ArchiveReader {
    public static let entryLimit = 200_000

    public static func read(_ url: URL, format: ArchiveFormat) throws -> ArchiveListing {
        let session = try ArchiveSession(url: url, format: format)
        return try session.listAll()
    }
}
