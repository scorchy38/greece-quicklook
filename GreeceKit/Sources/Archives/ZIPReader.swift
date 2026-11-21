import Foundation

/// Reads a ZIP central directory (including ZIP64) without touching file data.
enum ZIPReader {

    static func read(_ url: URL, archiveSize: UInt64) throws -> ArchiveListing {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 22 else { throw ArchiveError.corrupt("too small") }

        guard let eocd = findSignature(0x06054B50, in: data, searchBack: 65_557) else {
            throw ArchiveError.corrupt("no end of central directory")
        }
        var entryCount = UInt64(data.u16(eocd + 10))
        var directorySize = UInt64(data.u32(eocd + 12))
        var directoryOffset = UInt64(data.u32(eocd + 16))
        var directoryEnd = eocd

        // ZIP64: the locator sits immediately before the classic end record.
        if eocd >= 20, data.u32(eocd - 20) == 0x07064B50,
           let zip64 = Int(exactly: data.u64(eocd - 20 + 8)), zip64 >= 0, zip64 <= data.count - 56,
           data.u32(zip64) == 0x06064B50 {
            entryCount = data.u64(zip64 + 32)
            directorySize = data.u64(zip64 + 40)
            directoryOffset = data.u64(zip64 + 48)
            directoryEnd = zip64
        }

        // Self-extracting or prefixed archives: the directory really starts `size` bytes before its end.
        guard var offset = Int(exactly: directoryOffset), let size = Int(exactly: directorySize) else {
            throw ArchiveError.corrupt("invalid central directory")
        }
        if offset >= data.count || data.u32(offset) != 0x02014B50, size <= directoryEnd,
           data.u32(directoryEnd - size) == 0x02014B50 {
            offset = directoryEnd - size
        }

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(min(entryCount, UInt64(ArchiveReader.entryLimit))))
        var truncated = false

        while offset + 46 <= data.count, data.u32(offset) == 0x02014B50 {
            let madeBy = data.u16(offset + 4)
            let flags = data.u16(offset + 8)
            let dosTime = data.u16(offset + 12)
            let dosDate = data.u16(offset + 14)
            var compressed = UInt64(data.u32(offset + 20))
            var uncompressed = UInt64(data.u32(offset + 24))
            let nameLength = Int(data.u16(offset + 28))
            let extraLength = Int(data.u16(offset + 30))
            let commentLength = Int(data.u16(offset + 32))
            let external = data.u32(offset + 38)
            let nameStart = offset + 46
            guard nameStart + nameLength + extraLength <= data.count else { break }

            let nameBytes = data.subdata(in: nameStart..<(nameStart + nameLength))
            let path = decodeName(nameBytes, utf8Flag: flags & 0x0800 != 0)

            var modified = dosDateTime(date: dosDate, time: dosTime)
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = data.u16(extra)
                let size = Int(data.u16(extra + 2))
                let body = extra + 4
                guard body + size <= extraEnd else { break }
                if id == 0x0001 {
                    // ZIP64 extended info: only the fields saturated in the header are present, in order.
                    var cursor = body
                    if uncompressed == 0xFFFF_FFFF, cursor + 8 <= body + size { uncompressed = data.u64(cursor); cursor += 8 }
                    if compressed == 0xFFFF_FFFF, cursor + 8 <= body + size { compressed = data.u64(cursor); cursor += 8 }
                } else if id == 0x5455, size >= 5, data[body] & 0x01 != 0 {
                    // Extended timestamp: precise UTC modification time.
                    modified = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: data.u32(body + 1))))
                }
                extra = body + size
            }

            let unixMode = (madeBy >> 8) == 3 ? (external >> 16) : 0
            let isDirectory = path.hasSuffix("/") || (external & 0x10) != 0 || (unixMode & 0o170000) == 0o040000
            let isSymlink = (unixMode & 0o170000) == 0o120000

            entries.append(ArchiveEntry(
                path: path,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: isDirectory ? 0 : uncompressed,
                compressedSize: isDirectory ? 0 : compressed,
                modified: modified,
                isEncrypted: flags & 0x0001 != 0))

            offset = extraEnd + commentLength
            if entries.count >= ArchiveReader.entryLimit { truncated = true; break }
        }

        if entries.isEmpty && entryCount > 0 { throw ArchiveError.corrupt("unreadable central directory") }
        return ArchiveListing(format: .zip, container: .zip, entries: entries, archiveSize: archiveSize, truncated: truncated)
    }

    private static func findSignature(_ signature: UInt32, in data: Data, searchBack: Int) -> Int? {
        let lowest = max(0, data.count - searchBack)
        var index = data.count - 22
        while index >= lowest {
            if data.u32(index) == signature { return index }
            index -= 1
        }
        return nil
    }

    private static let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    private static func decodeName(_ bytes: Data, utf8Flag: Bool) -> String {
        if utf8Flag, let s = String(data: bytes, encoding: .utf8) { return s }
        if let s = String(data: bytes, encoding: .utf8) { return s }   // most modern tools, flag or not
        return String(data: bytes, encoding: cp437) ?? String(decoding: bytes, as: UTF8.self)
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
