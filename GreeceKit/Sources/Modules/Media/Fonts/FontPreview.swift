import AppKit
import CoreText

/// A type specimen: the face's name, a hero, samples at several sizes, OpenType features you can
/// turn on, variable axes on sliders, the character set, and everything the font says about itself.
///
/// CoreText reads the file (it decodes WOFF and WOFF2 and every table) and the page draws the type
/// with the same bytes through `FontFace`, which WebKit hands back to CoreText. The web page makes
/// features, axes and an editable sample cheap to offer; the rendering is still CoreText's.
enum FontPreview {

    struct Payload: Encodable {
        var format: String
        var faces: [Face]
    }

    struct Face: Encodable {
        struct Metrics: Encodable { var upm, ascender, descender, capHeight, xHeight: Int }
        struct Feature: Encodable { var tag: String; var name: String; var on: Bool; var sample: String }
        var family: String
        var style: String
        var fullName: String
        var postScriptName: String
        var version: String?
        var designer: String?
        var designerURL: String?
        var manufacturer: String?
        var vendorURL: String?
        var license: String?
        var licenseURL: String?
        var copyright: String?
        var trademark: String?
        var description: String?
        var sample: String
        var hero: String
        var icon: Bool
        var direction: String
        var glyphs: Int
        var characters: Int
        var metrics: Metrics
        var weight: Int?
        var width: Int?
        var italic: Bool
        var monospaced: Bool
        var outlines: String
        var color: [String]
        var embedding: String?
        var vendor: String?
        var created: String?
        var modified: String?
        var features: [Feature]
        var axes: [FontTables.Variation.Axis]
        var instances: [FontTables.Variation.Instance]
        var scripts: [String]
        var languages: [String]
    }

    static func prepare(_ file: FileInfo) throws -> PreparedPreview {
        // Fonts are memory-mapped and read in place, so big CJK and emoji collections are fine.
        let data = try file.mediaData(limit: 320 * 1024 * 1024)
        let info = try FontFileInfo(data: data)
        let faces = info.faces.map { face -> (Face, [Int]) in
            let codepoints = face.codepoints()
            return (describe(face, codepoints: codepoints), codepoints)
        }
        let payload = Payload(format: info.container.displayName, faces: faces.map(\.0))
        let resources = FontResources(faces: info.faces, codepoints: faces.map(\.1), container: info.container)

        var document = WebDocument(module: .init("media-font"), data: payload,
                                   scripts: ["modules/media.common.js", "modules/media.fonts.js"],
                                   styles: ["modules/media.css"])
        document.resources = { path in resources.respond(path) }

        let first = faces[0].0
        var details: [String] = []
        if info.faces.count > 1 {
            details.append(MediaText.plural(info.faces.count, "face"))
            details.append(first.family)
        } else {
            details.append(first.fullName)
        }
        details.append(MediaText.plural(first.glyphs, "glyph"))
        if !first.axes.isEmpty { details.append(MediaText.plural(first.axes.count, "axis", "axes")) }
        if let size = file.sizeText { details.append(size) }
        let summary = FileSummary(symbol: "textformat", title: info.title, details: details, trailing: file.modifiedText)
        return .web(document, summary, NSSize(width: 1000, height: 800))
    }

    // MARK: - Describing a face

