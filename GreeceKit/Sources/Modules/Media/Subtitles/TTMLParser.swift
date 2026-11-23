import Foundation

/// TTML and DFXP (and the IMSC, SMPTE-TT and EBU-TT profiles built on them): timed `<p>` paragraphs
/// whose times are relative to their parents, styled spans, line breaks and named speakers.
final class TTMLParser: NSObject, XMLParserDelegate {
    static func parse(_ text: String, into document: inout SubtitleDocument) {
        let data = Data(text.utf8)
        // Captions never need entity declarations; documents that have them are refused outright.
        guard !MediaLimits.declaresEntities(data) else { return }
        let delegate = TTMLParser(document: document)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        parser.parse()
        delegate.finish()
        document = delegate.document
    }

    private var document: SubtitleDocument
    private var frameRate = 30.0
    private var subFrameRate = 1.0
    private var tickRate = 1.0
    private var styles: [String: (flags: Int, color: String?)] = [:]
    private var agents: [String: String] = [:]
    private var currentAgent: String?
    private var inAgentName = false
    private var agentName = ""
    private var titleText: String?

    /// Each open element's begin and end, absolute, in milliseconds.
    private struct Scope { var begin: Int; var end: Int?; var flags: Int }
    private var scopes: [Scope] = [Scope(begin: 0, end: nil, flags: 0)]
    private var depth = 0

    private struct Paragraph { var start: Int; var end: Int?; var speaker: String?; var style: String?; var spans: [SubtitleCue.Span] }
    private var paragraph: Paragraph?
    private var paragraphDepth = 0

