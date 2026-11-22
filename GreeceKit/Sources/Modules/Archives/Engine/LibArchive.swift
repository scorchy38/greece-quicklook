import Foundation
import CLibArchive

/// A read handle on the system libarchive, restricted to formats and filters that decode in process.
///
/// zstd, lz4, lzop, grzip and lrzip are never enabled: this build of libarchive would launch external
/// programs for them. Greece decodes zstd itself (`ZstdSource`) and hands libarchive the result.
final class LibArchive {
    /// Where the archive's bytes come from.
    enum Input {
        /// A file, or the volumes of a split archive in order (RAR parts, 7z.001…).
        case files([URL])
        /// A seekable window of a file: a member inside a .deb, an RPM's payload.
        case window(RandomAccessFile, offset: UInt64, length: UInt64)
        /// A forward-only stream, such as zstd that Greece decodes itself.
        case stream(ByteSource)
        case memory(Data)
    }

    struct Formats: OptionSet {
        let rawValue: Int
        /// Every container libarchive reads (7z, RAR, CAB, LHA, ISO, cpio, tar, xar, ar, ZIP).
        static let containers = Formats(rawValue: 1)
        /// A lone compressed file, accepted when no container matches.
        static let raw = Formats(rawValue: 2)
        static let tarOnly = Formats(rawValue: 4)
        static let cpioOnly = Formats(rawValue: 8)
    }

