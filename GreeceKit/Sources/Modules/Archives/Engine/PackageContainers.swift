import Foundation

/// An RPM's lead and headers: package facts and the full file list, without touching the payload.
struct RPMHeader {
    enum Value {
        case ints([Int64])
        case strings([String])
    }

    private(set) var values: [Int: Value] = [:]
    /// Where the compressed cpio payload starts.
    let payloadOffset: UInt64
    let isSource: Bool

    static let wanted: Set<Int> = [1000, 1001, 1002, 1003, 1004, 1005, 1006, 1009, 1011, 1014, 1015, 1016, 1020, 1021, 1022,
                                   1027, 1028, 1030, 1034, 1036, 1049, 1050, 1116, 1117, 1118, 1124, 1125, 5008, 5009]

    init(_ file: RandomAccessFile) throws {
        let lead = file.read(at: 0, count: 96)
        guard lead.count == 96, lead.starts(with: [0xED, 0xAB, 0xEE, 0xDB]) else {
            throw ArchiveError.corrupt(String(localized: "not an RPM", bundle: .greeceKit,
                                              comment: "Why an RPM package is damaged, shown inside “This archive appears to be damaged (…)”"))
        }
        isSource = lead.u16be(6) == 1
        let signature = try RPMHeader.section(file, at: 96)
        var main = signature.end
        if main % 8 != 0 { main += 8 - main % 8 }            // the signature header is padded to 8 bytes
        let header = try RPMHeader.section(file, at: main)
        payloadOffset = header.end
        for (tag, type, offset, count) in header.index where RPMHeader.wanted.contains(tag) {
            if let value = RPMHeader.decode(type: type, offset: offset, count: count, store: header.store) { values[tag] = value }
        }
    }

    private static func section(_ file: RandomAccessFile, at offset: UInt64) throws -> (index: [(Int, Int, Int, Int)], store: Data, end: UInt64) {
        let intro = file.read(at: offset, count: 16)
        guard intro.count == 16, intro.starts(with: [0x8E, 0xAD, 0xE8]) else {
            throw ArchiveError.corrupt(String(localized: "RPM header missing", bundle: .greeceKit,
                                              comment: "Why an RPM package is damaged, shown inside “This archive appears to be damaged (…)”"))
        }
        let count = Int(intro.u32be(8)), size = Int(intro.u32be(12))
        guard count <= 100_000, size <= 64 * 1024 * 1024 else {
            throw ArchiveError.corrupt(String(localized: "RPM header too large", bundle: .greeceKit,
                                              comment: "Why an RPM package is damaged, shown inside “This archive appears to be damaged (…)”"))
        }
        let indexData = file.read(at: offset + 16, count: count * 16)
        let store = file.read(at: offset + 16 + UInt64(count * 16), count: size)
        guard indexData.count == count * 16, store.count == size else {
            throw ArchiveError.corrupt(String(localized: "RPM header truncated", bundle: .greeceKit,
                                              comment: "Why an RPM package is damaged, shown inside “This archive appears to be damaged (…)”"))
        }
        var index: [(Int, Int, Int, Int)] = []
        index.reserveCapacity(count)
        for i in 0..<count {
            let base = i * 16
            index.append((Int(indexData.u32be(base)), Int(indexData.u32be(base + 4)), Int(indexData.u32be(base + 8)), Int(indexData.u32be(base + 12))))
        }
        return (index, store, offset + 16 + UInt64(count * 16) + UInt64(size))
    }

