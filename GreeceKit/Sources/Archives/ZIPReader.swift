import Foundation
import CArchive

/// One member of a ZIP archive, as its central directory records it.
struct ZIPMember {
    var path: String
    /// The compression method code: 0 Stored, 8 Deflate, 93 Zstandard…
    var method: Int
    var flags: UInt16
    var crc: UInt32
    var compressedSize: UInt64
    var size: UInt64
    /// Where the member's local header starts in the archive's bytes (prefixes and volumes resolved).
    var localHeaderOffset: UInt64
    /// The DOS date and time fields, and the precise Unix time when an extended timestamp has one.
    /// Kept raw: turning them into a `Date` is slow, and most readers never ask.
    var dosDate: UInt16
    var dosTime: UInt16
    var unixTime: Int32?
    var isDirectory: Bool
    var isSymlink: Bool
    var isEncrypted: Bool
    /// Unix permission bits, when the archive was made on Unix.
    var permissions: UInt16?

    /// Sizes and CRC follow the data instead of the local header. The central directory has them
    /// either way, so reading is the same.
    var hasDataDescriptor: Bool { flags & 0x0008 != 0 }
    /// The stored name climbs out of the archive with a ".." component. Such a member is listed,
    /// but `ZIPArchive` never finds it by name.
    var escapesRoot: Bool { ZIPArchive.hasParentComponent(path) }

    var modified: Date? {
        if let unixTime { return Date(timeIntervalSince1970: TimeInterval(unixTime)) }
        return ZIPReader.dosDateTime(date: dosDate, time: dosTime)
    }
}

/// Reads ZIP archives: the central directory (including ZIP64, split and prefixed archives)
/// without touching file data, and single members by seeking straight to them.
///
/// Every ZIP Greece opens goes through here: the archive browser (kept alongside libarchive
/// because the central directory lists every size instantly, and random access makes comic
/// pages and previews inside the archive fast), and, through `ZIPArchive`, the formats built
/// on ZIP (IPA, APK, EPUB, KMZ, 3MF, dotLottie…).
enum ZIPReader {
    static let maxDirectorySize: UInt64 = 512 * 1024 * 1024
    /// Deflate can't expand data more than about 1,032 times: output beyond this is a lie.
    static let maxDeflateRatio: UInt64 = 1100

    struct Directory {
        var members: [ZIPMember] = []
        /// The member count the end record declares.
        var declaredCount: UInt64 = 0
        /// Where the central directory starts in the archive's bytes. An APK Signing Block ends right before it.
        var offset: UInt64 = 0
        /// Listing stopped at the member limit.
        var truncated = false
        /// Fewer members could be read than the end record declares.
        var endsEarly = false
        var comment: String?
        /// The central directory itself is encrypted (PKWARE strong encryption).
        var headerEncrypted = false
        /// The legacy encoding non-UTF-8 names were decoded with ("DOS Latin US" is CP437).
        var nameEncoding: String?
    }

    // MARK: - Central directory

    /// Reads the central directory, at most `limit` members.
    /// - Parameter spanned: the volumes are a real multi-disk set (.z01, .z02… .zip), so member
    ///   offsets are relative to their own disk.
    static func directory(_ file: any RandomAccessSource, spanned: Bool = false, limit: Int) throws -> Directory {
        var directory = Directory()
        directory.members = try scan(file, spanned: spanned, limit: limit, into: &directory, make: { member, _ in member },
                                     rename: { $0.path = $1 })
        return directory
    }

    /// The archive browser's listing: every member (up to `ArchiveReader.entryLimit`) as an `ArchiveEntry`.
    static func read(_ file: any RandomAccessSource, spanned: Bool = false) throws -> ArchiveListing {
        var directory = Directory()
        let entries = try scan(file, spanned: spanned, limit: ArchiveReader.entryLimit, into: &directory, make: { member, index in
            var entry = ArchiveEntry(path: member.path, isDirectory: member.isDirectory, isSymlink: member.isSymlink,
                                     size: member.isDirectory ? 0 : member.size, compressedSize: member.isDirectory ? 0 : member.compressedSize,
                                     modified: member.modified, isEncrypted: member.isEncrypted)
            entry.index = index
            entry.methodCode = member.method
            entry.method = member.isDirectory ? nil : methodName(member.method)
            entry.flags = Int(member.flags)
            entry.crc = member.crc
            entry.permissions = member.permissions
            entry.locator = member.localHeaderOffset
            return entry
        }, rename: { $0.path = $1 })
        var listing = ArchiveListing(format: .zip, container: .zip, entries: entries, archiveSize: file.size, truncated: directory.truncated)
        listing.comment = directory.comment
        listing.headerEncrypted = directory.headerEncrypted
        listing.nameEncoding = directory.nameEncoding
        if directory.endsEarly { listing.damage = "the file list ends early" }
        return listing
    }

