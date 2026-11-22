import Foundation

// MARK: - AsciiDoc

/// The common AsciiDoc subset as Markdown: header, sections, lists, admonitions, delimited
/// blocks, tables, inline formatting, attributes and cross references.
enum AsciiDocConverter {
    static let defaultAttributes: [String: String] = ["nbsp": "\u{00A0}", "zwsp": "", "amp": "&", "lt": "<", "gt": ">", "plus": "+", "startsb": "[", "endsb": "]", "vbar": "|", "caret": "^", "asterisk": "*", "tilde": "~", "apostrophe": "'", "backtick": "`", "empty": "", "sp": " ", "two-colons": "::", "quot": "\"", "deg": "°"]

    static func convert(_ source: String, inherited: [String: String] = [:]) -> ProseDocument {
        var doc = ProseDocument(format: "AsciiDoc")
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var attributes: [String: String] = inherited.isEmpty ? defaultAttributes : inherited
        var i = 0

        // Header: = Title, author line, revision line, attributes.
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty || lines[i].hasPrefix("//") { i += 1 }
        if i < lines.count, lines[i].hasPrefix("= ") {
            doc.title = String(lines[i].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            i += 1
            var headerLine = 0
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                let line = lines[i]
                if let attribute = attributeEntry(line) { attributes[attribute.0] = attribute.1; apply(attribute, to: &doc) }
                else if line.hasPrefix("//") {}
                else if headerLine == 0 {
                    doc.authors = line.components(separatedBy: ";").map { $0.replacingOccurrences(of: #"\s*<[^>]*>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    headerLine += 1
                } else if headerLine == 1 {
                    let parts = line.components(separatedBy: ":")
                    let revision = parts[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if let version = revision.first, !version.isEmpty { doc.meta.append(["Version", version.hasPrefix("v") ? String(version.dropFirst()) : version]) }
                    if revision.count > 1 { doc.date = revision[1] }
                    if parts.count > 1 { doc.meta.append(["Revision", parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)]) }
                    headerLine += 1
                }
                i += 1
            }
        }
        if let title = doc.title { doc.title = substitute(title, attributes) }

        var out: [String] = []
        var pendingTitle: String?
        var pendingAttributes: String?
        var pendingAnchor: String?
        var listOpen = false

        func inline(_ s: String) -> String { AsciiDocInline.convert(substitute(s, attributes)) }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { out.append(""); listOpen = false; i += 1; continue }
            if line.hasPrefix("//") && !line.hasPrefix("////") { i += 1; continue }
            if let attribute = attributeEntry(raw) { attributes[attribute.0] = attribute.1; i += 1; continue }

            // Block metadata lines.
            if line.hasPrefix("[[") && line.hasSuffix("]]") { pendingAnchor = String(line.dropFirst(2).dropLast(2)).components(separatedBy: ",").first; i += 1; continue }
            if line.hasPrefix("[") && line.hasSuffix("]") && !line.hasPrefix("[[") && !line.contains("](") {
                let inner = String(line.dropFirst().dropLast())
                if inner.hasPrefix("#") { pendingAnchor = String(inner.dropFirst()).components(separatedBy: CharacterSet(charactersIn: ".%,")).first }
                else { pendingAttributes = inner }
                i += 1
                continue
            }
            if line.hasPrefix("."), line.count > 1, !line.hasPrefix(".."), !line.hasPrefix(". "), line.dropFirst().first?.isWhitespace == false {
                pendingTitle = inline(String(line.dropFirst()))
                i += 1
                continue
            }

            // Delimited blocks.
            if let delimiter = blockDelimiter(line) {
                let (body, next) = collect(lines, from: i + 1, until: line)
                i = next
                let attrs = pendingAttributes ?? ""
                let style = attrs.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                pendingAttributes = nil
                var block = ""
                switch delimiter {
                case "----", "```":
                    var language = ""
                    let parts = attrs.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.first == "source" || parts.first == "listing", parts.count > 1 { language = parts[1] }
                    else if line.hasPrefix("```") { language = String(line.dropFirst(3)) }
                    let code = body.map { $0.replacingOccurrences(of: #"\s*<\d+>\s*$"#, with: "", options: .regularExpression) }.joined(separator: "\n")
                    block = MD.fence(substituteIfNeeded(code, attributes, attrs), language: language)
                case "....":
                    block = MD.fence(body.joined(separator: "\n"), language: "text")
                case "____":
                    let quote = convert(body.joined(separator: "\n"), inherited: attributes).markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    var q = quote.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
                    let parts = attrs.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                    if parts.first == "quote" || parts.first == "verse", parts.count > 1 {
                        q.append(">")
                        q.append("> — " + inline(parts[1]) + (parts.count > 2 ? ", *" + inline(parts[2]) + "*" : ""))
                    }
                    block = q.joined(separator: "\n")
                case "****":
                    let inner = convert(body.joined(separator: "\n"), inherited: attributes).markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    block = "<aside class=\"sidebar\">\n\n" + (pendingTitle.map { "**\($0)**\n\n" } ?? "") + inner + "\n\n</aside>"
                    pendingTitle = nil
                case "====":
                    let inner = convert(body.joined(separator: "\n"), inherited: attributes).markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    if MD.alertKinds[style] != nil { block = MD.alert(style, title: pendingTitle, body: inner); pendingTitle = nil }
                    else { block = "<div class=\"example\">\n\n" + (pendingTitle.map { "**\($0)**\n\n" } ?? "") + inner + "\n\n</div>"; pendingTitle = nil }
                case "--":
                    let inner = convert(body.joined(separator: "\n"), inherited: attributes).markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    block = MD.alertKinds[style] != nil ? MD.alert(style, title: nil, body: inner) : inner
                case "|===", ",===", ":===", "!===":
                    block = table(body, attributes: attrs, separator: delimiter.first == "," ? "," : delimiter.first == ":" ? ":" : delimiter.first == "!" ? "!" : "|", inline: inline)
                case "////", "++++":
                    block = ""
                default:
                    block = body.joined(separator: "\n")
                }
                if let title = pendingTitle {
                    out.append("<p class=\"block-title\">\(title)</p>")
                    out.append("")
                    pendingTitle = nil
                }
                out.append(block)
                out.append("")
                continue
            }

            // Sections.
            if let level = sectionLevel(line) {
                let title = String(line.drop { $0 == "=" || $0 == "#" }).trimmingCharacters(in: .whitespaces)
                let depth = min(6, level + 1)
                out.append("")
                if let anchor = pendingAnchor { out.append("<a id=\"\(MD.html(anchor))\"></a>"); out.append(""); pendingAnchor = nil }
                out.append(String(repeating: "#", count: depth) + " " + inline(title))
                out.append("")
                i += 1
                continue
            }

            // Admonition paragraphs: NOTE: text
            if let m = line.range(of: #"^(NOTE|TIP|IMPORTANT|WARNING|CAUTION):\s+"#, options: .regularExpression) {
                let kind = line[m].prefix { $0 != ":" }.lowercased()
                var body = [String(line[m.upperBound...])]
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { body.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1 }
                out.append(MD.alert(kind, title: nil, body: inline(body.joined(separator: " "))))
                out.append("")
                continue
            }

            // Block images.
            if line.hasPrefix("image::"), let open = line.firstIndex(of: "[") {
                let path = substitute(String(line[line.index(line.startIndex, offsetBy: 7)..<open]), attributes)
                let alt = line[line.index(after: open)...].dropLast().components(separatedBy: ",").first ?? ""
                out.append("![\(MD.escape(alt.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))))](\(MD.url(path) ?? ""))")
                if let title = pendingTitle { out.append(""); out.append("<p class=\"figure-caption\">\(title)</p>"); pendingTitle = nil }
                out.append("")
                i += 1
                continue
            }
            if line.hasPrefix("toc::[]") || line == "<<<" { i += 1; continue }
            if line == "'''" || line == "---" || line == "***" { out.append("\n---\n"); i += 1; continue }
            if line.hasPrefix("include::") { out.append(MD.chips(["Included: " + String(line.dropFirst(9).prefix { $0 != "[" })])); out.append(""); i += 1; continue }

            // Lists.
            if let item = listItem(line) {
                if !listOpen { out.append("") }
                listOpen = true
                let pad = String(repeating: "    ", count: item.depth)
                var content = item.content
                var box = ""
                if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") || content.hasPrefix("[*] ") { box = "[x] "; content = String(content.dropFirst(4)); doc.tasks.done += 1 }
                else if content.hasPrefix("[ ] ") { box = "[ ] "; content = String(content.dropFirst(4)); doc.tasks.open += 1 }
                var text = [content]
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || listItem(next) != nil || blockDelimiter(next) != nil || next == "+" || sectionLevel(next) != nil || descriptionItem(next) != nil { break }
                    text.append(next)
                    i += 1
                }
                if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) == "+" { i += 1 }
                out.append(pad + (item.ordered ? "1. " : "- ") + box + inline(text.joined(separator: " ")))
                continue
            }
            if let item = descriptionItem(line) {
                var definition = item.definition
                i += 1
                if definition.isEmpty {
                    var parts: [String] = []
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, descriptionItem(lines[i].trimmingCharacters(in: .whitespaces)) == nil {
                        parts.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
                    }
                    definition = parts.joined(separator: " ")
                    if let first = parts.first, listItem(first) != nil {
                        definition = parts.compactMap { listItem($0).map { "• " + $0.content } }.joined(separator: "<br>")
                    }
                }
                let pad = String(repeating: "    ", count: item.depth)
                out.append(pad + "- **\(inline(item.term))** — \(inline(definition))")
                listOpen = true
                continue
            }

            // Literal paragraph: indented text.
            if raw.hasPrefix(" ") && !listOpen {
                var body: [String] = []
                while i < lines.count, lines[i].hasPrefix(" "), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { body.append(lines[i]); i += 1 }
                out.append(MD.fence(body.map { String($0.dropFirst()) }.joined(separator: "\n"), language: "text"))
                out.append("")
                continue
            }

            // Paragraph.
            var paragraph: [String] = []
            while i < lines.count {
                let next = lines[i].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || blockDelimiter(next) != nil || sectionLevel(next) != nil || (paragraph.count > 0 && (listItem(next) != nil || next.hasPrefix("["))) { break }
                if next.hasPrefix("//") { i += 1; continue }
                paragraph.append(next)
                i += 1
            }
            // Convert as one piece (footnotes and links can span lines); " +" ends a line.
            paragraph = inline(paragraph.joined(separator: "\u{1}")).components(separatedBy: "\u{1}").map { $0.hasSuffix(" +") ? String($0.dropLast(2)) + "<br>" : $0 }
            if let anchor = pendingAnchor { out.append("<a id=\"\(MD.html(anchor))\"></a>"); pendingAnchor = nil }
            if let title = pendingTitle { out.append("**\(title)**"); out.append(""); pendingTitle = nil }
            if pendingAttributes != nil { pendingAttributes = nil }
            out.append(paragraph.joined(separator: "\n"))
            listOpen = false
        }
        doc.markdown = out.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return doc
    }

    private static func apply(_ attribute: (String, String), to doc: inout ProseDocument) {
        switch attribute.0 {
        case "description": doc.abstract = attribute.1
        case "keywords": doc.meta.append(["Keywords", attribute.1])
        case "revnumber": doc.meta.append(["Version", attribute.1])
        case "revdate": doc.date = attribute.1
        case "author": if doc.authors.isEmpty { doc.authors = [attribute.1] }
        default: break
        }
    }

    static func attributeEntry(_ line: String) -> (String, String)? {
        guard line.hasPrefix(":"), let m = line.range(of: #"^:([\w-]+!?):\s*(.*)$"#, options: .regularExpression) else { return nil }
        let body = line[m].dropFirst()
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let name = String(body[..<colon]).replacingOccurrences(of: "!", with: "")
        let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    static func substitute(_ text: String, _ attributes: [String: String]) -> String {
        guard text.contains("{") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}"), rest.distance(from: open, to: close) < 60 else { out += rest[open...]; return out }
            let name = String(rest[rest.index(after: open)..<close])
            if let value = attributes[name] { out += value } else { out += rest[open...close] }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    private static func substituteIfNeeded(_ code: String, _ attributes: [String: String], _ attrs: String) -> String {
        attrs.contains("subs=") && attrs.contains("attributes") ? substitute(code, attributes) : code
    }

    static func blockDelimiter(_ line: String) -> String? {
        for d in ["----", "....", "____", "****", "====", "////", "++++", "|===", ",===", ":===", "!==="] where line.count >= 4 && line.hasPrefix(d) {
            let char = d.first!
            if d.hasSuffix("===") && d.count == 4 && d.first != "=" { return line == d || line.allSatisfy({ $0 == char || $0 == "=" }) ? d : nil }
            return line.allSatisfy({ $0 == char }) ? d : nil
        }
        if line == "--" { return "--" }
        if line.hasPrefix("```") { return "```" }
        return nil
    }

    static func collect(_ lines: [String], from start: Int, until delimiter: String) -> ([String], Int) {
        var body: [String] = []
        var i = start
        let close = delimiter.hasPrefix("```") ? "```" : delimiter
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == close { return (body, i + 1) }
            body.append(lines[i])
            i += 1
        }
        return (body, i)
    }

    static func sectionLevel(_ line: String) -> Int? {
        let marker = line.first == "#" ? "#" : "="
        let count = line.prefix { String($0) == marker }.count
        guard count >= 2 || (count == 1 && marker == "#"), count <= 6, line.count > count, line[line.index(line.startIndex, offsetBy: count)] == " " else { return nil }
        return marker == "#" ? count : count - 1
    }

    static func listItem(_ line: String) -> (depth: Int, ordered: Bool, content: String)? {
        if let m = line.range(of: #"^(\*{1,5}|-)\s+"#, options: .regularExpression) {
            let marker = line[m].trimmingCharacters(in: .whitespaces)
            return (marker == "-" ? 0 : marker.count - 1, false, String(line[m.upperBound...]))
        }
        if let m = line.range(of: #"^(\.{1,5})\s+"#, options: .regularExpression) {
            return (line[m].trimmingCharacters(in: .whitespaces).count - 1, true, String(line[m.upperBound...]))
        }
        if let m = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return (0, true, String(line[m.upperBound...]))
        }
        return nil
    }

    static func descriptionItem(_ line: String) -> (depth: Int, term: String, definition: String)? {
        guard let m = line.range(of: #"^(.+?)(:{2,4}|;;)(\s+(.*))?$"#, options: .regularExpression), !line.hasPrefix("//"), !line.contains("://") || line.range(of: #"^[^:]+::(\s|$)"#, options: .regularExpression) != nil else { return nil }
        let text = String(line[m])
        guard let sep = text.range(of: #"(:{2,4}|;;)(\s|$)"#, options: .regularExpression) else { return nil }
        let term = String(text[..<sep.lowerBound])
        let marker = text[sep].trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !term.hasPrefix("image"), !term.hasPrefix("include"), !term.hasPrefix("toc") else { return nil }
        let definition = String(text[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (marker == ";;" ? 1 : max(0, marker.count - 2), term, definition)
    }

    private static func table(_ body: [String], attributes: String, separator: Character, inline: (String) -> String) -> String {
        var cells: [String] = []
        var firstLineCells = 0
        var headerByBlank = false
        var sawFirstLine = false
        for (index, raw) in body.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if sawFirstLine && index > 0 && cells.count == firstLineCells && !headerByBlank { headerByBlank = true }; continue }
            if line.first == separator || line.range(of: #"^[\d.*+]*[<^>]?[\d.*+]*[a-z]?\|"#, options: .regularExpression) != nil {
                let parts = line.split(separator: separator, omittingEmptySubsequences: false).dropFirst()
                let rowCells = parts.map { cell -> String in
                    var t = cell.trimmingCharacters(in: .whitespaces)
                    // A cell spec (2+, 3*, ^, .2+, a) for the next cell ends this segment.
                    t = t.replacingOccurrences(of: #"(^|\s)(\d+[+*]|\.\d+\+|\d+\.\d+\+)?[<^>]?(\.[<^>])?(?<=[\d+*<^>])[aehlmdsv]?$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                    return t
                }
                if !sawFirstLine { firstLineCells = rowCells.count; sawFirstLine = true }
                cells += rowCells
            } else if !cells.isEmpty {
                cells[cells.count - 1] += " " + line
            }
        }
        var columns = firstLineCells
        if let cols = attributes.range(of: #"cols\s*=\s*"([^"]*)""#, options: .regularExpression) {
            let spec = attributes[cols].drop { $0 != "\"" }.dropFirst().dropLast()
            let parts = spec.split(separator: ",")
            if parts.count == 1, let n = Int(parts[0].prefix { $0.isNumber }), parts[0].contains("*") { columns = n }
            else if !parts.isEmpty { columns = parts.count }
        }
        guard columns > 0 else { return "" }
        var rows: [[String]] = []
        var k = 0
        while k < cells.count {
            rows.append(Array(cells[k..<min(k + columns, cells.count)]).map { inline($0) })
            k += columns
        }
        let header = attributes.contains("header") || headerByBlank
        if header, let first = rows.first { return MD.table(header: first, rows: Array(rows.dropFirst())) }
        return MD.table(header: nil, rows: rows)
    }
}

enum AsciiDocInline {
    static func convert(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var plain = ""
        var i = 0
        func flush() { out += MD.escape(plain); plain = "" }
        func spanEnd(_ marker: Character, from start: Int, double: Bool) -> Int? {
            var j = start
            while j < chars.count {
                if chars[j] == marker {
                    if double { if j + 1 < chars.count, chars[j + 1] == marker { return j } }
                    else if !chars[j - 1].isWhitespace, j + 1 == chars.count || !(chars[j + 1].isLetter || chars[j + 1].isNumber) { return j }
                }
                j += 1
            }
            return nil
        }
        func macro(_ name: String) -> (target: String, body: String, end: Int)? {
            let n = Array(name)
            guard i + n.count <= chars.count, Array(chars[i..<(i + n.count)]) == n else { return nil }
            guard let open = chars[(i + n.count)...].firstIndex(of: "["), open - i < 400, let close = chars[open...].firstIndex(of: "]") else { return nil }
            let target = String(chars[(i + n.count)..<open])
            guard !target.contains(" ") else { return nil }
            return (target, String(chars[(open + 1)..<close]), close + 1)
        }
        while i < chars.count {
            let c = chars[i]
            let atWordStart = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)
            // Macros.
            if c.isLetter, atWordStart {
                if let m = macro("link:") {
                    flush(); out += MD.link(m.body.isEmpty ? MD.escape(m.target) : convert(m.body.components(separatedBy: ",").first ?? ""), m.target); i = m.end; continue
                }
                if let m = macro("xref:") { flush(); out += "[\(m.body.isEmpty ? MD.escape(m.target) : convert(m.body))](#\(m.target.replacingOccurrences(of: "#", with: "")))"; i = m.end; continue }
                if let m = macro("image:") { flush(); out += "![\(MD.escape(m.body.components(separatedBy: ",").first ?? ""))](\(MD.url(m.target) ?? ""))"; i = m.end; continue }
                if let m = macro("kbd:") { flush(); out += m.body.components(separatedBy: "+").map { "<kbd>\(MD.html($0.trimmingCharacters(in: .whitespaces)))</kbd>" }.joined(separator: "+"); i = m.end; continue }
                if let m = macro("btn:") { flush(); out += "<kbd class=\"btn\">\(MD.html(m.body))</kbd>"; i = m.end; continue }
                if let m = macro("menu:") { flush(); out += "<b>" + ([m.target] + m.body.components(separatedBy: ">")).map { MD.html($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: " › ") + "</b>"; i = m.end; continue }
                if let m = macro("footnote:") { flush(); out += "^[\(convert(m.body))]"; i = m.end; continue }
                if let m = macro("pass:") { flush(); out += MD.escape(m.body); i = m.end; continue }
                if let m = macro("stem:") ?? macro("latexmath:") { flush(); out += "$\(m.body)$"; i = m.end; continue }
                var matchedURL = false
                for scheme in ["https://", "http://", "mailto:"] {
                    let s = Array(scheme)
                    if i + s.count <= chars.count, Array(chars[i..<(i + s.count)]) == s {
                        var j = i
                        while j < chars.count, !chars[j].isWhitespace, chars[j] != "[" { j += 1 }
                        let url = String(chars[i..<j])
                        flush()
                        if j < chars.count, chars[j] == "[", let close = chars[j...].firstIndex(of: "]") {
                            let label = String(chars[(j + 1)..<close]).components(separatedBy: ",").first ?? ""
                            out += MD.link(label.isEmpty ? MD.escape(url) : convert(label), url)
                            i = close + 1
                        } else {
                            out += MD.link(MD.escape(url), url)
                            i = j
                        }
                        matchedURL = true
                        break
                    }
                }
                if matchedURL { continue }
            }
            // <<id,text>> cross references.
            if c == "<", i + 1 < chars.count, chars[i + 1] == "<", let end = OrgInline.find(chars, ">>", from: i + 2) {
                flush()
                let inner = String(chars[(i + 2)..<end]).components(separatedBy: ",")
                let id = inner[0].trimmingCharacters(in: .whitespaces)
                let label = inner.count > 1 ? convert(inner[1].trimmingCharacters(in: .whitespaces)) : MD.escape(id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
                out += "[\(label)](#\(id))"
                i = end + 2
                continue
            }
            // Constrained and unconstrained formatting.
            if "*_`#^~+".contains(c) {
                let double = i + 1 < chars.count && chars[i + 1] == c
                let start = double ? i + 2 : i + 1
                let constrainedOK = double || (atWordStart && start < chars.count && !chars[start].isWhitespace)
                if constrainedOK, (c != "^" && c != "~") || !double, let end = spanEnd(c, from: start + 1 <= chars.count ? start + (double ? 0 : 1) : start, double: double), end > start {
                    let inner = String(chars[start..<end])
                    flush()
                    switch c {
                    case "*": out += "<strong>\(convert(inner))</strong>"
                    case "_": out += "<em>\(convert(inner))</em>"
                    case "`": out += "<code>\(MD.html(inner))</code>"
                    case "#": out += "<mark>\(convert(inner))</mark>"
                    case "^": out += "<sup>\(convert(inner))</sup>"
                    case "~": out += "<sub>\(convert(inner))</sub>"
                    default: out += MD.escape(inner)
                    }
                    i = end + (double ? 2 : 1)
                    continue
                }
            }
            // Replacements.
            if c == "(", i + 2 < chars.count {
                let next3 = String(chars[i..<min(i + 4, chars.count)])
                if next3.hasPrefix("(C)") { plain += "©"; i += 3; continue }
                if next3.hasPrefix("(R)") { plain += "®"; i += 3; continue }
                if next3 == "(TM)" { plain += "™"; i += 4; continue }
            }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-", i > 0, chars[i - 1] != "-", i + 2 < chars.count, chars[i + 2] != "-" { plain += "—"; i += 2; continue }
            if c == "=", i + 1 < chars.count, chars[i + 1] == ">" { plain += "⇒"; i += 2; continue }
            if c == "-", i + 1 < chars.count, chars[i + 1] == ">" { plain += "→"; i += 2; continue }
            plain.append(c)
            i += 1
        }
        flush()
        return out
    }
}

// MARK: - reStructuredText

/// The common reStructuredText subset as Markdown: sections, docinfo, inline markup, lists,
/// literal blocks, directives (code, admonitions, images, math, tables) and footnotes.
enum RSTConverter {
    private static let adornment: Set<Character> = Set("=-`:'\"~^_*+#<>.")

    static func convert(_ source: String) -> ProseDocument {
        var doc = ProseDocument(format: "reStructuredText")
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        var targets: [String: String] = [:]
        var substitutions: [String: String] = [:]
        // Pass 1: targets and substitutions, heading styles.
        var styles: [String] = []
        var styleCounts: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let m = t.range(of: #"^\.\.\s+_([^:]+):\s*(\S+)"#, options: .regularExpression), line.hasPrefix("..") {
                let body = t[m].dropFirst(2).trimmingCharacters(in: .whitespaces).dropFirst()
                if let colon = body.range(of: ": ") ?? body.range(of: ":") {
                    targets[body[..<colon.lowerBound].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "`"))] = body[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                }
            }
            if let m = t.range(of: #"^\.\.\s+\|([^|]+)\|\s+replace::\s*(.*)$"#, options: .regularExpression) {
                let parts = t[m].components(separatedBy: "|")
                if parts.count >= 3 { substitutions[parts[1]] = parts[2].replacingOccurrences(of: "replace::", with: "").trimmingCharacters(in: .whitespaces) }
            }
            if let style = headingStyle(lines, at: index) {
                if !styles.contains(style.key) { styles.append(style.key) }
                styleCounts[style.key, default: 0] += 1
            }
        }

        var out: [String] = []
        var i = 0
        var firstHeading = true
        var titleStyle: String?
        var subtitleStyle: String?
        var footnoteCount = 0
        var docinfoAllowed = true

        let counter = RSTInline.Counter()
        func inline(_ s: String) -> String { RSTInline.convert(s, targets: targets, substitutions: substitutions, counter: counter) }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.isEmpty { out.append(""); i += 1; continue }

            // Headings.
            if let style = headingStyle(lines, at: i) {
                let title = lines[style.titleLine].trimmingCharacters(in: .whitespaces)
                i = style.next
                if firstHeading && styleCounts[style.key] == 1 && out.allSatisfy({ $0.isEmpty }) {
                    doc.title = RSTInline.plain(title)
                    titleStyle = style.key
                    firstHeading = false
                    // Subtitle: a unique style right after the title.
                    var j = i
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if let next = headingStyle(lines, at: j), styleCounts[next.key] == 1 {
                        doc.subtitle = RSTInline.plain(lines[next.titleLine].trimmingCharacters(in: .whitespaces))
                        subtitleStyle = next.key
                        i = next.next
                    }
                    continue
                }
                firstHeading = false
                docinfoAllowed = false
                let ranked = styles.filter { $0 != titleStyle && $0 != subtitleStyle }
                let level = (ranked.firstIndex(of: style.key) ?? 0) + 2
                out.append("")
                out.append(String(repeating: "#", count: min(6, level)) + " " + inline(title))
                out.append("")
                continue
            }

            // Docinfo field list right after the title.
            if docinfoAllowed, t.hasPrefix(":"), let m = t.range(of: #"^:([^:]+):\s*(.*)$"#, options: .regularExpression) {
                var fields: [(String, String)] = []
                while i < lines.count, let fm = lines[i].trimmingCharacters(in: .whitespaces).range(of: #"^:([^:]+):\s*(.*)$"#, options: .regularExpression) {
                    let field = lines[i].trimmingCharacters(in: .whitespaces)[fm]
                    let body = field.dropFirst()
                    if let colon = body.firstIndex(of: ":") { fields.append((String(body[..<colon]), body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces))) }
                    i += 1
                }
                _ = m
                for (name, value) in fields {
                    switch name.lowercased() {
                    case "author", "authors": doc.authors += value.components(separatedBy: CharacterSet(charactersIn: ";,")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    case "date": doc.date = value
                    case "abstract": doc.abstract = value
                    default: doc.meta.append([name, RSTInline.plain(value)])
                    }
                }
                docinfoAllowed = false
                continue
            }
            docinfoAllowed = false

            // Directives and comments.
            if t.hasPrefix("..") && (t == ".." || t.hasPrefix(".. ")) {
                let (body, next) = indentedBlock(lines, from: i + 1, indent: line.prefix { $0 == " " }.count)
                i = next
                if let m = t.range(of: #"^\.\.\s+([\w:-]+)::\s*(.*)$"#, options: .regularExpression) {
                    let header = t[m].dropFirst(2).trimmingCharacters(in: .whitespaces)
                    let name = header.components(separatedBy: "::")[0].lowercased()
                    let argument = header.components(separatedBy: "::").dropFirst().joined(separator: "::").trimmingCharacters(in: .whitespaces)
                    let options = body.prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix(":") }
                    let content = Array(body.dropFirst(options.count)).drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                    let indent = content.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
                    let text = content.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    func option(_ key: String) -> String? {
                        options.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(":\(key):") }.map { $0.trimmingCharacters(in: .whitespaces).dropFirst(key.count + 2).trimmingCharacters(in: .whitespaces) }
                    }
                    switch name {
                    case "code-block", "code", "sourcecode", "highlight", "literalinclude":
                        if name == "highlight" { break }
                        if name == "literalinclude" { out.append(MD.chips(["Included: " + argument])); break }
                        out.append(MD.fence(text, language: argument))
                    case "math":
                        let tex = argument.isEmpty ? text : argument + (text.isEmpty ? "" : "\n" + text)
                        out.append("$$\n\(tex)\n$$")
                    case "image", "figure":
                        let alt = option("alt") ?? ""
                        out.append("![\(MD.escape(alt))](\(MD.url(argument) ?? ""))")
                        if name == "figure", !text.isEmpty { out.append(""); out.append("<p class=\"figure-caption\">\(inline(text.replacingOccurrences(of: "\n", with: " ")))</p>") }
                    case "admonition":
                        out.append(MD.alert("note", title: inline(argument), body: convertNested(text)))
                    case "topic", "sidebar", "rubric":
                        out.append("<aside class=\"sidebar\">\n\n**\(inline(argument))**\n\n\(convertNested(text))\n\n</aside>")
                    case "versionadded", "versionchanged", "deprecated":
                        let label = name == "deprecated" ? "Deprecated since \(argument)" : name == "versionadded" ? "New in version \(argument)" : "Changed in version \(argument)"
                        out.append(MD.alert(name == "deprecated" ? "warning" : "note", title: label, body: convertNested(text)))
                    case "list-table":
                        out.append(listTable(Array(content), headerRows: Int(option("header-rows") ?? "0") ?? 0, inline: inline))
                        if !argument.isEmpty { out.insert("<p class=\"block-title\">\(inline(argument))</p>\n", at: out.count - 1) }
                    case "csv-table":
                        out.append(csvTable(Array(content), header: option("header"), headerRows: Int(option("header-rows") ?? "0") ?? 0, inline: inline))
                    case "contents", "toctree", "raw", "only", "index", "meta", "sectnum", "include", "default-role", "role", "autosummary", "automodule", "autoclass", "autofunction", "currentmodule", "module", "py:module", "tabularcolumns", "target-notes":
                        break
                    case let k where MD.alertKinds[k] != nil:
                        let full = argument.isEmpty ? text : argument + (text.isEmpty ? "" : "\n" + text)
                        out.append(MD.alert(k, title: nil, body: convertNested(full)))
                    default:
                        if !text.isEmpty { out.append(convertNested(text)) }
                    }
                    out.append("")
                    continue
                }
                // Footnote definitions: .. [#] text / .. [1] text
                if let m = t.range(of: #"^\.\.\s+\[([^\]]+)\]\s*(.*)$"#, options: .regularExpression) {
                    let inner = t[m].dropFirst(2).trimmingCharacters(in: .whitespaces)
                    let label = inner.dropFirst().prefix { $0 != "]" }
                    let rest = inner.drop { $0 != "]" }.dropFirst().trimmingCharacters(in: .whitespaces)
                    footnoteCount += 1
                    let id = label == "#" || label == "*" ? "\(footnoteCount)" : label.replacingOccurrences(of: "#", with: "")
                    out.append("[^\(id)]: " + inline(([rest] + body.map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")))
                    out.append("")
                    continue
                }
                // Targets, substitutions and comments produce nothing.
                continue
            }

            // Tables.
            if t.hasPrefix("+-") && t.hasSuffix("+") {
                var block: [String] = []
                while i < lines.count, let first = lines[i].trimmingCharacters(in: .whitespaces).first, first == "+" || first == "|" { block.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1 }
                out.append(gridTable(block, inline: inline))
                out.append("")
                continue
            }
            if t.range(of: #"^=+(\s+=+)+$"#, options: .regularExpression) != nil {
                var block: [String] = [t]
                i += 1
                var rules = 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).range(of: #"^=+(\s+=+)+$"#, options: .regularExpression) != nil {
                        block.append(l); rules += 1; i += 1
                        if rules == 3 || (rules == 2 && (i >= lines.count || lines[i].trimmingCharacters(in: .whitespaces).isEmpty)) { break }
                        continue
                    }
                    block.append(l)
                    i += 1
                }
                out.append(simpleTable(block, inline: inline))
                out.append("")
                continue
            }

            // Transitions.
            if t.count >= 4, let c = t.first, adornment.contains(c), t.allSatisfy({ $0 == c }) { out.append("\n---\n"); i += 1; continue }

            // Lists.
            if let item = listItem(line) {
                var text = [item.content]
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    let indent = next.prefix { $0 == " " }.count
                    if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        if i + 1 < lines.count, lines[i + 1].prefix(while: { $0 == " " }).count >= item.contentIndent, listItem(lines[i + 1]) == nil { i += 1; text.append(""); continue }
                        break
                    }
                    if indent < item.contentIndent || listItem(next) != nil && indent <= item.indent { break }
                    if let nested = listItem(next), indent >= item.contentIndent {
                        _ = nested
                        let (block, after) = indentedBlock(lines, from: i, indent: item.contentIndent - 1)
                        let nestedMarkdown = convertNested(block.joined(separator: "\n"))
                        text.append("\n" + nestedMarkdown.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n"))
                        i = after
                        continue
                    }
                    text.append(next.trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                let pad = String(repeating: "    ", count: item.indent / 3)
                let joined = text.filter { !$0.isEmpty }.map { $0.hasPrefix("\n") ? $0 : inline($0) }.joined(separator: " ").replacingOccurrences(of: " \n", with: "\n")
                out.append(pad + (item.ordered ? "1. " : "- ") + joined)
                continue
            }

            // Indented block: a quote (or a definition list body).
            if line.hasPrefix(" ") {
                let (block, next) = indentedBlock(lines, from: i, indent: 0)
                i = next
                let nested = convertNested(block.joined(separator: "\n"))
                out.append(nested.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
                out.append("")
                continue
            }

            // Line blocks.
            if t.hasPrefix("| ") || t == "|" {
                var block: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { block.append(inline(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2)))); i += 1 }
                out.append(block.joined(separator: "<br>\n"))
                out.append("")
                continue
            }

            // Doctest.
            if t.hasPrefix(">>> ") {
                var block: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { block.append(lines[i]); i += 1 }
                out.append(MD.fence(block.joined(separator: "\n"), language: "python"))
                out.append("")
                continue
            }

            // Definition list: term line followed by an indented definition.
            if i + 1 < lines.count, lines[i + 1].hasPrefix(" "), !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty, !t.hasSuffix("::") {
                let term = t
                let (block, next) = indentedBlock(lines, from: i + 1, indent: 0)
                i = next
                let definition = convertNested(block.joined(separator: "\n"))
                out.append("<dl><dt>\(RSTInline.html(term, targets: targets, substitutions: substitutions))</dt><dd>\n\n\(definition)\n\n</dd></dl>")
                out.append("")
                continue
            }

            // Paragraph (maybe introducing a literal block with ::).
            var paragraph: [String] = []
            while i < lines.count {
                let next = lines[i]
                let nt = next.trimmingCharacters(in: .whitespaces)
                if nt.isEmpty || next.hasPrefix(" ") || headingStyle(lines, at: i) != nil || (paragraph.count > 0 && listItem(next) != nil) { break }
                paragraph.append(nt)
                i += 1
                if nt.hasSuffix("::") { break }
            }
            var text = paragraph.joined(separator: " ")
            var literal = false
            if text.hasSuffix("::") {
                literal = true
                text = text == "::" ? "" : (text.hasSuffix(" ::") ? String(text.dropLast(3)) : String(text.dropLast(1)))
            }
            if !text.isEmpty { out.append(inline(text)); out.append("") }
            if literal {
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
                let (block, next) = indentedBlock(lines, from: i, indent: 0)
                if !block.isEmpty {
                    i = next
                    let indent = block.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
                    out.append(MD.fence(block.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n").trimmingCharacters(in: .newlines), language: "text"))
                    out.append("")
                }
            }
            if paragraph.isEmpty { i += 1 }
        }
        doc.markdown = out.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return doc
    }

    private static func convertNested(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        let dedented = lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
        var nested = convert(dedented).markdown
        // A nested "document" shouldn't promote its first heading to a title.
        nested = nested.trimmingCharacters(in: .whitespacesAndNewlines)
        return nested
    }

    struct HeadingStyle { var key: String; var titleLine: Int; var next: Int }

    /// Title with an underline (and optional overline) of one punctuation character.
    static func headingStyle(_ lines: [String], at i: Int) -> HeadingStyle? {
        guard i < lines.count else { return nil }
        func isRule(_ s: String) -> Character? {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2, let c = t.first, adornment.contains(c), t.allSatisfy({ $0 == c }), !s.hasPrefix(" ") else { return nil }
            return c
        }
        let line = lines[i]
        if let over = isRule(line), i + 2 < lines.count, let under = isRule(lines[i + 2]), over == under,
           !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty, isRule(lines[i + 1]) == nil {
            return HeadingStyle(key: "o\(over)", titleLine: i + 1, next: i + 3)
        }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, isRule(line) == nil, !line.hasPrefix(" "), i + 1 < lines.count,
              let under = isRule(lines[i + 1]), lines[i + 1].trimmingCharacters(in: .whitespaces).count >= min(line.trimmingCharacters(in: .whitespaces).count, 3),
              i == 0 || lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty || isRule(lines[i - 1]) != nil else { return nil }
        // "::" alone or a table border is not a heading.
        if lines[i + 1].trimmingCharacters(in: .whitespaces).count < 3 && under == ":" { return nil }
        return HeadingStyle(key: "u\(under)", titleLine: i, next: i + 2)
    }

    struct ListItem { var indent: Int; var contentIndent: Int; var ordered: Bool; var content: String }

    static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+•".contains(first), rest.dropFirst().first == " " {
            return ListItem(indent: indent, contentIndent: indent + 2, ordered: false, content: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        if let m = rest.range(of: #"^(\d+|#|[a-zA-Z]|[ivxlcdm]+|[IVXLCDM]+)[.)]\s+|^\((\d+|#|[a-zA-Z])\)\s+"#, options: .regularExpression) {
            let marker = rest[m]
            return ListItem(indent: indent, contentIndent: indent + marker.count, ordered: true, content: String(rest[m.upperBound...]))
        }
        return nil
    }

    /// Lines indented past `indent` (blank lines included), from `start`.
    static func indentedBlock(_ lines: [String], from start: Int, indent: Int) -> ([String], Int) {
        var block: [String] = []
        var i = start
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Blank lines belong to the block only if more indented text follows.
                var j = i
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, lines[j].prefix(while: { $0 == " " }).count > indent { block += Array(repeating: "", count: j - i); i = j; continue }
                break
            }
            if line.prefix(while: { $0 == " " }).count <= indent && !(indent == 0 && line.hasPrefix(" ")) { break }
            if indent == 0 && !line.hasPrefix(" ") { break }
            block.append(line)
            i += 1
        }
        return (block, i)
    }

    private static func gridTable(_ block: [String], inline: (String) -> String) -> String {
        guard let border = block.first else { return "" }
        let separators = border.enumerated().filter { $0.element == "+" }.map(\.offset)
        guard separators.count >= 2 else { return "" }
        var rows: [[String]] = []
        var current = Array(repeating: "", count: separators.count - 1)
        var headerRows: Int?
        var hasContent = false
        for line in block.dropFirst() {
            if line.hasPrefix("+") {
                if hasContent { rows.append(current) }
                if line.contains("=") && headerRows == nil { headerRows = rows.count }
                current = Array(repeating: "", count: separators.count - 1)
                hasContent = false
                continue
            }
            let chars = Array(line)
            for k in 0..<(separators.count - 1) {
                let a = separators[k] + 1, b = separators[k + 1]
                guard a < chars.count else { continue }
                let cell = String(chars[a..<min(b, chars.count)]).trimmingCharacters(in: .whitespaces)
                if !cell.isEmpty { current[k] += (current[k].isEmpty ? "" : " ") + cell; hasContent = true }
            }
        }
        if hasContent { rows.append(current) }
        let converted = rows.map { $0.map(inline) }
        if let h = headerRows, h >= 1, h <= converted.count { return MD.table(header: converted[0], rows: Array(converted[h...])) }
        return MD.table(header: nil, rows: converted)
    }

    private static func simpleTable(_ block: [String], inline: (String) -> String) -> String {
        guard let rule = block.first else { return "" }
        var columns: [(Int, Int)] = []
        var start: Int?
        for (k, c) in rule.enumerated() {
            if c == "=" { if start == nil { start = k } } else if let s = start { columns.append((s, k)); start = nil }
        }
        if let s = start { columns.append((s, rule.count)) }
        var rows: [[String]] = []
        var headerRows: Int?
        for line in block.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).range(of: #"^=+(\s+=+)*$"#, options: .regularExpression) != nil { if headerRows == nil { headerRows = rows.count }; continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let chars = Array(line)
            rows.append(columns.enumerated().map { index, col in
                let end = index == columns.count - 1 ? chars.count : min(columns[index + 1].0, chars.count)
                guard col.0 < chars.count else { return "" }
                return inline(String(chars[col.0..<max(col.0, end)]).trimmingCharacters(in: .whitespaces))
            })
        }
        if let h = headerRows, h >= 1, h < rows.count + 1, block.count > 3 { return MD.table(header: rows[0], rows: Array(rows.dropFirst(h))) }
        return MD.table(header: nil, rows: rows)
    }

    private static func listTable(_ lines: [String], headerRows: Int, inline: (String) -> String) -> String {
        var rows: [[String]] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("* - ") { rows.append([String(t.dropFirst(4))]) }
            else if t.hasPrefix("- "), !rows.isEmpty { rows[rows.count - 1].append(String(t.dropFirst(2))) }
            else if !t.isEmpty, !rows.isEmpty, let last = rows[rows.count - 1].indices.last { rows[rows.count - 1][last] += " " + t }
        }
        let converted = rows.map { $0.map(inline) }
        if headerRows >= 1, let first = converted.first { return MD.table(header: first, rows: Array(converted.dropFirst())) }
        return MD.table(header: nil, rows: converted)
    }

