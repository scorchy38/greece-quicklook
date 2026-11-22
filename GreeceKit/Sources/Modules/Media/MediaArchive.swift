import Foundation
import CArchive

/// Just enough decompression for media containers: gzip (SVGZ) and ZIP members (dotLottie,
/// Procreate swatches), always with a ceiling on what comes out.
enum MediaInflate {
    /// windowBits: 15 + 32 detects gzip or zlib headers; -15 is a raw deflate stream (ZIP).
    static func inflate(_ input: Data, windowBits: Int32, limit: Int) -> Data? {
        guard !input.isEmpty else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunk = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var finishedMembers = 0
        var failed = false
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(raw.count)
            while true {
                var produced = 0
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    let result = CArchive.inflate(&stream, Z_NO_FLUSH)
                    produced = chunk - Int(stream.avail_out)
                    output.append(out.baseAddress!, count: produced)
                    return result
                }
                if output.count > limit { failed = true; break }
                if status == Z_STREAM_END {
                    finishedMembers += 1
                    // Concatenated gzip members; anything else after the end is padding.
                    guard windowBits > 0, stream.avail_in > 0, inflateReset(&stream) == Z_OK else { break }
                    continue
                }
                if status != Z_OK {
                    // Junk after a complete member is tolerated; a broken first member is not.
                    if finishedMembers == 0 && status != Z_BUF_ERROR { failed = true }
                    break
                }
                if stream.avail_in == 0 && produced < chunk { break }
            }
            stream.next_in = nil
            stream.next_out = nil
        }
        guard !failed, !output.isEmpty else { return nil }
        return output
    }
}

/// Reads named members out of a ZIP file (stored or deflated), for containers like dotLottie.
struct MediaZip {
    struct Entry { let name: String; let method: Int; let compressedSize: Int; let size: Int; let localHeader: Int }

    let data: Data
    let entries: [Entry]

    static let entryLimit = 4096

    init?(_ data: Data) {
        self.data = data
        let reader = MediaReaderLE(data)
        // The end-of-central-directory record is in the last 64 KB.
        let lowest = max(0, data.count - 65_557)
        var eocd: Int?
        var position = data.count - 22
        while position >= lowest {
            if reader.u32(position) == 0x0605_4B50 { eocd = position; break }
            position -= 1
        }
        guard let eocd, let count = reader.u16(eocd + 10), let directory = reader.u32(eocd + 16) else { return nil }
        var entries: [Entry] = []
        var offset = directory
        for _ in 0..<min(count, Self.entryLimit) {
            guard reader.u32(offset) == 0x0201_4B50, let method = reader.u16(offset + 10), let compressed = reader.u32(offset + 20),
                  let size = reader.u32(offset + 24), let nameLength = reader.u16(offset + 28), let extraLength = reader.u16(offset + 30),
                  let commentLength = reader.u16(offset + 32), let local = reader.u32(offset + 42),
                  offset + 46 + nameLength <= data.count else { break }
            let name = String(decoding: data[(data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size, localHeader: local))
            offset += 46 + nameLength + extraLength + commentLength
        }
        guard !entries.isEmpty else { return nil }
        self.entries = entries
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name } ?? entries.first { $0.name.lowercased() == name.lowercased() }
    }

    /// A member's bytes, or nil if it's damaged, encrypted, oddly compressed or bigger than `limit`.
    func contents(of entry: Entry, limit: Int) -> Data? {
        guard entry.size <= limit, entry.compressedSize <= data.count else { return nil }
        let reader = MediaReaderLE(data)
        guard reader.u32(entry.localHeader) == 0x0403_4B50, let flags = reader.u16(entry.localHeader + 6), flags & 1 == 0,
              let nameLength = reader.u16(entry.localHeader + 26), let extraLength = reader.u16(entry.localHeader + 28) else { return nil }
        let start = entry.localHeader + 30 + nameLength + extraLength
        guard start >= 0, start + entry.compressedSize <= data.count else { return nil }
        let body = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0: return body
        case 8: return MediaInflate.inflate(body, windowBits: -15, limit: limit)
        default: return nil
        }
    }
}

/// Little-endian reads for ZIP structures.
struct MediaReaderLE {
    let data: Data
    init(_ data: Data) { self.data = data }

    func u16(_ offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        let base = data.startIndex + offset
        return Int(data[base]) | Int(data[base + 1]) << 8
    }

    func u32(_ offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let base = data.startIndex + offset
        return Int(data[base]) | Int(data[base + 1]) << 8 | Int(data[base + 2]) << 16 | Int(data[base + 3]) << 24
    }
}
