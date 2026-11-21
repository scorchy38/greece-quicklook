import Foundation
import Compression
import CArchive

/// A forward-only stream of bytes. `read` returns an empty Data at the end.
protocol ByteSource: AnyObject {
    func read(upTo count: Int) throws -> Data
    /// Discards `count` bytes. Sources that can seek do so.
    func skip(_ count: UInt64) throws
}

extension ByteSource {
    func skip(_ count: UInt64) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = try read(upTo: Int(min(remaining, 1 << 20)))
            if chunk.isEmpty { throw ArchiveError.corrupt("unexpected end of data") }
            remaining -= UInt64(chunk.count)
        }
    }
}

final class FileSource: ByteSource {
    private let handle: FileHandle
    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    func read(upTo count: Int) throws -> Data { try handle.read(upToCount: count) ?? Data() }
    func skip(_ count: UInt64) throws {
        let offset = try handle.offset()
        try handle.seek(toOffset: offset + count)
    }
}

/// Adds exact reads and peeking on top of any source.
final class BufferedReader: ByteSource {
    private let source: ByteSource
    private var buffer = Data()

    init(_ source: ByteSource) { self.source = source }

    func peek(_ count: Int) throws -> Data {
        while buffer.count < count {
            let chunk = try source.read(upTo: max(count - buffer.count, 64 * 1024))
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return buffer.prefix(count)
    }

    func read(upTo count: Int) throws -> Data {
        if buffer.isEmpty { return try source.read(upTo: count) }
        let out = buffer.prefix(count)
        buffer = buffer.dropFirst(out.count)
        if buffer.isEmpty { buffer = Data() }
        return Data(out)
    }

    func readExactly(_ count: Int) throws -> Data? {
        let data = try peek(count)
        guard data.count == count else { return nil }
        buffer = buffer.dropFirst(count)
        if buffer.isEmpty { buffer = Data() }
        return Data(data)
    }

    func skip(_ count: UInt64) throws {
        let fromBuffer = Int(min(UInt64(buffer.count), count))
        buffer = buffer.dropFirst(fromBuffer)
        if buffer.isEmpty { buffer = Data() }
        if count > UInt64(fromBuffer) { try source.skip(count - UInt64(fromBuffer)) }
    }
}

// MARK: - gzip (zlib, multi-member)

final class GzipSource: ByteSource {
    private let input: FileHandle
    private var stream = z_stream()
    private var inputBuffer = Data()
    private var finished = false

    init(url: URL) throws {
        input = try FileHandle(forReadingFrom: url)
        // 15 + 32: auto-detect gzip or zlib headers.
        let status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw ArchiveError.corrupt("gzip init \(status)") }
    }

    deinit {
        inflateEnd(&stream)
        try? input.close()
    }

    private var membersEnded = 0

    func read(upTo count: Int) throws -> Data {
        guard !finished, count > 0 else { return Data() }
        var output = Data(count: count)
        var produced = 0
        while produced == 0 && !finished {
            if stream.avail_in == 0 {
                inputBuffer = try input.read(upToCount: 256 * 1024) ?? Data()
                if inputBuffer.isEmpty { finished = true; break }
                stream.avail_in = uInt(inputBuffer.count)
            }
            let status: Int32 = inputBuffer.withUnsafeMutableBytes { inPtr in
                output.withUnsafeMutableBytes { outPtr in
                    let consumed = inPtr.count - Int(stream.avail_in)
                    stream.next_in = inPtr.baseAddress!.assumingMemoryBound(to: Bytef.self).advanced(by: consumed)
                    stream.next_out = outPtr.baseAddress!.assumingMemoryBound(to: Bytef.self).advanced(by: produced)
                    stream.avail_out = uInt(count - produced)
                    let before = stream.avail_out
                    let result = inflate(&stream, Z_NO_FLUSH)
                    produced += Int(before - stream.avail_out)
                    stream.next_in = nil
                    stream.next_out = nil
                    return result
                }
            }
            switch status {
            case Z_OK:
                break
            case Z_STREAM_END:
                // Another gzip member may follow (concatenated .gz files).
                membersEnded += 1
                inflateReset(&stream)
            case Z_BUF_ERROR where stream.avail_in == 0:
                break
            default:
                // Trailing padding after a complete member is common in tarballs: treat it as the end.
                if membersEnded > 0 { finished = true } else { throw ArchiveError.corrupt("gzip data error") }
            }
        }
        output.count = produced
        return output
    }