    static func describe(_ face: FontFaceInfo, codepoints: [Int]) -> Face {
        let covered = Set(codepoints)
        let icon = FontFaceInfo.isIconFont(codepoints)
        let scripts = FontScripts.scripts(in: codepoints)
        let primary = scripts.first ?? "Latin"
        let sample = chooseSample(face: face, covered: covered, codepoints: codepoints, primary: primary, icon: icon)
        let hero = chooseHero(covered: covered, codepoints: codepoints, primary: primary, icon: icon)

        let font = face.font
        let metrics = Face.Metrics(
            upm: face.unitsPerEm,
            ascender: Int(CTFontGetAscent(font).rounded()),
            descender: Int(CTFontGetDescent(font).rounded()),
            capHeight: face.os2.capHeight.flatMap { $0 > 0 ? $0 : nil } ?? Int(CTFontGetCapHeight(font).rounded()),
            xHeight: face.os2.xHeight.flatMap { $0 > 0 ? $0 : nil } ?? Int(CTFontGetXHeight(font).rounded()))

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none

        let languages = face.languages.prefix(1000).compactMap { Locale.current.localizedString(forIdentifier: $0) }
        return Face(
            family: face.family,
            style: face.style,
            fullName: face.fullName,
            postScriptName: face.postScriptName,
            version: face.version,
            designer: face.names[9],
            designerURL: webLink(face.names[12]),
            manufacturer: face.names[8],
            vendorURL: webLink(face.names[11]),
            license: face.names[13],
            licenseURL: webLink(face.names[14]),
            copyright: face.names[0],
            trademark: face.names[7],
            description: face.names[10],
            sample: sample,
            hero: hero,
            icon: icon,
            direction: ["Arabic", "Hebrew", "Syriac", "Thaana", "NKo"].contains(primary) ? "rtl" : "ltr",
            glyphs: face.glyphCount,
            characters: codepoints.count,
            metrics: metrics,
            weight: face.os2.weightClass,
            width: face.os2.widthClass,
            italic: face.isItalic,
            monospaced: face.isMonospaced,
            outlines: face.outlines,
            color: face.colorFormats,
            embedding: face.os2.embedding,
            vendor: face.os2.vendor,
            created: face.head.created.map(formatter.string),
            modified: face.head.modified.map(formatter.string),
            features: features(face, codepoints: codepoints, covered: covered, sample: sample),
            axes: face.variation.axes,
            instances: face.variation.instances,
            scripts: scripts,
            languages: Array(Set(languages)).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// Only http(s) links become links; anything else in a font's name table stays text.
    static func webLink(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, !value.contains(" ") else { return nil }
        if value.lowercased().hasPrefix("www.") { value = "https://" + value }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url.absoluteString
    }

    static let pangrams: [(script: String, text: String)] = [
        ("Latin", "The quick brown fox jumps over the lazy dog"),
        ("Greek", "Ταχίστη αλώπηξ βαφής ψημένη γη, δρασκελίζει υπέρ νωθρού κυνός"),
        ("Cyrillic", "Съешь же ещё этих мягких французских булок, да выпей чаю"),
        ("Hebrew", "דג סקרן שט בים מאוכזב ולפתע מצא חברה"),
        ("Arabic", "نص حكيم له سر قاطع وذو شأن عظيم مكتوب على ثوب أخضر"),
        ("Devanagari", "ऋषियों को सताने वाले दुष्ट राक्षसों के राजा रावण का सर्वनाश"),
        ("Thai", "เป็นมนุษย์สุดประเสริฐเลิศคุณค่า"),
        ("Hangul", "다람쥐 헌 쳇바퀴에 타고파"),
        ("Kana", "いろはにほへと ちりぬるを わかよたれそ"),
        ("Han", "天地玄黄 宇宙洪荒 日月盈昃 辰宿列张"),
        ("Armenian", "Բել դղյակի ձախ ժամն օֆ ազգությանը ցպահանջ"),
        ("Georgian", "ქართული ანბანი ოცდაცამეტი ასოსგან შედგება"),
    ]

    static let heroes: [String: String] = [
        "Latin": "Aa", "Greek": "Αα", "Cyrillic": "Бб", "Hebrew": "אב", "Arabic": "عر", "Devanagari": "अक",
        "Thai": "กข", "Hangul": "가나", "Kana": "あア", "Han": "永", "Armenian": "Աա", "Georgian": "აბ",
    ]

    private static func coverage(_ text: String, _ covered: Set<Int>) -> Double {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return 0 }
        return Double(scalars.filter { covered.contains(Int($0.value)) }.count) / Double(scalars.count)
    }

    static func chooseSample(face: FontFaceInfo, covered: Set<Int>, codepoints: [Int], primary: String, icon: Bool) -> String {
        if !icon, let own = face.names[19], own.count <= 200, coverage(own, covered) >= 0.98 { return own }
        if !icon {
            let ordered = pangrams.filter { $0.script == primary } + pangrams.filter { $0.script != primary }
            if let match = ordered.first(where: { coverage($0.text, covered) >= 0.98 }) { return match.text }
        }
        // Symbols, icons, emoji and scripts without a pangram: a run of the font's own characters.
        let pool = characterPool(codepoints, icon: icon)
        let separator = icon || pool.first.map(isPictograph) == true ? " " : ""
        return pool.prefix(icon ? 18 : 40).compactMap { Unicode.Scalar(UInt32($0)).map { String(Character($0)) } }.joined(separator: separator)
    }

    static func chooseHero(covered: Set<Int>, codepoints: [Int], primary: String, icon: Bool) -> String {
        if !icon, let hero = heroes[primary], coverage(hero, covered) == 1 { return hero }
        if !icon, coverage("Aa", covered) == 1 { return "Aa" }
        let pool = characterPool(codepoints, icon: icon)
        return String(String.UnicodeScalarView(pool.prefix(icon || pool.first.map(isPictograph) == true ? 3 : 2).compactMap { Unicode.Scalar(UInt32($0)) }))
    }

    private static func isPictograph(_ value: Int) -> Bool {
        (0x1F300...0x1FAFF).contains(value) || (0x2600...0x27BF).contains(value)
    }

    /// The characters that best show a font with no pangram: its icons, else its letters, else its
    /// pictographs (emoji fonts), else whatever it has.
    private static func characterPool(_ codepoints: [Int], icon: Bool) -> [Int] {
        let visible = codepoints.filter { value in
            guard let scalar = Unicode.Scalar(UInt32(value)) else { return false }
            return !scalar.properties.isWhitespace && scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .nonspacingMark
        }
        if icon {
            let privateUse = visible.filter { $0 >= 0xE000 }
            return privateUse.isEmpty ? visible : privateUse
        }
        let letters = visible.filter { Unicode.Scalar(UInt32($0))?.properties.isAlphabetic == true }
        if letters.count >= 10 { return letters }
        let pictographs = visible.filter(isPictograph)
        if pictographs.count >= 10 { return pictographs }
        return visible.isEmpty ? codepoints : visible
    }

    // MARK: - Features

    /// Features applied by default in text layout.
    static let defaultOn: Set<String> = ["liga", "clig", "calt", "kern", "rlig"]

    /// Shaping features a script needs to render at all: not choices a designer makes.
    static let shaping: Set<String> = [
        "abvf", "abvm", "abvs", "akhn", "blwf", "blwm", "blws", "ccmp", "cfar", "cjct", "curs", "dist", "dtls", "fin2", "fin3", "fina",
        "flac", "half", "haln", "init", "isol", "ljmo", "locl", "mark", "med2", "medi", "mkmk", "mset", "nukt", "pref", "pres", "pstf",
        "psts", "rclt", "rkrf", "rlig", "rphf", "rvrn", "size", "ssty", "stch", "tjmo", "vatu", "vjmo", "vert", "vrt2", "vrtr", "vkrn",
        "vpal", "vhal", "valt", "vkna", "lfbd", "rtbd", "opbd", "abrv", "rtlm", "ltra", "ltrm", "rtla", "aalt",
    ]

    static let featureNames: [String: String] = [
        "afrc": "Alternative Fractions", "c2pc": "Petite Capitals from Capitals", "c2sc": "Small Capitals from Capitals",
        "calt": "Contextual Alternates", "case": "Case-Sensitive Forms", "clig": "Contextual Ligatures", "cpct": "Centered CJK Punctuation",
        "cpsp": "Capital Spacing", "cswh": "Contextual Swash", "dlig": "Discretionary Ligatures", "dnom": "Denominators",
        "expt": "Expert Forms", "falt": "Final Glyph on Line Alternates", "frac": "Fractions", "fwid": "Full Widths",
        "halt": "Alternate Half Widths", "hist": "Historical Forms", "hkna": "Horizontal Kana Alternates", "hlig": "Historical Ligatures",
        "hngl": "Hangul", "hojo": "Hojo Kanji Forms", "hwid": "Half Widths", "ital": "Italics", "jalt": "Justification Alternates",
        "jp78": "JIS78 Forms", "jp83": "JIS83 Forms", "jp90": "JIS90 Forms", "jp04": "JIS2004 Forms", "kern": "Kerning",
        "liga": "Standard Ligatures", "lnum": "Lining Figures", "mgrk": "Mathematical Greek", "nalt": "Alternate Annotation Forms",
        "nlck": "NLC Kanji Forms", "numr": "Numerators", "onum": "Oldstyle Figures", "ordn": "Ordinals", "ornm": "Ornaments",
        "palt": "Proportional Alternate Widths", "pcap": "Petite Capitals", "pkna": "Proportional Kana", "pnum": "Proportional Figures",
        "pwid": "Proportional Widths", "qwid": "Quarter Widths", "rand": "Randomize", "ruby": "Ruby Notation Forms",
        "salt": "Stylistic Alternates", "sinf": "Scientific Inferiors", "smcp": "Small Capitals", "smpl": "Simplified Forms",
        "subs": "Subscript", "sups": "Superscript", "swsh": "Swash", "titl": "Titling", "tnam": "Traditional Name Forms",
        "tnum": "Tabular Figures", "trad": "Traditional Forms", "twid": "Third Widths", "unic": "Unicase", "zero": "Slashed Zero",
    ]

    /// Text that shows a feature off: what it changes is visible at a glance.
    static let demos: [String: String] = [
        "frac": "1/2 3/4", "afrc": "1/2 3/4", "numr": "12345", "dnom": "12345",
        "sups": "E=mc2", "subs": "H2O", "sinf": "C6H12O6", "ordn": "1a 2o No",
        "tnum": "1,111.18", "pnum": "1,111.18", "lnum": "0123456", "onum": "0123456",
        "zero": "0 2025", "smcp": "Small Caps", "c2sc": "SMALL CAPS", "pcap": "Petite Caps", "c2pc": "PETITE CAPS",
        "case": "(H) [H-H]", "cpsp": "CAPITALS", "kern": "AVA To Wa", "titl": "TITLING", "unic": "Unicase",
    ]

    static func featureName(_ tag: String, face: FontFaceInfo, uiNameID: Int?) -> String {
        if let id = uiNameID, let name = face.names[id] { return name }
        if tag.count == 4, tag.hasPrefix("ss"), let number = Int(tag.dropFirst(2)) { return "Stylistic Set \(number)" }
        if tag.count == 4, tag.hasPrefix("cv"), let number = Int(tag.dropFirst(2)) { return "Character Variant \(number)" }
        return featureNames[tag] ?? tag
    }

    static func features(_ face: FontFaceInfo, codepoints: [Int], covered: Set<Int>, sample: String) -> [Face.Feature] {
        var seen = Set<String>()
        var result: [Face.Feature] = []
        var reverse: [Int: Int]?
        let tables: [(FontTables.Layout, Bool)] = [face.substitutions.map { ($0, true) }, face.positioning.map { ($0, false) }].compactMap { $0 }
        for (table, isSubstitution) in tables {
            for feature in table.features where !shaping.contains(feature.tag) && seen.insert(feature.tag).inserted {
                let tag = feature.tag
                let known = featureNames[tag] != nil || tag.hasPrefix("ss") || tag.hasPrefix("cv")
                guard known else { continue }
                var demo = ""
                if let curated = demos[tag], coverage(curated, covered) >= 0.95 {
                    demo = curated
                } else if isSubstitution {
                    if reverse == nil { reverse = face.reverseMap(codepoints) }
                    let sequences = table.inputs(of: feature, limit: 48)
                    let words = sequences.compactMap { sequence -> String? in
                        let scalars = sequence.compactMap { reverse?[$0] }.compactMap { Unicode.Scalar(UInt32($0)) }
                        guard scalars.count == sequence.count else { return nil }
                        return String(String.UnicodeScalarView(scalars))
                    }
                    demo = orderedDemo(words)
                }
                if demo.isEmpty { demo = String(sample.prefix(40)) }
                result.append(Face.Feature(tag: tag, name: featureName(tag, face: face, uiNameID: feature.uiNameID),
                                           on: defaultOn.contains(tag), sample: demo))
                if result.count >= 120 { return result }
            }
        }
        return result.sorted { order($0.tag) < order($1.tag) }
    }

    /// Letters first (lowercase, then capitals), then figures and the rest; at most 14 words.
    private static func orderedDemo(_ words: [String]) -> String {
        func rank(_ word: String) -> Int {
            guard let scalar = word.unicodeScalars.first else { return 9 }
            if CharacterSet.lowercaseLetters.contains(scalar) { return scalar.value < 0x80 ? 0 : 2 }
            if CharacterSet.uppercaseLetters.contains(scalar) { return scalar.value < 0x80 ? 1 : 3 }
            if CharacterSet.decimalDigits.contains(scalar) { return 4 }
            return 5
        }
        let unique = Array(NSOrderedSet(array: words)) as? [String] ?? words
        // Short enough to show whole, off and on side by side.
        var picked: [String] = []
        var length = 0
        for word in unique.enumerated().sorted(by: { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }).map(\.element) {
            if !picked.isEmpty && length + word.count + 1 > 9 { break }
            picked.append(word)
            length += word.count + (picked.count > 1 ? 1 : 0)
        }
        return picked.joined(separator: " ")
    }

    /// Ligatures and alternates first, figures next, stylistic sets and variants in number order.
    private static func order(_ tag: String) -> String {
        let groups = ["kern": "0", "liga": "1", "clig": "1", "calt": "1", "dlig": "2", "hlig": "2", "swsh": "3", "cswh": "3", "salt": "3",
                      "smcp": "4", "c2sc": "4", "pcap": "4", "c2pc": "4", "unic": "4", "case": "4", "cpsp": "4", "titl": "4",
                      "lnum": "5", "onum": "5", "pnum": "5", "tnum": "5", "zero": "5", "frac": "5", "afrc": "5", "numr": "5",
                      "dnom": "5", "sups": "5", "subs": "5", "sinf": "5", "ordn": "5"]
        if let group = groups[tag] { return group + tag }
        if tag.hasPrefix("ss") { return "7" + tag }
        if tag.hasPrefix("cv") { return "8" + tag }
        return "6" + tag
    }
}

// MARK: - On-demand data

/// Serves each face's bytes, its character set by Unicode block, and details of one glyph.
final class FontResources: @unchecked Sendable {
    private let faces: [FontFaceInfo]
    private let codepoints: [[Int]]
    private let container: FontContainer

