import AppKit
import CoreText

/// One face of a font file, read through CoreText (which decodes WOFF and WOFF2 too) plus the
/// OpenType tables CoreText doesn't summarise.
final class FontFaceInfo: @unchecked Sendable {
    let font: CTFont
    /// Bytes WebKit can load for this face: the file itself, or a face cut out of a collection.
    let webData: Data
    let names: FontTables.Name
    let os2: FontTables.OS2
    let head: FontTables.Head
    let variation: FontTables.Variation
    let substitutions: FontTables.Layout?
    let positioning: FontTables.Layout?
    let tables: Set<String>

    init?(data: Data, webData: Data) {
        guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { return nil }
        let probe = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let unitsPerEm = CGFloat(max(16, min(16384, CTFontGetUnitsPerEm(probe))))
        // Measured at one point per font unit, so CoreText's metrics come back in font units.
        let font = CTFontCreateWithFontDescriptor(descriptor, unitsPerEm, nil)
        self.font = font
        self.webData = webData
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
        var present = Set<String>()
        for tag in ["glyf", "CFF ", "CFF2", "COLR", "CPAL", "SVG ", "sbix", "CBDT", "EBDT", "kern", "morx", "MATH", "vhea"] where table(tag) != nil {
            present.insert(tag)
        }
        tables = present
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
        return "Unknown"
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
        guard let container = FontContainer.sniff([UInt8](data.prefix(16))) else { throw MediaError.unreadable("This isn’t a font file Greece can read.") }
        self.container = container
        var faces: [FontFaceInfo] = []
        if container == .collection {
            let reader = MediaReader(data)
            for offset in FontFile.faceOffsets(reader) {
                if let face = FontFile.extractFace(reader, at: offset), let info = FontFaceInfo(data: face, webData: face) { faces.append(info) }
            }
        } else if let info = FontFaceInfo(data: data, webData: data) {
            faces.append(info)
        }
        guard !faces.isEmpty else { throw MediaError.unreadable("This font is damaged or uses a format macOS can’t read.") }
        self.faces = faces
    }

    var title: String {
        switch container {
        case .collection: return "Font Collection"
        case .woff: return "WOFF Font"
        case .woff2: return "WOFF2 Font"
        case .sfnt:
            let face = faces[0]
            if !face.variation.axes.isEmpty { return "Variable Font" }
            return face.outlines == "TrueType" ? "TrueType Font" : "OpenType Font"
        }
    }
}