    /// The original file name stored in the gzip header (FNAME), if present.
    static func originalName(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 1024) else { return nil }
        try? handle.close()
        let bytes = [UInt8](data)
        guard bytes.count > 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[3] & 0x08 != 0 else { return nil }
        var index = 10
        if bytes[3] & 0x04 != 0, bytes.count > 12 { index += 2 + Int(bytes[10]) | Int(bytes[11]) << 8 }
        guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0) else { return nil }
        let name = String(decoding: bytes[index..<end], as: UTF8.self)
        return name.isEmpty ? nil : (name as NSString).lastPathComponent
    }

    /// ISIZE: uncompressed size mod 2^32 from the trailer. Reliable for single-member files under 4 GB.
    static func trailerSize(_ url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end >= 18 else { return nil }
        try? handle.seek(toOffset: end - 4)
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return nil }
        return UInt64(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
    }
}

// MARK: - bzip2 (libbz2, multi-stream)

final class Bzip2Source: ByteSource {
    private let input: FileHandle
    private var stream = bz_stream()
    private var inputBuffer = Data()
    private var consumed = 0
    private var finished = false
    private var streamsEnded = 0

    init(url: URL) throws {
        input = try FileHandle(forReadingFrom: url)
        guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { throw ArchiveError.corrupt("bzip2 init") }
    }

    deinit {
        BZ2_bzDecompressEnd(&stream)
        try? input.close()
    }

    func read(upTo count: Int) throws -> Data {
        guard !finished, count > 0 else { return Data() }
        var output = Data(count: count)
        var produced = 0
        while produced == 0 && !finished {
            if consumed >= inputBuffer.count {
                inputBuffer = try input.read(upToCount: 256 * 1024) ?? Data()
                consumed = 0
                if inputBuffer.isEmpty { finished = true; break }
            }
            let offset = consumed
            var status: Int32 = BZ_OK
            inputBuffer.withUnsafeMutableBytes { inPtr in
                output.withUnsafeMutableBytes { outPtr in
                    stream.next_in = inPtr.baseAddress!.assumingMemoryBound(to: CChar.self).advanced(by: offset)
                    stream.avail_in = UInt32(inPtr.count - offset)
                    stream.next_out = outPtr.baseAddress!.assumingMemoryBound(to: CChar.self).advanced(by: produced)
                    stream.avail_out = UInt32(count - produced)
                    let inBefore = stream.avail_in, outBefore = stream.avail_out
                    status = BZ2_bzDecompress(&stream)
                    consumed += Int(inBefore - stream.avail_in)
                    produced += Int(outBefore - stream.avail_out)
                    stream.next_in = nil
                    stream.next_out = nil
                }
            }
            switch status {
            case BZ_OK:
                break
            case BZ_STREAM_END:
                // Another stream may follow (pbzip2 and concatenated files): start a fresh decoder
                // on the remaining input, which stays in the buffer.
                streamsEnded += 1
                BZ2_bzDecompressEnd(&stream)
                stream = bz_stream()
                guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { throw ArchiveError.corrupt("bzip2 init") }
            default:
                // Padding after a complete stream is common; it ends the data rather than failing it.
                if streamsEnded > 0 { finished = true } else { throw ArchiveError.corrupt("bzip2 data error") }
            }
        }
        output.count = produced
        return output
    }
}

// MARK: - xz (Apple Compression, LZMA)

final class XZSource: ByteSource {
    private let input: FileHandle
    private var stream: compression_stream
    private var inputBuffer = Data()
    private var consumed = 0
    private var inputEOF = false
    private var finished = false

    init(url: URL) throws {
        input = try FileHandle(forReadingFrom: url)
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        stream = compression_stream(dst_ptr: placeholder, dst_size: 0, src_ptr: placeholder, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw ArchiveError.corrupt("xz init")
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        try? input.close()
    }

    func read(upTo count: Int) throws -> Data {
        guard !finished, count > 0 else { return Data() }
        var output = Data(count: count)
        var produced = 0
        while produced == 0 && !finished {
            if consumed >= inputBuffer.count && !inputEOF {
                inputBuffer = try input.read(upToCount: 256 * 1024) ?? Data()
                consumed = 0
                if inputBuffer.isEmpty { inputEOF = true }
            }
            let status: compression_status = inputBuffer.withUnsafeBytes { inPtr in
                output.withUnsafeMutableBytes { outPtr in
                    let base = inPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    stream.src_ptr = base.map { UnsafePointer($0.advanced(by: consumed)) } ?? UnsafePointer(outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                    stream.src_size = inputBuffer.count - consumed
                    stream.dst_ptr = outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: produced)
                    stream.dst_size = count - produced
                    let before = stream.dst_size
                    let srcBefore = stream.src_size
                    let result = compression_stream_process(&stream, inputEOF ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    produced += before - stream.dst_size
                    consumed += srcBefore - stream.src_size
                    return result
                }
            }
            switch status {
            case COMPRESSION_STATUS_END: finished = true
            case COMPRESSION_STATUS_OK: if inputEOF && produced == 0 { finished = true }
            default: throw ArchiveError.corrupt("xz data error")
            }
        }
        output.count = produced
        return output
    }
}
