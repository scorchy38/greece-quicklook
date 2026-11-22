import Foundation

/// Quarto, R Markdown, Livebook and MultiMarkdown are Markdown with extras. This tidies them
/// for Greece's Markdown renderer: front matter becomes a title block, `{r}` chunk headers and
/// `#|` options become quiet labels, callouts become alerts, cross references get numbers.
enum NotebookMarkdown {
    static func convert(_ source: String, format: String) -> ProseDocument {
        var doc = ProseDocument(format: format)
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        // Front matter.
        if text.hasPrefix("---\n") || text.hasPrefix("---\r") {
            let lines = text.components(separatedBy: "\n")
            if let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
                let yaml = Array(lines[1..<end])
                applyFrontMatter(YAML.parse(yaml), to: &doc, format: format)
                text = lines[(end + 1)...].joined(separator: "\n")
            }
        } else if format == "MultiMarkdown" {
            // MultiMarkdown metadata: Key: value lines at the very top.
            var lines = text.components(separatedBy: "\n")
            var meta: [(String, String)] = []
            while let first = lines.first, let colon = first.firstIndex(of: ":"), !first.hasPrefix(" "), !first.hasPrefix("#"),
                  first[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }) {
                meta.append((String(first[..<colon]).trimmingCharacters(in: .whitespaces), first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                lines.removeFirst()
            }
            if !meta.isEmpty, lines.first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                var node: [String: YAML.Value] = [:]
                for (k, v) in meta { node[k.lowercased()] = .string(v) }
                applyFrontMatter(.map(node, Array(meta.map { $0.0.lowercased() })), to: &doc, format: format)
                text = lines.joined(separator: "\n")
            }
        }

        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var calloutDepth = 0         // lines inside callouts are quoted
        var divStack: [Bool] = []    // true for a callout div
        var references: [String: String] = [:]
        var counters: [String: Int] = [:]
        var pendingOutput = false

