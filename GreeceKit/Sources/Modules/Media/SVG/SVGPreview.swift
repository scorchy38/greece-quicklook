import AppKit

/// SVG and SVGZ, always drawn as an image (`<img>` from greece://module), never as markup in the
/// page, so nothing in the file can run. Fit to the window, zoom and pan, 1:1, a transparency
/// checkerboard, and the highlighted source.
enum SVGPreview {
    static let decompressedLimit = 64 * 1024 * 1024

    static func looksLikeSVG(_ head: String) -> Bool {
        head.range(of: #"<(\w+:)?svg[\s>]"#, options: .regularExpression) != nil
    }

    struct Info: Encodable, Equatable {
        var width: Double
        var height: Double
        /// The root element's own width and height, as written ("100%", "24px", "12mm").
        var widthText: String?
        var heightText: String?
        var viewBox: [Double]?
        var elements = 0
        var hasScripts = false
        var hasExternalReferences = false
        var hasRasterImages = false
        var hasText = false
        var compressed = false
        var bytes = 0
        var title: String?
    }

    /// The SVG's markup: decompressed for SVGZ, never more than `decompressedLimit`.
    static func load(_ file: FileInfo, compressed: Bool) throws -> Data {
        let raw = try file.mediaData(limit: compressed ? 32 * 1024 * 1024 : decompressedLimit)
        guard compressed else { return raw }
        guard let inflated = MediaInflate.inflate(raw, windowBits: 15 + 32, limit: decompressedLimit) else {
            throw MediaError.unreadable("This compressed SVG is damaged or too large to expand.")
        }
        return inflated
    }

    // MARK: - Reading the root element

    static func inspect(_ data: Data) -> Info {
        let head = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
        var info = Info(width: 300, height: 150)
        info.bytes = data.count
        let attributes = rootAttributes(head)
        let viewBox = attributes["viewBox"].flatMap(parseViewBox)
        info.viewBox = viewBox
        info.widthText = attributes["width"]
        info.heightText = attributes["height"]
        let width = attributes["width"].flatMap(length)
        let height = attributes["height"].flatMap(length)
        // The same rules browsers use for an image's natural size.
        switch (width, height, viewBox) {
        case let (w?, h?, _): (info.width, info.height) = (w, h)
        case let (w?, nil, box?) where box[2] > 0: (info.width, info.height) = (w, w * box[3] / box[2])
        case let (nil, h?, box?) where box[3] > 0: (info.width, info.height) = (h * box[2] / box[3], h)
        case let (nil, nil, box?) where box[2] > 0 && box[3] > 0: (info.width, info.height) = (box[2], box[3])
        case let (w?, nil, _): info.width = w
        case let (nil, h?, _): info.height = h
        default: break
        }
        if !(info.width.isFinite && info.width > 0) { info.width = 300 }
        if !(info.height.isFinite && info.height > 0) { info.height = 150 }

        let sample = String(decoding: data.prefix(4 * 1024 * 1024), as: UTF8.self)
        info.elements = count(#"<[A-Za-z]"#, in: sample)
        info.hasScripts = sample.range(of: #"<(\w+:)?script\b|\son[a-zA-Z]+\s*=|javascript:"#, options: [.regularExpression, .caseInsensitive]) != nil
        info.hasExternalReferences = sample.range(of: #"(href|src)\s*=\s*["']\s*(https?:|//|file:)"#, options: [.regularExpression, .caseInsensitive]) != nil
        info.hasRasterImages = sample.range(of: #"<(\w+:)?image\b"#, options: .regularExpression) != nil
        info.hasText = sample.range(of: #"<(\w+:)?text\b"#, options: .regularExpression) != nil
        if let title = sample.range(of: #"<title[^>]*>([^<]{1,200})</title>"#, options: .regularExpression) {
            let inner = sample[title].replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { info.title = inner }
        }
        return info
    }

    /// Attributes of the first `<svg>` element, read without an XML parser (no entities, no DTDs).
    static func rootAttributes(_ head: String) -> [String: String] {
        guard let open = head.range(of: #"<(\w+:)?svg[\s>/]"#, options: .regularExpression) else { return [:] }
        var tag = ""
        var quote: Character?
        for character in head[open.lowerBound...].dropFirst() {
            if let active = quote { if character == active { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == ">" { break }
            tag.append(character)
            if tag.count > 16_384 { break }
        }
        var result: [String: String] = [:]
        guard let pattern = try? NSRegularExpression(pattern: #"([A-Za-z_][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return [:] }
        let ns = tag as NSString
        for match in pattern.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            if result[name] == nil { result[name] = ns.substring(with: valueRange).trimmingCharacters(in: .whitespaces) }
        }
        return result
    }

    static func parseViewBox(_ value: String) -> [Double]? {
        let numbers = value.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" }).compactMap { Double($0) }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { return nil }
        return numbers
    }

    /// An absolute length in CSS pixels; percentages and nonsense are nil.
    static func length(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("px", 1), ("pt", 4.0 / 3), ("pc", 16), ("mm", 96 / 25.4), ("cm", 96 / 2.54), ("in", 96), ("em", 16), ("ex", 8)]
        for (unit, scale) in units where trimmed.hasSuffix(unit) {
            guard let number = Double(trimmed.dropLast(unit.count).trimmingCharacters(in: .whitespaces)), number.isFinite, number > 0 else { return nil }
            return min(number * scale, 1_000_000)
        }
        guard !trimmed.hasSuffix("%"), let number = Double(trimmed), number.isFinite, number > 0 else { return nil }
        return min(number, 1_000_000)
    }

    private static func count(_ pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 0
    }

    static func format(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    // MARK: - Preview

    static func prepare(_ file: FileInfo, compressed: Bool) throws -> PreparedPreview {
        let data = try load(file, compressed: compressed)
        var info = inspect(data)
        info.compressed = compressed

        var document = WebDocument(module: .init("media-svg"), data: info,
                                   scripts: ["modules/media.common.js", "modules/media.svg.js"], styles: ["modules/media.css"])
        document.resources = { path in
            switch path {
            case "image.svg": return (data, "image/svg+xml")
            case "source.txt": return (data.prefix(8 * 1024 * 1024), "text/plain; charset=utf-8")
            default: return nil
            }
        }

        var details = ["\(format(info.width)) × \(format(info.height))"]
        if let box = info.viewBox { details.append("viewBox " + box.map(format).joined(separator: " ")) }
        if info.elements > 0 { details.append(MediaText.plural(info.elements, "element")) }
        if let size = file.sizeText { details.append(compressed ? "\(size), \(MediaText.size(data.count)) expanded" : size) }
        let summary = FileSummary(symbol: "square.on.circle", title: compressed ? "SVGZ Image" : "SVG Image", details: details, trailing: file.modifiedText)
        return .web(document, summary, NSSize(width: 900, height: 720))
    }
}

/// The image itself, drawn by AppKit's own SVG renderer (CoreSVG), the way Finder shows SVG,
/// which also gives compressed SVGZ files a real thumbnail.
enum SVGThumbnail {
    static func make(_ file: FileInfo, compressed: Bool, size: CGSize) -> ThumbnailPage? {
        guard let data = try? SVGPreview.load(file, compressed: compressed), data.count <= 16 * 1024 * 1024,
              !MediaLimits.declaresEntities(data), let image = NSImage(data: data) else { return nil }
        let info = SVGPreview.inspect(data)
        let aspect = info.width / info.height
        guard aspect.isFinite, aspect > 0 else { return nil }
        var target = size
        if aspect >= 1 { target.height = max(1, (size.width / aspect).rounded()) } else { target.width = max(1, (size.height * aspect).rounded()) }
        return ThumbnailPage(size: target, badge: compressed ? "SVGZ" : "SVG") { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
    }
}