    /// Walks the central directory, turning each record into the caller's entry type in the same
    /// pass. `rename` fixes up names that turn out to be in a legacy encoding once all are seen.
    private static func scan<Entry>(_ file: any RandomAccessSource, spanned: Bool, limit: Int, into result: inout Directory,
                                    make: (ZIPMember, Int) -> Entry, rename: (inout Entry, String) -> Void) throws -> [Entry] {
        guard file.size >= 22 else { throw ArchiveError.corrupt("too small") }

        // The end record sits in the last 64 KB (its comment can be up to 65,535 bytes).
        let tailStart = file.size > 65_557 ? file.size - 65_557 : 0
        let tail = Data(file.read(at: tailStart, count: Int(file.size - tailStart)))
        guard let eocdInTail = lastSignature(0x06054B50, in: tail) else {
            throw ArchiveError.corrupt("no end of central directory")
        }
        let eocd = tailStart + UInt64(eocdInTail)
        var directoryDisk = UInt64(tail.u16(eocdInTail + 6))
        var entryCount = UInt64(tail.u16(eocdInTail + 10))
        var directorySize = UInt64(tail.u32(eocdInTail + 12))
        var directoryOffset = UInt64(tail.u32(eocdInTail + 16))
        let commentLength = Int(tail.u16(eocdInTail + 20))
        var directoryEnd = eocd

        // ZIP64: the locator sits immediately before the classic end record.
        if eocdInTail >= 20, tail.u32(eocdInTail - 20) == 0x07064B50 {
            let locatorDisk = UInt64(tail.u32(eocdInTail - 20 + 4))
            var recordOffset = tail.u64(eocdInTail - 20 + 8)
            if spanned, let start = file.start(ofVolume: Int(clamping: locatorDisk)) { recordOffset = start.saturatingAdd(recordOffset) }
            let record = file.read(at: recordOffset, count: 56)
            if record.count == 56, record.u32(0) == 0x06064B50 {
                directoryDisk = UInt64(record.u32(16))
                entryCount = record.u64(32)
                directorySize = record.u64(40)
                directoryOffset = record.u64(48)
                directoryEnd = recordOffset
            }
        }

        // Where the directory really starts in the combined stream.
        var start = directoryOffset
        if spanned, let volume = file.start(ofVolume: Int(clamping: directoryDisk)) { start = volume.saturatingAdd(directoryOffset) }
        // Self-extracting and prefixed archives (CRX, SFX): offsets are short by the prefix.
        var delta: Int64 = 0
        if !spanned, directorySize <= directoryEnd, directoryEnd - directorySize != start {
            let actual = directoryEnd - directorySize
            if file.read(at: actual, count: 4).u32(0) == 0x02014B50 {
                delta = Int64(bitPattern: actual &- start)
                start = actual
            }
        }
        guard directorySize <= maxDirectorySize, start < file.size else {
            throw ArchiveError.corrupt("invalid central directory")
        }

        result.declaredCount = entryCount
        result.offset = start
        if commentLength > 0, eocdInTail + 22 + commentLength <= tail.count {
            let comment = String(decoding: tail.subdata(in: (eocdInTail + 22)..<(eocdInTail + 22 + commentLength)), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !comment.isEmpty { result.comment = String(comment.prefix(2000)) }
        }

        var cursor = DirectoryCursor(file: file, position: start, end: start + min(directorySize, file.size - start))
        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(entryCount, UInt64(max(limit, 0)))))
        var legacy: [(index: Int, bytes: [UInt8])] = []

        while let fixed = cursor.reserve(46) {
            let header = cursor.buffer.withUnsafeBytes { raw in
                (signature: raw.le32(fixed), name: Int(raw.le16(fixed + 28)), extra: Int(raw.le16(fixed + 30)), comment: Int(raw.le16(fixed + 32)))
            }
            guard header.signature == 0x02014B50 else { break }
            if entries.count >= limit { result.truncated = true; break }
            // The name must be there; a damaged extra field that runs past the directory is cut
            // short rather than costing the member.
            let wanted = Int(min(UInt64(46 + header.name + header.extra), cursor.remaining))
            guard wanted >= 46 + header.name, let at = cursor.reserve(wanted) else { break }
            cursor.advance(46 + header.name + header.extra + header.comment)
            let (member, legacyName) = cursor.buffer.withUnsafeBytes { raw in
                record(raw, at: at, length: wanted, nameLength: header.name, volumes: spanned ? file : nil, delta: delta)
            }
            if let legacyName { legacy.append((entries.count, legacyName)) }
            entries.append(make(member, entries.count))
            if member.flags & 0x2000 != 0 { result.headerEncrypted = true }
        }