        // First pass: number figures, tables and equations for @references.
        let labelPatterns = [#"#\|\s*label:\s*((fig|tbl)-[\w-]+)"#, #"\{#((fig|tbl|eq|sec|lst)-[\w-]+)"#]
        for pattern in labelPatterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let label = String(text[r])
                guard references[label] == nil else { continue }
                let kind = String(label.prefix { $0 != "-" })
                if kind == "sec" { references[label] = "Section"; continue }
                counters[kind, default: 0] += 1
                references[label] = "\(counters[kind]!)"
            }
        }

        func emit(_ line: String) { out.append(calloutDepth > 0 ? (line.isEmpty ? ">" : "> " + line) : line) }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Livebook markers.
            if trimmed.hasPrefix("<!-- livebook:") {
                if trimmed.contains("\"output\":true") { pendingOutput = true }
                if trimmed.contains("force_markdown") || trimmed.contains("break_markdown") { emit("") }
                i += 1
                continue
            }

            // Pandoc fenced divs.
            if trimmed.hasPrefix(":::") {
                let attributes = trimmed.drop { $0 == ":" }.trimmingCharacters(in: .whitespaces)
                if attributes.isEmpty {
                    if let callout = divStack.popLast(), callout { calloutDepth -= 1; out.append("") }
                    i += 1
                    continue
                }
                if let m = attributes.range(of: #"\.callout-(\w+)"#, options: .regularExpression) {
                    let kind = String(attributes[m].dropFirst(9))
                    var title: String?
                    if let t = attributes.range(of: #"title="([^"]*)""#, options: .regularExpression) { title = String(attributes[t].dropFirst(7).dropLast()) }
                    // Quarto also takes the title from a heading on the first line.
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if title == nil, j < lines.count, lines[j].hasPrefix("#") {
                        title = lines[j].drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                        i = j
                    }
                    out.append("")
                    let type = MD.alertKinds[kind.lowercased()] ?? "NOTE"
                    out.append(calloutDepth > 0 ? "> > [!\(type)]" : "> [!\(type)]")
                    calloutDepth += 1
                    divStack.append(true)
                    if let title { emit("**\(cleanInline(title))**"); emit("") }
                    i += 1
                    continue
                }
                divStack.append(false)
                i += 1
                continue
            }

            // Code chunks: ```{r label, echo=FALSE}  ```{python}
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fenceChar = trimmed.first!
                let fence = String(trimmed.prefix { $0 == fenceChar })
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !(lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) && lines[i].trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fenceChar })) {
                    body.append(lines[i]); i += 1
                }
                i += 1
                var chips: [String] = []
                var language = info
                if info.hasPrefix("{") {
                    let inner = info.dropFirst().prefix { $0 != "}" }
                    if inner.hasPrefix("=") { continue }   // raw output blocks ({=html})
                    let parts = splitChunkOptions(String(inner))
                    language = parts.first?.lowercased() ?? ""
                    if parts.count > 1 {
                        let rest = Array(parts.dropFirst())
                        if let label = rest.first, !label.contains("=") { chips.append(label) }
                        chips += rest.filter { $0.contains("=") }.map { $0.replacingOccurrences(of: #"\s*=\s*"#, with: "=", options: .regularExpression) }
                    }
                }
                // Quarto #| options.
                while let first = body.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#|") {
                    let option = first.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if option.hasPrefix("label:") { chips.insert(option.dropFirst(6).trimmingCharacters(in: .whitespaces), at: 0) }
                    else if !option.isEmpty { chips.append(option) }
                    body.removeFirst()
                }
                if language == "dot" || language == "graphviz" { language = "text" }
                if pendingOutput {
                    chips = ["Output"]
                    language = language.isEmpty || language == "elixir" ? "text" : language
                    pendingOutput = false
                }
                if !chips.isEmpty { emit(MD.chips(chips)); emit("") }
                for codeLine in MD.fence(body.joined(separator: "\n"), language: language).components(separatedBy: "\n") { emit(codeLine) }
                continue
            }

            // Display math with an equation label: $$ … $$ {#eq-x}
            if trimmed.hasPrefix("$$"), let label = trimmed.range(of: #"\{#(eq-[\w-]+)\}"#, options: .regularExpression).map({ String(trimmed[$0].dropFirst(2).dropLast()) }), let n = references[label] {
                emit(trimmed.replacingOccurrences(of: #"\$\$\s*\{#eq-[\w-]+\}"#, with: NSRegularExpression.escapedTemplate(for: "\\tag{\(n)}$$"), options: .regularExpression))
                i += 1
                continue
            }
            if trimmed.hasPrefix("$$"), trimmed != "$$" || true {
                // Multi-line $$ … $$ {#eq-x}: tag the closing line.
                var block = [line]
                if trimmed == "$$" || !(trimmed.count > 2 && trimmed.hasSuffix("$$")) {
                    var j = i + 1
                    while j < lines.count, !lines[j].contains("$$") { block.append(lines[j]); j += 1 }
                    if j < lines.count {
                        var closing = lines[j]
                        if let r = closing.range(of: #"\{#(eq-[\w-]+)\}"#, options: .regularExpression) {
                            let label = String(closing[r].dropFirst(2).dropLast())
                            closing.removeSubrange(r)
                            if let n = references[label] { closing = closing.replacingOccurrences(of: "$$", with: "\\tag{\(n)}$$") }
                        }
                        block.append(closing)
                        for b in block { emit(b) }
                        i = j + 1
                        continue
                    }
                }
            }

            // Headings and images: drop Pandoc attributes ({#id .class width=50%}).
            var cleaned = line
            if cleaned.contains("{") {
                cleaned = cleaned.replacingOccurrences(of: #"(\]\([^)]*\))\{[^}]*\}"#, with: "$1", options: .regularExpression)
                if cleaned.hasPrefix("#") || cleaned.hasPrefix(":") || cleaned.hasPrefix("|") {
                    cleaned = cleaned.replacingOccurrences(of: #"\s*\{[#.][^}]*\}\s*$"#, with: "", options: .regularExpression)
                }
                if trimmed.hasPrefix(": ") { cleaned = "*" + cleaned.trimmingCharacters(in: .whitespaces).dropFirst(2).replacingOccurrences(of: #"\s*\{#tbl-[\w-]+\}"#, with: "", options: .regularExpression) + "*" }
            } else if trimmed.hasPrefix(": "), i > 0, lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                cleaned = "*" + trimmed.dropFirst(2) + "*"
            }
            // Inline chunks: `r expr` and Livebook/Quarto `{python} expr`.
            cleaned = cleaned.replacingOccurrences(of: #"`r ([^`]+)`"#, with: "<code class=\"inline-chunk\">$1</code>", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"`\{(\w+)\} ([^`]+)`"#, with: "<code class=\"inline-chunk\">$2</code>", options: .regularExpression)
            // Cross references.
            if cleaned.contains("@") { cleaned = crossReferences(cleaned, references) }
            emit(cleaned)
            i += 1
        }
        doc.markdown = out.joined(separator: "\n")
        return doc
    }

    private static func cleanInline(_ s: String) -> String {
        s.replacingOccurrences(of: "*", with: "\\*")
    }

    private static func crossReferences(_ line: String, _ references: [String: String]) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?<![\w@])@((fig|tbl|eq|sec|lst)-[\w-]*[\w])"#)
        var result = line
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let r = Range(match.range, in: result), let labelRange = Range(match.range(at: 1), in: line) else { continue }
            let label = String(line[labelRange])
            let kind = String(label.prefix { $0 != "-" })
            let word = ["fig": "Figure", "tbl": "Table", "eq": "Equation", "sec": "Section", "lst": "Listing"][kind] ?? ""
            let number = references[label]
            let text = kind == "sec" ? "Section" : number.map { kind == "eq" ? "\(word) (\($0))" : "\(word) \($0)" } ?? word
            result.replaceSubrange(r, with: "<span class=\"xref\">\(text)</span>")
        }
        return result
    }

    /// `r label, echo=FALSE, fig.cap="A, B"` split at top-level commas (or spaces before the first).
    static func splitChunkOptions(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for c in text {
            if let q = quote { current.append(c); if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; current.append(c); continue }
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            if (c == "," || (c == " " && parts.isEmpty && !current.contains("="))) && depth == 0 {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { parts.append(t) }
                current = ""
                continue
            }
            current.append(c)
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { parts.append(t) }
        return parts
    }

    private static func applyFrontMatter(_ yaml: YAML.Value, to doc: inout ProseDocument, format: String) {
        guard case .map(let map, let order) = yaml else { return }
        func text(_ value: YAML.Value?) -> String? {
            guard let value else { return nil }
            switch value {
            case .string(let s): return evaluate(s)
            case .list(let items): return items.compactMap { text($0) }.joined(separator: ", ")
            case .map(let m, _): return text(m["name"]) ?? text(m["text"])
            }
        }
        doc.title = text(map["title"]) ?? doc.title
        doc.subtitle = text(map["subtitle"])
        doc.date = text(map["date"])
        doc.abstract = text(map["abstract"]) ?? text(map["description"])
        switch map["author"] ?? map["authors"] {
        case .some(.list(let items)): doc.authors = items.compactMap { text($0) }
        case .some(let value): doc.authors = text(value).map { [$0] } ?? []
        case .none: break
        }
        if let keywords = map["keywords"] ?? map["tags"] ?? map["categories"] {
            switch keywords {
            case .list(let items): doc.tags = items.compactMap { text($0) }
            default: doc.tags = text(keywords)?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            }
        }
        let shown: Set<String> = ["title", "subtitle", "date", "abstract", "description", "author", "authors", "keywords", "tags", "categories"]
        for key in order where !shown.contains(key) {
            guard let value = map[key] else { continue }
            let rendered: String
            switch value {
            case .string(let s): rendered = s
            case .list(let items): rendered = items.compactMap { text($0) }.joined(separator: ", ")
            case .map(let sub, let keys):
                rendered = keys.map { key -> String in
                    if case .string(let value) = sub[key] ?? .string("") { return value.isEmpty ? key : "\(key): \(value)" }
                    return key
                }.joined(separator: ", ")
            }
            guard !rendered.isEmpty, rendered.count < 120 else { continue }
            doc.meta.append([key, rendered])
        }
    }

    /// R Markdown dates are often code: `r Sys.Date()`. Show what R would.
    private static func evaluate(_ value: String) -> String {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("`r ") && t.hasSuffix("`") else { return value }
        if t.contains("Sys.Date()") && !t.contains("format") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: Date())
        }
        if t.contains("Sys.Date()") || t.contains("Sys.time()") { return MD.todayLong() }
        return value
    }
}

