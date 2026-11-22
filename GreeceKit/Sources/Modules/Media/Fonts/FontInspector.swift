import AppKit
import CoreText

/// One face of a font file, read through CoreText (which decodes WOFF and WOFF2 too) plus the
/// OpenType tables CoreText doesn't summarise.
final class FontFaceInfo: @unchecked Sendable {
    let font: CTFont
    let names: FontTables.Name
    let os2: FontTables.OS2
    let head: FontTables.Head
    let variation: FontTables.Variation
    let substitutions: FontTables.Layout?
    let positioning: FontTables.Layout?
    /// Every table the face has, by tag.
    let tables: Set<String>
    private let makeWebData: () -> Data?
    private var cachedWebData: Data?
    private let lock = NSLock()

    /// A face from its own bytes (a plain font, WOFF or WOFF2).
    convenience init?(data: Data) {
        guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { return nil }
        self.init(descriptor: descriptor, webData: { data })
    }

    /// `webData` makes the bytes WebKit loads for this face, only when the page asks for them.
    init(descriptor: CTFontDescriptor, webData: @escaping () -> Data?) {
        let probe = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let unitsPerEm = CGFloat(max(16, min(16384, CTFontGetUnitsPerEm(probe))))
        // Measured at one point per font unit, so CoreText's metrics come back in font units.
        let font = CTFontCreateWithFontDescriptor(descriptor, unitsPerEm, nil)
        self.font = font
        makeWebData = webData
        func table(_ tag: String) -> Data? {
            let code = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return CTFontCopyTable(font, code, []) as Data?
        }
        let names = FontTables.Name(table("name"))
        self.names = names
        os2 = FontTables.OS2(table("OS/2"))
        head = FontTables.Head(table("head"))
        variation = FontTables.Variation(table("fvar"), names: names)
        substitutions = FontTables.Layout(table("GSUB"))
        positioning = FontTables.Layout(table("GPOS"))
        tables = Self.tableTags(font)
    }