    private static func csvTable(_ lines: [String], header: String?, headerRows: Int, inline: (String) -> String) -> String {
        func split(_ s: String) -> [String] {
            var cells: [String] = []
            var cur = ""
            var quoted = false
            for c in s {
                if c == "\"" { quoted.toggle(); continue }
                if c == ",", !quoted { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
                cur.append(c)
            }
            cells.append(cur.trimmingCharacters(in: .whitespaces))
            return cells
        }
        let rows = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { split($0.trimmingCharacters(in: .whitespaces)).map(inline) }
        if let header { return MD.table(header: split(header).map(inline), rows: rows) }
        if headerRows >= 1, let first = rows.first { return MD.table(header: first, rows: Array(rows.dropFirst())) }
        return MD.table(header: nil, rows: rows)
    }
}

enum RSTInline {
    /// Numbers auto footnotes ([#]_) across the whole document.
    final class Counter { var references = 0 }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"[*`]+"#, with: "", options: .regularExpression)
    }

    static func html(_ text: String, targets: [String: String], substitutions: [String: String]) -> String {
        // For definition terms inside raw HTML: no Markdown, so format directly.
        MD.html(plain(text))
    }

    static func convert(_ text: String, targets: [String: String], substitutions: [String: String], counter: Counter = Counter()) -> String {
        let chars = Array(text)
        var out = ""
        var plainText = ""
        var i = 0
        func flush() { out += MD.escape(plainText); plainText = "" }
        func startOK(_ k: Int) -> Bool { k == 0 || " \t-:/'\"<([{".contains(chars[k - 1]) }
        func find(_ needle: String, from: Int) -> Int? {
            guard let end = OrgInline.find(chars, needle, from: from), end > from, !chars[end - 1].isWhitespace else { return nil }
            return end
        }
        while i < chars.count {
            let c = chars[i]
            // ``literal``
            if c == "`", i + 1 < chars.count, chars[i + 1] == "`", let end = find("``", from: i + 2) {
                flush(); out += "<code>\(MD.html(String(chars[(i + 2)..<end])))</code>"; i = end + 2; continue
            }
            // :role:`text`
            if c == ":", startOK(i), let m = String(chars[i...]).range(of: #"^:([\w:+-]+):`"#, options: .regularExpression) {
                let roleText = String(chars[i...])[m]
                let role = roleText.dropFirst().dropLast(2)
                let start = i + roleText.count
                if let end = OrgInline.find(chars, "`", from: start) {
                    flush()
                    let inner = String(chars[start..<end])
                    switch role {
                    case "math": out += "$\(inner)$"
                    case "code", "literal", "file", "command", "program", "samp", "envvar", "option", "kbd", "py:func", "func", "class", "meth", "mod", "attr", "data", "obj", "exc", "py:class", "py:meth", "c:func", "cpp:func":
                        let shown = inner.replacingOccurrences(of: #"^~"#, with: "", options: .regularExpression).replacingOccurrences(of: #".*<(.*)>$"#, with: "$1", options: .regularExpression)
                        out += role == "kbd" ? "<kbd>\(MD.html(inner))</kbd>" : "<code>\(MD.html(shown))</code>"
                    case "sup", "superscript": out += "<sup>\(MD.html(inner))</sup>"
                    case "sub", "subscript": out += "<sub>\(MD.html(inner))</sub>"
                    case "strong": out += "<strong>\(MD.html(inner))</strong>"
                    case "emphasis", "title-reference", "title", "t", "dfn", "term", "abbr":
                        out += "<em>\(MD.html(inner.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)))</em>"
                    case "pep": out += MD.link("PEP \(inner)", "https://peps.python.org/pep-\(String(repeating: "0", count: max(0, 4 - inner.count)) + inner)/")
                    case "rfc": out += MD.link("RFC \(inner)", "https://www.rfc-editor.org/rfc/rfc\(inner)")
                    default:
                        // :ref:, :doc: and friends: show the label.
                        let label = inner.range(of: #"^(.*?)\s*<.*>$"#, options: .regularExpression) != nil ? String(inner.prefix { $0 != "<" }).trimmingCharacters(in: .whitespaces) : inner
                        out += "<em class=\"rst-ref\">\(MD.html(label))</em>"
                    }
                    i = end + 1
                    continue
                }
            }
            // `text <url>`_  /  `text`_  /  `interpreted`
            if c == "`", let end = OrgInline.find(chars, "`", from: i + 1), end > i + 1 {
                let inner = String(chars[(i + 1)..<end])
                var next = end + 1
                let isLink = next < chars.count && chars[next] == "_"
                if isLink { next += 1; if next < chars.count, chars[next] == "_" { next += 1 } }
                flush()
                if isLink {
                    if let lt = inner.lastIndex(of: "<"), inner.hasSuffix(">") {
                        let label = inner[..<lt].trimmingCharacters(in: .whitespaces)
                        let target = String(inner[inner.index(after: lt)..<inner.index(before: inner.endIndex)])
                        out += MD.link(MD.escape(label.isEmpty ? target : label), target.hasSuffix("_") ? (targets[String(target.dropLast()).lowercased()] ?? "#") : target)
                    } else if let target = targets[inner.lowercased()] {
                        out += MD.link(MD.escape(inner), target)
                    } else {
                        out += "[\(MD.escape(inner))](#\(OrgInline.slugify(inner)))"
                    }
                } else {
                    out += "<em>\(MD.html(inner))</em>"
                }
                i = next
                continue
            }
            // **strong**, *emphasis*
            if c == "*", startOK(i) {
                let double = i + 1 < chars.count && chars[i + 1] == "*"
                let start = i + (double ? 2 : 1)
                if start < chars.count, !chars[start].isWhitespace, let end = find(double ? "**" : "*", from: start) {
                    flush()
                    let inner = String(chars[start..<end])
                    out += double ? "<strong>\(MD.html(inner))</strong>" : "<em>\(MD.html(inner))</em>"
                    i = end + (double ? 2 : 1)
                    continue
                }
            }
            // Footnote and citation references: [#]_ [1]_ [#name]_ [CIT2002]_
            if c == "[", let close = chars[i...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "_", close - i < 40 {
                flush()
                let label = String(chars[(i + 1)..<close])
                out += label.hasPrefix("#") || label == "*" || Int(label) != nil ? "[^\(label == "#" || label == "*" ? "auto" : label.replacingOccurrences(of: "#", with: ""))]" : "[\(MD.escape(label))]"
                i = close + 2
                continue
            }
            // |substitution|
            if c == "|", startOK(i), let end = OrgInline.find(chars, "|", from: i + 1), end > i + 1, let value = substitutions[String(chars[(i + 1)..<end])] {
                flush(); out += MD.escape(value); i = end + 1; continue
            }
            // Bare hyperlink reference: word_
            plainText.append(c)
            i += 1
        }
        flush()
        // Number auto footnotes in order.
        while let range = out.range(of: "[^auto]") { counter.references += 1; out.replaceSubrange(range, with: "[^\(counter.references)]") }
        return out
    }
}
