import Foundation
import CArchive

/// Reads single members out of a ZIP container (3MF packages, zipped AMF). Stored and deflated
/// members only, with hard limits on entry counts and inflated sizes.
struct ZipMembers {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    let data: Data
    let entries: [Entry]

    static let entryLimit = 20_000

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ArchiveError.corrupt("too small") }
        // The end-of-central-directory record sits in the last 64 KB.
        var eocd: Int?
        var index = data.count - 22
        let lowest = max(0, data.count - 65_557)
        while index >= lowest {
            if data.u32(index) == 0x06054B50 { eocd = index; break }
            index -= 1
        }
        guard let eocd else { throw ArchiveError.corrupt("no end of central directory") }
        var offset = Int(data.u32(eocd + 16))
        let declared = Int(data.u16(eocd + 10))
        var entries: [Entry] = []
        entries.reserveCapacity(min(declared, Self.entryLimit))
        while offset + 46 <= data.count, data.u32(offset) == 0x02014B50, entries.count < Self.entryLimit {
            let method = data.u16(offset + 10)
            let compressed = Int(data.u32(offset + 20))
            let size = Int(data.u32(offset + 24))
            let nameLength = Int(data.u16(offset + 28))
            let extraLength = Int(data.u16(offset + 30))
            let commentLength = Int(data.u16(offset + 32))
            let local = Int(data.u32(offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(decoding: data.subdata(in: nameStart..<(nameStart + nameLength)), as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size, localHeaderOffset: local))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        guard !entries.isEmpty else { throw ArchiveError.corrupt("empty central directory") }
        self.entries = entries
    }

    /// The entry with this path, ignoring case and a leading slash (3MF part names start with one).
    func entry(named name: String) -> Entry? {
        let wanted = name.drop { $0 == "/" }.lowercased()
        return entries.first { $0.name.drop { $0 == "/" }.lowercased() == wanted }
    }

    /// The member's bytes, or nil if it is missing, encrypted, uses another method or exceeds `limit`.
    func contents(of entry: Entry, limit: Int) -> Data? {
        guard entry.size <= limit, entry.compressedSize <= data.count else { return nil }
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count, data.u32(header) == 0x04034B50 else { return nil }
        guard data.u16(header + 6) & 0x0001 == 0 else { return nil }   // encrypted
        let start = header + 30 + Int(data.u16(header + 26)) + Int(data.u16(header + 28))
        guard start <= data.count, entry.compressedSize <= data.count - start else { return nil }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0: return raw
        case 8: return Self.inflateRaw(raw, expected: entry.size, limit: limit)
        default: return nil
        }
    }

    /// Raw DEFLATE (no zlib header), stopping at `limit` bytes.
    static func inflateRaw(_ input: Data, expected: Int, limit: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(1, min(expected > 0 ? expected : input.count * 4, limit)))
        var produced = 0
        var input = input
        let status: Int32 = input.withUnsafeMutableBytes { inPtr -> Int32 in
            guard let inBase = inPtr.baseAddress else { return Z_DATA_ERROR }
            stream.next_in = inBase.assumingMemoryBound(to: Bytef.self)
            stream.avail_in = uInt(inPtr.count)
            while true {
                if produced == output.count {
                    guard output.count < limit else { return Z_BUF_ERROR }
                    output.count = min(limit, output.count * 2)
                }
                let result: Int32 = output.withUnsafeMutableBytes { outPtr in
                    stream.next_out = outPtr.baseAddress!.assumingMemoryBound(to: Bytef.self).advanced(by: produced)
                    stream.avail_out = uInt(outPtr.count - produced)
                    let before = stream.avail_out
                    let result = inflate(&stream, Z_NO_FLUSH)
                    produced += Int(before - stream.avail_out)
                    return result
                }
                if result == Z_STREAM_END { return Z_STREAM_END }
                if result != Z_OK { return result }
                if stream.avail_in == 0 && produced < output.count { return Z_STREAM_END }
            }
        }
        guard status == Z_STREAM_END else { return nil }
        output.count = produced
        return output
    }
}