        if !legacy.isEmpty {
            let encoding = NameDecoder.choose(legacy.map(\.bytes), fallback: NameDecoder.candidates[0].encoding)
            for (index, bytes) in legacy {
                rename(&entries[index], NameDecoder.decode(bytes, with: encoding))
            }
            result.nameEncoding = encoding.name
        }

        if entries.isEmpty && entryCount > 0 { throw ArchiveError.corrupt("unreadable central directory") }
        result.endsEarly = UInt64(entries.count) < min(entryCount, UInt64(max(limit, 0))) && !result.truncated
        return entries
    }

    /// One central directory record, known to lie within `raw[at..<at + length]`. Returns the
    /// member, and its raw name when that isn't UTF-8 (decoded later, with all the others).
    private static func record(_ raw: UnsafeRawBufferPointer, at: Int, length: Int, nameLength: Int,
                               volumes: (any RandomAccessSource)?, delta: Int64) -> (ZIPMember, [UInt8]?) {
        let madeBy = raw.le16(at + 4)
        let flags = raw.le16(at + 8)
        let method = Int(raw.le16(at + 10))
        let crc = raw.le32(at + 16)
        var compressed = UInt64(raw.le32(at + 20))
        var uncompressed = UInt64(raw.le32(at + 24))
        var disk = UInt64(raw.le16(at + 34))
        let external = raw.le32(at + 38)
        var localOffset = UInt64(raw.le32(at + 42))

        // Flagged or not, most tools write UTF-8: decode natively, and keep it if nothing needed repair.
        let name = UnsafeRawBufferPointer(rebasing: raw[(at + 46)..<(at + 46 + nameLength)]).bindMemory(to: UInt8.self)
        var lossy = String(decoding: name, as: UTF8.self)
        let isUTF8 = nameLength == 0 || (lossy.utf8.count == nameLength
            && lossy.withUTF8 { memcmp($0.baseAddress, name.baseAddress, nameLength) == 0 })
        var path: String? = isUTF8 ? lossy : nil

        var unixTime: Int32?
        var isAES = false
        var extra = at + 46 + nameLength
        let extraEnd = at + length
        while extra + 4 <= extraEnd {
            let id = raw.le16(extra)
            let size = Int(raw.le16(extra + 2))
            let body = extra + 4
            guard body + size <= extraEnd else { break }
            switch id {
            case 0x0001:
                // ZIP64 extended info: only the fields saturated in the header are present, in order.
                var field = body
                if uncompressed == 0xFFFF_FFFF, field + 8 <= body + size { uncompressed = raw.le64(field); field += 8 }
                if compressed == 0xFFFF_FFFF, field + 8 <= body + size { compressed = raw.le64(field); field += 8 }
                if localOffset == 0xFFFF_FFFF, field + 8 <= body + size { localOffset = raw.le64(field); field += 8 }
                if disk == 0xFFFF, field + 4 <= body + size { disk = UInt64(raw.le32(field)) }
            case 0x5455 where size >= 5 && raw[body] & 0x01 != 0:
                // Extended timestamp: precise UTC modification time.
                unixTime = Int32(bitPattern: raw.le32(body + 1))
            case 0x7075 where size > 5 && path == nil:
                // Info-ZIP Unicode Path: the UTF-8 name, for archives whose header name is legacy.
                path = String(bytes: UnsafeRawBufferPointer(rebasing: raw[(body + 5)..<(body + size)]), encoding: .utf8)
            case 0x9901:
                isAES = true
            default:
                break
            }
            extra = body + size
        }

        let unixMode = (madeBy >> 8) == 3 ? (external >> 16) : 0
        let decodedPath = path ?? lossy
        var location = localOffset
        if let volumes, let start = volumes.start(ofVolume: Int(clamping: disk)) { location = start.saturatingAdd(localOffset) }
        let member = ZIPMember(
            path: decodedPath, method: method, flags: flags, crc: crc, compressedSize: compressed, size: uncompressed,
            localHeaderOffset: UInt64(bitPattern: Int64(bitPattern: location) &+ delta),
            dosDate: raw.le16(at + 14), dosTime: raw.le16(at + 12), unixTime: unixTime,
            isDirectory: decodedPath.utf8.last == UInt8(ascii: "/") || (external & 0x10) != 0 || (unixMode & 0o170000) == 0o040000,
            isSymlink: (unixMode & 0o170000) == 0o120000,
            isEncrypted: flags & 0x0001 != 0 || isAES || method == 99,
            permissions: unixMode != 0 ? UInt16(unixMode & 0o7777) : nil)
        return (member, path == nil ? [UInt8](name) : nil)
    }

    static func methodName(_ code: Int) -> String {
        switch code {
        case 0: return "Stored"
        case 8: return "Deflate"
        case 9: return "Deflate64"
        case 12: return "bzip2"
        case 14: return "LZMA"
        case 93: return "Zstandard"
        case 95: return "xz"
        case 98: return "PPMd"
        case 99: return "AES"
        default: return "Method \(code)"
        }
    }

    // MARK: - Extraction

    /// True if Greece decodes this method itself; others go through libarchive.
    static func supports(_ method: Int) -> Bool { method == 0 || method == 8 || method == 93 }

    static func canExtract(_ entry: ArchiveEntry) -> Bool { supports(entry.methodCode) }

    /// Where a member's bytes are: right after its local header, for its compressed size.
    struct DataRange {
        var start: UInt64
        /// The bytes actually there: the compressed size, or less if the archive ends first.
        var length: UInt64
        /// The member's bytes run past the end of the archive.
        var pastEnd: Bool
    }

    /// Finds a member's bytes through its local header. Only the name and extra lengths are taken
    /// from it: the central directory is the authority on sizes, method and encryption.
    static func locate(localHeader offset: UInt64, compressedSize: UInt64, in file: any RandomAccessSource) throws -> DataRange {
        let header = file.read(at: offset, count: 30)
        guard header.count == 30, header.u32(0) == 0x04034B50 else { throw ArchiveError.corrupt("missing local header") }
        let start = offset.saturatingAdd(30 + UInt64(header.u16(26)) + UInt64(header.u16(28)))
        let available = start < file.size ? file.size - start : 0
        return DataRange(start: start, length: min(compressedSize, available), pastEnd: compressedSize > available)
    }

    struct Extraction {
        /// Bytes handed to `deliver`.
        var delivered: UInt64 = 0
        /// The whole member was delivered: neither the limit nor `deliver` cut it short.
        var complete = false
        /// A Deflate stream ran out of input before its end marker (a damaged or cut-off member).
        /// What decoded before that was delivered.
        var endedEarly = false
    }

    /// Streams a member's uncompressed bytes into `deliver`, never more than `limit` of them
    /// (Deflate output is further held to `maxDeflateRatio` times its input). Return false from
    /// `deliver` to stop early.
    static func extract(_ range: DataRange, method: Int, from file: any RandomAccessSource, limit: UInt64,
                        chunkSize: Int = 256 * 1024, cancel: CancelToken? = nil,
                        deliver: (UnsafeRawBufferPointer) throws -> Bool) throws -> Extraction {
        let source = RangeSource(file, offset: range.start, length: range.length)
        let chunkSize = max(chunkSize, 4096)
        let limit = method == 8 ? min(limit, saturatingMultiply(range.length, maxDeflateRatio).saturatingAdd(1024)) : limit
        var result = Extraction()

        /// Hands over a chunk within the limit; false once the limit is reached or `deliver` wants no more.
        func emit(_ buffer: UnsafeRawBufferPointer) throws -> Bool {
            let keep = Int(min(UInt64(buffer.count), limit - result.delivered))
            var more = true
            if keep > 0 { more = try deliver(UnsafeRawBufferPointer(rebasing: buffer[0..<keep])) }
            result.delivered += UInt64(keep)
            return more && keep == buffer.count
        }

        switch method {
        case 0:
            while true {
                if cancel?.isCancelled == true { throw ArchiveError.cancelled }
                let chunk = try source.read(upTo: chunkSize)
                if chunk.isEmpty { result.complete = true; return result }
                let whole = try chunk.withUnsafeBytes { try emit($0) }
                if !whole || (result.delivered == limit && source.remaining > 0) { return result }
            }
        case 8:
            let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
            defer { scratch.deallocate() }
            let end = try inflate(source, inputChunk: chunkSize, cancel: cancel, room: { scratch }) { count in
                try emit(UnsafeRawBufferPointer(rebasing: scratch[0..<count]))
            }
            result.complete = end != .stopped
            result.endedEarly = end == .inputEnded
            return result
        case 93:
            let zstd = try ZstdSource(source)
            while true {
                if cancel?.isCancelled == true { throw ArchiveError.cancelled }
                let chunk = try zstd.read(upTo: chunkSize)
                if chunk.isEmpty { result.complete = true; return result }
                let whole = try chunk.withUnsafeBytes { try emit($0) }
                if !whole { return result }
            }
        default:
            throw ArchiveError.unsupported(methodName(method))
        }
    }

    /// The archive browser's extraction: an entry's bytes (up to `limit`). Returns the bytes
    /// delivered and whether that was all of it.
    static func extract(_ entry: ArchiveEntry, from file: any RandomAccessSource, limit: UInt64, cancel: CancelToken? = nil,
                        deliver: (UnsafeRawBufferPointer) throws -> Void) throws -> (UInt64, Bool) {
        if entry.isEncrypted { throw ArchiveError.encrypted }
        let range = try locate(localHeader: entry.locator, compressedSize: entry.compressedSize ?? 0, in: file)
        let result = try extract(range, method: entry.methodCode, from: file, limit: limit, cancel: cancel) { try deliver($0); return true }
        return (result.delivered, result.complete)
    }

    /// Inflates a whole Deflate member straight into one buffer sized from its header (grown if
    /// the header lied), never past `limit` (nor `maxDeflateRatio` times its input). Nothing is
    /// copied on the way: the buffer becomes the result.
    static func inflateWhole(_ range: DataRange, expectedSize: UInt64, from file: any RandomAccessSource,
                             limit: UInt64) throws -> (data: Data, complete: Bool, endedEarly: Bool) {
        let limit = min(limit, saturatingMultiply(range.length, maxDeflateRatio).saturatingAdd(1024))
        // One byte past the limit is room enough to tell that there was more.
        let ceiling = Int(clamping: limit.saturatingAdd(1))
        // The declared size plus one byte: an honest header never needs the buffer grown to see the end.
        var capacity = Int(clamping: min(expectedSize.saturatingAdd(1), UInt64(ceiling)))
        guard var output = malloc(capacity) else { throw ArchiveError.tooLarge }
        var produced = 0
        let end: InflateEnd
        do {
            end = try inflate(RangeSource(file, offset: range.start, length: range.length), inputChunk: 256 * 1024, cancel: nil, room: {
                if produced == capacity {
                    guard capacity < ceiling else { return nil }
                    let grown = Int(min(UInt64(capacity) * 2, UInt64(ceiling)))
                    guard let bigger = realloc(output, grown) else { throw ArchiveError.tooLarge }
                    output = bigger
                    capacity = grown
                }
                return UnsafeMutableRawBufferPointer(start: output + produced, count: capacity - produced)
            }) { count in
                produced += count
                return true
            }
        } catch {
            free(output)
            throw error
        }
        let complete = UInt64(produced) <= limit
        let endedEarly = end == .inputEnded
        guard produced > 0 else { free(output); return (Data(), complete, endedEarly) }
        return (Data(bytesNoCopy: output, count: produced, deallocator: .free), complete, endedEarly)
    }

    /// Inflates a Deflate member into fresh chunks of up to `chunkSize` bytes that become the
    /// `Data` handed to `deliver` as they are, never more than `maximum` bytes in all. Return
    /// false from `deliver` to stop.
    static func inflateChunks(_ range: DataRange, from file: any RandomAccessSource, maximum: UInt64, chunkSize: Int,
                              deliver: (Data) throws -> Bool) throws {
        let limit = min(maximum, saturatingMultiply(range.length, maxDeflateRatio).saturatingAdd(1024))
        let chunkSize = max(chunkSize, 4096)
        var current: UnsafeMutableRawPointer?
        var filled = 0
        var total: UInt64 = 0
        defer { free(current) }

        /// Hands over the chunk being filled, which then belongs to its `Data`.
        func flush() throws -> Bool {
            guard let chunk = current, filled > 0 else { return true }
            current = nil
            defer { filled = 0 }
            return try deliver(Data(bytesNoCopy: chunk, count: filled, deallocator: .free))
        }

        let end = try inflate(RangeSource(file, offset: range.start, length: range.length), inputChunk: chunkSize, cancel: nil, room: {
            guard total < limit else { return nil }
            if current == nil {
                guard let fresh = malloc(chunkSize) else { throw ArchiveError.tooLarge }
                current = fresh
            }
            return UnsafeMutableRawBufferPointer(start: current! + filled, count: Int(min(UInt64(chunkSize - filled), limit - total)))
        }) { count in
            filled += count
            total += UInt64(count)
            if filled < chunkSize && total < limit { return true }
            return try flush()
        }
        if end != .stopped { _ = try flush() }
    }

    private enum InflateEnd { case finished, stopped, inputEnded }

    /// The one Deflate loop. `room` says where the next output goes (nil: no room left, stop);
    /// `wrote` hears how many bytes went there and returns false to stop.
    private static func inflate(_ source: RangeSource, inputChunk: Int, cancel: CancelToken?,
                                room: () throws -> UnsafeMutableRawBufferPointer?,
                                wrote: (Int) throws -> Bool) throws -> InflateEnd {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ArchiveError.corrupt("inflate init")
        }
        defer { inflateEnd(&stream) }

        while true {
            if cancel?.isCancelled == true { throw ArchiveError.cancelled }
            let chunk = try source.read(upTo: inputChunk)
            if chunk.isEmpty { return .inputEnded }   // ran out of input: keep what decoded
            var ended = false
            var stopped = false
            try chunk.withUnsafeBytes { input in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                defer { stream.next_in = nil; stream.next_out = nil }
                while true {
                    guard let space = try room(), let base = space.baseAddress, !space.isEmpty else { stopped = true; return }
                    stream.next_out = base.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(min(space.count, Int(UInt32.max)))
                    let offered = stream.avail_out
                    let status = CArchive.inflate(&stream, Z_NO_FLUSH)
                    let produced = Int(offered - stream.avail_out)
                    if produced > 0, try !wrote(produced) { stopped = true; return }
                    if status == Z_STREAM_END { ended = true; return }
                    if status != Z_OK && status != Z_BUF_ERROR { throw ArchiveError.corrupt("deflate data error") }
                    if stream.avail_in == 0 && stream.avail_out > 0 { return }
                    if status == Z_BUF_ERROR && produced == 0 { return }
                }
            }
            if stopped { return .stopped }
            if ended { return .finished }
        }
    }

    // MARK: - Helpers

    private static func saturatingMultiply(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? .max : product
    }

    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if data.u32(index) == signature { return index }
            index -= 1
        }
        return nil
    }

    static func dosDateTime(date: UInt16, time: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var components = DateComponents()
        components.year = Int((date >> 9) & 0x7F) + 1980
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int((time >> 11) & 0x1F)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int((time & 0x1F) * 2)
        return Calendar.current.date(from: components)
    }
}

