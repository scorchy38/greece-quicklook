import Foundation

/// A forward-only stream of bytes. `read` returns an empty Data at the end.
protocol ByteSource: AnyObject {
    func read(upTo count: Int) throws -> Data
}

/// Bytes at any offset: a file on disk or bytes already in memory. Reads never trap: past the
/// end they come back short or empty.
protocol RandomAccessSource: AnyObject {
    var size: UInt64 { get }
    /// Up to `count` bytes from `offset`; shorter only at the end.
    func read(at offset: UInt64, count: Int) -> Data
    /// The offset where volume `index` begins, for archives split across several files.
    func start(ofVolume index: Int) -> UInt64?
}

/// Bytes already in memory (often a mapped file) behind the `RandomAccessSource` interface.
/// Reads return slices that share the storage, so nothing is copied until it is used.
final class InMemoryFile: RandomAccessSource, @unchecked Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }

    var size: UInt64 { UInt64(data.count) }

    func read(at offset: UInt64, count: Int) -> Data {
        guard count > 0, offset < size else { return Data() }
        let start = data.startIndex + Int(offset)
        return data[start..<(start + Int(min(UInt64(count), size - offset)))]
    }

    func start(ofVolume index: Int) -> UInt64? { index == 0 ? 0 : nil }
}

/// Bytes at any offset of one file, or of several volumes read back to back as one.
/// Reads use `pread`, so several threads can share one instance.
final class RandomAccessFile: RandomAccessSource, @unchecked Sendable {
    struct Part { let url: URL; let start: UInt64; let size: UInt64; let descriptor: Int32 }
    let parts: [Part]
    let size: UInt64

    init(_ urls: [URL]) throws {
        var parts: [Part] = []
        var start: UInt64 = 0
        for url in urls {
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                parts.forEach { close($0.descriptor) }
                throw ArchiveError.unsupported("“\(url.lastPathComponent)” can’t be opened.")
            }
            var info = stat()
            let size = fstat(descriptor, &info) == 0 ? UInt64(max(info.st_size, 0)) : 0
            parts.append(Part(url: url, start: start, size: size, descriptor: descriptor))
            start = start.saturatingAdd(size)
        }
        self.parts = parts
        size = start
    }

    convenience init(_ url: URL) throws { try self.init([url]) }

    deinit { parts.forEach { close($0.descriptor) } }

    /// The offset where volume `index` begins in the combined stream.
    func start(ofVolume index: Int) -> UInt64? { index >= 0 && index < parts.count ? parts[index].start : nil }

    /// Up to `count` bytes from `offset`; shorter only at the end.
    func read(at offset: UInt64, count: Int) -> Data {
        guard count > 0, offset < size else { return Data() }
        let wanted = Int(min(UInt64(count), size - offset))
        // Read straight into fresh memory: zero-filling it first would touch every byte twice.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: wanted, alignment: 16)
        var filled = 0
        var position = offset
        while filled < wanted {
            guard let part = parts.last(where: { $0.start <= position }), position < part.start + part.size else { break }
            let local = position - part.start
            let chunk = Int(min(UInt64(wanted - filled), part.size - local))
            let got = pread(part.descriptor, buffer + filled, chunk, off_t(local))
            if got <= 0 { break }
            filled += got
            position += UInt64(got)
        }
        guard filled > 0 else { buffer.deallocate(); return Data() }
        return Data(bytesNoCopy: buffer, count: filled, deallocator: .custom { pointer, _ in pointer.deallocate() })
    }
}

/// A window of a file (a member of a .deb or a ZIP, an RPM's payload), read forwards.
final class RangeSource: ByteSource {
    private let file: any RandomAccessSource
    private let end: UInt64
    private(set) var position: UInt64

    init(_ file: any RandomAccessSource, offset: UInt64 = 0, length: UInt64? = nil) {
        self.file = file
        position = min(offset, file.size)
        end = min(file.size, length.map { offset.saturatingAdd($0) } ?? file.size)
    }

    var remaining: UInt64 { end > position ? end - position : 0 }

    func read(upTo count: Int) throws -> Data {
        let chunk = Int(min(UInt64(max(count, 0)), remaining))
        guard chunk > 0 else { return Data() }
        let data = file.read(at: position, count: chunk)
        position += UInt64(data.count)
        return data
    }

    func seek(to offset: UInt64) { position = min(offset, end) }
    var startOffset: UInt64 { end - remaining }
}

/// Facts from a gzip header and trailer, read without decompressing.
enum GzipHeader {
    /// The original file name stored in the gzip header (FNAME), if present.
    static func originalName(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 1024) else { return nil }
        try? handle.close()
        let bytes = [UInt8](data)
        guard bytes.count > 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[3] & 0x08 != 0 else { return nil }
        var index = 10
        if bytes[3] & 0x04 != 0, bytes.count > 12 { index += 2 + (Int(bytes[10]) | Int(bytes[11]) << 8) }
        guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0) else { return nil }
        let name = String(decoding: bytes[index..<end], as: UTF8.self)
        let last = (name as NSString).lastPathComponent
        return last.isEmpty || last == "." || last == ".." ? nil : last
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

/// A cooperative cancel flag shared between the main thread and a worker.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