/// Enough YAML for front matter: nested maps, block and flow lists, quoted strings.
enum YAML {
    indirect enum Value {
        case string(String)
        case list([Value])
        case map([String: Value], [String])
    }

    static func parse(_ lines: [String]) -> Value {
        var index = 0
        let clean = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        return parseBlock(clean, &index, indent: 0, depth: 0)
    }

    private static func indentOf(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func parseBlock(_ lines: [String], _ i: inout Int, indent: Int, depth: Int) -> Value {
        guard depth < 12 else { return .string("") }
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        guard i < lines.count else { return .map([:], []) }
        let first = lines[i].trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("- ") || first == "-" {
            var items: [Value] = []
            let listIndent = indentOf(lines[i])
            while i < lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
                guard indentOf(line) == listIndent, line.trimmingCharacters(in: .whitespaces).hasPrefix("-") else { break }
                let content = line.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
                if content.isEmpty {
                    i += 1
                    items.append(parseBlock(lines, &i, indent: listIndent + 1, depth: depth + 1))
                } else if let colon = keyColon(content) {
                    // A map inside a list item: "- name: X" plus following indented keys.
                    var sub = [String(repeating: " ", count: listIndent + 2) + content]
                    i += 1
                    while i < lines.count, indentOf(lines[i]) > listIndent || lines[i].trimmingCharacters(in: .whitespaces).isEmpty { sub.append(lines[i]); i += 1 }
                    var j = 0
                    _ = colon
                    items.append(parseBlock(sub, &j, indent: listIndent + 2, depth: depth + 1))
                } else {
                    items.append(.string(unquote(content)))
                    i += 1
                }
                if items.count > 500 { break }
            }
            return .list(items)
        }
        var map: [String: Value] = [:]
        var order: [String] = []
        let mapIndent = indentOf(lines[i])
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if indentOf(line) < mapIndent { break }
            guard indentOf(line) == mapIndent, let colon = keyColon(trimmed) else { i += 1; continue }
            let key = unquote(String(trimmed[..<colon])).lowercased()
            let rest = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            i += 1
            let value: Value
            if rest.isEmpty {
                value = parseBlock(lines, &i, indent: mapIndent + 1, depth: depth + 1)
            } else if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                var text: [String] = []
                while i < lines.count, indentOf(lines[i]) > mapIndent || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    text.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
                }
                value = .string(text.joined(separator: rest.hasPrefix("|") ? "\n" : " ").trimmingCharacters(in: .whitespacesAndNewlines))
            } else if rest.hasPrefix("[") && rest.hasSuffix("]") {
                value = .list(rest.dropFirst().dropLast().split(separator: ",").map { .string(unquote($0.trimmingCharacters(in: .whitespaces))) })
            } else {
                value = .string(unquote(rest))
            }
            if map[key] == nil { order.append(key) }
            map[key] = value
            if order.count > 500 { break }
        }
        return .map(map, order)
    }

    private static func keyColon(_ text: String) -> String.Index? {
        var quote: Character?
        for index in text.indices {
            let c = text[index]
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == ":" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " { return index }
            }
        }
        return nil
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) { return String(t.dropFirst().dropLast()) }
        return t
    }
}
