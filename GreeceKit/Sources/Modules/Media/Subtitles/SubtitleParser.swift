import Foundation

enum SubtitleFormat: String, Codable, CaseIterable {
    case srt, webvtt, ass, ssa, sami, ttml, sbv, microdvd, lrc

    var title: String {
        switch self {
        case .srt: return "SubRip Subtitles"
        case .webvtt: return "WebVTT Subtitles"
        case .ass: return "Advanced SubStation Subtitles"
        case .ssa: return "SubStation Alpha Subtitles"
        case .sami: return "SAMI Captions"
        case .ttml: return "TTML Captions"
        case .sbv: return "YouTube Captions"
        case .microdvd: return "MicroDVD Subtitles"
        case .lrc: return "Lyrics"
        }
    }

    var badge: String {
        switch self {
        case .srt: return "SRT"
        case .webvtt: return "VTT"
        case .ass: return "ASS"
        case .ssa: return "SSA"
        case .sami: return "SAMI"
        case .ttml: return "TTML"
        case .sbv: return "SBV"
        case .microdvd: return "SUB"
        case .lrc: return "LRC"
        }
    }

    /// Decided by extension, then confirmed by content: `.sub` is also VobSub, `.xml` is anything.
    static func detect(ext: String, probe: FileProbe) -> SubtitleFormat? {
        let candidates: [String: SubtitleFormat] = [
            "srt": .srt, "vtt": .webvtt, "ass": .ass, "ssa": .ssa, "smi": .sami, "sami": .sami,
            "ttml": .ttml, "dfxp": .ttml, "sbv": .sbv, "sub": .microdvd, "lrc": .lrc, "xml": .ttml,
        ]
        guard let format = candidates[ext], probe.isText else { return nil }
        let text = TextFile.decode(Data(probe.bytes)).0
        return format.confirms(text) ? format : nil
    }

