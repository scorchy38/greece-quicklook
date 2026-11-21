import Foundation
import Compression
import CArchive

enum DiskImageError: Error, Equatable {
    case notADiskImage
    case corrupt(String)
    case encrypted
    case unsupported(String)
    case tooLarge
    case timedOut
}

/// A wall-clock budget shared by everything that walks an image.
final class DiskDeadline {
    let end: CFAbsoluteTime
    init(seconds: TimeInterval) { end = CFAbsoluteTimeGetCurrent() + seconds }
    var expired: Bool { CFAbsoluteTimeGetCurrent() > end }
    static var unlimited: DiskDeadline { DiskDeadline(seconds: 3600) }
}

/// Random access to the virtual disk inside an image. Reads past the end are short; holes read as zeros.
protocol DiskDevice: AnyObject {
    /// Size of the virtual disk in bytes.
    var size: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
}

extension DiskDevice {
    /// Reads exactly `count` bytes or throws.
    func readExactly(at offset: UInt64, count: Int) throws -> Data {
        let data = try read(at: offset, count: count)
        guard data.count == count else { throw DiskImageError.corrupt("short read") }
        return data
    }
}

/// A window onto another device (a partition).
final class SliceDevice: DiskDevice {
    let base: DiskDevice
    let start: UInt64
    let size: UInt64

    init(_ base: DiskDevice, start: UInt64, length: UInt64) {
        self.base = base
        self.start = min(start, base.size)
        size = min(length, base.size - self.start)
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let length = Int(min(UInt64(count), size - offset))
        return try base.read(at: start + offset, count: length)
    }
}

/// A plain file (or part of one) used as a disk: raw images, ISO files, UDRW.
final class FileDiskDevice: DiskDevice {
    private let data: Data
    private let start: Int
    let size: UInt64

    init(url: URL, start: UInt64 = 0, length: UInt64? = nil) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        self.start = Int(min(start, UInt64(data.count)))
        let available = UInt64(data.count - self.start)
        size = min(length ?? available, available)
    }

    init(data: Data) {
        self.data = data.startIndex == 0 ? data : Data(data)
        start = 0
        size = UInt64(data.count)
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let length = Int(min(UInt64(count), size - offset))
        let from = start + Int(offset)
        return data.subdata(in: from..<(from + length))
    }
}

/// Small LRU cache for decompressed chunks and bands.
final class DiskChunkCache {
    private var storage: [Int: Data] = [:]
    private var order: [Int] = []
    private let capacity: Int
    private var bytes = 0
    private let byteLimit: Int

    init(capacity: Int = 24, byteLimit: Int = 48 << 20) {
        self.capacity = capacity
        self.byteLimit = byteLimit
    }

    func get(_ key: Int) -> Data? {
        guard let value = storage[key] else { return nil }
        if let index = order.firstIndex(of: key) { order.remove(at: index); order.append(key) }
        return value
    }

    func put(_ key: Int, _ value: Data) {
        if storage[key] != nil { return }
        storage[key] = value
        order.append(key)
        bytes += value.count
        while (order.count > capacity || bytes > byteLimit), order.count > 1 {
            let evicted = order.removeFirst()
            bytes -= storage.removeValue(forKey: evicted)?.count ?? 0
        }
    }
}

// MARK: - Decompression

enum DiskDecompress {
    /// zlib-wrapped deflate (UDZO chunks, HFS+ compression).
    static func zlib(_ input: Data, expected: Int) throws -> Data {
        try inflateData(input, expected: expected, windowBits: 15)
    }

    /// Raw deflate without a header.
    static func deflate(_ input: Data, expected: Int) throws -> Data {
        try inflateData(input, expected: expected, windowBits: -15)
    }

    private static func inflateData(_ input: Data, expected: Int, windowBits: Int32) throws -> Data {
        guard expected >= 0, expected <= 256 << 20 else { throw DiskImageError.tooLarge }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DiskImageError.corrupt("zlib")
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: expected)
        var produced = 0
        let status: Int32 = input.withUnsafeBytes { (inBuffer: UnsafeRawBufferPointer) -> Int32 in
            output.withUnsafeMutableBytes { (outBuffer: UnsafeMutableRawBufferPointer) -> Int32 in
                guard let inBase = inBuffer.baseAddress, let outBase = outBuffer.baseAddress else { return Z_DATA_ERROR }
                stream.next_in = UnsafeMutablePointer(mutating: inBase.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBase.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(outBuffer.count)
                let result = inflate(&stream, Z_FINISH)
                produced = outBuffer.count - Int(stream.avail_out)
                return result
            }
        }
        guard status == Z_STREAM_END || status == Z_OK || (status == Z_BUF_ERROR && produced > 0) else {
            throw DiskImageError.corrupt("zlib data")
        }
        output.count = produced
        return output
    }

