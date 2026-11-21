import Foundation

/// Lists a tar stream (ustar, GNU and PAX) without extracting anything.
final class TarReader {
    private let reader: BufferedReader

    init(source: ByteSource) throws { reader = BufferedReader(source) }
    init(reader: BufferedReader) { self.reader = reader }

    static func isValidHeader(_ block: ArraySlice<UInt8>) -> Bool {
        guard block.count >= 512 else { return false }
        let base = block.startIndex
        if block.allSatisfy({ $0 == 0 }) { return false }
        let stored = parseNumber(block[(base + 148)..<(base + 156)])
        var unsigned = 0
        for (offset, byte) in block.enumerated() {
            unsigned += (offset >= 148 && offset < 156) ? 32 : Int(byte)
        }
        return stored == UInt64(unsigned)
    }

    static func isValidHeader(_ block: Data) -> Bool { isValidHeader([UInt8](block)[...]) }

    func listing() throws -> ArchiveListing {
        var entries: [ArchiveEntry] = []
        var pendingName: String?
        var pax: [String: String] = [:]
        var truncated = false

        while let header = try reader.readExactly(512) {
            let block = [UInt8](header)
            if block.allSatisfy({ $0 == 0 }) { break }
            guard TarReader.isValidHeader(block[...]) else {
                if entries.isEmpty { throw ArchiveError.corrupt("invalid tar header") }
                break
            }

            let type = block[156]
            var size = TarReader.parseNumber(block[124..<136])
            guard let padded = TarReader.padded(size) else { truncated = true; break }

            switch type {
            case UInt8(ascii: "L"), UInt8(ascii: "K"), UInt8(ascii: "x"):
                // GNU long names and PAX records are small; never pull a huge declared body into memory.
                guard size <= TarReader.maxHeaderBody else {
                    try reader.skip(padded)
                    continue
                }
                let data = try reader.readExactly(Int(size)) ?? Data()
                try reader.skip(padded - size)
                if type == UInt8(ascii: "L") { pendingName = TarReader.string(data) }
                if type == UInt8(ascii: "x") { pax = TarReader.parsePAX(data) }
                continue
            case UInt8(ascii: "g"):                      // global PAX header
                try reader.skip(padded)
                continue
            default:
                break
            }

            var name = TarReader.string(block[0..<100])
            let isUstar = Array(block[257..<263]) == Array("ustar\0".utf8)
            if isUstar {
                let prefix = TarReader.string(block[345..<500])
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            if let long = pendingName { name = long }
            if let path = pax["path"] { name = path }
            if let paxSize = pax["size"].flatMap(UInt64.init) { size = paxSize }
            var modified = Date(timeIntervalSince1970: TimeInterval(TarReader.parseNumber(block[136..<148])))
            if let mtime = pax["mtime"].flatMap(Double.init) { modified = Date(timeIntervalSince1970: mtime) }
            pendingName = nil
            pax = [:]

            if name.hasPrefix("./") { name.removeFirst(2) }
            let isDirectory = type == UInt8(ascii: "5") || name.hasSuffix("/")
            if !name.isEmpty && name != "." && type != UInt8(ascii: "V") {
                entries.append(ArchiveEntry(
                    path: name,
                    isDirectory: isDirectory,
                    isSymlink: type == UInt8(ascii: "2"),
                    size: isDirectory ? 0 : size,
                    compressedSize: nil,
                    modified: modified))
            }

            // Only regular files carry data (hard links, symlinks and directories have none).
            let carriesData = !(type == UInt8(ascii: "1") || type == UInt8(ascii: "2") || type == UInt8(ascii: "5"))
            if carriesData {
                guard let skip = TarReader.padded(size) else { truncated = true; break }
                try reader.skip(skip)
            }

            if entries.count >= ArchiveReader.entryLimit { truncated = true; break }
        }

        return ArchiveListing(format: .tar, container: .tar, entries: entries, archiveSize: 0, truncated: truncated)
    }

    // MARK: - Field parsing

    static let maxHeaderBody: UInt64 = 1 << 20

    /// Size rounded up to whole 512-byte blocks, or nil when a corrupt header would overflow.
    static func padded(_ size: UInt64) -> UInt64? {
        guard size <= UInt64.max - 511 else { return nil }
        return (size + 511) / 512 * 512
    }

    static func parseNumber(_ field: ArraySlice<UInt8>) -> UInt64 {
        guard let first = field.first else { return 0 }
        if first & 0x80 != 0 {
            // GNU base-256 for values that do not fit in octal.
            var value: UInt64 = UInt64(first & 0x7F)
            for byte in field.dropFirst() { value = (value << 8) | UInt64(byte) }
            return value
        }
        var value: UInt64 = 0
        for byte in field {
            if byte == 0 || byte == 0x20 { if value > 0 { break } else { continue } }
            guard byte >= 0x30 && byte <= 0x37 else { break }
            value = value * 8 + UInt64(byte - 0x30)
        }
        return value
    }

    private static func string<S: Collection>(_ bytes: S) -> String where S.Element == UInt8 {
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private static func string(_ data: Data) -> String { string([UInt8](data)) }

    static func parsePAX(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            guard let space = bytes[index...].firstIndex(of: 0x20),
                  let length = Int(String(decoding: bytes[index..<space], as: UTF8.self)),
                  length >= space - index + 2, length <= bytes.count - index else { break }
            let record = bytes[(space + 1)..<(index + length - 1)]
            if let equals = record.firstIndex(of: UInt8(ascii: "=")) {
                let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
                let value = String(decoding: record[(equals + 1)...], as: UTF8.self)
                result[key] = value
            }
            index += length
        }
        return result
    }
}
