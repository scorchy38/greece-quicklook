import Foundation
import Compression
import CArchive

/// In-memory decompression for installer members, always bounded: output stops at `limit`
/// and `truncated` says so, so a small member can never expand into gigabytes.
enum PackageDecompression {
    struct Output {
        var data: Data
        var truncated: Bool
    }

    /// zlib or gzip (auto-detected), including concatenated gzip members.
    static func zlib(_ input: Data, limit: Int) -> Output? {
        guard !input.isEmpty else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        var failed = false
        var truncated = false
        input.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else { failed = true; return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(buffer.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                if produced > 0 {
                    let room = limit - output.count
                    if produced >= room {
                        output.append(contentsOf: chunk[0..<max(0, room)])
                        truncated = true
                        return
                    }
                    output.append(contentsOf: chunk[0..<produced])
                }
                switch status {
                case Z_OK: continue
                case Z_STREAM_END:
                    // Another gzip member may follow.
                    if stream.avail_in > 0, inflateReset(&stream) == Z_OK { continue }
                    return
                case Z_BUF_ERROR where stream.avail_in == 0:
                    return
                default:
                    if output.isEmpty { failed = true }
                    return
                }
            }
        }
        return failed ? nil : Output(data: output, truncated: truncated)
    }

    static func bunzip2(_ input: Data, limit: Int) -> Output? {
        guard !input.isEmpty else { return nil }
        var stream = bz_stream()
        guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { return nil }
        defer { BZ2_bzDecompressEnd(&stream) }
        var output = Data()
        var chunk = [CChar](repeating: 0, count: 256 * 1024)
        var failed = false
        var truncated = false
        input.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { failed = true; return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = UInt32(buffer.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = UInt32(out.count)
                    return BZ2_bzDecompress(&stream)
                }
                let produced = chunk.count - Int(stream.avail_out)
                if produced > 0 {
                    let room = limit - output.count
                    let bytes = chunk.withUnsafeBufferPointer { UnsafeRawBufferPointer($0) }
                    if produced >= room {
                        output.append(contentsOf: bytes[0..<max(0, room)])
                        truncated = true
                        return
                    }
                    output.append(contentsOf: bytes[0..<produced])
                }
                if status == BZ_STREAM_END { return }
                if status != BZ_OK { if output.isEmpty { failed = true }; return }
                if stream.avail_in == 0 && produced == 0 { return }
            }
        }
        return failed ? nil : Output(data: output, truncated: truncated)
    }

    /// xz (and raw LZMA as Apple's Compression framework reads it).
    static func unxz(_ input: Data, limit: Int) -> Output? {
        guard !input.isEmpty else { return nil }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        var failed = false
        var truncated = false
        input.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { failed = true; return }
            stream.src_ptr = base
            stream.src_size = buffer.count
            while true {
                let status: compression_status = chunk.withUnsafeMutableBufferPointer { out in
                    stream.dst_ptr = out.baseAddress!
                    stream.dst_size = out.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunk.count - stream.dst_size
                if produced > 0 {
                    let room = limit - output.count
                    if produced >= room {
                        output.append(contentsOf: chunk[0..<max(0, room)])
                        truncated = true
                        return
                    }
                    output.append(contentsOf: chunk[0..<produced])
                }
                if status == COMPRESSION_STATUS_END { return }
                if status == COMPRESSION_STATUS_ERROR { if output.isEmpty { failed = true }; return }
                if produced == 0 && stream.src_size == 0 { return }
            }
        }
        return failed ? nil : Output(data: output, truncated: truncated)
    }

    /// Apple's pbzx container (macOS payloads): "pbzx", a flags word, then chunks of
    /// (uncompressed size, compressed size, bytes), each either xz or stored.
    static func unpbzx(_ input: Data, limit: Int) -> Output? {
        let reader = BinaryReader(input, bigEndian: true)
        guard input.count >= 12, input.prefix(4).elementsEqual(Array("pbzx".utf8)) else { return nil }
        var position = 12
        var output = Data()
        var chunks = 0
        while position + 16 <= input.count, chunks < 1_000_000 {
            chunks += 1
            guard let raw = reader.u64(at: position), let packed = reader.u64(at: position + 8),
                  let length = Int(exactly: packed), length >= 0, reader.has(length, at: position + 16),
                  let expanded = Int(exactly: raw) else { break }
            let body = input.subdata(in: (position + 16)..<(position + 16 + length))
            position += 16 + length
            let room = limit - output.count
            if packed == raw {
                output.append(body.prefix(room))
            } else if let piece = unxz(body, limit: min(room, max(expanded, 0) + 1)) {
                output.append(piece.data.prefix(room))
            } else {
                break
            }
            if output.count >= limit { return Output(data: output, truncated: true) }
        }
        return output.isEmpty ? nil : Output(data: output, truncated: false)
    }

    /// Picks the decoder from magic bytes: gzip, zlib, bzip2, xz, pbzx, or stored.
    static func decode(_ input: Data, limit: Int) -> Output? {
        let head = [UInt8](input.prefix(6))
        if head.starts(with: [0x1F, 0x8B]) || (head.count >= 2 && head[0] == 0x78 && (UInt16(head[0]) << 8 | UInt16(head[1])) % 31 == 0) {
            return zlib(input, limit: limit)
        }
        if head.starts(with: Array("BZh".utf8)) { return bunzip2(input, limit: limit) }
        if head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return unxz(input, limit: limit) }
        if head.starts(with: Array("pbzx".utf8)) { return unpbzx(input, limit: limit) }
        return Output(data: input.prefix(limit), truncated: input.count > limit)
    }
}
