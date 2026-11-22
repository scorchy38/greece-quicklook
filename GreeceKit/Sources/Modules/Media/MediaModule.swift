import AppKit

/// Fonts, subtitles, SVG, Lottie animations and colour palettes: the files designers and video
/// people pass around, each with a purpose-built preview and a native Finder thumbnail.
enum MediaModule: PreviewModule {
    static let id = "media"

    static func claims(_ file: FileInfo) -> Bool {
        MediaFormat.detect(file) != nil
    }

    static func prepare(_ file: FileInfo, settings: PreviewSettings) throws -> PreparedPreview {
        guard let format = MediaFormat.detect(file) else { throw PreviewError.unsupported }
        switch format {
        case .font: return try FontPreview.prepare(file)
        case .subtitles(let kind): return try SubtitlePreview.prepare(file, format: kind)
        case .svg(let compressed): return try SVGPreview.prepare(file, compressed: compressed)
        case .lottie(let packaged): return try LottiePreview.prepare(file, packaged: packaged)
        case .palette(let kind): return try PalettePreview.prepare(file, format: kind)
        }
    }

    static func thumbnail(_ file: FileInfo, size: CGSize, settings: PreviewSettings) -> ThumbnailPage? {
        guard let format = MediaFormat.detect(file) else { return nil }
        switch format {
        case .font: return FontThumbnail.make(file, size: size)
        case .subtitles(let kind): return SubtitleThumbnail.make(file, format: kind, size: size)
        case .svg(let compressed): return SVGThumbnail.make(file, compressed: compressed, size: size)
        case .lottie(let packaged): return LottieThumbnail.make(file, packaged: packaged, size: size)
        case .palette(let kind): return PaletteThumbnail.make(file, format: kind, size: size)
        }
    }
}

/// What a media file is, decided from its extension and first bytes.
enum MediaFormat: Equatable {
    case font
    case subtitles(SubtitleFormat)
    case svg(compressed: Bool)
    case lottie(packaged: Bool)
    case palette(PaletteFormat)

    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]

    static func detect(_ file: FileInfo) -> MediaFormat? {
        guard !file.isDirectory else { return nil }
        let probe = file.probe
        let ext = file.ext

        if FontContainer.sniff(probe.bytes) != nil, fontExtensions.contains(ext) || probe.hasPrefix(Array("wOF".utf8)) {
            return .font
        }

        switch ext {
        case "svg":
            return probe.isText && SVGPreview.looksLikeSVG(probe.text) ? .svg(compressed: false) : nil
        case "svgz":
            return probe.hasPrefix([0x1F, 0x8B]) ? .svg(compressed: true) : nil
        case "lottie":
            return probe.hasPrefix([0x50, 0x4B, 0x03, 0x04]) ? .lottie(packaged: true) : nil
        case "json":
            return LottiePreview.looksLikeLottie(probe.bytes) ? .lottie(packaged: false) : nil
        default:
            break
        }

        if let palette = PaletteFormat.detect(ext: ext, probe: probe) { return .palette(palette) }
        if let subtitles = SubtitleFormat.detect(ext: ext, probe: probe) { return .subtitles(subtitles) }
        return nil
    }
}

// MARK: - Shared helpers

enum MediaLimits {
    /// The most of any one file a preview reads.
    static let fileBytes = 96 * 1024 * 1024
    /// XML documents that declare entities are refused: subtitles and SVG never need them,
    /// and they are how "billion laughs" files blow up a parser.
    static func declaresEntities(_ data: Data) -> Bool {
        data.range(of: Data("<!ENTITY".utf8)) != nil
    }
}

extension FileInfo {
    /// The whole file, refusing anything over `limit`.
    func mediaData(limit: Int = MediaLimits.fileBytes) throws -> Data {
        if let size = fileSize, size > limit { throw MediaError.tooLarge(size) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.count > limit { throw MediaError.tooLarge(data.count) }
        return data
    }
}

enum MediaError: LocalizedError {
    case tooLarge(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let size):
            return "This file is too large to preview (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
        case .unreadable(let reason):
            return reason
        }
    }
}

enum MediaText {
    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count.formatted()) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// "1:02:03" or "2:03", for durations in milliseconds.
    static func clock(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1000
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Encodes a module payload for `greece://module/…` responses.
enum MediaJSON {
    static func response<T: Encodable>(_ value: T) -> (data: Data, mimeType: String)? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (data, "application/json; charset=utf-8")
    }
}
