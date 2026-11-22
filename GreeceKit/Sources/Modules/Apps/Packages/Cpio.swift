import Foundation

/// Reads cpio archives as installer packages use them (Scripts and Payload): the portable
/// "odc" format (070707, octal fields) and "newc" (070701/070702, hex fields, 4-byte aligned).
enum Cpio {
    struct Entry {
        var path: String
        var mode: UInt32
        var size: UInt64
        var modified: Date?
        /// The bytes, when kept (only for members under the caller's size limit).
        var contents: Data?

        var isDirectory: Bool { mode & 0o170000 == 0o040000 }
        var isSymlink: Bool { mode & 0o170000 == 0o120000 }
        var isFile: Bool { mode & 0o170000 == 0o100000 || mode & 0o170000 == 0 }
    }

    struct Listing {
        var entries: [Entry]
        var truncated: Bool
    }

    static func isCpio(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(6), as: UTF8.self)
        return head == "070707" || head == "070701" || head == "070702"
    }

    /// Lists the archive, keeping the contents of members no larger than `keepContentsUpTo`.
    static func read(_ data: Data, limit: Int = 200_000, keepContentsUpTo keep: Int = 0) -> Listing {
        let bytes = BinaryReader(data)
        var entries: [Entry] = []
        var position = 0
        var truncated = false

        func field(_ start: Int, _ length: Int, radix: Int) -> UInt64? {
            guard let raw = bytes.bytes(at: start, count: length) else { return nil }
            return UInt64(String(decoding: raw, as: UTF8.self), radix: radix)
        }

        while position < data.count {
            if entries.count >= limit { truncated = true; break }
            guard let magicBytes = bytes.bytes(at: position, count: 6) else { break }
            let magic = String(decoding: magicBytes, as: UTF8.self)
            let nameLength: Int, size: UInt64, mode: UInt32, mtime: UInt64
            let headerLength: Int, aligned: Bool
            if magic == "070707" {
                guard let m = field(position + 18, 6, radix: 8), let t = field(position + 48, 11, radix: 8),
                      let n = field(position + 59, 6, radix: 8), let s = field(position + 65, 11, radix: 8) else { break }
                mode = UInt32(truncatingIfNeeded: m); mtime = t; nameLength = Int(min(n, 1 << 16)); size = s
                headerLength = 76; aligned = false
            } else if magic == "070701" || magic == "070702" {
                guard let m = field(position + 14, 8, radix: 16), let t = field(position + 46, 8, radix: 16),
                      let s = field(position + 54, 8, radix: 16), let n = field(position + 94, 8, radix: 16) else { break }
                mode = UInt32(truncatingIfNeeded: m); mtime = t; nameLength = Int(min(n, 1 << 16)); size = s
                headerLength = 110; aligned = true
            } else {
                break
            }
            let nameStart = position + headerLength
            guard nameLength > 0, let nameBytes = bytes.bytes(at: nameStart, count: nameLength) else { break }
            var name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            if name == "TRAILER!!!" { break }
            var dataStart = nameStart + nameLength
            if aligned { dataStart = (dataStart + 3) & ~3 }
            guard let length = Int(exactly: size), bytes.has(length, at: dataStart) else {
                // A size that runs past the end: list the member without its contents, then stop.
                while name.hasPrefix("./") { name.removeFirst(2) }
                if !name.isEmpty && name != "." { entries.append(Entry(path: name, mode: mode, size: size, modified: nil)) }
                truncated = true
                break
            }
            while name.hasPrefix("./") { name.removeFirst(2) }
            if !name.isEmpty && name != "." {
                let kept = length <= keep ? data.subdata(in: dataStart..<(dataStart + length)) : nil
                let modified = mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil
                entries.append(Entry(path: name, mode: mode, size: size, modified: modified, contents: kept))
            }
            position = dataStart + length
            if aligned { position = (position + 3) & ~3 }
        }
        return Listing(entries: entries, truncated: truncated)
    }
}
