import Foundation
import Compression

/// One item on a volume inside an image.
struct VolumeEntry {
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool
    var size: UInt64
    var modified: Date?
}

/// A file system read straight from an image's sectors, without mounting it.
protocol DiskFileSystem: AnyObject {
    var kind: FileSystemKind { get }
    var volumeName: String { get }
    /// Bytes in use and the volume's capacity, when the file system records them.
    var usedBytes: UInt64? { get }
    var capacity: UInt64? { get }
    /// Every file and folder (paths relative to the volume root), within the limits.
    func entries(limit: Int, deadline: DiskDeadline) throws -> (entries: [VolumeEntry], truncated: Bool)
    /// A file's contents (decompressed), refusing anything larger than `limit`.
    func readFile(_ path: String, limit: Int) throws -> Data
    /// A symbolic link's target.
    func linkTarget(_ path: String) throws -> String?
}

enum DiskFileSystems {
    /// Opens the file system on a partition, if Greece can read it.
    static func open(_ device: DiskDevice, kind: FileSystemKind) throws -> DiskFileSystem? {
        switch kind {
        case .hfsPlus, .hfsX: return try HFSPlusVolume(device: device)
        case .apfs: return try APFSContainer(device: device).firstVolume()
        case .iso9660: return try ISO9660Volume(device: device)
        default: return nil
        }
    }

    /// Splits "a/b/c" into components, rejecting empty and parent references.
    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    }
}

/// HFS+ and APFS transparent compression ("com.apple.decmpfs").
enum Decmpfs {
    struct Header {
        var type: UInt32
        var size: UInt64
    }

    static func header(_ xattr: Data) -> Header? {
        let r = BinaryReader(xattr)
        guard xattr.count >= 16, r.u32(at: 0) == 0x636D_7066 /* "fpmc" */, let type = r.u32(at: 4), let size = r.u64(at: 8) else { return nil }
        return Header(type: type, size: size)
    }

    /// Whether the compressed bytes live in the resource fork rather than inside the attribute.
    static func usesResourceFork(_ type: UInt32) -> Bool { [4, 8, 10, 12, 14].contains(type) }

    /// Decompresses a file given its decmpfs attribute and (for resource-fork types) the resource fork.
    static func decompress(xattr: Data, resourceFork: () throws -> Data?, limit: Int) throws -> Data {
        guard let header = header(xattr) else { throw DiskImageError.corrupt("decmpfs header") }
        guard header.size <= UInt64(limit) else { throw DiskImageError.tooLarge }
        let size = Int(header.size)
        let inline = xattr.subdata(in: (xattr.startIndex + 16)..<xattr.endIndex)
        switch header.type {
        case 1:
            return inline.prefix(size)
        case 9:
            // LZBITMAP; a 0xCC first byte means stored uncompressed.
            if inline.first == 0xCC { return inline.dropFirst().prefix(size) }
            return try DiskDecompress.apple(inline, expected: size, algorithm: COMPRESSION_LZBITMAP)
        case 3:
            // A first byte with low nibble 0xF means the rest is stored uncompressed.
            if let first = inline.first, first & 0x0F == 0x0F { return inline.dropFirst().prefix(size) }
            return try DiskDecompress.zlib(inline, expected: size)
        case 7:
            if inline.first == 0x06 { return inline.dropFirst().prefix(size) }
            return try DiskDecompress.lzvn(inline, expected: size)
        case 11:
            if inline.first == 0xFF { return inline.dropFirst().prefix(size) }
            return try DiskDecompress.lzfse(inline, expected: size)
        case 4:
            guard let fork = try resourceFork() else { throw DiskImageError.corrupt("missing resource fork") }
            return try zlibResourceFork(fork, size: size)
        case 8, 10, 12:
            guard let fork = try resourceFork() else { throw DiskImageError.corrupt("missing resource fork") }
            return try blockTableFork(fork, size: size, type: header.type)
        default:
            throw DiskImageError.unsupported("compression type \(header.type)")
        }
    }

    /// Type 4: a classic resource fork whose single resource holds a table of 64 KB zlib blocks.
    private static func zlibResourceFork(_ fork: Data, size: Int) throws -> Data {
        let big = BinaryReader(fork, bigEndian: true)
        let little = BinaryReader(fork)
        guard let dataOffset = big.u32(at: 0).map(Int.init), let blocks = little.u32(at: dataOffset + 4).map(Int.init),
              blocks <= (size / 65_536) + 2 else { throw DiskImageError.corrupt("zlib resource fork") }
        let base = dataOffset + 4
        var output = Data()
        output.reserveCapacity(size)
        for index in 0..<blocks {
            guard let offset = little.u32(at: dataOffset + 8 + index * 8).map(Int.init),
                  let length = little.u32(at: dataOffset + 12 + index * 8).map(Int.init),
                  let block = little.bytes(at: base + offset, count: length) else { throw DiskImageError.corrupt("zlib block") }
            let expected = min(65_536, size - output.count)
            if block.first.map({ $0 & 0x0F == 0x0F }) == true {
                output.append(block.dropFirst().prefix(expected))
            } else {
                output.append(try DiskDecompress.zlib(block, expected: expected))
            }
            if output.count >= size { break }
        }
        return output.prefix(size)
    }

    /// Types 8, 10 and 12: a little-endian table of block offsets, then LZVN, LZBITMAP or LZFSE blocks of 64 KB.
    private static func blockTableFork(_ fork: Data, size: Int, type: UInt32) throws -> Data {
        let r = BinaryReader(fork)
        guard let tableSize = r.u32(at: 0).map(Int.init), tableSize >= 8, tableSize % 4 == 0,
              tableSize / 4 - 1 <= (size / 65_536) + 2 else { throw DiskImageError.corrupt("block table") }
        let blocks = tableSize / 4 - 1
        var output = Data()
        output.reserveCapacity(size)
        for index in 0..<blocks {
            guard let start = r.u32(at: index * 4).map(Int.init), let end = r.u32(at: index * 4 + 4).map(Int.init), end >= start,
                  let block = r.bytes(at: start, count: end - start) else { throw DiskImageError.corrupt("block") }
            let expected = min(65_536, size - output.count)
            let rawMarker: UInt8 = type == 8 ? 0x06 : (type == 10 ? 0xCC : 0xFF)
            if block.first == rawMarker {
                output.append(block.dropFirst().prefix(expected))
            } else {
                switch type {
                case 8: output.append(try DiskDecompress.lzvn(block, expected: expected))
                case 10: output.append(try DiskDecompress.apple(block, expected: expected, algorithm: COMPRESSION_LZBITMAP))
                default: output.append(try DiskDecompress.lzfse(block, expected: expected))
                }
            }
            if output.count >= size { break }
        }
        return output.prefix(size)
    }
}