/// Reads the central directory forwards a block at a time, so a huge (or lying) directory never
/// has to sit in memory whole.
private struct DirectoryCursor {
    let file: any RandomAccessSource
    var position: UInt64
    let end: UInt64
    /// The block read last; `reserve` says where the bytes it asked for start in it.
    private(set) var buffer = Data()
    private var base: UInt64 = 0
    private static let block = 1 << 20

    init(file: any RandomAccessSource, position: UInt64, end: UInt64) {
        self.file = file
        self.position = position
        self.end = end
    }

    /// Makes the next `count` bytes available in `buffer` (without consuming them) and returns
    /// their offset there, or nil if they'd cross the directory's end.
    mutating func reserve(_ count: Int) -> Int? {
        guard count >= 0, position.saturatingAdd(UInt64(count)) <= end else { return nil }
        if position < base || position + UInt64(count) > base + UInt64(buffer.count) {
            buffer = file.read(at: position, count: Int(min(end - position, UInt64(max(count, Self.block)))))
            base = position
            guard buffer.count >= count else { return nil }
        }
        return Int(position - base)
    }

    mutating func advance(_ count: Int) { position = position.saturatingAdd(UInt64(count)) }

    /// Bytes left before the directory's end.
    var remaining: UInt64 { end > position ? end - position : 0 }
}

extension UnsafeRawBufferPointer {
    /// Little-endian reads at offsets the caller has already bounds-checked.
    @inline(__always) func le16(_ offset: Int) -> UInt16 { loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    @inline(__always) func le32(_ offset: Int) -> UInt32 { loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    @inline(__always) func le64(_ offset: Int) -> UInt64 { loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
}

extension Data {
    @inline(__always) func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }
    @inline(__always) func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
    @inline(__always) func u64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
    }
}
