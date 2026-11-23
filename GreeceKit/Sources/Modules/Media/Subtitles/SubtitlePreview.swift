import AppKit

/// Reading-speed and layout checks, after the guidelines streaming services publish
/// (20 characters a second, 42 characters a line, two lines, 5/6 s to 7 s on screen).
enum SubtitleChecks {
    static let maxCPS = 20.0
    static let maxLineLength = 42
    static let maxLines = 2
    static let minDuration = 833
    static let maxDuration = 7000

    struct Flag: OptionSet {
        let rawValue: Int
        static let fast = Flag(rawValue: 1)
        static let longLine = Flag(rawValue: 2)
        static let brief = Flag(rawValue: 4)
        static let lingering = Flag(rawValue: 8)
        static let overlap = Flag(rawValue: 16)
        static let manyLines = Flag(rawValue: 32)
        static let badTiming = Flag(rawValue: 64)
    }

    struct Stats: Encodable {
        var cues = 0
        var start = 0
        var end = 0
        var averageCPS: Double?
        var fast = 0
        var longLines = 0
        var brief = 0
        var lingering = 0
        var overlaps = 0
        var manyLines = 0
        var badTiming = 0
        var speakers = 0
        var flagged = 0
    }

    static func appliesChecks(_ format: SubtitleFormat) -> Bool { format != .lrc }

    static func analyze(_ document: inout SubtitleDocument) -> Stats {
        var stats = Stats()
        let checks = appliesChecks(document.format)
        // Layered formats show several lines at once on purpose.
        let overlapsMatter = ![.ass, .ssa, .ttml, .lrc].contains(document.format)
        var characters = 0
        var spoken = 0
        var latestEnd: Int?
        var speakers = Set<String>()
        for index in document.cues.indices {
            var cue = document.cues[index]
            let duration = cue.end - cue.start
            let lines = cue.text.split(separator: "\n", omittingEmptySubsequences: false)
            let count = lines.reduce(0) { $0 + $1.count }
            if duration > 0 {
                cue.cps = (Double(count) / (Double(duration) / 1000) * 10).rounded() / 10
                characters += count
                spoken += duration
            }
            if let speaker = cue.speaker { speakers.insert(speaker) }
            var flags = Flag()
            if checks {
                if let cps = cue.cps, cps > maxCPS { flags.insert(.fast); stats.fast += 1 }
                if lines.contains(where: { $0.count > maxLineLength }) { flags.insert(.longLine); stats.longLines += 1 }
                if lines.count > maxLines { flags.insert(.manyLines); stats.manyLines += 1 }
                if duration <= 0 { flags.insert(.badTiming); stats.badTiming += 1 }
                else if duration < minDuration { flags.insert(.brief); stats.brief += 1 }
                else if duration > maxDuration { flags.insert(.lingering); stats.lingering += 1 }
                if overlapsMatter, let latestEnd, cue.start < latestEnd { flags.insert(.overlap); stats.overlaps += 1 }
            }
            if !flags.isEmpty { stats.flagged += 1 }
            cue.flags = flags.rawValue
            latestEnd = max(latestEnd ?? cue.end, cue.end)
            document.cues[index] = cue
        }
        stats.cues = document.cues.count
        stats.start = document.cues.map(\.start).min() ?? 0
        stats.end = document.cues.map(\.end).max() ?? 0
        stats.averageCPS = spoken > 0 ? (Double(characters) / (Double(spoken) / 1000) * 10).rounded() / 10 : nil
        stats.speakers = speakers.count
        return stats
    }
}

enum SubtitlePreview {
    struct Payload: Encodable {
        var format: String
        var kind: String
        var title: String?
        var languages: [String]
        var metadata: [[String]]
        var frameRate: Double?
        var truncated: Bool
        var checks: Bool
        var styleColors: [String: String]
        var stats: SubtitleChecks.Stats
        var limits: [String: Double]
    }

    static func load(_ file: FileInfo, format: SubtitleFormat) throws -> SubtitleDocument {
        let text = try TextFile(url: file.url, limit: 32 * 1024 * 1024)
        var document = SubtitleParser.parse(text.text, format: format)
        if text.truncated { document.truncated = true }
        return document
    }

