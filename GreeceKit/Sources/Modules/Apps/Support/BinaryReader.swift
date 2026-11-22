import Foundation

/// Bounds-checked reads over untrusted bytes. Every read past the end returns nil instead of trapping,
/// and offsets are always relative to the start of `data` (slices included).
struct BinaryReader {
    let data: Data
    var offset: Int = 0
    var bigEndian: Bool

    init(_ data: Data, bigEndian: Bool = false) {
        // Rebase slices so offset 0 is always the first byte.
        self.data = data.startIndex == 0 ? data : Data(data)
        self.bigEndian = bigEndian
    }

    var count: Int { data.count }
    var remaining: Int { max(0, data.count - offset) }
    var isAtEnd: Bool { offset >= data.count }

    func has(_ length: Int, at position: Int) -> Bool {
        position >= 0 && length >= 0 && position <= data.count && length <= data.count - position
    }

    // MARK: Absolute reads

    func u8(at position: Int) -> UInt8? {
        guard has(1, at: position) else { return nil }
        return data[position]
    }

    func u16(at position: Int) -> UInt16? {
        guard has(2, at: position) else { return nil }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: position, as: UInt16.self) }
        return bigEndian ? UInt16(bigEndian: raw) : UInt16(littleEndian: raw)
    }

    func u32(at position: Int) -> UInt32? {
        guard has(4, at: position) else { return nil }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: position, as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw)
    }

    func u64(at position: Int) -> UInt64? {
        guard has(8, at: position) else { return nil }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: position, as: UInt64.self) }
        return bigEndian ? UInt64(bigEndian: raw) : UInt64(littleEndian: raw)
    }

    func bytes(at position: Int, count length: Int) -> Data? {
        guard has(length, at: position) else { return nil }
        return data.subdata(in: position..<(position + length))
    }

    /// A NUL-terminated (or field-bounded) string, decoded leniently.
    func cString(at position: Int, maxLength: Int = 4096) -> String? {
        guard has(1, at: position) else { return nil }
        let end = min(data.count, position + maxLength)
        var stop = position
        while stop < end && data[stop] != 0 { stop += 1 }
        return String(decoding: data[position..<stop], as: UTF8.self)
    }

    /// A fixed-width field padded with NULs (Mach-O segment names, PE section names).
    func fixedString(at position: Int, length: Int) -> String? {
        guard let field = bytes(at: position, count: length) else { return nil }
        let trimmed = field.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    // MARK: Sequential reads

    mutating func readU8() -> UInt8? { defer { offset += 1 }; return u8(at: offset) }
    mutating func readU16() -> UInt16? { defer { offset += 2 }; return u16(at: offset) }
    mutating func readU32() -> UInt32? { defer { offset += 4 }; return u32(at: offset) }
    mutating func readU64() -> UInt64? { defer { offset += 8 }; return u64(at: offset) }
    mutating func readBytes(_ length: Int) -> Data? {
        guard length >= 0, let value = bytes(at: offset, count: length) else { offset = data.count; return nil }
        offset += length
        return value
    }
    mutating func skip(_ length: Int) { offset = length < 0 || length > remaining ? data.count : offset + length }
}

extension Data {
    /// Hex for hashes and UUIDs, lowercase without separators.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Big-endian reads (Mach-O signatures, xar headers, bencode never). Out of range reads return 0.
    func be32(_ offset: Int) -> UInt32 { BinaryReader(self, bigEndian: true).u32(at: offset) ?? 0 }
    func be64(_ offset: Int) -> UInt64 { BinaryReader(self, bigEndian: true).u64(at: offset) ?? 0 }

    /// The first occurrence of `pattern` at or after `start`, searching at most `limit` bytes.
    func firstRange(of pattern: [UInt8], from start: Int = 0, limit: Int = .max) -> Int? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        let end = Swift.min(count - pattern.count, start.addingReportingOverflow(limit).overflow ? count : start + limit)
        guard start >= 0, start <= end else { return nil }
        return withUnsafeBytes { buffer -> Int? in
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let first = pattern[0]
            var index = start
            while index <= end {
                guard let found = memchr(pointer + index, Int32(first), end - index + 1) else { return nil }
                let position = pointer.distance(to: found.assumingMemoryBound(to: UInt8.self))
                if memcmp(pointer + position, pattern, pattern.count) == 0 { return position }
                index = position + 1
            }
            return nil
        }
    }
}