    init(faces: [FontFaceInfo], codepoints: [[Int]], container: FontContainer) {
        self.faces = faces
        self.codepoints = codepoints
        self.container = container
    }

    /// The most characters the glyph grid lays out.
    static let gridLimit = 12_000

    struct Section: Encodable { var name: String; var codepoints: [Int]; var names: [String?]? }
    struct Glyphs: Encodable { var sections: [Section]; var total: Int; var shown: Int }
    struct Detail: Encodable { var codepoint: Int; var name: String?; var glyph: String?; var id: Int?; var advance: Int? }

    func respond(_ path: String) -> (data: Data, mimeType: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let index = Int(parts[1]), faces.indices.contains(index) else { return nil }
        let face = faces[index]
        switch parts[0] {
        case "face":
            let type: String
            switch container {
            case .woff: type = "font/woff"
            case .woff2: type = "font/woff2"
            default: type = "font/otf"
            }
            return face.webData.map { ($0, type) }
        case "glyphs":
            let all = codepoints[index]
            let shown = Array(all.prefix(Self.gridLimit))
            let icon = FontFaceInfo.isIconFont(all)
            var sections: [Section] = []
            for (name, members) in FontScripts.group(shown) {
                let names: [String?]? = icon ? members.map { face.glyph(for: $0).flatMap(face.glyphName) } : nil
                sections.append(Section(name: name, codepoints: members, names: names))
            }
            return MediaJSON.response(Glyphs(sections: sections, total: all.count, shown: shown.count))
        case "glyph":
            guard parts.count == 3, let codepoint = Int(parts[2], radix: 16), let scalar = Unicode.Scalar(UInt32(codepoint)) else { return nil }
            let glyph = face.glyph(for: codepoint)
            let name = scalar.properties.name ?? scalar.properties.nameAlias
            return MediaJSON.response(Detail(codepoint: codepoint, name: name, glyph: glyph.flatMap(face.glyphName),
                                             id: glyph.map(Int.init), advance: glyph.map(face.advance)))
        default:
            return nil
        }
    }
}
