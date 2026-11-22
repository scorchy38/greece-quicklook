import Foundation

/// dBase III/IV/V/7, FoxPro and Visual FoxPro tables, with memo fields from .dbt and .fpt files.
struct DBFTable {
    struct Field {
        let name: String
        let type: Character
        let length: Int
        let decimals: Int
        let offset: Int
        let flags: UInt8
        /// Hidden system columns (Visual FoxPro's _NullFlags).
        var isSystem: Bool { flags & 0x01 != 0 }
        var isNullable: Bool { flags & 0x02 != 0 }

        var typeName: String {
            switch type {
            case "C": return "Character(\(length))"
            case "N": return decimals > 0 ? "Numeric(\(length),\(decimals))" : "Numeric(\(length))"
            case "F": return "Float(\(length),\(decimals))"
            case "D": return "Date"
            case "L": return "Logical"
            case "M": return "Memo"
            case "I": return "Integer"
            case "Y": return "Currency"
            case "T", "@": return "DateTime"
            case "B": return "Double / Binary"
            case "O": return "Double"
            case "+": return "Autoincrement"
            case "G": return "General (OLE)"
            case "P": return "Picture"
            case "V": return "Varchar(\(length))"
            case "Q": return "Varbinary(\(length))"
            case "W": return "Blob"
            default: return String(type)
            }
        }
    }

    var version: UInt8
    var versionName: String
    var updated: Date?
    var recordCount: Int
    var fields: [Field]
    var rows: [[GridValue]] = []
    var deleted = Set<Int>()
    var encodingName: String
    var memoFile: String?
    var truncated = false

    static let maxRecords = 200_000
    static let maxFields = 1_000

    // MARK: - Detection

    static func sniff(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 32 else { return false }
        let known: Set<UInt8> = [0x02, 0x03, 0x04, 0x05, 0x07, 0x30, 0x31, 0x32, 0x43, 0x63, 0x83, 0x87, 0x8B, 0x8C, 0x8E, 0xCB, 0xE5, 0xF5, 0xFB]
        guard known.contains(bytes[0]) else { return false }
        let month = bytes[2], day = bytes[3]
        guard month <= 12, day <= 31 else { return false }
        let header = Int(bytes[8]) | Int(bytes[9]) << 8
        let record = Int(bytes[10]) | Int(bytes[11]) << 8
        return header >= 33 && record >= 1
    }

    // MARK: - Reading

    enum Failure: Error { case malformed }