    func confirms(_ head: String) -> Bool {
        let lower = head.lowercased()
        switch self {
        case .srt: return head.contains("-->")
        case .webvtt: return head.drop(while: { $0 == "\u{FEFF}" }).hasPrefix("WEBVTT")
        case .ass, .ssa: return lower.contains("[script info]") || lower.contains("[events]")
        case .sami: return lower.contains("<sami")
        case .ttml: return lower.contains("<tt") && (lower.contains("http://www.w3.org/ns/ttml") || lower.contains("http://www.w3.org/2006/10/ttaf1") || lower.contains("http://www.w3.org/2006/04/ttaf1"))
        case .sbv: return head.range(of: #"(?m)^\d+:\d{2}:\d{2}\.\d{1,3},\d+:\d{2}:\d{2}\.\d{1,3}\s*$"#, options: .regularExpression) != nil
        case .microdvd:
            let first = head.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return first.map { String($0).range(of: #"^\s*\{\d+\}\{\d*\}"#, options: .regularExpression) != nil } ?? false
        case .lrc: return head.range(of: #"(?m)^\s*\[\d{1,3}:\d{1,2}([.:]\d{1,3})?\]"#, options: .regularExpression) != nil
        }
    }
}

/// One timed caption, in milliseconds.
struct SubtitleCue: Encodable, Equatable {
    /// A run of text with formatting: 1 italic, 2 bold, 4 underline.
    struct Span: Encodable, Equatable { var t: String; var f: Int }
    var start: Int
    var end: Int
    var text: String
    var spans: [Span]?
    var speaker: String?
    var style: String?
    var id: String?
    /// Filled in by `SubtitleChecks`: reading speed and what to look at again.
    var cps: Double?
    var flags = 0

    enum CodingKeys: String, CodingKey { case start = "s", end = "e", text = "t", spans = "r", speaker = "p", style = "y", id = "i", cps = "c", flags = "f" }
}

struct SubtitleDocument {
    var format: SubtitleFormat
    var cues: [SubtitleCue] = []
    var title: String?
    var languages: [String] = []
    var metadata: [(String, String)] = []
    /// Style name → colour, for ASS/SSA and TTML styles.
    var styleColors: [String: String] = [:]
    var frameRate: Double?
    var truncated = false
}

enum SubtitleParser {
    static let cueLimit = 100_000
    static let lineLimit = 2_000_000

    static func parse(_ text: String, format: SubtitleFormat) -> SubtitleDocument {
        var document = SubtitleDocument(format: format)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        switch format {
        case .srt, .webvtt, .sbv: parseBlocks(normalized, into: &document)
        case .ass, .ssa: parseSubStation(normalized, into: &document)
        case .sami: parseSAMI(normalized, into: &document)
        case .ttml: TTMLParser.parse(normalized, into: &document)
        case .microdvd: parseMicroDVD(normalized, into: &document)
        case .lrc: parseLRC(normalized, into: &document)
        }
        if document.cues.count >= cueLimit { document.truncated = true }
        return document
    }

    // MARK: - Times

    /// "01:02:03,456", "1:02:03.45", "02:03.456", "3.5": hours optional, any fraction length.
    static func clock(_ raw: Substring) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.count <= 20 else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts.dropLast() {
            guard let number = Int(part), number >= 0, number < 100_000 else { return nil }
            total = total * 60 + number
        }
        let last = parts.last!.replacingOccurrences(of: ",", with: ".")
        let pieces = last.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), let seconds = Int(pieces[0]), seconds >= 0, seconds < 100_000 else { return nil }
        var milliseconds = 0
        if pieces.count == 2 {
            let digits = String(pieces[1].prefix(3))
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let fraction = Int(digits) else { return nil }
            milliseconds = fraction * [100, 10, 1][digits.count - 1]
        }
        return (total * 60 + seconds) * 1000 + milliseconds
    }

    // MARK: - SRT, WebVTT, SBV

    private static func timing(_ line: Substring, format: SubtitleFormat) -> (Int, Int)? {
        if format == .sbv {
            let parts = line.split(separator: ",")
            guard parts.count == 2, let start = clock(parts[0]), let end = clock(parts[1]) else { return nil }
            return (start, end)
        }
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound]
        // WebVTT settings and SRT coordinates follow the end time.
        let right = line[arrow.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
        guard let start = clock(left), let end = clock(right) else { return nil }
        return (start, end)
    }

    private static func parseBlocks(_ text: String, into document: inout SubtitleDocument) {
        let format = document.format
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineLimit)
        var index = lines.startIndex
        if format == .webvtt, let header = lines.first, header.hasPrefix("WEBVTT") {
            let title = header.dropFirst(6).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-")))
            if !title.isEmpty { document.title = title }
            // Header metadata ("Kind: captions", "Language: en") runs to the first blank line.
            index += 1
            while index < lines.endIndex, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let line = lines[index]
                if !line.contains("-->"), let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if key.lowercased() == "language", !value.isEmpty { document.languages.append(value) }
                    else if !key.isEmpty, !value.isEmpty { document.metadata.append((key, value)) }
                } else if line.contains("-->") { break }
                index += 1
            }
        }
        var previousBlank = true
        while index < lines.endIndex, document.cues.count < cueLimit {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if format == .webvtt, previousBlank, trimmed.hasPrefix("NOTE") || trimmed == "STYLE" || trimmed == "REGION" {
                // Comment and style blocks run to the next blank line.
                while index < lines.endIndex, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
                continue
            }
            guard let (start, end) = timing(line, format: format) else {
                previousBlank = trimmed.isEmpty
                index += 1
                continue
            }
            var identifier: String?
            if index > lines.startIndex {
                let before = lines[index - 1].trimmingCharacters(in: .whitespaces)
                if !before.isEmpty, !before.contains("-->"), before.count <= 64 { identifier = before }
            }
            var body: [Substring] = []
            index += 1
            while index < lines.endIndex {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if timing(next, format: format) != nil { break }
                // A missing blank line before the next numbered cue.
                if format == .srt, index + 1 < lines.endIndex, Int(next.trimmingCharacters(in: .whitespaces)) != nil,
                   timing(lines[index + 1], format: format) != nil { break }
                body.append(next)
                index += 1
            }
            var cue = SubtitleMarkup.cue(body.joined(separator: "\n"), start: start, end: end)
            cue.id = identifier
            document.cues.append(cue)
            previousBlank = false
        }
    }

    // MARK: - SubStation Alpha

    private static func parseSubStation(_ text: String, into document: inout SubtitleDocument) {
        var section = ""
        var eventFields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var styleFields = ["name", "fontname", "fontsize", "primarycolour"]
        for raw in text.split(separator: "\n").prefix(lineLimit) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { section = line.lowercased(); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "[script info]":
                if key == "title", !value.isEmpty, value != "<untitled>" { document.title = value }
                else if ["original script", "original translation", "original timing", "script updated by"].contains(key), !value.isEmpty {
                    document.metadata.append((String(line[..<colon]), value))
                }
            case "[v4+ styles]", "[v4 styles]", "[v4 styles+]":
                if key == "format" {
                    styleFields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if key == "style" {
                    let fields = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    if let nameIndex = styleFields.firstIndex(of: "name"), nameIndex < fields.count,
                       let colourIndex = styleFields.firstIndex(of: "primarycolour"), colourIndex < fields.count,
                       let colour = assColor(fields[colourIndex]) {
                        document.styleColors[fields[nameIndex]] = colour
                    }
                }
            case "[events]":
                if key == "format" {
                    eventFields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if key == "dialogue", document.cues.count < cueLimit {
                    // The last field (Text) keeps its commas.
                    let fields = value.split(separator: ",", maxSplits: max(eventFields.count - 1, 0), omittingEmptySubsequences: false)
                        .map { String($0) }
                    func field(_ name: String) -> String? {
                        guard let at = eventFields.firstIndex(of: name), at < fields.count else { return nil }
                        return fields[at]
                    }
                    guard let start = field("start").flatMap({ clock(Substring($0)) }), let end = field("end").flatMap({ clock(Substring($0)) }) else { continue }
                    var cue = SubtitleMarkup.subStationCue(field("text") ?? "", start: start, end: end)
                    let style = field("style")?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
                    cue.style = style?.isEmpty == false && style != "Default" ? style : nil
                    let name = field("name")?.trimmingCharacters(in: .whitespaces) ?? ""
                    cue.speaker = name.isEmpty ? nil : name
                    if cue.text.isEmpty { continue }
                    document.cues.append(cue)
                }
            default:
                continue
            }
        }
    }

    /// "&H00FFFFFF" (AABBGGRR) or a decimal BGR value → "#rrggbb".
    static func assColor(_ value: String) -> String? {
        var raw = value.uppercased().replacingOccurrences(of: "&H", with: "").replacingOccurrences(of: "&", with: "")
        var number: UInt64
        if value.uppercased().hasPrefix("&H") {
            guard !raw.isEmpty, raw.count <= 8, let parsed = UInt64(raw, radix: 16) else { return nil }
            number = parsed
        } else {
            raw = value.trimmingCharacters(in: .whitespaces)
            guard let parsed = Int64(raw) else { return nil }
            number = UInt64(UInt32(truncatingIfNeeded: parsed))
        }
        let red = number & 0xFF, green = (number >> 8) & 0xFF, blue = (number >> 16) & 0xFF
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    // MARK: - SAMI

    private static func parseSAMI(_ text: String, into document: inout SubtitleDocument) {
        let source = text as NSString
        // Languages declared in the style sheet: .ENCC { Name: English; lang: en-US; }
        if let style = try? NSRegularExpression(pattern: #"\.(\w+)\s*\{([^}]*)\}"#, options: []) {
            for match in style.matches(in: text, range: NSRange(location: 0, length: min(source.length, 64 * 1024))).prefix(32) {
                let body = source.substring(with: match.range(at: 2))
                if let name = body.range(of: #"(?i)name\s*:\s*([^;]+)"#, options: .regularExpression) {
                    let value = body[name].split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !value.isEmpty, !document.languages.contains(value) { document.languages.append(value) }
                }
            }
        }
        guard let sync = try? NSRegularExpression(pattern: #"<sync\b[^>]*?start\s*=\s*["']?(\d+)[^>]*>"#, options: [.caseInsensitive]) else { return }
        if let title = text.range(of: #"(?i)<title>([^<]{1,200})</title>"#, options: .regularExpression) {
            let value = SubtitleMarkup.cue(String(text[title]).replacingOccurrences(of: #"(?i)</?title>"#, with: "", options: .regularExpression), start: 0, end: 0).text
            if !value.isEmpty { document.title = value }
        }
        let matches = sync.matches(in: text, range: NSRange(location: 0, length: source.length))
        var pending: (start: Int, body: String)?
        func close(at end: Int) {
            guard let open = pending else { return }
            pending = nil
            var cue = SubtitleMarkup.cue(open.body, start: open.start, end: max(end, open.start))
            cue.text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cue.text.isEmpty, document.cues.count < cueLimit { document.cues.append(cue) }
        }
        for (position, match) in matches.enumerated() {
            guard let start = Int(source.substring(with: match.range(at: 1))) else { continue }
            let bodyStart = match.range.location + match.range.length
            let bodyEnd = position + 1 < matches.count ? matches[position + 1].range.location : source.length
            var body = source.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)))
            if let bodyClose = body.range(of: "</body", options: .caseInsensitive) { body = String(body[..<bodyClose.lowerBound]) }
            // Several languages share one SYNC: keep the first paragraph.
            let paragraphs = body.components(separatedBy: "<P").count > 2 ? firstParagraph(body) : body
            close(at: start)
            let plain = paragraphs.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pending = (start, paragraphs.replacingOccurrences(of: "\n", with: " "))
            }
        }
        close(at: (pending?.start ?? 0) + 4000)
    }

    private static func firstParagraph(_ body: String) -> String {
        let parts = body.components(separatedBy: "<P")
        return parts.count > 1 ? "<P" + parts[1] : body
    }

    // MARK: - MicroDVD

    private static func parseMicroDVD(_ text: String, into document: inout SubtitleDocument) {
        var fps = 23.976
        var declared = false
        guard let pattern = try? NSRegularExpression(pattern: #"^\{(\d+)\}\{(\d*)\}(.*)$"#) else { return }
        var cues: [(Int, Int?, String)] = []
        for raw in text.split(separator: "\n").prefix(lineLimit) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let start = Int(ns.substring(with: match.range(at: 1))) else { continue }
            let end = Int(ns.substring(with: match.range(at: 2)))
            let body = ns.substring(with: match.range(at: 3))
            if cues.isEmpty, !declared, start <= 1, let rate = Double(body.trimmingCharacters(in: .whitespaces)), rate > 1, rate < 241 {
                fps = rate
                declared = true
                continue
            }
            cues.append((start, end, body))
            if cues.count >= cueLimit { break }
        }
        document.frameRate = fps
        for (position, item) in cues.enumerated() {
            let start = Int(Double(item.0) / fps * 1000)
            let nextStart = position + 1 < cues.count ? Int(Double(cues[position + 1].0) / fps * 1000) : start + 3000
            let end = item.1.map { Int(Double($0) / fps * 1000) } ?? nextStart
            var flags = 0
            let lines = item.2.split(separator: "|", omittingEmptySubsequences: false).map { line -> String in
                var line = String(line)
                if line.lowercased().contains("{y:i}") { flags |= 1 }
                if line.lowercased().contains("{y:b}") { flags |= 2 }
                if line.lowercased().contains("{y:u}") { flags |= 4 }
                line = line.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                if line.hasPrefix("/") { flags |= 1; line.removeFirst() }
                return line
            }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            document.cues.append(SubtitleCue(start: start, end: end, text: text, spans: flags != 0 ? [.init(t: text, f: flags)] : nil))
        }
    }

    // MARK: - LRC

    /// "mm:ss", "mm:ss.xx" or "mm:ss:xx".
    static func lrcTime(_ tag: Substring) -> Int? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false).flatMap { $0.split(separator: ".", omittingEmptySubsequences: false) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }),
              let minutes = Int(parts[0]), let seconds = Int(parts[1]), seconds < 60 else { return nil }
        var milliseconds = 0
        if parts.count == 3, let fraction = Int(parts[2]) { milliseconds = fraction * [100, 10, 1][parts[2].count - 1] }
        return (minutes * 60 + seconds) * 1000 + milliseconds
    }

    private static func parseLRC(_ text: String, into document: inout SubtitleDocument) {
        var offset = 0
        var length: Int?
        var lines: [(Int, String)] = []
        let names = ["ti": "Title", "ar": "Artist", "al": "Album", "au": "Author", "by": "Lyrics by", "re": "Created with", "ve": "Version"]
        for raw in text.split(separator: "\n").prefix(lineLimit) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var times: [Int] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let time = lrcTime(tag) {
                    times.append(time)
                } else if let colon = tag.firstIndex(of: ":") {
                    let key = tag[..<colon].lowercased(), value = tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if key == "offset" { offset = Int(value) ?? 0 }
                    else if key == "length" { length = clock(Substring(value)) }
                    else if key == "ti", !value.isEmpty { document.title = value }
                    else if let name = names[key], !value.isEmpty { document.metadata.append((name, value)) }
                }
            }
            guard !times.isEmpty else { continue }
            // Enhanced LRC times each word: <00:12.34>.
            let words = rest.replacingOccurrences(of: #"<\d+:\d+(\.\d+)?>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            for time in times { lines.append((max(0, time - offset), words)) }
            if lines.count >= cueLimit { break }
        }
        lines.sort { $0.0 < $1.0 }
        for (position, line) in lines.enumerated() where !line.1.isEmpty {
            let end = position + 1 < lines.count ? lines[position + 1].0 : max(length ?? 0, line.0 + 4000)
            document.cues.append(SubtitleCue(start: line.0, end: max(end, line.0), text: line.1))
        }
    }
}

