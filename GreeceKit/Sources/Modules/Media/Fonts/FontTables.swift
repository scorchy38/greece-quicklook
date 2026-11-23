import Foundation

/// Bounds-checked big-endian reads over untrusted bytes. Every read returns nil past the end.
/// Backed by `Data`, so a memory-mapped file is read in place, never copied.
struct MediaReader {
    private let data: Data
    private let base: Int

    init(_ data: Data) { self.data = data; base = data.startIndex }
    init(bytes: [UInt8]) { self.init(Data(bytes)) }

    var count: Int { data.count }

    private subscript(_ offset: Int) -> UInt8 { data[base + offset] }

    func u8(_ offset: Int) -> Int? {
        offset >= 0 && offset < count ? Int(self[offset]) : nil
    }

    func u16(_ offset: Int) -> Int? {
        guard offset >= 0, offset <= count - 2 else { return nil }
        return Int(self[offset]) << 8 | Int(self[offset + 1])
    }

    func i16(_ offset: Int) -> Int? {
        u16(offset).map { Int(Int16(truncatingIfNeeded: $0)) }
    }

    func u32(_ offset: Int) -> Int? {
        guard offset >= 0, offset <= count - 4 else { return nil }
        return Int(self[offset]) << 24 | Int(self[offset + 1]) << 16 | Int(self[offset + 2]) << 8 | Int(self[offset + 3])
    }

    func i32(_ offset: Int) -> Int? {
        u32(offset).map { Int(Int32(truncatingIfNeeded: $0)) }
    }

    func i64(_ offset: Int) -> Int64? {
        guard let high = u32(offset), let low = u32(offset + 4) else { return nil }
        return Int64(bitPattern: UInt64(high) << 32 | UInt64(low))
    }

    /// 16.16 fixed point.
    func fixed(_ offset: Int) -> Double? {
        i32(offset).map { Double($0) / 65536 }
    }

    /// A four-character tag, if it's printable ASCII.
    func tag(_ offset: Int) -> String? {
        guard let slice = slice(offset, 4), slice.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: slice, as: UTF8.self)
    }

    func slice(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= count - length else { return nil }
        return data[(base + offset)..<(base + offset + length)]
    }
}

/// How a font file wraps its faces.
enum FontContainer: String {
    case sfnt, collection, woff, woff2

    static func sniff(_ bytes: [UInt8]) -> FontContainer? {
        let reader = MediaReader(bytes: Array(bytes.prefix(16)))
        guard let magic = reader.u32(0) else { return nil }
        switch magic {
        case 0x0001_0000, 0x7472_7565 /* true */, 0x4F54_544F /* OTTO */:
            guard let tables = reader.u16(4), (1...512).contains(tables) else { return nil }
            return .sfnt
        case 0x7474_6366: // ttcf
            guard let faces = reader.u32(8), (1...4096).contains(faces) else { return nil }
            return .collection
        case 0x774F_4646: return .woff  // wOFF
        case 0x774F_4632: return .woff2 // wOF2
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .sfnt: return String(localized: "Font", bundle: .greeceKit, comment: "A font file’s format on its preview page, as opposed to a font collection or a web font")
        case .collection: return Self.collectionName
        case .woff: return "WOFF"
        case .woff2: return "WOFF2"
        }
    }

    static var collectionName: String {
        String(localized: "Font Collection", bundle: .greeceKit, comment: "Info bar title: a file that holds several fonts (.ttc, .otc)")
    }
}

enum FontFile {
    static let maximumFaces = 64

    /// Where each face's table directory starts: one for a plain font, several for a collection.
    static func faceOffsets(_ reader: MediaReader) -> [Int] {
        guard let magic = reader.u32(0) else { return [] }
        guard magic == 0x7474_6366 else { return [0] }
        guard let count = reader.u32(8), count > 0 else { return [] }
        return (0..<min(count, maximumFaces)).compactMap { reader.u32(12 + $0 * 4) }.filter { $0 < reader.count }
    }