    static func bzip2(_ input: Data, expected: Int) throws -> Data {
        guard expected >= 0, expected <= 256 << 20 else { throw DiskImageError.tooLarge }
        var output = Data(count: expected)
        var length = UInt32(expected)
        let status: Int32 = input.withUnsafeBytes { inBuffer in
            output.withUnsafeMutableBytes { outBuffer in
                guard let inBase = inBuffer.baseAddress, let outBase = outBuffer.baseAddress else { return BZ_DATA_ERROR }
                return BZ2_bzBuffToBuffDecompress(outBase.assumingMemoryBound(to: CChar.self), &length,
                                                  UnsafeMutablePointer(mutating: inBase.assumingMemoryBound(to: CChar.self)),
                                                  UInt32(inBuffer.count), 0, 0)
            }
        }
        guard status == BZ_OK else { throw DiskImageError.corrupt("bzip2") }
        output.count = Int(length)
        return output
    }

    /// LZFSE, LZVN (inside LZFSE framing) and LZMA (xz) through Apple's Compression.
    static func apple(_ input: Data, expected: Int, algorithm: compression_algorithm) throws -> Data {
        guard expected >= 0, expected <= 256 << 20 else { throw DiskImageError.tooLarge }
        if expected == 0 { return Data() }
        var output = Data(count: expected)
        let produced: Int = input.withUnsafeBytes { inBuffer in
            output.withUnsafeMutableBytes { outBuffer in
                guard let inBase = inBuffer.baseAddress, let outBase = outBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(outBase.assumingMemoryBound(to: UInt8.self), outBuffer.count,
                                                 inBase.assumingMemoryBound(to: UInt8.self), inBuffer.count, nil, algorithm)
            }
        }
        guard produced > 0 else { throw DiskImageError.corrupt("compressed data") }
        output.count = produced
        return output
    }

    static func lzfse(_ input: Data, expected: Int) throws -> Data {
        try apple(input, expected: expected, algorithm: COMPRESSION_LZFSE)
    }

    /// Raw LZVN, wrapped in the LZFSE block framing ("bvxn" … "bvx$") that Compression understands.
    static func lzvn(_ input: Data, expected: Int) throws -> Data {
        var framed = Data("bvxn".utf8)
        var raw = UInt32(clamping: expected).littleEndian
        var payload = UInt32(clamping: input.count).littleEndian
        framed.append(Data(bytes: &raw, count: 4))
        framed.append(Data(bytes: &payload, count: 4))
        framed.append(input)
        framed.append(Data("bvx$".utf8))
        return try lzfse(framed, expected: expected)
    }

    static func lzma(_ input: Data, expected: Int) throws -> Data {
        try apple(input, expected: expected, algorithm: COMPRESSION_LZMA)
    }

    /// Apple Data Compression (UDCO), a small LZ77 variant.
    static func adc(_ input: Data, expected: Int) throws -> Data {
        guard expected >= 0, expected <= 256 << 20 else { throw DiskImageError.tooLarge }
        let bytes = [UInt8](input)
        var output = [UInt8]()
        output.reserveCapacity(expected)
        var index = 0
        while index < bytes.count && output.count < expected {
            let byte = bytes[index]
            if byte & 0x80 != 0 {
                // Literal run of 1...128 bytes.
                let length = Int(byte & 0x7F) + 1
                guard index + 1 + length <= bytes.count else { throw DiskImageError.corrupt("adc") }
                output.append(contentsOf: bytes[(index + 1)..<(index + 1 + length)])
                index += 1 + length
            } else {
                var length: Int
                var distance: Int
                if byte & 0x40 != 0 {
                    guard index + 2 < bytes.count else { throw DiskImageError.corrupt("adc") }
                    length = Int(byte & 0x3F) + 4
                    distance = Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
                    index += 3
                } else {
                    guard index + 1 < bytes.count else { throw DiskImageError.corrupt("adc") }
                    length = Int((byte >> 2) & 0x0F) + 3
                    distance = Int(byte & 0x03) << 8 | Int(bytes[index + 1])
                    index += 2
                }
                let start = output.count - distance - 1
                guard start >= 0 else { throw DiskImageError.corrupt("adc") }
                length = min(length, expected - output.count)
                for offset in 0..<length { output.append(output[start + offset]) }
            }
        }
        return Data(output)
    }
}