// MARK: - Inline markup

/// Turns cue markup into plain text plus formatting runs. Everything else (classes, voices' tags,
/// fonts, karaoke timings) is dropped; the text itself is always kept as text, never as HTML.
enum SubtitleMarkup {
    static func cue(_ raw: String, start: Int, end: Int) -> SubtitleCue {
        var spans: [SubtitleCue.Span] = []
        var flags = 0
        var speaker: String?
        var buffer = ""
        var formatted = false

        func flush() {
            guard !buffer.isEmpty else { return }
            if let last = spans.last, last.f == flags { spans[spans.count - 1].t += buffer } else { spans.append(.init(t: buffer, f: flags)) }
            buffer = ""
        }

        // SRT files often carry SubStation positioning ({\an8}); drop it.
        let source = raw.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "<", let close = source[index...].firstIndex(of: ">"), source.distance(from: index, to: close) < 200 {
                let tag = source[source.index(after: index)..<close].trimmingCharacters(in: .whitespaces)
                let closing = tag.hasPrefix("/")
                let name = tag.drop(while: { $0 == "/" }).prefix { $0.isLetter }.lowercased()
                let bit = ["i": 1, "em": 1, "b": 2, "strong": 2, "u": 4][name] ?? 0
                if bit != 0 {
                    flush()
                    flags = closing ? flags & ~bit : flags | bit
                    formatted = true
                } else if name == "br" {
                    buffer += "\n"
                } else if name == "v", !closing {
                    // <v Speaker> or <v.loud Speaker>
                    let voice = tag.drop { $0 != " " && $0 != "\t" }.trimmingCharacters(in: .whitespaces)
                    if !voice.isEmpty, speaker == nil { speaker = String(voice.prefix(80)) }
                } else if name.isEmpty, tag.first?.isNumber == true {
                    // A karaoke timestamp: <00:00:01.000>
                }
                index = source.index(after: close)
                continue
            }
            if character == "&", let semicolon = source[index...].prefix(10).firstIndex(of: ";") {
                let entity = String(source[source.index(after: index)..<semicolon])
                if let decoded = decodeEntity(entity) {
                    buffer += decoded
                    index = source.index(after: semicolon)
                    continue
                }
            }
            buffer.append(character)
            index = source.index(after: index)
        }
        flush()
        let text = spans.map(\.t).joined()
            .split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFormatting = formatted && spans.contains { $0.f != 0 }
        return SubtitleCue(start: start, end: end, text: text, spans: hasFormatting ? trim(spans) : nil, speaker: speaker)
    }

    /// SubStation text: {\i1}…{\i0} overrides, \N line breaks, \h hard spaces, {\p1} drawings.
    static func subStationCue(_ raw: String, start: Int, end: Int) -> SubtitleCue {
        var spans: [SubtitleCue.Span] = []
        var flags = 0
        var drawing = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            if let last = spans.last, last.f == flags { spans[spans.count - 1].t += buffer } else { spans.append(.init(t: buffer, f: flags)) }
            buffer = ""
        }
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "{", let close = raw[index...].firstIndex(of: "}") {
                let block = raw[raw.index(after: index)..<close]
                for code in block.split(separator: "\\").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    func toggle(_ bit: Int, _ value: Substring) {
                        flush()
                        // \b also takes a weight (\b700): anything but 0 turns it on.
                        flags = Int(value).map { $0 != 0 } ?? true ? flags | bit : flags & ~bit
                    }
                    if code.hasPrefix("i"), code.count == 2 { toggle(1, code.dropFirst()) }
                    else if code.hasPrefix("b"), code.count >= 2, Int(code.dropFirst()) != nil { toggle(2, code.dropFirst()) }
                    else if code.hasPrefix("u"), code.count == 2 { toggle(4, code.dropFirst()) }
                    else if code == "r" { flush(); flags = 0 }
                    else if code.hasPrefix("p"), let level = Int(code.dropFirst()) { drawing = level > 0 }
                }
                index = raw.index(after: close)
                continue
            }
            if character == "\\", raw.index(after: index) < raw.endIndex {
                let next = raw[raw.index(after: index)]
                if next == "N" || next == "n" { if !drawing { buffer += "\n" }; index = raw.index(index, offsetBy: 2); continue }
                if next == "h" { if !drawing { buffer += "\u{00A0}" }; index = raw.index(index, offsetBy: 2); continue }
            }
            if !drawing { buffer.append(character) }
            index = raw.index(after: index)
        }
        flush()
        let text = spans.map(\.t).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return SubtitleCue(start: start, end: end, text: text, spans: spans.contains { $0.f != 0 } ? trim(spans) : nil)
    }

    private static func trim(_ spans: [SubtitleCue.Span]) -> [SubtitleCue.Span] {
        var spans = spans
        while let first = spans.first, first.t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spans.removeFirst() }
        while let last = spans.last, last.t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spans.removeLast() }
        if !spans.isEmpty {
            spans[0].t = String(spans[0].t.drop { $0.isWhitespace })
            spans[spans.count - 1].t = String(spans[spans.count - 1].t.reversed().drop { $0.isWhitespace }.reversed())
        }
        return spans
    }

    static func decodeEntity(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        case "lrm": return "\u{200E}"
        case "rlm": return "\u{200F}"
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let value = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) { return String(scalar) }
            if entity.hasPrefix("#"), let value = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(value) { return String(scalar) }
            return nil
        }
    }
}