    /// A face's PostScript name, read from its own `name` table inside the collection.
    static func postScriptName(_ reader: MediaReader, at offset: Int) -> String? {
        guard let tableCount = reader.u16(offset + 4), tableCount <= 512 else { return nil }
        for index in 0..<tableCount {
            let record = offset + 12 + index * 16
            guard reader.tag(record) == "name", let start = reader.u32(record + 8), let length = reader.u32(record + 12) else { continue }
            return FontTables.Name(reader.slice(start, length))[6]
        }
        return nil
    }

    /// One face of a collection as a standalone font file, so WebKit can load any face by itself.
    static func extractFace(_ reader: MediaReader, at offset: Int) -> Data? {
        guard let version = reader.u32(offset), let tableCount = reader.u16(offset + 4), (1...512).contains(tableCount) else { return nil }
        struct Table { var tag: UInt32; var checksum: UInt32; var offset: Int; var length: Int }
        var tables: [Table] = []
        for index in 0..<tableCount {
            let record = offset + 12 + index * 16
            guard let tag = reader.u32(record), let checksum = reader.u32(record + 4),
                  let start = reader.u32(record + 8), let length = reader.u32(record + 12),
                  reader.slice(start, length) != nil else { return nil }
            tables.append(Table(tag: UInt32(tag), checksum: UInt32(checksum), offset: start, length: length))
        }
        var output = Data()
        func put16(_ value: Int) { output += [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func put32(_ value: Int) { output += [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        var power = 1, log2 = 0
        while power * 2 <= tableCount { power *= 2; log2 += 1 }
        put32(version); put16(tableCount); put16(power * 16); put16(log2); put16(tableCount * 16 - power * 16)
        var cursor = 12 + tableCount * 16
        var body = Data()
        // Collections share tables between faces: copy only this face's, never the whole file.
        for table in tables {
            put32(Int(table.tag)); put32(Int(table.checksum)); put32(cursor); put32(table.length)
            body += reader.slice(table.offset, table.length)!
            while body.count % 4 != 0 { body.append(0) }
            cursor = 12 + tableCount * 16 + body.count
        }
        return output + body
    }
}

/// The OpenType tables Greece reads for a specimen.
enum FontTables {
    // MARK: - name

    /// The `name` table: family, designer, licence and the names variable instances and stylistic sets point to.
    struct Name {
        private var strings: [Int: String] = [:]

        init(_ data: Data?) {
            guard let data else { return }
            let reader = MediaReader(data)
            guard let count = reader.u16(2), let storage = reader.u16(4) else { return }
            var best: [Int: (rank: Int, value: String)] = [:]
            for index in 0..<min(count, 4096) {
                let record = 6 + index * 12
                guard let platform = reader.u16(record), let encoding = reader.u16(record + 2), let language = reader.u16(record + 4),
                      let id = reader.u16(record + 6), let length = reader.u16(record + 8), let offset = reader.u16(record + 10),
                      let bytes = reader.slice(storage + offset, length) else { continue }
                let rank: Int
                let value: String?
                switch platform {
                case 3 where encoding == 1 || encoding == 10 || encoding == 0:
                    rank = language == 0x409 ? 0 : 2
                    value = String(bytes: Array(bytes), encoding: .utf16BigEndian)
                case 0:
                    rank = 3
                    value = String(bytes: Array(bytes), encoding: .utf16BigEndian)
                case 1 where encoding == 0:
                    rank = language == 0 ? 1 : 4
                    value = String(bytes: Array(bytes), encoding: .macOSRoman)
                default:
                    continue
                }
                guard let value, !value.isEmpty else { continue }
                if best[id] == nil || best[id]!.rank > rank { best[id] = (rank, value) }
            }
            strings = best.mapValues { Name.clean($0.value) }
        }

        subscript(id: Int) -> String? { strings[id] }

        private static func clean(_ value: String) -> String {
            let trimmed = value.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 6000 ? String(trimmed.prefix(6000)) + "…" : trimmed
        }
    }

    // MARK: - fvar

    struct Variation {
        struct Axis: Encodable {
            var tag: String
            var name: String
            var min: Double
            var `default`: Double
            var max: Double
            var hidden: Bool
        }
        struct Instance: Encodable {
            var name: String
            var coordinates: [String: Double]
        }

        var axes: [Axis] = []
        var instances: [Instance] = []

        init(_ data: Data?, names: Name) {
            guard let data else { return }
            let reader = MediaReader(data)
            guard let axesOffset = reader.u16(4), let axisCount = reader.u16(8), let axisSize = reader.u16(10),
                  let instanceCount = reader.u16(12), let instanceSize = reader.u16(14),
                  axisSize >= 20, axisCount <= 64 else { return }
            for index in 0..<axisCount {
                let record = axesOffset + index * axisSize
                guard let tag = reader.tag(record), let min = reader.fixed(record + 4), let def = reader.fixed(record + 8),
                      let max = reader.fixed(record + 12), let flags = reader.u16(record + 16), let nameID = reader.u16(record + 18),
                      min <= def, def <= max else { continue }
                axes.append(Axis(tag: tag, name: names[nameID] ?? Variation.axisName(tag), min: min, default: def, max: max, hidden: flags & 1 != 0))
            }
            guard axes.count == axisCount, instanceSize >= 4 + axisCount * 4 else { return }
            let instancesOffset = axesOffset + axisCount * axisSize
            for index in 0..<min(instanceCount, 512) {
                let record = instancesOffset + index * instanceSize
                guard let nameID = reader.u16(record) else { break }
                var coordinates: [String: Double] = [:]
                for (axisIndex, axis) in axes.enumerated() {
                    if let value = reader.fixed(record + 4 + axisIndex * 4) { coordinates[axis.tag] = value }
                }
                let name = names[nameID] ?? String(localized: "Instance \(String(index + 1))", bundle: .greeceKit,
                                                   comment: "A variable font’s named style that has no name of its own. The argument is its number, such as “Instance 3”")
                instances.append(Instance(name: name, coordinates: coordinates))
            }
        }

        /// Names for the registered axes, when the font gives none.
        static func axisName(_ tag: String) -> String {
            switch tag {
            case "wght": return String(localized: "Weight [font axis]", defaultValue: "Weight", bundle: .greeceKit, comment: "Variable font axis: how bold the letters are")
            case "wdth": return String(localized: "Width [font axis]", defaultValue: "Width", bundle: .greeceKit, comment: "Variable font axis: how wide or condensed the letters are")
            case "slnt": return String(localized: "Slant", bundle: .greeceKit, comment: "Variable font axis: how far the letters lean")
            case "ital": return String(localized: "Italic", bundle: .greeceKit, comment: "Variable font axis: upright or italic")
            case "opsz": return String(localized: "Optical Size", bundle: .greeceKit, comment: "Variable font axis: letterforms tuned for the size they’re read at")
            case "GRAD": return String(localized: "Grade", bundle: .greeceKit, comment: "Variable font axis: how heavy the strokes are, without changing the letters’ width")
            default: return tag
            }
        }
    }

    // MARK: - OS/2 and head

    struct OS2 {
        var weightClass: Int?
        var widthClass: Int?
        var fsType: Int?
        var vendor: String?
        var capHeight: Int?
        var xHeight: Int?

        init(_ data: Data?) {
            guard let data else { return }
            let reader = MediaReader(data)
            weightClass = reader.u16(4)
            widthClass = reader.u16(6)
            fsType = reader.u16(8)
            vendor = reader.tag(58).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            if let version = reader.u16(0), version >= 2 {
                xHeight = reader.i16(86)
                capHeight = reader.i16(88)
            }
        }

        /// What the font's licence allows when it's embedded in documents (OS/2 fsType).
        var embedding: String? {
            guard let fsType else { return nil }
            let usage = fsType & 0x000F
            var parts: [String]
            if usage & 0x2 != 0 && usage & 0xC == 0 {
                parts = [String(localized: "Restricted", bundle: .greeceKit, comment: "Font embedding permission: the font may not be embedded in documents")]
            } else if usage & 0x8 != 0 {
                parts = [String(localized: "Editable", bundle: .greeceKit, comment: "Font embedding permission: documents with the font embedded may be edited")]
            } else if usage & 0x4 != 0 {
                parts = [String(localized: "Preview & Print", bundle: .greeceKit, comment: "Font embedding permission: documents with the font embedded may only be viewed and printed")]
            } else {
                parts = [String(localized: "Installable", bundle: .greeceKit, comment: "Font embedding permission: the font may be embedded and installed")]
            }
            // Further limits, listed after the permission: “Editable, no subsetting, bitmaps only”.
            if fsType & 0x0100 != 0 {
                parts.append(String(localized: "no subsetting", bundle: .greeceKit, comment: "Font embedding limit, listed after the permission: the whole font must be embedded"))
            }
            if fsType & 0x0200 != 0 {
                parts.append(String(localized: "bitmaps only", bundle: .greeceKit, comment: "Font embedding limit, listed after the permission: only bitmaps may be embedded, not outlines"))
            }
            return parts.joined(separator: ", ")
        }
    }

    struct Head {
        var unitsPerEm: Int?
        var created: Date?
        var modified: Date?

        init(_ data: Data?) {
            guard let data else { return }
            let reader = MediaReader(data)
            guard reader.u32(12) == 0x5F0F_3CF5 else { return }
            unitsPerEm = reader.u16(18)
            // Seconds since 1904-01-01.
            func date(_ offset: Int) -> Date? {
                guard let seconds = reader.i64(offset), seconds > 0, seconds < 8_000_000_000 else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(seconds) - 2_082_844_800)
            }
            created = date(20)
            modified = date(28)
        }
    }

    // MARK: - GSUB / GPOS

    /// OpenType layout tables: which features and scripts a font offers, and which glyphs each feature changes.
    struct Layout {
        struct Feature {
            var tag: String
            var lookups: [Int]
            var uiNameID: Int?
        }

        let reader: MediaReader
        private(set) var features: [Feature] = []
        private(set) var scripts: [String] = []

        init?(_ data: Data?) {
            guard let data, data.count >= 10 else { return nil }
            reader = MediaReader(data)
            guard reader.u16(0) == 1, let scriptList = reader.u16(4), let featureList = reader.u16(6) else { return nil }

            if let count = reader.u16(scriptList) {
                for index in 0..<min(count, 256) {
                    if let tag = reader.tag(scriptList + 2 + index * 6) { scripts.append(tag) }
                }
            }
            if let count = reader.u16(featureList) {
                var seen = [String: Int]()
                for index in 0..<min(count, 2048) {
                    let record = featureList + 2 + index * 6
                    guard let tag = reader.tag(record), let offset = reader.u16(record + 4) else { continue }
                    let table = featureList + offset
                    guard let lookupCount = reader.u16(table + 2) else { continue }
                    let lookups = (0..<min(lookupCount, 512)).compactMap { reader.u16(table + 4 + $0 * 2) }
                    var uiName: Int?
                    if let params = reader.u16(table), params != 0 {
                        // Stylistic sets: version, UINameID. Character variants: format, FeatUILabelNameID.
                        if tag.hasPrefix("ss") || tag.hasPrefix("cv"), let id = reader.u16(table + params + 2), id >= 256 { uiName = id }
                    }
                    // The same feature appears once per script; merge their lookups.
                    if let existing = seen[tag] {
                        features[existing].lookups = Array(Set(features[existing].lookups + lookups))
                        if features[existing].uiNameID == nil { features[existing].uiNameID = uiName }
                    } else {
                        seen[tag] = features.count
                        features.append(Feature(tag: tag, lookups: lookups, uiNameID: uiName))
                    }
                }
            }
        }

        /// Glyph sequences a GSUB feature applies to: single glyphs, or whole sequences for ligatures.
        func inputs(of feature: Feature, limit: Int = 64) -> [[Int]] {
            guard let lookupList = reader.u16(8), let lookupCount = reader.u16(lookupList) else { return [] }
            var result: [[Int]] = []
            var seen = Set<[Int]>()
            func add(_ sequence: [Int]) {
                guard result.count < limit, seen.insert(sequence).inserted else { return }
                result.append(sequence)
            }
            for lookupIndex in feature.lookups.sorted() where lookupIndex < lookupCount && result.count < limit {
                guard let lookupOffset = reader.u16(lookupList + 2 + lookupIndex * 2) else { continue }
                let lookup = lookupList + lookupOffset
                guard let type = reader.u16(lookup), let subtableCount = reader.u16(lookup + 4) else { continue }
                for subIndex in 0..<min(subtableCount, 64) {
                    guard let subOffset = reader.u16(lookup + 6 + subIndex * 2) else { continue }
                    var subtable = lookup + subOffset
                    var kind = type
                    if kind == 7, let realType = reader.u16(subtable + 2), let extensionOffset = reader.u32(subtable + 4) {
                        kind = realType
                        subtable += extensionOffset
                    }
                    collect(kind: kind, subtable: subtable, limit: limit, add: add)
                    if result.count >= limit { break }
                }
            }
            return result
        }

        private func collect(kind: Int, subtable: Int, limit: Int, add: ([Int]) -> Void) {
            guard let format = reader.u16(subtable) else { return }
            switch kind {
            case 1, 2, 3, 8:
                if let coverage = reader.u16(subtable + 2) { for glyph in glyphs(coverage: subtable + coverage, limit: limit) { add([glyph]) } }
            case 4:
                guard let coverage = reader.u16(subtable + 2), let setCount = reader.u16(subtable + 4) else { return }
                let firsts = glyphs(coverage: subtable + coverage, limit: 4096)
                for (index, first) in firsts.prefix(setCount).enumerated() {
                    guard let setOffset = reader.u16(subtable + 6 + index * 2) else { continue }
                    let set = subtable + setOffset
                    guard let ligatureCount = reader.u16(set) else { continue }
                    for ligatureIndex in 0..<min(ligatureCount, 32) {
                        guard let ligatureOffset = reader.u16(set + 2 + ligatureIndex * 2) else { continue }
                        let ligature = set + ligatureOffset
                        guard let components = reader.u16(ligature + 2), (2...8).contains(components) else { continue }
                        let rest = (1..<components).compactMap { reader.u16(ligature + 4 + ($0 - 1) * 2) }
                        add([first] + rest)
                    }
                }
            case 5, 6:
                if format == 3 {
                    // Format 3 lists coverage tables directly: the input's first one is what changes.
                    let base: Int
                    if kind == 5 {
                        base = subtable + 6
                    } else {
                        guard let backtrack = reader.u16(subtable + 2) else { return }
                        base = subtable + 4 + backtrack * 2 + 2
                    }
                    if let coverage = reader.u16(base) { for glyph in glyphs(coverage: subtable + coverage, limit: limit) { add([glyph]) } }
                } else if let coverage = reader.u16(subtable + 2) {
                    for glyph in glyphs(coverage: subtable + coverage, limit: limit) { add([glyph]) }
                }
            default:
                break
            }
        }

        func glyphs(coverage offset: Int, limit: Int) -> [Int] {
            guard let format = reader.u16(offset), let count = reader.u16(offset + 2) else { return [] }
            var result: [Int] = []
            if format == 1 {
                for index in 0..<min(count, limit) {
                    if let glyph = reader.u16(offset + 4 + index * 2) { result.append(glyph) }
                }
            } else if format == 2 {
                for index in 0..<min(count, 1024) {
                    let record = offset + 4 + index * 6
                    guard let start = reader.u16(record), let end = reader.u16(record + 2), start <= end else { continue }
                    for glyph in start...min(end, start + limit) {
                        result.append(glyph)
                        if result.count >= limit { return result }
                    }
                }
            }
            return result
        }
    }
}
