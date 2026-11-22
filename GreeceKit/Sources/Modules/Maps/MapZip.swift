import Foundation
import CArchive

/// zlib inflate with a hard output cap, so a zip bomb or a hostile tile can't exhaust memory.
enum Inflate {
    enum Mode { case raw, gzipOrZlib }

    static func decompress(_ input: Data, mode: Mode, limit: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        var stream = z_stream()
        let bits: Int32 = mode == .raw ? -15 : 15 + 32
        guard inflateInit2_(&stream, bits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        let ok: Bool = input.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return false }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 {
                    guard output.count + produced <= limit else { return false }
                    output.append(contentsOf: buffer[0..<produced])
                }
                if status == Z_STREAM_END { return true }
                if status != Z_OK { return status == Z_BUF_ERROR && stream.avail_in == 0 && !output.isEmpty }
                if stream.avail_in == 0 && produced == 0 { return !output.isEmpty }
            }
        }
        return ok ? output : nil
    }

    static func isGzip(_ data: Data) -> Bool { data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B }
    static func isZlib(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let a = data[data.startIndex], b = data[data.startIndex + 1]
        return a & 0x0F == 8 && (UInt16(a) << 8 | UInt16(b)) % 31 == 0
    }
}

/// Reads individual members of a ZIP (KMZ, zipped shapefiles) through its central directory.
final class MapZipMembers {
    struct Member {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
        let encrypted: Bool
    }

    private let data: Data
    private(set) var members: [Member] = []

    init(url: URL, maxMembers: Int = 10_000) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        try readDirectory(maxMembers: maxMembers)
    }

    init(data: Data, maxMembers: Int = 10_000) throws {
        self.data = data
        try readDirectory(maxMembers: maxMembers)
    }

    private func readDirectory(maxMembers: Int) throws {
        guard data.count >= 22 else { throw GeoError.invalid("This archive is damaged.") }
        var eocd: Int?
        var index = data.count - 22
        let lowest = max(0, data.count - 65_557)
        while index >= lowest {
            if data.u32(index) == 0x06054B50 { eocd = index; break }
            index -= 1
        }
        guard let eocd else { throw GeoError.invalid("This archive is damaged.") }
        var offset = Int(data.u32(eocd + 16))
        let size = Int(data.u32(eocd + 12))
        if offset >= data.count || data.u32(offset) != 0x02014B50, size <= eocd, data.u32(eocd - size) == 0x02014B50 {
            offset = eocd - size
        }
        while offset + 46 <= data.count, data.u32(offset) == 0x02014B50, members.count < maxMembers {
            let flags = data.u16(offset + 8)
            let method = data.u16(offset + 10)
            let compressed = Int(data.u32(offset + 20))
            let uncompressed = Int(data.u32(offset + 24))
            let nameLength = Int(data.u16(offset + 28))
            let extraLength = Int(data.u16(offset + 30))
            let commentLength = Int(data.u16(offset + 32))
            let header = Int(data.u32(offset + 42))
            guard offset + 46 + nameLength <= data.count else { break }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            members.append(Member(name: name, method: method, compressedSize: compressed, size: uncompressed,
                                  headerOffset: header, encrypted: flags & 1 != 0))
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    /// Case-insensitive lookup, ignoring a leading "./" or "/".
    func member(named name: String) -> Member? {
        var wanted = name.replacingOccurrences(of: "\\", with: "/")
        while wanted.hasPrefix("./") { wanted.removeFirst(2) }
        while wanted.hasPrefix("/") { wanted.removeFirst() }
        let lower = wanted.lowercased()
        return members.first { $0.name.lowercased() == lower }
    }

    /// A member's bytes (stored or deflated), or nil if it's damaged, encrypted or over `limit`.
    func data(_ member: Member, limit: Int) -> Data? {
        guard !member.encrypted, member.size <= limit else { return nil }
        let local = member.headerOffset
        guard local >= 0, local + 30 <= data.count, data.u32(local) == 0x04034B50 else { return nil }
        let start = local + 30 + Int(data.u16(local + 26)) + Int(data.u16(local + 28))
        let end = start + member.compressedSize
        guard start <= data.count, end <= data.count, end >= start else { return nil }
        let slice = data.subdata(in: start..<end)
        switch member.method {
        case 0: return slice
        case 8:
            guard let out = Inflate.decompress(slice, mode: .raw, limit: limit) else { return nil }
            return out
        default: return nil
        }
    }
}
