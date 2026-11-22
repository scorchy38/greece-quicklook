import Foundation
import CArchive

/// Reads a ZIP central directory (including ZIP64, split and prefixed archives) without touching
/// file data, and extracts single entries by seeking straight to them.
///
/// Kept alongside libarchive because the central directory lists every size instantly, and
/// random access makes comic pages and previews inside the archive fast.
enum ZIPReader {
    static let maxDirectorySize: UInt64 = 512 * 1024 * 1024

    /// - Parameter spanned: the volumes are a real multi-disk set (.z01, .z02… .zip), so entry
    ///   offsets are relative to their own disk.
    static func read(_ file: RandomAccessFile, spanned: Bool = false) throws -> ArchiveListing {
        guard file.size >= 22 else { throw ArchiveError.corrupt("too small") }

        // The end record sits in the last 64 KB (its comment can be up to 65,535 bytes).
        let tailStart = file.size > 65_557 ? file.size - 65_557 : 0
        let tail = file.read(at: tailStart, count: Int(file.size - tailStart))
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
        let directory = file.read(at: start, count: Int(min(directorySize, file.size - start)))

        var listing = ArchiveListing(format: .zip, container: .zip, entries: [], archiveSize: file.size)
        if commentLength > 0, eocdInTail + 22 + commentLength <= tail.count {
            let comment = String(decoding: tail.subdata(in: (eocdInTail + 22)..<(eocdInTail + 22 + commentLength)), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !comment.isEmpty { listing.comment = String(comment.prefix(2000)) }
        }

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(min(entryCount, UInt64(ArchiveReader.entryLimit))))
        var legacy: [(index: Int, bytes: [UInt8])] = []
        var offset = 0

        while offset + 46 <= directory.count, directory.u32(offset) == 0x02014B50 {
            let madeBy = directory.u16(offset + 4)
            let flags = directory.u16(offset + 8)
            let method = Int(directory.u16(offset + 10))
            let dosTime = directory.u16(offset + 12)
            let dosDate = directory.u16(offset + 14)
            let crc = directory.u32(offset + 16)
            var compressed = UInt64(directory.u32(offset + 20))
            var uncompressed = UInt64(directory.u32(offset + 24))
            let nameLength = Int(directory.u16(offset + 28))
            let extraLength = Int(directory.u16(offset + 30))
            let entryCommentLength = Int(directory.u16(offset + 32))
            var disk = UInt64(directory.u16(offset + 34))
            let external = directory.u32(offset + 38)
            var localOffset = UInt64(directory.u32(offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength + extraLength <= directory.count else { break }

            let nameBytes = [UInt8](directory[(directory.startIndex + nameStart)..<(directory.startIndex + nameStart + nameLength)])
            var path: String?
            if let utf8 = String(bytes: nameBytes, encoding: .utf8) { path = utf8 }   // flagged or not: most tools write UTF-8

            var modified = dosDateTime(date: dosDate, time: dosTime)
            var isAES = false
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = directory.u16(extra)
                let size = Int(directory.u16(extra + 2))
                let body = extra + 4
                guard body + size <= extraEnd else { break }
                switch id {
                case 0x0001:
                    // ZIP64 extended info: only the fields saturated in the header are present, in order.
                    var cursor = body
                    if uncompressed == 0xFFFF_FFFF, cursor + 8 <= body + size { uncompressed = directory.u64(cursor); cursor += 8 }
                    if compressed == 0xFFFF_FFFF, cursor + 8 <= body + size { compressed = directory.u64(cursor); cursor += 8 }
                    if localOffset == 0xFFFF_FFFF, cursor + 8 <= body + size { localOffset = directory.u64(cursor); cursor += 8 }
                    if disk == 0xFFFF, cursor + 4 <= body + size { disk = UInt64(directory.u32(cursor)) }
                case 0x5455 where size >= 5 && directory[directory.startIndex + body] & 0x01 != 0:
                    // Extended timestamp: precise UTC modification time.
                    modified = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: directory.u32(body + 1))))
                case 0x7075 where size > 5 && path == nil:
                    // Info-ZIP Unicode Path: the UTF-8 name, for archives whose header name is legacy.
                    let bytes = [UInt8](directory[(directory.startIndex + body + 5)..<(directory.startIndex + body + size)])
                    path = String(bytes: bytes, encoding: .utf8)
                case 0x9901:
                    isAES = true
                default:
                    break
                }
                extra = body + size
            }

            let unixMode = (madeBy >> 8) == 3 ? (external >> 16) : 0
            let decodedPath = path ?? String(decoding: nameBytes, as: UTF8.self)
            let isDirectory = decodedPath.hasSuffix("/") || (external & 0x10) != 0 || (unixMode & 0o170000) == 0o040000
            var entry = ArchiveEntry(path: decodedPath, isDirectory: isDirectory, isSymlink: (unixMode & 0o170000) == 0o120000,
                                     size: isDirectory ? 0 : uncompressed, compressedSize: isDirectory ? 0 : compressed,
                                     modified: modified, isEncrypted: flags & 0x0001 != 0 || isAES || method == 99)
            entry.index = entries.count
            entry.methodCode = method
            entry.method = isDirectory ? nil : methodName(method)
            entry.flags = Int(flags)
            entry.crc = crc
            if unixMode != 0 { entry.permissions = UInt16(unixMode & 0o7777) }
            var location = localOffset
            if spanned, let volume = file.start(ofVolume: Int(clamping: disk)) { location = volume.saturatingAdd(localOffset) }
            entry.locator = UInt64(bitPattern: Int64(bitPattern: location) &+ delta)
            if path == nil { legacy.append((entries.count, nameBytes)) }
            entries.append(entry)

