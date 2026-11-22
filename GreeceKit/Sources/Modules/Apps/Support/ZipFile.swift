import Foundation
import CArchive

/// Random access to the members of a ZIP file (.ipa, .apk, .aab): the central directory, plus
/// bounded extraction of stored and deflated members. The file is memory-mapped, so members
/// that are never read cost nothing.
final class ZipFile {
    struct Member {
        let path: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: UInt64
        let size: UInt64
        let localHeaderOffset: UInt64
        var isDirectory: Bool { path.hasSuffix("/") }
        var isEncrypted: Bool { flags & 0x1 != 0 }
    }

    enum Failure: Error, Equatable { case notZip, tooLarge, unsupportedMethod, corrupt, encrypted }

    static let memberLimit = 200_000

    let url: URL
    let data: Data
    let members: [Member]
    /// Where the central directory starts: the APK Signing Block ends right before it.
    let centralDirectoryOffset: Int
    /// The listing stopped at `memberLimit`.
    let truncated: Bool
    private let index: [String: Int]

    init(url: URL) throws {
        self.url = url
        data = try Data(contentsOf: url, options: .alwaysMapped)
        let reader = BinaryReader(data)
        guard data.count >= 22, let eocd = ZipFile.findEndRecord(in: data) else { throw Failure.notZip }

        var count = UInt64(reader.u16(at: eocd + 10) ?? 0)
        var size = UInt64(reader.u32(at: eocd + 12) ?? 0)
        var start = UInt64(reader.u32(at: eocd + 16) ?? 0)
        var end = eocd
        if eocd >= 20, reader.u32(at: eocd - 20) == 0x0706_4B50, let z64 = reader.u64(at: eocd - 20 + 8),
           let position = Int(exactly: z64), reader.u32(at: position) == 0x0606_4B50 {
            count = reader.u64(at: position + 32) ?? count
            size = reader.u64(at: position + 40) ?? size
            start = reader.u64(at: position + 48) ?? start
            end = position
        }
        guard var offset = Int(exactly: start), let length = Int(exactly: size) else { throw Failure.corrupt }
        // Prefixed archives (self-extractors): trust the directory's size over its recorded offset.
        if reader.u32(at: offset) != 0x0201_4B50, length <= end, reader.u32(at: end - length) == 0x0201_4B50 {
            offset = end - length
        }
        centralDirectoryOffset = offset

        var members: [Member] = []
        members.reserveCapacity(Int(min(count, UInt64(ZipFile.memberLimit))))
        var truncated = false
        while reader.u32(at: offset) == 0x0201_4B50 {
            if members.count >= ZipFile.memberLimit { truncated = true; break }
            guard let flags = reader.u16(at: offset + 8), let method = reader.u16(at: offset + 10),
                  var compressed = reader.u32(at: offset + 20).map(UInt64.init),
                  var uncompressed = reader.u32(at: offset + 24).map(UInt64.init),
                  let nameLength = reader.u16(at: offset + 28).map(Int.init),
                  let extraLength = reader.u16(at: offset + 30).map(Int.init),
                  let commentLength = reader.u16(at: offset + 32).map(Int.init),
                  var local = reader.u32(at: offset + 42).map(UInt64.init),
                  let nameBytes = reader.bytes(at: offset + 46, count: nameLength) else { break }
            var extra = offset + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd, let id = reader.u16(at: extra), let fieldSize = reader.u16(at: extra + 2).map(Int.init) {
                let body = extra + 4
                guard body + fieldSize <= extraEnd else { break }
                if id == 0x0001 {
                    var cursor = body
                    if uncompressed == 0xFFFF_FFFF, cursor + 8 <= body + fieldSize { uncompressed = reader.u64(at: cursor) ?? 0; cursor += 8 }
                    if compressed == 0xFFFF_FFFF, cursor + 8 <= body + fieldSize { compressed = reader.u64(at: cursor) ?? 0; cursor += 8 }
                    if local == 0xFFFF_FFFF, cursor + 8 <= body + fieldSize { local = reader.u64(at: cursor) ?? 0 }
                }
                extra = body + fieldSize
            }
            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            members.append(Member(path: name, method: method, flags: flags, compressedSize: compressed,
                                  size: uncompressed, localHeaderOffset: local))
            offset = extraEnd + commentLength
        }
        guard !members.isEmpty || count == 0 else { throw Failure.corrupt }
        self.members = members
        self.truncated = truncated
        var index: [String: Int] = [:]
        index.reserveCapacity(members.count)
        for (position, member) in members.enumerated() where index[member.path] == nil { index[member.path] = position }
        self.index = index
    }