    private static func decode(type: Int, offset: Int, count: Int, store: Data) -> Value? {
        guard offset >= 0, offset < store.count, count >= 0, count <= 2_000_000 else { return nil }
        switch type {
        case 3, 4, 5:                                       // INT16, INT32, INT64 (big-endian)
            let width = type == 3 ? 2 : type == 4 ? 4 : 8
            guard offset + count * width <= store.count else { return nil }
            return .ints((0..<count).map { i in
                let at = offset + i * width
                switch width {
                case 2: return Int64(store.u16be(at))
                case 4: return Int64(Int32(bitPattern: store.u32be(at)))
                default: return Int64(bitPattern: UInt64(store.u32be(at)) << 32 | UInt64(store.u32be(at + 4)))
                }
            })
        case 6, 8, 9:                                       // STRING, STRING_ARRAY, I18NSTRING
            var strings: [String] = []
            var cursor = offset
            let wanted = type == 6 ? 1 : count
            while strings.count < wanted, cursor < store.count {
                let end = store[(store.startIndex + cursor)...].firstIndex(of: 0) ?? store.endIndex
                strings.append(String(decoding: store[(store.startIndex + cursor)..<end], as: UTF8.self))
                cursor = end - store.startIndex + 1
            }
            return .strings(strings)
        default:
            return nil
        }
    }

    func string(_ tag: Int) -> String? {
        if case .strings(let strings) = values[tag], let first = strings.first, !first.isEmpty { return first }
        return nil
    }
    func strings(_ tag: Int) -> [String] { if case .strings(let s) = values[tag] { return s }; return [] }
    func ints(_ tag: Int) -> [Int64] { if case .ints(let i) = values[tag] { return i }; return [] }

    var name: String? { string(1000) }
    var version: String? { string(1001) }
    var release: String? { string(1002) }
    var payloadCompressor: String { string(1125) ?? "gzip" }

    /// The file list, straight from the header (the payload is only decompressed to preview a file).
    func entries() -> [ArchiveEntry] {
        var paths: [String]
        let basenames = strings(1117)
        if !basenames.isEmpty {
            let directories = strings(1118)
            let indexes = ints(1116)
            paths = basenames.enumerated().map { i, base in
                let directory = i < indexes.count && Int(indexes[i]) >= 0 && Int(indexes[i]) < directories.count ? directories[Int(indexes[i])] : ""
                return directory + base
            }
        } else {
            paths = strings(1027)
        }
        let sizes = ints(5008).isEmpty ? ints(1028) : ints(5008)
        let modes = ints(1030), times = ints(1034), links = strings(1036)
        var result: [ArchiveEntry] = []
        for (i, path) in paths.prefix(ArchiveReader.entryLimit).enumerated() {
            let mode = i < modes.count ? UInt16(truncatingIfNeeded: modes[i]) : 0o100644
            let type = mode & 0o170000
            var entry = ArchiveEntry(path: path, isDirectory: type == 0o040000, isSymlink: type == 0o120000,
                                     size: type == 0o040000 ? 0 : UInt64(max(i < sizes.count ? sizes[i] : 0, 0)),
                                     modified: i < times.count ? Date(timeIntervalSince1970: TimeInterval(times[i])) : nil)
            entry.index = i
            entry.permissions = mode & 0o7777
            if entry.isSymlink, i < links.count, !links[i].isEmpty { entry.linkTarget = links[i] }
            result.append(entry)
        }
        return result
    }
}

/// Members of a Unix `ar` archive (the outer layer of a .deb).
enum ARArchive {
    struct Member { let name: String; let offset: UInt64; let size: UInt64 }

    static func members(_ file: RandomAccessFile, limit: Int = 64) -> [Member] {
        guard file.read(at: 0, count: 8) == Data("!<arch>\n".utf8) else { return [] }
        var members: [Member] = []
        var offset: UInt64 = 8
        while members.count < limit, offset + 60 <= file.size {
            let header = file.read(at: offset, count: 60)
            guard header.count == 60, header[58] == 0x60, header[59] == 0x0A else { break }
            var name = String(decoding: header[0..<16], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if name.hasSuffix("/") { name.removeLast() }
            let size = UInt64(String(decoding: header[48..<58], as: UTF8.self).trimmingCharacters(in: .whitespaces)) ?? 0
            let data = offset + 60
            guard data.saturatingAdd(size) <= file.size else { break }
            members.append(Member(name: name, offset: data, size: size))
            offset = data + size + (size % 2)
        }
        return members
    }
}

extension Data {
    func u16be(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian }
    }
    func u32be(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }
}