            if flags & 0x2000 != 0 { listing.headerEncrypted = true }
            offset = extraEnd + entryCommentLength
            if entries.count >= ArchiveReader.entryLimit { listing.truncated = true; break }
        }

        if !legacy.isEmpty {
            let encoding = NameDecoder.choose(legacy.map(\.bytes), fallback: NameDecoder.candidates[0].encoding)
            for (index, bytes) in legacy {
                entries[index].path = NameDecoder.decode(bytes, with: encoding)
            }
            listing.nameEncoding = encoding.name
        }

        if entries.isEmpty && entryCount > 0 { throw ArchiveError.corrupt("unreadable central directory") }
        if UInt64(entries.count) < min(entryCount, UInt64(ArchiveReader.entryLimit)) && !listing.truncated {
            listing.damage = "the file list ends early"
        }
        listing.entries = entries
        return listing
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

    /// True if Greece can decode this entry itself; others go through libarchive.
    static func canExtract(_ entry: ArchiveEntry) -> Bool { [0, 8, 93].contains(entry.methodCode) }

    /// Streams an entry's bytes (up to `limit`). Returns the bytes delivered and whether that was all of it.
    static func extract(_ entry: ArchiveEntry, from file: RandomAccessFile, limit: UInt64, cancel: CancelToken? = nil,
                        deliver: (UnsafeRawBufferPointer) throws -> Void) throws -> (UInt64, Bool) {
        if entry.isEncrypted { throw ArchiveError.encrypted }
        let header = file.read(at: entry.locator, count: 30)
        guard header.count == 30, header.u32(0) == 0x04034B50 else { throw ArchiveError.corrupt("missing local header") }
        let dataStart = entry.locator + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        let compressed = entry.compressedSize ?? 0
        let source = RangeSource(file, offset: dataStart, length: compressed)
        var total: UInt64 = 0

        /// Hands over a chunk within the limit; false once the limit is reached.
        func emit(_ buffer: UnsafeRawBufferPointer) throws -> Bool {
            let keep = Int(min(UInt64(buffer.count), limit - total))
            if keep > 0 { try deliver(UnsafeRawBufferPointer(rebasing: buffer[0..<keep])) }
            total += UInt64(keep)
            return keep == buffer.count
        }

        switch entry.methodCode {
        case 0:
            while true {
                if cancel?.isCancelled == true { throw ArchiveError.cancelled }
                let chunk = try source.read(upTo: 256 * 1024)
                if chunk.isEmpty { return (total, true) }
                let whole = try chunk.withUnsafeBytes { try emit($0) }
                if !whole || (total == limit && source.remaining > 0) { return (total, false) }
            }
        case 8:
            let complete = try inflate(source, cancel: cancel, emit: emit)
            return (total, complete)
        case 93:
            let zstd = try ZstdSource(source)
            while true {
                if cancel?.isCancelled == true { throw ArchiveError.cancelled }
                let chunk = try zstd.read(upTo: 256 * 1024)
                if chunk.isEmpty { return (total, true) }
                let whole = try chunk.withUnsafeBytes { try emit($0) }
                if !whole { return (total, false) }
            }
        default:
            throw ArchiveError.unsupported(methodName(entry.methodCode))
        }
    }

    /// Inflates raw Deflate data into `emit`. Returns false if `emit` stopped early (the limit), true otherwise.
    private static func inflate(_ source: RangeSource, cancel: CancelToken?, emit: (UnsafeRawBufferPointer) throws -> Bool) throws -> Bool {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ArchiveError.corrupt("inflate init")
        }
        defer { inflateEnd(&stream) }
        let capacity = 256 * 1024
        let output = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { output.deallocate() }

        while true {
            if cancel?.isCancelled == true { throw ArchiveError.cancelled }
            let chunk = try source.read(upTo: capacity)
            if chunk.isEmpty { return true }   // ran out of input: keep what decoded
            var ended = false
            var stopped = false
            try chunk.withUnsafeBytes { input in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                defer { stream.next_in = nil; stream.next_out = nil }
                while true {
                    stream.next_out = output.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(capacity)
                    let status = CArchive.inflate(&stream, Z_NO_FLUSH)
                    let produced = capacity - Int(stream.avail_out)
                    if produced > 0, try !emit(UnsafeRawBufferPointer(start: output, count: produced)) { stopped = true; return }
                    if status == Z_STREAM_END { ended = true; return }
                    if status != Z_OK && status != Z_BUF_ERROR { throw ArchiveError.corrupt("deflate data error") }
                    if stream.avail_in == 0 && stream.avail_out > 0 { return }
                    if status == Z_BUF_ERROR && produced == 0 { return }
                }
            }
            if stopped { return false }
            if ended { return true }
        }
    }

    // MARK: - Helpers

    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if data.u32(index) == signature { return index }
            index -= 1
        }
        return nil
    }

    private static func dosDateTime(date: UInt16, time: UInt16) -> Date? {
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