    func member(_ path: String) -> Member? { index[path].map { members[$0] } }

    /// Case-insensitive lookup, for archives built on case-insensitive file systems.
    func member(caseInsensitive path: String) -> Member? {
        if let exact = member(path) { return exact }
        let lower = path.lowercased()
        return members.first { $0.path.lowercased() == lower }
    }

    /// The member's whole contents, refusing anything larger than `limit` once uncompressed.
    func contents(of member: Member, limit: Int = 32 << 20) throws -> Data {
        guard member.size <= UInt64(limit) else { throw Failure.tooLarge }
        var output = Data()
        output.reserveCapacity(Int(member.size))
        try stream(member, maximum: UInt64(limit)) { chunk in
            output.append(chunk)
            return true
        }
        return output
    }

    func contents(of path: String, limit: Int = 32 << 20) -> Data? {
        guard let member = member(path) else { return nil }
        return try? contents(of: member, limit: limit)
    }

    /// Streams the member's uncompressed bytes in chunks. Return false from `body` to stop early.
    /// Never produces more than `maximum` bytes, whatever the headers claim.
    func stream(_ member: Member, maximum: UInt64 = .max, chunkSize: Int = 1 << 20, _ body: (Data) throws -> Bool) throws {
        guard !member.isEncrypted else { throw Failure.encrypted }
        let reader = BinaryReader(data)
        guard let local = Int(exactly: member.localHeaderOffset), reader.u32(at: local) == 0x0403_4B50,
              let nameLength = reader.u16(at: local + 26), let extraLength = reader.u16(at: local + 28) else { throw Failure.corrupt }
        let start = local + 30 + Int(nameLength) + Int(extraLength)
        let available = UInt64(max(0, data.count - start))
        let compressedLength = Int(min(member.compressedSize, available))
        guard reader.has(compressedLength, at: start) else { throw Failure.corrupt }

        switch member.method {
        case 0:
            var position = start
            let end = start + Int(min(UInt64(compressedLength), maximum))
            while position < end {
                let next = min(end, position + chunkSize)
                if try !body(data.subdata(in: position..<next)) { return }
                position = next
            }
        case 8:
            try inflateRaw(data, from: start, length: compressedLength, maximum: maximum, chunkSize: chunkSize, body)
        default:
            throw Failure.unsupportedMethod
        }
    }

    /// Raw deflate (no zlib header), as ZIP stores it.
    private func inflateRaw(_ data: Data, from start: Int, length: Int, maximum: UInt64, chunkSize: Int,
                            _ body: (Data) throws -> Bool) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.corrupt }
        defer { inflateEnd(&stream) }
        var produced: UInt64 = 0
        var output = [UInt8](repeating: 0, count: chunkSize)
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else { throw Failure.corrupt }
            stream.next_in = UnsafeMutablePointer(mutating: base + start)
            stream.avail_in = uInt(length)
            while true {
                let status: Int32 = output.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let have = chunkSize - Int(stream.avail_out)
                if have > 0 {
                    let allowed = Int(min(UInt64(have), maximum - produced))
                    produced += UInt64(allowed)
                    if try !body(Data(output[0..<allowed])) { return }
                    if produced >= maximum { return }
                }
                if status == Z_STREAM_END { return }
                if status == Z_BUF_ERROR && stream.avail_in == 0 { return }   // truncated member: keep what we have
                guard status == Z_OK else { throw Failure.corrupt }
            }
        }
    }

    private static func findEndRecord(in data: Data) -> Int? {
        let reader = BinaryReader(data)
        let lowest = max(0, data.count - 65_557)
        var position = data.count - 22
        while position >= lowest {
            if reader.u32(at: position) == 0x0605_4B50 { return position }
            position -= 1
        }
        return nil
    }
}