    let handle: OpaquePointer
    private var client: Client?
    private var memory: UnsafeMutableRawPointer?
    private var fileNames: [UnsafeMutablePointer<CChar>?] = []
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: LibArchive.chunk, alignment: 16)
    private static let chunk = 256 * 1024
    /// Headers read so far, so callers can find an entry again by its position.
    private(set) var headerIndex = -1

    init(_ input: Input, formats: Formats = .containers) throws {
        guard let archive = archive_read_new() else { throw ArchiveError.unsupported("The archive reader couldn’t start.") }
        handle = archive

        archive_read_support_filter_gzip(archive)
        archive_read_support_filter_bzip2(archive)
        archive_read_support_filter_xz(archive)
        archive_read_support_filter_lzma(archive)
        archive_read_support_filter_lzip(archive)
        archive_read_support_filter_compress(archive)
        archive_read_support_filter_uu(archive)
        archive_read_support_filter_rpm(archive)

        if formats.contains(.containers) {
            archive_read_support_format_7zip(archive)
            archive_read_support_format_ar(archive)
            archive_read_support_format_cab(archive)
            archive_read_support_format_cpio(archive)
            archive_read_support_format_iso9660(archive)
            archive_read_support_format_lha(archive)
            archive_read_support_format_rar(archive)
            archive_read_support_format_rar5(archive)
            archive_read_support_format_tar(archive)
            archive_read_support_format_xar(archive)
            archive_read_support_format_zip_seekable(archive)
        }
        if formats.contains(.tarOnly) { archive_read_support_format_tar(archive) }
        if formats.contains(.cpioOnly) { archive_read_support_format_cpio(archive) }
        if formats.contains(.raw) { archive_read_support_format_raw(archive) }
        archive_read_support_format_empty(archive)

        let status: Int32
        switch input {
        case .files(let urls):
            guard !urls.isEmpty else { archive_read_free(archive); throw ArchiveError.unsupported("No archive to read.") }
            if urls.count == 1 {
                status = archive_read_open_filename(archive, urls[0].path, LibArchive.chunk)
            } else {
                fileNames = urls.map { strdup($0.path) } + [nil]
                status = fileNames.withUnsafeMutableBufferPointer { names in
                    names.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: names.count) {
                        archive_read_open_filenames(archive, $0, LibArchive.chunk)
                    }
                }
            }
        case .window(let file, let offset, let length):
            let window = WindowClient(file: file, offset: offset, length: length, capacity: LibArchive.chunk)
            client = window
            archive_read_set_read_callback(archive, libarchiveRead)
            archive_read_set_seek_callback(archive, libarchiveSeek)
            archive_read_set_skip_callback(archive, libarchiveSkip)
            archive_read_set_callback_data(archive, Unmanaged.passUnretained(window).toOpaque())
            status = archive_read_open1(archive)
        case .stream(let source):
            let stream = StreamClient(source: source, capacity: LibArchive.chunk)
            client = stream
            archive_read_set_read_callback(archive, libarchiveRead)
            archive_read_set_callback_data(archive, Unmanaged.passUnretained(stream).toOpaque())
            status = archive_read_open1(archive)
        case .memory(let data):
            let copy = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
            data.copyBytes(to: copy.assumingMemoryBound(to: UInt8.self), count: data.count)
            memory = copy
            status = archive_read_open_memory(archive, copy, data.count)
        }
        if status < ARCHIVE_WARN {
            let message = LibArchive.message(archive)
            release()
            throw LibArchive.error(message)
        }
    }

    deinit { release() }

    private var released = false
    private func release() {
        guard !released else { return }
        released = true
        archive_read_free(handle)
        buffer.deallocate()
        memory?.deallocate()
        fileNames.forEach { free($0) }
    }

    // MARK: - Headers

    /// The next entry header, or nil at the end. Warnings (an unconvertible name, say) still return it.
    func nextHeader() throws -> OpaquePointer? {
        var entry: OpaquePointer?
        var retries = 0
        while true {
            let status = archive_read_next_header(handle, &entry)
            if status == ARCHIVE_EOF { return nil }
            if status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry {
                headerIndex += 1
                return entry
            }
            if status == ARCHIVE_RETRY, retries < 8 { retries += 1; continue }
            throw LibArchive.error(LibArchive.message(handle))
        }
    }

    /// Reads the current entry's data in chunks, stopping after `limit` bytes. Returns the bytes
    /// delivered and whether that was the whole entry.
    @discardableResult
    func readData(limit: UInt64, cancel: CancelToken? = nil, _ deliver: (UnsafeRawBufferPointer) throws -> Void) throws -> (UInt64, Bool) {
        var total: UInt64 = 0
        var retries = 0
        while true {
            if cancel?.isCancelled == true { throw ArchiveError.cancelled }
            let got = archive_read_data(handle, buffer, LibArchive.chunk)
            if got == 0 { return (total, true) }
            if got < 0 {
                if (got == Int(ARCHIVE_WARN) || got == Int(ARCHIVE_RETRY)) && retries < 8 { retries += 1; continue }
                throw LibArchive.error(LibArchive.message(handle))
            }
            let room = limit - total
            let keep = Int(min(UInt64(got), room))
            if keep > 0 { try deliver(UnsafeRawBufferPointer(start: buffer, count: keep)) }
            total += UInt64(keep)
            if UInt64(got) > room { return (total, false) }
            if total == limit {
                // Exactly at the limit: the entry is whole only if nothing follows.
                return (total, archive_read_data(handle, buffer, 1) == 0)
            }
        }
    }

    // MARK: - Facts

    var format: ArchiveFormat? {
        switch archive_format(handle) & ARCHIVE_FORMAT_BASE_MASK {
        case ARCHIVE_FORMAT_7ZIP: return .sevenZip
        case ARCHIVE_FORMAT_RAR, ARCHIVE_FORMAT_RAR_V5: return .rar
        case ARCHIVE_FORMAT_ZIP: return .zip
        case ARCHIVE_FORMAT_TAR: return .tar
        case ARCHIVE_FORMAT_CPIO: return .cpio
        case ARCHIVE_FORMAT_ISO9660: return .iso
        case ARCHIVE_FORMAT_AR: return .ar
        case ARCHIVE_FORMAT_XAR: return .xar
        case ARCHIVE_FORMAT_LHA: return .lha
        case ARCHIVE_FORMAT_CAB: return .cab
        case ARCHIVE_FORMAT_WARC: return .warc
        default: return nil
        }
    }

    var isRaw: Bool { archive_format(handle) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_RAW }
    var isEmpty: Bool { archive_format(handle) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_EMPTY }

    var formatName: String? { archive_format_name(handle).map { String(cString: $0) } }

    /// The outermost compression filter, if any.
    var compression: ArchiveFormat? {
        let count = archive_filter_count(handle)
        for index in 0..<max(count, 0) {
            switch archive_filter_code(handle, index) {
            case ARCHIVE_FILTER_GZIP: return .gzip
            case ARCHIVE_FILTER_BZIP2: return .bzip2
            case ARCHIVE_FILTER_XZ: return .xz
            case ARCHIVE_FILTER_LZMA: return .lzma
            case ARCHIVE_FILTER_LZIP: return .lzip
            case ARCHIVE_FILTER_COMPRESS: return .compress
            default: continue
            }
        }
        return nil
    }

    // MARK: - Entries

    /// Reads an entry header into Greece's model. Names libarchive couldn't decode come back in
    /// `rawName` for the legacy-encoding detector.
    func entry(_ header: OpaquePointer, unicodeNames: Bool) -> (ArchiveEntry, rawName: [UInt8]?) {
        var raw: [UInt8]?
        var path: String?
        if let pointer = archive_entry_pathname(header) {
            let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: strlen(pointer)))
            if let utf8 = String(bytes: bytes, encoding: .utf8) { path = utf8 } else { raw = bytes }
        }
        if path == nil, let utf8 = archive_entry_pathname_utf8(header) { path = String(cString: utf8) }
        if path == nil, unicodeNames || raw == nil, let wide = archive_entry_pathname_w(header) { path = LibArchive.string(wide) }
        if path != nil { raw = nil }

        let type = archive_entry_filetype(header) & S_IFMT
        let isDirectory = type == S_IFDIR
        let isSymlink = type == S_IFLNK
        var entry = ArchiveEntry(path: path ?? String(decoding: raw ?? [], as: UTF8.self), isDirectory: isDirectory, isSymlink: isSymlink,
                                 size: 0, compressedSize: nil,
                                 // A zero timestamp means "not recorded" (reproducible builds), not 1 January 1970.
                                 modified: archive_entry_mtime_is_set(header) != 0 && archive_entry_mtime(header) != 0
                                    ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(header))) : nil)
        if !isDirectory, archive_entry_size_is_set(header) != 0 {
            entry.size = UInt64(max(archive_entry_size(header), 0))
        }
        entry.isEncrypted = archive_entry_is_encrypted(header) != 0
        entry.index = headerIndex
        entry.permissions = UInt16(archive_entry_perm(header) & 0o7777)
        if isSymlink, let target = archive_entry_symlink_utf8(header) ?? archive_entry_symlink(header) {
            entry.linkTarget = String(decoding: UnsafeRawBufferPointer(start: target, count: strlen(target)), as: UTF8.self)
        }
        return (entry, raw)
    }

    private static func string(_ wide: UnsafePointer<wchar_t>) -> String? {
        var scalars = String.UnicodeScalarView()
        var pointer = wide
        var count = 0
        while pointer.pointee != 0 && count < 65_536 {
            guard let scalar = Unicode.Scalar(UInt32(bitPattern: pointer.pointee)) else { return nil }
            scalars.append(scalar)
            pointer += 1
            count += 1
        }
        return String(scalars)
    }

    // MARK: - Errors

    static func message(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "unreadable data"
    }

    static func error(_ message: String) -> ArchiveError {
        let lower = message.lowercased()
        if lower.contains("encrypt") || lower.contains("passphrase") || lower.contains("password") { return .encrypted }
        if lower.contains("unrecognized archive format") { return .unsupported("Greece doesn’t recognise this archive’s format.") }
        return .corrupt(message)
    }
}