    static func prepare(_ file: FileInfo, format: SubtitleFormat) throws -> PreparedPreview {
        var document = try load(file, format: format)
        let stats = SubtitleChecks.analyze(&document)
        // Language codes ("en", "pt-BR") read better as names; names written out stay as they are.
        let languages = document.languages.map { language -> String in
            guard language.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else { return language }
            return Locale.current.localizedString(forIdentifier: language) ?? language
        }
        let payload = Payload(
            format: format.badge, kind: format.title, title: document.title, languages: languages,
            metadata: document.metadata.prefix(12).map { [$0.0, $0.1] }, frameRate: document.frameRate,
            truncated: document.truncated, checks: SubtitleChecks.appliesChecks(format), styleColors: document.styleColors,
            stats: stats,
            limits: ["cps": SubtitleChecks.maxCPS, "line": Double(SubtitleChecks.maxLineLength), "lines": Double(SubtitleChecks.maxLines),
                     "min": Double(SubtitleChecks.minDuration), "max": Double(SubtitleChecks.maxDuration)])
        let cues = (try? JSONEncoder().encode(document.cues)) ?? Data("[]".utf8)

        var web = WebDocument(module: .init("media-subtitles"), data: payload,
                              scripts: ["modules/media.common.js", "modules/media.subtitles.js"], styles: ["modules/media.css"])
        web.resources = { path in path == "cues.json" ? (cues, "application/json; charset=utf-8") : nil }

        var details = [format == .lrc
            ? String(localized: "\(stats.cues) lines", bundle: .greeceKit, comment: "Info bar detail: how many lines a text file, or a song’s lyrics, has")
            : String(localized: "\(stats.cues) cues", bundle: .greeceKit, comment: "Info bar detail: how many cues (subtitles shown at once) a subtitle file has")]
        if stats.end > 0 { details.append(MediaText.clock(stats.end)) }
        if SubtitleChecks.appliesChecks(format), let cps = stats.averageCPS {
            let speed = cps.formatted(.number.precision(.fractionLength(0...1)))
            details.append(String(localized: "\(speed) cps average", bundle: .greeceKit,
                                  comment: "Info bar detail: subtitles’ average reading speed in characters per second, such as “14.2 cps average”"))
            if stats.fast > 0 {
                details.append(String(localized: "\(stats.fast) too fast", bundle: .greeceKit,
                                      comment: "Info bar detail: how many subtitles go by too fast to read, such as “2 too fast”"))
            }
        }
        if let language = document.languages.first { details.append(Locale.current.localizedString(forIdentifier: language) ?? language) }
        if document.truncated {
            details.append(String(localized: "Showing first %lld [cues]", defaultValue: "Showing first \(document.cues.count)", bundle: .greeceKit,
                                  comment: "Info bar detail: only the first subtitles of a very long file are shown. The argument is how many"))
        }
        let summary = FileSummary(symbol: format == .lrc ? "music.note.list" : "captions.bubble", title: format.title, details: details, trailing: file.modifiedText)
        return .web(web, summary, NSSize(width: 960, height: 760))
    }
}

/// A page of the first cues: timestamps in the margin, the words beside them.
enum SubtitleThumbnail {
    static func make(_ file: FileInfo, format: SubtitleFormat, size: CGSize) -> ThumbnailPage? {
        guard let text = try? TextFile(url: file.url, limit: 256 * 1024) else { return nil }
        let document = SubtitleParser.parse(text.text, format: format)
        guard !document.cues.isEmpty else { return nil }
        let cues = Array(document.cues.prefix(24))
        let pageSize = Thumbnailer.pageSize(fitting: size)
        return ThumbnailPage(size: pageSize, badge: format.badge) { rect in
            NSColor.white.setFill()
            rect.fill()
            let padding = rect.width * 0.085
            let body = max(rect.width / 21, 1)
            let timeFont = NSFont.monospacedDigitSystemFont(ofSize: body * 0.72, weight: .medium)
            let textFont = NSFont.systemFont(ofSize: body)
            let italic = NSFontManager.shared.convert(textFont, toHaveTrait: .italicFontMask)
            let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            let secondary = NSColor(srgbRed: 0.0, green: 0.48, blue: 1, alpha: 0.85)
            let hairline = NSColor(white: 0, alpha: 0.08)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.lineHeightMultiple = 1.1

            var top = rect.maxY - padding
            for cue in cues {
                let lines = cue.text.split(separator: "\n").prefix(2).map(String.init)
                let lineHeight = body * 1.3
                let blockHeight = body * 0.95 + CGFloat(lines.count) * lineHeight + body * 0.55
                guard top - blockHeight > rect.minY + padding * 0.5 else { break }
                let time = NSAttributedString(string: clock(cue.start), attributes: [.font: timeFont, .foregroundColor: secondary])
                time.draw(at: CGPoint(x: rect.minX + padding, y: top - body * 0.85))
                var y = top - body * 0.95
                let isItalic = cue.spans?.allSatisfy { $0.f & 1 != 0 } ?? false
                for line in lines {
                    let attributed = NSAttributedString(string: line, attributes: [.font: isItalic ? italic : textFont, .foregroundColor: ink, .paragraphStyle: style])
                    attributed.draw(with: CGRect(x: rect.minX + padding, y: y - lineHeight, width: rect.width - padding * 2, height: lineHeight),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                    y -= lineHeight
                }
                top -= blockHeight
                hairline.setFill()
                CGRect(x: rect.minX + padding, y: top + body * 0.28, width: rect.width - padding * 2, height: max(rect.width / 600, 0.5)).fill()
            }
        }
    }

    private static func clock(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