    private init(document: SubtitleDocument) {
        self.document = document
    }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func attribute(_ attributes: [String: String], _ name: String) -> String? {
        if let value = attributes[name] { return value }
        return attributes.first { local($0.key) == name }?.value
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        guard depth < 64, document.cues.count < SubtitleParser.cueLimit else { parser.abortParsing(); return }
        let name = Self.local(elementName)
        switch name {
        case "tt":
            if let rate = attributes.first(where: { Self.local($0.key) == "frameRate" }).flatMap({ Double($0.value) }), rate > 0, rate < 1000 { frameRate = rate }
            if let multiplier = attributes.first(where: { Self.local($0.key) == "frameRateMultiplier" })?.value {
                let parts = multiplier.split(separator: " ").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0 { frameRate *= parts[0] / parts[1] }
            }
            if let rate = attributes.first(where: { Self.local($0.key) == "subFrameRate" }).flatMap({ Double($0.value) }), rate > 0 { subFrameRate = rate }
            if let rate = attributes.first(where: { Self.local($0.key) == "tickRate" }).flatMap({ Double($0.value) }), rate > 0 { tickRate = rate }
            if let language = Self.attribute(attributes, "lang"), !language.isEmpty { document.languages.append(language) }
        case "style":
            if let id = Self.attribute(attributes, "id") {
                styles[id] = (Self.flags(attributes, inherited: 0), Self.attribute(attributes, "color").flatMap(Self.cssColor))
            }
        case "agent":
            currentAgent = Self.attribute(attributes, "id")
        case "title" where paragraph == nil && document.title == nil:
            titleText = ""
        case "name" where currentAgent != nil:
            inAgentName = true
            agentName = ""
        default:
            break
        }

        let parent = scopes.last!
        var begin = parent.begin
        if let value = Self.attribute(attributes, "begin"), let offset = time(value) { begin = parent.begin + offset }
        var end = parent.end
        if let value = Self.attribute(attributes, "end"), let offset = time(value) { end = min(parent.begin + offset, parent.end ?? .max) }
        if let value = Self.attribute(attributes, "dur"), let duration = time(value) { end = min(begin + duration, end ?? .max) }
        var flags = parent.flags
        if let reference = Self.attribute(attributes, "style") {
            for id in reference.split(separator: " ") { flags |= styles[String(id)]?.flags ?? 0 }
        }
        flags = Self.flags(attributes, inherited: flags)
        scopes.append(Scope(begin: begin, end: end, flags: flags))

        if name == "p", paragraph == nil {
            let speaker = Self.attribute(attributes, "agent").map { agents[$0] ?? $0 }
            let style = Self.attribute(attributes, "style")?.split(separator: " ").first.map(String.init)
            paragraph = Paragraph(start: begin, end: end, speaker: speaker, style: style, spans: [])
            paragraphDepth = depth
        } else if name == "br", paragraph != nil {
            append("\n", flags: flags)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = Self.local(elementName)
        if name == "name", inAgentName, let agent = currentAgent {
            agents[agent] = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
            inAgentName = false
        } else if name == "agent" {
            currentAgent = nil
        } else if name == "title", let title = titleText {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { document.title = String(trimmed.prefix(200)) }
            titleText = nil
        }
        if name == "p", depth == paragraphDepth, let open = paragraph {
            paragraph = nil
            let text = open.spans.map(\.t).joined()
                .split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let formatted = open.spans.contains { $0.f != 0 }
                document.cues.append(SubtitleCue(start: open.start, end: open.end ?? open.start + 3000, text: text,
                                                 spans: formatted ? open.spans : nil, speaker: open.speaker, style: open.style))
            }
        }
        if scopes.count > 1 { scopes.removeLast() }
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inAgentName { agentName += string; return }
        if titleText != nil { titleText! += string; return }
        guard paragraph != nil else { return }
        // XML whitespace inside a paragraph collapses to single spaces.
        let collapsed = string.replacingOccurrences(of: #"[ \t\n]+"#, with: " ", options: .regularExpression)
        append(collapsed, flags: scopes.last?.flags ?? 0)
    }

    private func append(_ text: String, flags: Int) {
        guard !text.isEmpty else { return }
        if let last = paragraph?.spans.last, last.f == flags {
            paragraph!.spans[paragraph!.spans.count - 1].t += text
        } else {
            paragraph?.spans.append(.init(t: text, f: flags))
        }
    }

    fileprivate func finish() {
        for (id, style) in styles {
            if let color = style.color { document.styleColors[id] = color }
        }
        document.cues.sort { $0.start < $1.start }
    }

    private static func flags(_ attributes: [String: String], inherited: Int) -> Int {
        var flags = inherited
        if let style = attribute(attributes, "fontStyle") { flags = style == "italic" || style == "oblique" ? flags | 1 : flags & ~1 }
        if let weight = attribute(attributes, "fontWeight") { flags = weight == "bold" ? flags | 2 : flags & ~2 }
        if let decoration = attribute(attributes, "textDecoration") { flags = decoration.contains("underline") ? flags | 4 : flags & ~4 }
        return flags
    }

    private static func cssColor(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$"#, options: .regularExpression) != nil else { return nil }
        return String(trimmed.prefix(7)).lowercased()
    }

    /// Clock times ("00:01:02.5", "00:01:02:12" with frames) and offsets ("12.5s", "500ms", "30f", "1000t").
    private func time(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            if parts.count == 4, let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Int(parts[2]) {
                let frameParts = parts[3].split(separator: ".")
                let frames = Double(frameParts[0]) ?? 0
                let sub = frameParts.count > 1 ? (Double(frameParts[1]) ?? 0) / subFrameRate : 0
                return Int((Double(hours * 3600 + minutes * 60 + seconds) + (frames + sub) / frameRate) * 1000)
            }
            return SubtitleParser.clock(Substring(trimmed))
        }
        let units: [(String, Double)] = [("ms", 1), ("h", 3_600_000), ("m", 60_000), ("s", 1000), ("f", 1000 / frameRate), ("t", 1000 / tickRate)]
        for (unit, scale) in units where trimmed.hasSuffix(unit) {
            guard let number = Double(trimmed.dropLast(unit.count)), number.isFinite, number >= 0, number < 1e9 else { return nil }
            return Int(number * scale)
        }
        return nil
    }
}