// MARK: - Callbacks

/// Feeds libarchive from Swift. The buffer stays valid until the next call, as libarchive requires.
private class Client {
    let buffer: UnsafeMutableRawPointer
    let capacity: Int
    init(capacity: Int) {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        self.capacity = capacity
    }
    deinit { buffer.deallocate() }
    func read(_ out: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int { 0 }
    func seek(_ offset: Int64, whence: Int32) -> Int64 { Int64(ARCHIVE_FATAL) }
    func skip(_ request: Int64) -> Int64 { 0 }
}

private final class StreamClient: Client {
    private let source: ByteSource
    init(source: ByteSource, capacity: Int) {
        self.source = source
        super.init(capacity: capacity)
    }
    override func read(_ out: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        guard let data = try? source.read(upTo: capacity) else { return Int(ARCHIVE_FATAL) }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        out.pointee = UnsafeRawPointer(buffer)
        return data.count
    }
}

private final class WindowClient: Client {
    private let file: RandomAccessFile
    private let start: UInt64
    private let length: UInt64
    private var position: UInt64 = 0

    init(file: RandomAccessFile, offset: UInt64, length: UInt64, capacity: Int) {
        self.file = file
        start = min(offset, file.size)
        self.length = min(length, file.size - start)
        super.init(capacity: capacity)
    }

    override func read(_ out: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        let count = Int(min(UInt64(capacity), length - min(position, length)))
        guard count > 0 else { return 0 }
        let data = file.read(at: start + position, count: count)
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        position += UInt64(data.count)
        out.pointee = UnsafeRawPointer(buffer)
        return data.count
    }

    override func seek(_ offset: Int64, whence: Int32) -> Int64 {
        let base: Int64
        switch whence {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = Int64(position)
        case SEEK_END: base = Int64(length)
        default: return Int64(ARCHIVE_FATAL)
        }
        let target = base + offset
        guard target >= 0 else { return Int64(ARCHIVE_FATAL) }
        position = min(UInt64(target), length)
        return Int64(position)
    }

    override func skip(_ request: Int64) -> Int64 {
        guard request > 0 else { return 0 }
        let step = min(UInt64(request), length - min(position, length))
        position += step
        return Int64(step)
    }
}

private let libarchiveRead: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int = { _, context, out in
    guard let context, let out else { return Int(ARCHIVE_FATAL) }
    return Unmanaged<Client>.fromOpaque(context).takeUnretainedValue().read(out)
}

private let libarchiveSeek: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int64, Int32) -> Int64 = { _, context, offset, whence in
    guard let context else { return Int64(ARCHIVE_FATAL) }
    return Unmanaged<Client>.fromOpaque(context).takeUnretainedValue().seek(offset, whence: whence)
}

private let libarchiveSkip: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int64) -> Int64 = { _, context, request in
    guard let context else { return 0 }
    return Unmanaged<Client>.fromOpaque(context).takeUnretainedValue().skip(request)
}