    static func load(_ url: URL, maxRecords: Int = DBFTable.maxRecords) throws -> DBFTable {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let memo = MemoFile.open(beside: url)
        let cpg = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("cpg"), encoding: .ascii)
        return try parse(data, memo: memo, codePageHint: cpg, maxRecords: maxRecords)
    }

    static func parse(_ data: Data, memo: MemoFile? = nil, codePageHint: String? = nil, maxRecords: Int = DBFTable.maxRecords) throws -> DBFTable {
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard sniff(bytes) else { throw Failure.malformed }
        let version = bytes[0]
        let year = Int(bytes[1])
        let updated = DateComponents(calendar: Calendar(identifier: .gregorian), year: year < 80 ? 2000 + year : 1900 + year, month: max(1, Int(bytes[2])), day: max(1, Int(bytes[3]))).date
        let records = Int(UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24)
        let headerLength = Int(bytes[8]) | Int(bytes[9]) << 8
        let recordLength = Int(bytes[10]) | Int(bytes[11]) << 8
        let isVisualFoxPro = [0x30, 0x31, 0x32].contains(version)
        let isLevel7 = version & 0x07 == 0x04 && headerLength >= 68 && (headerLength - 68 - 1) % 48 == 0 && bytes.count > 68 && bytes[68] != 0x0D

        // Field descriptors: 32 bytes each from offset 32 (48 bytes from 68 in dBase 7), ending at 0x0D.
        var fields: [Field] = []
        var offset = 1
        var position = isLevel7 ? 68 : 32
        let size = isLevel7 ? 48 : 32
        let nameLength = isLevel7 ? 32 : 11
        while position + size <= min(headerLength, bytes.count), bytes[position] != 0x0D, fields.count < maxFields {
            let nameBytes = bytes[position..<position + nameLength].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let typeIndex = position + nameLength
            let type = Character(Unicode.Scalar(bytes[typeIndex]))
            let length = Int(bytes[isLevel7 ? typeIndex + 1 : position + 16])
            let decimals = Int(bytes[isLevel7 ? typeIndex + 2 : position + 17])
            let flags = isLevel7 ? 0 : bytes[position + 18]
            // Character fields longer than 255 use the decimal byte as the high byte (Clipper, FoxPro).
            let width = type == "C" && !isLevel7 ? length | decimals << 8 : length
            fields.append(Field(name: name.isEmpty ? "FIELD\(fields.count + 1)" : name, type: type, length: width,
                                decimals: type == "C" ? 0 : decimals, offset: offset, flags: flags))
            offset += width
            position += size
        }
        guard !fields.isEmpty, recordLength >= 1, headerLength <= data.count || records == 0 else { throw Failure.malformed }

        let (encoding, encodingName) = codePage(bytes[29], hint: codePageHint)
        var table = DBFTable(version: version, versionName: versionName(version, level7: isLevel7), updated: updated, recordCount: records,
                             fields: fields, encodingName: encodingName, memoFile: memo?.name)
        // _NullFlags: one bit for each nullable field (and one for each varying-length field).
        let nullFlags = fields.first { $0.isSystem && $0.name.uppercased() == "_NULLFLAGS" }
        var nullBits: [Int: Int] = [:], varBits: [Int: Int] = [:]
        var bit = 0
        for (index, field) in fields.enumerated() where !field.isSystem {
            if field.type == "V" || field.type == "Q" { varBits[index] = bit; bit += 1 }
            if field.isNullable { nullBits[index] = bit; bit += 1 }
        }

        let visible = fields.indices.filter { !fields[$0].isSystem }
        let available = max(0, (data.count - headerLength) / recordLength)
        let count = min(records, available, maxRecords)
        table.truncated = count < records
        table.rows.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            for record in 0..<count {
                let start = headerLength + record * recordLength
                guard start + recordLength <= base.count else { break }
                let row = UnsafeBufferPointer(rebasing: base[start..<start + recordLength])
                if row[0] == 0x1A { break }
                if row[0] == 0x2A { table.deleted.insert(table.rows.count) }
                var flagsBytes: UnsafeBufferPointer<UInt8>?
                if let nullFlags, nullFlags.offset + nullFlags.length <= row.count {
                    flagsBytes = UnsafeBufferPointer(rebasing: row[nullFlags.offset..<nullFlags.offset + nullFlags.length])
                }
                func flag(_ bit: Int?) -> Bool {
                    guard let bit, let flagsBytes, bit / 8 < flagsBytes.count else { return false }
                    return flagsBytes[bit / 8] & (1 << UInt8(bit % 8)) != 0
                }
                var values: [GridValue] = []
                values.reserveCapacity(visible.count)
                for index in visible {
                    let field = fields[index]
                    guard field.offset + field.length <= row.count else { values.append(.null); continue }
                    if flag(nullBits[index]) { values.append(.null); continue }
                    var slice = UnsafeBufferPointer(rebasing: row[field.offset..<field.offset + field.length])
                    if flag(varBits[index]), let last = slice.last, Int(last) < slice.count {
                        slice = UnsafeBufferPointer(rebasing: slice.prefix(Int(last)))
                    }
                    values.append(value(field, slice, encoding: encoding, foxPro: isVisualFoxPro, memo: memo))
                }
                table.rows.append(values)
            }
        }
        return table
    }

    private static func value(_ field: Field, _ bytes: UnsafeBufferPointer<UInt8>, encoding: String.Encoding,
                              foxPro: Bool, memo: MemoFile?) -> GridValue {
        func text() -> String {
            let trimmed = bytes.prefix { $0 != 0 }
            return (String(bytes: trimmed, encoding: encoding) ?? String(decoding: trimmed, as: UTF8.self)).trimmingCharacters(in: .whitespaces)
        }
        func int32() -> Int32 { bytes.count >= 4 ? Int32(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24) : 0 }
        func int64() -> Int64 {
            guard bytes.count >= 8 else { return 0 }
            var value: UInt64 = 0
            for i in (0..<8).reversed() { value = value << 8 | UInt64(bytes[i]) }
            return Int64(bitPattern: value)
        }
        switch field.type {
        case "C", "V":
            let value = text()
            return value.isEmpty ? .placeholder("") : .text(value)
        case "N", "F":
            let value = text()
            if value.isEmpty { return .null }
            if value.allSatisfy({ $0 == "*" }) { return .placeholder("Overflow") }
            return .text(value)
        case "D":
            let value = text()
            guard value.count == 8, let y = Int(value.prefix(4)), let m = Int(value.dropFirst(4).prefix(2)), let d = Int(value.suffix(2)), m >= 1, m <= 12, d >= 1, d <= 31 else {
                return value.isEmpty || value == "00000000" ? .null : .text(value)
            }
            return .text(String(format: "%04d-%02d-%02d", y, m, d))
        case "L":
            switch bytes.first {
            case UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: "Y"), UInt8(ascii: "y"): return .text("true")
            case UInt8(ascii: "F"), UInt8(ascii: "f"), UInt8(ascii: "N"), UInt8(ascii: "n"): return .text("false")
            default: return .null
            }
        case "I":
            return .text(String(int32()))
        case "+":
            // dBase 7 autoincrement: big-endian with the sign bit flipped.
            guard bytes.count >= 4 else { return .null }
            let raw = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return .text(String(Int32(bitPattern: raw ^ 0x8000_0000)))
        case "Y":
            let value = Double(int64()) / 10_000
            return .text(String(format: "%.4f", value))
        case "T":
            guard bytes.count >= 8 else { return .null }
            let day = Int(int32())
            let ms = Int(Int32(bitPattern: UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24))
            guard day > 0 else { return .null }
            // Julian day 2440588 is 1970-01-01.
            let seconds = Double(day - 2_440_588) * 86_400 + Double(ms) / 1000
            return .text(isoDateTime(seconds))
        case "@":
            // dBase 7 timestamp: big-endian double of milliseconds since 4713 BC, sign bit flipped.
            guard bytes.count >= 8 else { return .null }
            var raw: UInt64 = 0
            for b in bytes.prefix(8) { raw = raw << 8 | UInt64(b) }
            let value = Double(bitPattern: raw ^ 0x8000_0000_0000_0000)
            guard value > 0 else { return .null }
            return .text(isoDateTime(value / 1000 - 210_866_803_200))
        case "O":
            guard bytes.count >= 8 else { return .null }
            var raw: UInt64 = 0
            for b in bytes.prefix(8) { raw = raw << 8 | UInt64(b) }
            raw = raw & 0x8000_0000_0000_0000 != 0 ? raw ^ 0x8000_0000_0000_0000 : ~raw
            return .text(ColumnProfile.full(Double(bitPattern: raw)))
        case "B" where foxPro:
            guard bytes.count >= 8 else { return .null }
            return .text(ColumnProfile.full(Double(bitPattern: UInt64(bitPattern: int64()))))
        case "M", "B", "G", "P", "W", "Q":
            // Memo reference: ten ASCII digits (dBase) or a 4-byte integer (Visual FoxPro).
            let block: Int
            if bytes.count == 4 { block = Int(UInt32(bitPattern: int32())) }
            else { block = Int(text()) ?? 0 }
            guard block > 0 else { return .null }
            guard let memo else { return .placeholder("Memo \(block)") }
            switch memo.read(block: block) {
            case .text(let data):
                let string = (String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{1A}\0").union(.whitespacesAndNewlines))
                return field.type == "M" ? (string.isEmpty ? .placeholder("") : .text(string)) : .secondary("Binary · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
            case .binary(let size):
                return .secondary((field.type == "G" ? "OLE object" : field.type == "P" ? "Picture" : "Binary") + " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            case .missing:
                return .placeholder("Unreadable memo")
            }
        default:
            let value = text()
            return value.isEmpty ? .null : .text(value)
        }
    }

    private static func isoDateTime(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate, .withSpaceBetweenDateAndTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func versionName(_ version: UInt8, level7: Bool) -> String {
        if level7 { return "dBase 7" }
        switch version {
        case 0x02, 0xFB: return "FoxBASE"
        case 0x03: return "dBase III"
        case 0x83: return "dBase III with memo"
        case 0x04: return "dBase IV"
        case 0x8B, 0x8E, 0xCB, 0x43, 0x63: return "dBase IV with memo"
        case 0x05: return "dBase V"
        case 0x07, 0x87: return "Visual Objects"
        case 0x30, 0x31, 0x32: return "Visual FoxPro"
        case 0xF5: return "FoxPro 2"
        case 0xE5: return "Clipper SIX"
        default: return "dBase"
        }
    }

    /// The code page from the language driver byte; a .cpg sidecar (shapefiles) wins when the byte is 0.
    static func codePage(_ ldid: UInt8, hint: String?) -> (String.Encoding, String) {
        if ldid == 0, let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !hint.isEmpty {
            if hint.contains("UTF") && hint.contains("8") { return (.utf8, "UTF-8") }
            if let number = Int(hint.filter(\.isNumber)), let encoding = windows(number) { return (encoding, "Code page \(number)") }
        }
        let table: [UInt8: (Int, String)] = [
            0x01: (437, "DOS USA"), 0x02: (850, "DOS Multilingual"), 0x03: (1252, "Windows ANSI"), 0x04: (10000, "Mac Roman"),
            0x08: (865, "DOS Danish"), 0x09: (437, "DOS Dutch"), 0x0A: (850, "DOS Dutch"), 0x0B: (437, "DOS Finnish"),
            0x0D: (437, "DOS French"), 0x0E: (850, "DOS French"), 0x0F: (437, "DOS German"), 0x10: (850, "DOS German"),
            0x11: (437, "DOS Italian"), 0x12: (850, "DOS Italian"), 0x13: (932, "Japanese Shift-JIS"), 0x14: (850, "DOS Spanish"),
            0x15: (437, "DOS Swedish"), 0x16: (850, "DOS Swedish"), 0x17: (865, "DOS Norwegian"), 0x18: (437, "DOS Spanish"),
            0x19: (437, "DOS English"), 0x1A: (850, "DOS English"), 0x1B: (437, "DOS USA"), 0x1C: (863, "DOS French Canadian"),
            0x1D: (850, "DOS French"), 0x1F: (852, "DOS Czech"), 0x22: (852, "DOS Hungarian"), 0x23: (852, "DOS Polish"),
            0x24: (860, "DOS Portuguese"), 0x25: (850, "DOS Portuguese"), 0x26: (866, "DOS Russian"), 0x37: (850, "DOS USA"),
            0x40: (852, "DOS Romanian"), 0x4D: (936, "Chinese GBK"), 0x4E: (949, "Korean"), 0x4F: (950, "Chinese Big5"),
            0x50: (874, "Thai"), 0x57: (1252, "Windows ANSI"), 0x58: (1252, "Windows Western European"), 0x59: (1252, "Windows Spanish"),
            0x64: (852, "DOS Eastern European"), 0x65: (866, "DOS Russian"), 0x66: (865, "DOS Nordic"), 0x67: (861, "DOS Icelandic"),
            0x6A: (737, "DOS Greek"), 0x6B: (857, "DOS Turkish"), 0x6C: (863, "DOS French Canadian"), 0x78: (950, "Chinese Big5"),
            0x79: (949, "Korean"), 0x7A: (936, "Chinese GBK"), 0x7B: (932, "Japanese Shift-JIS"), 0x7C: (874, "Thai"),
            0x7D: (1255, "Windows Hebrew"), 0x7E: (1256, "Windows Arabic"), 0x86: (737, "DOS Greek"), 0x87: (852, "DOS Slovenian"),
            0x88: (857, "DOS Turkish"), 0x96: (10007, "Mac Cyrillic"), 0x97: (10029, "Mac Central European"), 0x98: (10006, "Mac Greek"),
            0xC8: (1250, "Windows Central European"), 0xC9: (1251, "Windows Cyrillic"), 0xCA: (1254, "Windows Turkish"),
            0xCB: (1253, "Windows Greek"), 0xCC: (1257, "Windows Baltic"),
        ]
        if let (page, name) = table[ldid] {
            let encoding: String.Encoding?
            switch page {
            case 10000: encoding = .macOSRoman
            case 10006: encoding = cfEncoding(CFStringEncoding(CFStringEncodings.macGreek.rawValue))
            case 10007: encoding = cfEncoding(CFStringEncoding(CFStringEncodings.macCyrillic.rawValue))
            case 10029: encoding = cfEncoding(CFStringEncoding(CFStringEncodings.macCentralEurRoman.rawValue))
            default: encoding = windows(page)
            }
            if let encoding { return (encoding, "\(name) (\(page))") }
        }
        // No code page recorded: UTF-8 if it decodes, otherwise Windows ANSI.
        return (.windowsCP1252, "Windows ANSI")
    }

    private static func windows(_ page: Int) -> String.Encoding? {
        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(page))
        return cf == kCFStringEncodingInvalidId ? nil : cfEncoding(cf)
    }

    private static func cfEncoding(_ encoding: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    // MARK: - Table

    func store() -> RecordTable {
        let visible = fields.filter { !$0.isSystem }
        let columns = visible.map { field -> RecordColumn in
            let numeric = ["N", "F", "I", "Y", "B", "O", "+"].contains(field.type) && !(field.type == "B" && !versionName.contains("FoxPro"))
            let binary = ["G", "P", "W", "Q"].contains(field.type) || (field.type == "B" && !versionName.contains("FoxPro"))
            return RecordColumn(title: field.name, toolTip: field.typeName, numeric: numeric, sort: numeric ? .numeric : .natural,
                                profiled: !binary, caption: field.typeName)
        }
        let table = RecordTable(columns: columns, rows: rows)
        table.dimmed = deleted
        return table
    }
}

/// A memo file beside a table: .dbt (dBase III and IV) or .fpt (FoxPro).
final class MemoFile {
    enum Block { case text(Data), binary(Int), missing }
    enum Kind { case dBase3, dBase4, foxPro }

    let name: String
    private let data: Data
    private let kind: Kind
    private let blockSize: Int

    private init(name: String, data: Data, kind: Kind, blockSize: Int) {
        self.name = name
        self.data = data
        self.kind = kind
        self.blockSize = blockSize
    }

    static func open(beside url: URL) -> MemoFile? {
        let base = url.deletingPathExtension()
        for ext in ["fpt", "FPT", "dbt", "DBT"] {
            let candidate = base.appendingPathExtension(ext)
            guard let data = try? Data(contentsOf: candidate, options: .mappedIfSafe) else { continue }
            return make(data, name: candidate.lastPathComponent, foxPro: ext.lowercased() == "fpt")
        }
        return nil
    }

    static func make(_ data: Data, name: String, foxPro: Bool) -> MemoFile? {
        guard data.count >= 512 else { return nil }
        let bytes = [UInt8](data.prefix(32))
        if foxPro {
            let size = Int(bytes[6]) << 8 | Int(bytes[7])
            return MemoFile(name: name, data: data, kind: .foxPro, blockSize: size > 0 ? size : 64)
        }
        // dBase IV records its block size at 20–21; dBase III always uses 512.
        let size = Int(bytes[20]) | Int(bytes[21]) << 8
        let isDBase4 = bytes[16] != 0x03 && size > 0 && size % 64 == 0 && size <= 32_768 && data.count > 512 + 8 && data[data.startIndex + 512] == 0xFF
        return MemoFile(name: name, data: data, kind: isDBase4 ? .dBase4 : .dBase3, blockSize: isDBase4 ? size : 512)
    }

    /// Memo text is capped: a preview shows its start.
    static let maxMemo = 64 * 1024

    func read(block: Int) -> Block {
        let (offset, overflow) = block.multipliedReportingOverflow(by: blockSize)
        guard !overflow, offset >= 0, offset < data.count else { return .missing }
        let start = data.startIndex + offset
        switch kind {
        case .foxPro:
            guard offset + 8 <= data.count else { return .missing }
            let type = data[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            let length = data[start + 4..<start + 8].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 0 else { return .missing }
            let end = min(start + 8 + length, data.endIndex)
            return type == 1 ? .text(data[(start + 8)..<min(end, start + 8 + Self.maxMemo)]) : .binary(length)
        case .dBase4:
            guard offset + 8 <= data.count, data[start] == 0xFF, data[start + 1] == 0xFF else { return .missing }
            let length = Int(data[start + 4]) | Int(data[start + 5]) << 8 | Int(data[start + 6]) << 16 | Int(data[start + 7]) << 24
            let end = min(start + max(length, 8), data.endIndex)
            return .text(data[(start + 8)..<min(end, start + 8 + Self.maxMemo)])
        case .dBase3:
            // Text runs to the first 0x1A (end of file marker).
            let limit = min(data.endIndex, start + Self.maxMemo)
            let end = data[start..<limit].firstIndex(of: 0x1A) ?? limit
            return .text(data[start..<end])
        }
    }
}