    /// Tags from the table directory, without copying any table (an emoji font's bitmaps run to 180 MB).
    private static func tableTags(_ font: CTFont) -> Set<String> {
        guard let array = CTFontCopyAvailableTables(font, []) else { return [] }
        var result = Set<String>()
        for index in 0..<min(CFArrayGetCount(array), 512) {
            // The array holds raw four-byte tags, not objects.
            let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(array, index)))
            let bytes = [UInt8(tag >> 24 & 0xFF), UInt8(tag >> 16 & 0xFF), UInt8(tag >> 8 & 0xFF), UInt8(tag & 0xFF)]
            if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { result.insert(String(decoding: bytes, as: UTF8.self)) }
        }
        return result
    }

    /// Bytes WebKit can load for this face: the file itself, or this face cut out of a collection.
    var webData: Data? {
        lock.lock()
        defer { lock.unlock() }
        if cachedWebData == nil { cachedWebData = makeWebData() }
        return cachedWebData
    }

    var unitsPerEm: Int { Int(CTFontGetUnitsPerEm(font)) }
    var glyphCount: Int { CTFontGetGlyphCount(font) }

    var family: String {
        names[16] ?? names[1] ?? (CTFontCopyFamilyName(font) as String)
    }

    var style: String {
        names[17] ?? names[2] ?? (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "Regular"
    }

    var fullName: String {
        if let name = names[4] ?? (CTFontCopyFullName(font) as String?), !name.isEmpty { return name }
        return style == "Regular" ? family : "\(family) \(style)"
    }

    var postScriptName: String {
        names[6] ?? (CTFontCopyPostScriptName(font) as String)
    }

    var version: String? {
        guard var value = names[5] else { return nil }
        if value.lowercased().hasPrefix("version ") { value = String(value.dropFirst(8)) }
        // "1.002;PS 001.002;hotconv 1.0.88" — keep the version, not the toolchain.
        return value.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    var traits: CTFontSymbolicTraits { CTFontGetSymbolicTraits(font) }
    var isItalic: Bool { traits.contains(.traitItalic) }
    var isMonospaced: Bool { traits.contains(.traitMonoSpace) }

    var outlines: String {
        if tables.contains("CFF2") { return "CFF2" }
        if tables.contains("CFF ") { return "PostScript (CFF)" }
        if tables.contains("glyf") { return "TrueType" }
        if tables.contains("sbix") || tables.contains("CBDT") || tables.contains("EBDT") { return "Bitmap" }
        return String(localized: "Unknown [font outlines]", defaultValue: "Unknown", bundle: .greeceKit,
                      comment: "A font’s outline format (TrueType, PostScript…) that Greece can’t tell")
    }

    var colorFormats: [String] {
        var result: [String] = []
        if tables.contains("COLR") { result.append("COLR") }
        if tables.contains("SVG ") { result.append("SVG") }
        if tables.contains("sbix") { result.append("sbix") }
        if tables.contains("CBDT") { result.append("CBDT") }
        return result
    }

    // MARK: Characters

    /// Every Unicode scalar the font maps, in order, up to `limit`.
    func codepoints(limit: Int = 200_000) -> [Int] {
        let set = CTFontCopyCharacterSet(font)
        var result: [Int] = []
        for plane in 0..<17 where CFCharacterSetHasMemberInPlane(set, CFIndex(plane)) {
            let base = plane << 16
            for value in base..<(base + 0x10000) {
                guard CFCharacterSetIsLongCharacterMember(set, UTF32Char(value)) else { continue }
                // Controls, surrogates, spaces and invisible format characters have no glyph worth showing
                // (CoreText also maps no-break and other spaces to a font's space by itself).
                if value < 0x21 || (0x7F...0xA0).contains(value) || (0xD800...0xDFFF).contains(value) { continue }
                if let scalar = Unicode.Scalar(UInt32(value)), scalar.properties.isWhitespace || scalar.properties.isDefaultIgnorableCodePoint { continue }
                result.append(value)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    func glyph(for codepoint: Int) -> CGGlyph? {
        guard let scalar = Unicode.Scalar(UInt32(codepoint)) else { return nil }
        var units = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    func glyphName(_ glyph: CGGlyph) -> String? {
        guard let name = CTFontCopyNameForGlyph(font, glyph) as String?, !name.isEmpty, name.count <= 80 else { return nil }
        // Generated names ("glyph42", "gid42") say nothing a code point doesn't.
        if name.range(of: #"^(glyph|gid|g)\d+$"#, options: .regularExpression) != nil { return nil }
        return name
    }

    func advance(_ glyph: CGGlyph) -> Int {
        var glyph = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return Int(advance.width.rounded())
    }

    /// Glyph → the first character that maps to it, for turning feature coverage back into text.
    func reverseMap(_ codepoints: [Int]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for codepoint in codepoints.prefix(70_000) {
            if let glyph = glyph(for: codepoint), map[Int(glyph)] == nil { map[Int(glyph)] = codepoint }
        }
        return map
    }

    var languages: [String] {
        (CTFontCopySupportedLanguages(font) as? [String]) ?? []
    }

    /// Icon fonts (Font Awesome, Material Symbols…) map glyphs to private-use code points and no letters.
    static func isIconFont(_ codepoints: [Int]) -> Bool {
        guard !codepoints.isEmpty else { return false }
        let letters = codepoints.filter { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }.count
        let privateUse = codepoints.filter { (0xE000...0xF8FF).contains($0) || $0 >= 0xF0000 }.count
        return letters < 10 && privateUse * 2 >= codepoints.count
    }
}

// MARK: - The file

/// Every face in a font file.
struct FontFileInfo {
    let container: FontContainer
    let faces: [FontFaceInfo]

    init(data: Data) throws {
        guard let container = FontContainer.sniff([UInt8](data.prefix(16))) else { throw MediaError.unreadable(String(localized: "This isn’t a font file Greece can read.", bundle: .greeceKit)) }
        self.container = container
        var faces: [FontFaceInfo] = []
        if container == .collection {
            let reader = MediaReader(data)
            let offsets = FontFile.faceOffsets(reader)
            // CoreText reads every face straight from the mapped file when its faces line up with the
            // collection's directory (they do, unless faces are variable); only the face the page shows
            // is ever cut out and copied.
            let descriptors = (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]) ?? []
            let names = descriptors.map { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            if descriptors.count == offsets.count, zip(names, offsets).allSatisfy({ $0 != nil && $0 == FontFile.postScriptName(reader, at: $1) }) {
                for (descriptor, offset) in zip(descriptors, offsets) {
                    faces.append(FontFaceInfo(descriptor: descriptor, webData: { FontFile.extractFace(reader, at: offset) }))
                }
            } else {
                for offset in offsets {
                    if let face = FontFile.extractFace(reader, at: offset), let info = FontFaceInfo(data: face) { faces.append(info) }
                }
            }
        } else if let info = FontFaceInfo(data: data) {
            faces.append(info)
        }
        guard !faces.isEmpty else { throw MediaError.unreadable(String(localized: "This font is damaged or uses a format macOS can’t read.", bundle: .greeceKit)) }
        self.faces = faces
    }

    var title: String {
        switch container {
        case .collection: return FontContainer.collectionName
        case .woff: return String(localized: "WOFF Font", bundle: .greeceKit, comment: "Info bar title: a web font. WOFF is a file format")
        case .woff2: return String(localized: "WOFF2 Font", bundle: .greeceKit, comment: "Info bar title: a web font. WOFF2 is a file format")
        case .sfnt:
            let face = faces[0]
            if !face.variation.axes.isEmpty {
                return String(localized: "Variable Font", bundle: .greeceKit, comment: "Info bar title: a font whose weight, width or other styles vary along axes")
            }
            return face.outlines == "TrueType"
                ? String(localized: "TrueType Font", bundle: .greeceKit, comment: "Info bar title. TrueType is a font format")
                : String(localized: "OpenType Font", bundle: .greeceKit, comment: "Info bar title. OpenType is a font format")
        }
    }
}
