import AppKit

/// A prose document converted to Markdown for Greece's reading view, with its title block.
struct ProseDocument: Encodable {
    var format: String
    var title: String?
    var subtitle: String?
    var authors: [String] = []
    var date: String?
    var abstract: String?
    /// Other metadata worth showing (tags, version, keywords…), as label/value pairs.
    var meta: [[String]] = []
    var tags: [String] = []
    var markdown: String = ""
    var tasks: (open: Int, done: Int) = (0, 0)

    enum CodingKeys: String, CodingKey { case format, title, subtitle, authors, date, abstract, meta, tags, openTasks, doneTasks }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encode(authors, forKey: .authors)
        try c.encodeIfPresent(date, forKey: .date)
        try c.encodeIfPresent(abstract, forKey: .abstract)
        try c.encode(meta, forKey: .meta)
        try c.encode(tags, forKey: .tags)
        try c.encode(tasks.open, forKey: .openTasks)
        try c.encode(tasks.done, forKey: .doneTasks)
    }
}

enum ProsePreview {
    static func convert(_ text: String, format: DocumentsModule.Format, fileName: String = "") -> ProseDocument {
        switch format {
        case .org: return OrgConverter.convert(text)
        case .asciidoc: return AsciiDocConverter.convert(text)
        case .rst: return RSTConverter.convert(text)
        case .quarto: return NotebookMarkdown.convert(text, format: "Quarto")
        case .rmarkdown: return NotebookMarkdown.convert(text, format: "R Markdown")
        case .livebook: return NotebookMarkdown.convert(text, format: "Livebook")
        case .multiMarkdown: return NotebookMarkdown.convert(text, format: "MultiMarkdown")
        default: return ProseDocument(format: String(localized: "Text", bundle: .greeceKit, comment: "Info bar title: a plain text document"), markdown: text)
        }
    }

    static func prepare(_ file: FileInfo, format: DocumentsModule.Format) throws -> PreparedPreview {
        let text = try TextFile(url: file.url)
        let document = convert(text.text, format: format, fileName: file.url.lastPathComponent)
        var web = WebDocument(module: .init("prose"), data: document, scripts: ["modules/documents.js"], styles: ["modules/documents.css"],
                              libraries: [.markdown], text: document.markdown, baseDirectory: file.url.deletingLastPathComponent())
        web.truncated = text.truncated
        let words = PreviewFactory.wordCount(proseText(document.markdown))
        var details = DocumentsModule.readingFacts(words: words)
        let tasks = document.tasks.open + document.tasks.done
        if tasks > 0 {
            let done = document.tasks.done
            details.append(String(localized: "\(done) of \(tasks) done", bundle: .greeceKit,
                                  comment: "Info bar detail: tasks checked off in a document, such as “3 of 8 done”"))
        }
        let symbol: String
        switch format {
        case .org: symbol = "list.bullet.indent"
        case .quarto, .rmarkdown, .livebook: symbol = "book.pages"
        default: symbol = "doc.richtext"
        }
        return .web(web, FileSummary(symbol: symbol, title: document.format, details: details, trailing: file.modifiedText), NSSize(width: 980, height: 780))
    }

    /// Markdown without code blocks and markup, for word counts.
    static func proseText(_ markdown: String) -> String {
        var out: [Substring] = []
        var fence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence.toggle(); continue }
            if fence || t.hasPrefix("<div class=\"chunk-meta") { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }
}

/// Markdown and HTML escaping shared by the converters.
enum MD {
    /// Text that must stay literal inside Markdown: every punctuation character Markdown or the math plugin reacts to.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        for c in text {
            switch c {
            case "\\", "`", "*", "_", "[", "]", "<", ">", "#", "|", "$", "~", "!", "&":
                out.append("\\"); out.append(c)
            default:
                out.append(c)
            }
        }
        return out
    }

    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A safe link target: http(s), mailto, relative paths and in-page anchors only.
    static func url(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:") { return nil }
        if let colon = lower.firstIndex(of: ":"), !lower[..<colon].contains("/"), !lower[..<colon].contains("#") {
            let scheme = lower[..<colon]
            guard ["http", "https", "mailto", "file"].contains(scheme) else { return nil }
        }
        return trimmed.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "\"", with: "%22")
    }

    static func link(_ text: String, _ target: String) -> String {
        guard let url = url(target) else { return text }
        return "[\(text)](\(url))"
    }

    static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "svg", "webp", "tif", "tiff", "bmp", "heic", "avif"].contains((path as NSString).pathExtension.lowercased())
    }

    static func fence(_ code: String, language: String) -> String {
        var marker = "```"
        while code.contains(marker) { marker += "`" }
        var lang = language.lowercased().filter { $0.isLetter || $0.isNumber || "+#-_.".contains($0) }
        if lang == "text" || lang == "plain" || lang == "txt" { lang = "" }
        return "\(marker)\(lang)\n\(code)\n\(marker)"
    }

    static let alertKinds: [String: String] = [
        "note": "NOTE", "tip": "TIP", "hint": "TIP", "important": "IMPORTANT", "warning": "WARNING", "caution": "CAUTION",
        "danger": "CAUTION", "error": "CAUTION", "attention": "WARNING", "seealso": "NOTE", "info": "NOTE", "todo": "NOTE",
    ]

    /// A GitHub-style alert (`> [!NOTE]`), which Greece's Markdown renders as a callout.
    static func alert(_ kind: String, title: String?, body: String) -> String {
        let type = alertKinds[kind.lowercased()] ?? "NOTE"
        var lines = ["> [!\(type)]"]
        if let title, !title.isEmpty { lines.append("> **\(title)**") ; lines.append(">") }
        for line in body.components(separatedBy: "\n") { lines.append(line.isEmpty ? ">" : "> " + line) }
        return lines.joined(separator: "\n")
    }

    static func table(header: [String]?, rows: [[String]]) -> String {
        let columns = max(header?.count ?? 0, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        func row(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: max(0, columns - cells.count))
            return "| " + padded.prefix(columns).map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
        }
        var lines: [String] = []
        let head = header ?? rows.first ?? []
        lines.append(row(head))
        lines.append("|" + String(repeating: " --- |", count: columns))
        for r in (header == nil ? Array(rows.dropFirst()) : rows) { lines.append(row(r)) }
        return lines.joined(separator: "\n")
    }

    static func chips(_ items: [String], kind: String = "chunk-meta") -> String {
        guard !items.isEmpty else { return "" }
        return "<div class=\"\(kind)\">" + items.map { "<span class=\"chip\">\(html($0))</span>" }.joined() + "</div>"
    }

    /// "Included: chapter2.adoc", a chip where a document includes another file.
    static func included(_ name: String) -> String {
        String(localized: "Included: \(name)", bundle: .greeceKit, comment: "Label where a document includes another file. The argument is its path, such as “chapter2.adoc”")
    }

    /// Today as a document would print it ("November 20, 2026"), in the reader's language.
    static func todayLong() -> String {
        Date().formatted(date: .long, time: .omitted)
    }
}

// MARK: - Org

enum OrgConverter {
    static let defaultTodo = ["TODO", "NEXT", "WAITING", "HOLD", "STARTED", "DOING"]
    static let defaultDone = ["DONE", "CANCELLED", "CANCELED", "FIXED"]

    static func convert(_ source: String) -> ProseDocument {
        var doc = ProseDocument(format: "Org")
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var todo = defaultTodo
        var done = defaultDone
        // Keywords first: they change how headings parse.
        for line in lines.prefix(400) {
            let upper = line.uppercased()
            if upper.hasPrefix("#+TODO:") || upper.hasPrefix("#+SEQ_TODO:") || upper.hasPrefix("#+TYP_TODO:") {
                let spec = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                let parts = spec.components(separatedBy: "|")
                let clean: (String) -> [String] = { $0.split(separator: " ").map { String($0.split(separator: "(").first ?? "") }.filter { !$0.isEmpty } }
                if parts.count == 2 { todo = clean(parts[0]); done = clean(parts[1]) }
                else if let words = parts.first.map(clean), !words.isEmpty { todo = Array(words.dropLast()); done = [words.last!] }
            }
        }
        let keywords = todo + done
        var out: [String] = []
        var i = 0
        var listStack: [Int] = []
        var hasTitle = false
        var footnotes: [String] = []
        var pendingCaption: String?

        func flushList() { listStack.removeAll() }
        func inline(_ s: String) -> String { OrgInline.convert(s) }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()

            // Keywords: #+TITLE: and friends.
            if upper.hasPrefix("#+") && !upper.hasPrefix("#+BEGIN") && !upper.hasPrefix("#+END"), let colon = line.firstIndex(of: ":") {
                let key = line[line.index(line.startIndex, offsetBy: 2)..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "title": doc.title = (doc.title.map { $0 + " " } ?? "") + value; hasTitle = true
                case "subtitle": doc.subtitle = value
                case "author": doc.authors += value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                case "date": doc.date = OrgInline.timestampText(value) ?? value
                case "email": doc.meta.append([String(localized: "Email", bundle: .greeceKit, comment: "Label in a document’s title block: the author’s email address"), value])
                case "filetags": doc.tags += value.split(separator: ":").map(String.init).filter { !$0.isEmpty }.flatMap { $0.split(separator: " ").map(String.init) }
                case "description": doc.abstract = value
                case "keywords": doc.meta.append([String(localized: "Keywords", bundle: .greeceKit, comment: "Label in a document’s title block"), value])
                case "caption": pendingCaption = value
                case "results":
                    // Results that follow: fixed-width lines or a block.
                    out.append(MD.chips([String(localized: "Results", bundle: .greeceKit, comment: "Label above the output of a code block in an Org document")], kind: "chunk-meta result"))
                case "include": out.append(MD.chips([MD.included(value)]))
                default: break
                }
                i += 1
                continue
            }

            // Blocks
            if upper.hasPrefix("#+BEGIN_") {
                flushList()
                let header = line.dropFirst(8)
                let kind = header.split(separator: " ").first.map { $0.lowercased() } ?? ""
                let args = header.dropFirst(kind.count).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#+END_" + kind.uppercased()) {
                    body.append(lines[i]); i += 1
                }
                i += 1
                let text = dedent(body).joined(separator: "\n")
                switch kind {
                case "src":
                    let language = args.split(separator: " ").first.map(String.init) ?? ""
                    let lang = ["emacs-lisp": "lisp", "elisp": "lisp", "sh": "bash", "shell": "bash", "jupyter-python": "python", "ipython": "python"][language] ?? language
                    out.append(MD.fence(text.replacingOccurrences(of: "\n,*", with: "\n*").replacingOccurrences(of: "\n,#+", with: "\n#+"), language: lang))
                case "example", "verbatim":
                    out.append(MD.fence(text, language: "text"))
                case "quote":
                    out.append(convertNested(text).components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
                case "verse":
                    out.append(body.map { inline($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "<br>\n"))
                case "center":
                    out.append(convertNested(text))
                case "comment", "export":
                    break
                case let k where MD.alertKinds[k] != nil:
                    out.append(MD.alert(k, title: args.isEmpty ? nil : inline(args), body: convertNested(text)))
                default:
                    out.append(convertNested(text))
                }
                if let caption = pendingCaption { out.append("*\(inline(caption))*"); pendingCaption = nil }
                out.append("")
                continue
            }

            // Comments and drawers.
            if line.hasPrefix("# ") || line == "#" { i += 1; continue }
            if line.range(of: #"^:[A-Z_]+:$"#, options: .regularExpression) != nil {
                let name = line.dropFirst().dropLast().uppercased()
                var props: [String] = []
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).uppercased() != ":END:" {
                    if name == "PROPERTIES" {
                        let p = lines[i].trimmingCharacters(in: .whitespaces)
                        if let m = p.range(of: #"^:([^:]+):\s*(.*)$"#, options: .regularExpression) {
                            let parts = p[m].dropFirst().split(separator: ":", maxSplits: 1)
                            if parts.count == 2 { props.append("\(parts[0].lowercased().capitalized): \(parts[1].trimmingCharacters(in: .whitespaces))") }
                        }
                    }
                    i += 1
                }
                i += 1
                if !props.isEmpty { out.append(MD.chips(props, kind: "org-properties")) ; out.append("") }
                continue
            }

            // Headlines
            if let stars = headlineLevel(raw), raw.dropFirst(stars).trimmingCharacters(in: .whitespaces).lowercased() == "footnotes" {
                // Org's footnote section: the notes are shown at the end anyway.
                flushList()
                i += 1
                continue
            }
            if let stars = headlineLevel(raw) {
                flushList()
                var rest = raw.dropFirst(stars).trimmingCharacters(in: .whitespaces)
                var parts: [String] = []
                var keyword: String?
                if let first = rest.split(separator: " ").first.map(String.init), keywords.contains(first) {
                    keyword = first
                    rest = rest.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
                }
                var priority: String?
                if let m = rest.range(of: #"^\[#[A-Z0-9]\]\s*"#, options: .regularExpression) {
                    priority = String(rest[m].dropFirst(2).prefix(1))
                    rest.removeSubrange(m)
                }
                var tags: [String] = []
                if let m = rest.range(of: #"\s+(:[\w@#%:]+:)\s*$"#, options: .regularExpression) {
                    tags = rest[m].trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init).filter { !$0.isEmpty }
                    rest.removeSubrange(m)
                }
                if rest.hasPrefix("COMMENT ") { rest = String(rest.dropFirst(8)) }
                if let keyword {
                    let isDone = done.contains(keyword)
                    if isDone { doc.tasks.done += 1 } else { doc.tasks.open += 1 }
                    parts.append("<span class=\"org-todo \(isDone ? "done" : "todo")\">\(MD.html(keyword))</span>")
                }
                if let priority { parts.append("<span class=\"org-priority p\(priority.lowercased())\">\(priority)</span>") }
                parts.append(cookies(inline(rest)))
                if !tags.isEmpty { parts.append("<span class=\"org-tags\">" + tags.map { "<span class=\"org-tag\">\(MD.html($0))</span>" }.joined() + "</span>") }
                let level = min(6, stars + (hasTitle ? 1 : 0))
                out.append("")
                out.append(String(repeating: "#", count: level) + " " + parts.joined(separator: " "))
                out.append("")
                i += 1
                // Planning line right under the headline.
                if i < lines.count, let planning = planningLine(lines[i]) { out.append(planning); out.append(""); i += 1 }
                continue
            }
            if let planning = planningLine(raw) { out.append(planning); out.append(""); i += 1; continue }

            // Tables
            if line.hasPrefix("|") {
                flushList()
                var rows: [[String]] = []
                var headerRows: Int?
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    if row.hasPrefix("|-") || row.hasPrefix("|+") { if headerRows == nil, !rows.isEmpty { headerRows = rows.count } }
                    else {
                        var cells = row.dropFirst().components(separatedBy: "|")
                        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, row.hasSuffix("|") { cells.removeLast() }
                        rows.append(cells.map { inline($0.trimmingCharacters(in: .whitespaces)) })
                    }
                    i += 1
                }
                if let caption = pendingCaption { out.append("*\(inline(caption))*"); out.append(""); pendingCaption = nil }
                if let h = headerRows, h >= 1 {
                    let header = rows[0..<h].reduce([String]()) { acc, r in acc.isEmpty ? r : zip(acc, r).map { $0 + " " + $1 } }
                    out.append(MD.table(header: header, rows: Array(rows[h...])))
                } else {
                    out.append(MD.table(header: nil, rows: rows))
                }
                out.append("")
                continue
            }

            // Fixed-width lines (": output")
            if line.hasPrefix(": ") || line == ":" {
                flushList()
                var body: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(":"),
                      lines[i].trimmingCharacters(in: .whitespaces).range(of: #"^:[A-Z_]+:$"#, options: .regularExpression) == nil {
                    body.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2)))
                    i += 1
                }
                out.append(MD.fence(body.joined(separator: "\n"), language: "text"))
                out.append("")
                continue
            }

            // Horizontal rule
            if line.range(of: #"^-{5,}$"#, options: .regularExpression) != nil { flushList(); out.append("\n---\n"); i += 1; continue }

            // Footnote definitions
            if let m = line.range(of: #"^\[fn:([^\]]+)\]\s*"#, options: .regularExpression), raw.hasPrefix("[") {
                let label = line[m].dropFirst(4).prefix { $0 != "]" }
                var body = String(line[m.upperBound...])
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || next.hasPrefix("[fn:") || headlineLevel(lines[i]) != nil || next.hasPrefix("#+") { break }
                    body += " " + next
                    i += 1
                }
                footnotes.append("[^\(label)]: " + inline(body))
                continue
            }

            // Lists
            if let item = listItem(raw) {
                // Nesting from indentation.
                while let last = listStack.last, item.indent < last { listStack.removeLast() }
                if listStack.last != item.indent { listStack.append(item.indent) }
                let depth = listStack.count - 1
                let pad = String(repeating: "    ", count: depth)
                var content = item.content
                var prefix = ""
                if let box = content.range(of: #"^\[([ Xx-])\]\s+"#, options: .regularExpression) {
                    let mark = content[box].dropFirst().prefix(1)
                    prefix = mark == " " ? "[ ] " : mark == "-" ? "[ ] " : "[x] "
                    if mark == " " || mark == "-" { doc.tasks.open += 0 }
                    content.removeSubrange(box)
                }
                if let dt = content.range(of: " :: ") {
                    let term = String(content[..<dt.lowerBound])
                    let def = String(content[dt.upperBound...])
                    content = "**\(inline(term))** — \(inline(def))"
                } else if content.hasSuffix(" ::") {
                    content = "**\(inline(String(content.dropLast(3))))**"
                } else {
                    content = cookies(inline(content))
                }
                out.append(pad + (item.ordered ? "1. " : "- ") + prefix + content)
                i += 1
                // Continuation lines: indented past the bullet.
                while i < lines.count {
                    let next = lines[i]
                    let nextIndent = next.prefix { $0 == " " }.count
                    let trimmed = next.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || nextIndent <= item.indent || listItem(next) != nil || trimmed.hasPrefix("#+") || trimmed.hasPrefix("|") { break }
                    out.append(pad + "    " + inline(trimmed))
                    i += 1
                }
                continue
            }

            if line.isEmpty {
                if !listStack.isEmpty {
                    // A blank line ends the list unless the next line continues it.
                    if i + 1 < lines.count, listItem(lines[i + 1]) == nil { flushList() }
                }
                out.append("")
                i += 1
                continue
            }

            // Paragraph text (images alone on a line become figures).
            flushList()
            var paragraph = inline(line)
            if raw.hasSuffix("\\\\") { paragraph = String(paragraph.dropLast(4)) + "<br>" }
            out.append(paragraph)
            if let caption = pendingCaption, line.hasPrefix("[[") { out.append(""); out.append("*\(inline(caption))*"); pendingCaption = nil }
            i += 1
        }
        if !footnotes.isEmpty { out.append(""); out += footnotes }
        doc.markdown = out.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return doc
    }

    /// Progress cookies, [2/3] and [66%], as quiet chips.
    static func cookies(_ text: String) -> String {
        text.replacingOccurrences(of: #"\\\[(\d+/\d+|\d+%)\\\]"#, with: "<span class=\"org-cookie\">$1</span>", options: .regularExpression)
    }

    /// Converts a block's body (quotes, special blocks) with the same rules.
    private static func convertNested(_ text: String) -> String {
        convert(text).markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func headlineLevel(_ line: String) -> Int? {
        let stars = line.prefix { $0 == "*" }.count
        guard stars > 0, line.count > stars, line[line.index(line.startIndex, offsetBy: stars)] == " " else { return nil }
        return stars
    }

    static func listItem(_ line: String) -> (indent: Int, ordered: Bool, content: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(indent)
        if rest.hasPrefix("- ") || rest.hasPrefix("+ ") || (indent > 0 && rest.hasPrefix("* ")) {
            return (indent, false, String(rest.dropFirst(2)))
        }
        if let m = rest.range(of: #"^(\d+|[a-zA-Z])[.)]\s+"#, options: .regularExpression) {
            return (indent, true, String(rest[m.upperBound...]))
        }
        if rest == "-" || rest == "+" { return (indent, false, "") }
        return nil
    }

    static func planningLine(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("SCHEDULED:") || t.hasPrefix("DEADLINE:") || t.hasPrefix("CLOSED:") else { return nil }
        var chips: [String] = []
        let regex = try! NSRegularExpression(pattern: #"(SCHEDULED|DEADLINE|CLOSED):\s*([<\[][^>\]]+[>\]])"#)
        for m in regex.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let k = Range(m.range(at: 1), in: t), let v = Range(m.range(at: 2), in: t) else { continue }
            let label: String
            switch t[k] {
            case "SCHEDULED": label = String(localized: "Scheduled", bundle: .greeceKit, comment: "Label before an Org task’s scheduled date")
            case "DEADLINE": label = String(localized: "Deadline", bundle: .greeceKit, comment: "Label before an Org task’s deadline")
            default: label = String(localized: "Closed", bundle: .greeceKit, comment: "Label before the date an Org task was closed (done)")
            }
            let value = OrgInline.timestampText(String(t[v])) ?? String(t[v])
            chips.append("<span class=\"org-plan \(t[k].lowercased())\"><span class=\"k\">\(MD.html(label))</span> \(MD.html(value))</span>")
        }
        return chips.isEmpty ? nil : "<div class=\"org-planning\">\(chips.joined())</div>"
    }

    private static func dedent(_ lines: [String]) -> [String] {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
    }
}

/// Org inline markup: emphasis, links, footnotes, timestamps, math, entities.
enum OrgInline {
    private static let markers: Set<Character> = ["*", "/", "_", "=", "~", "+"]
    private static let pre: Set<Character> = [" ", "\t", "-", "(", "{", "'", "\"", "["]
    private static let post: Set<Character> = [" ", "\t", "-", ".", ",", ";", ":", "!", "?", "'", ")", "}", "[", "\"", "\\"]
    private static let entities: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "pi": "π", "lambda": "λ", "mu": "μ", "sigma": "σ", "to": "→",
        "rarr": "→", "larr": "←", "nbsp": "\u{00A0}", "times": "×", "deg": "°", "copy": "©", "reg": "®", "trade": "™",
        "mdash": "—", "ndash": "–", "hellip": "…", "pm": "±", "infin": "∞", "le": "≤", "ge": "≥", "ne": "≠", "check": "✓",
    ]

    static func convert(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        var plain = ""
        func flush() { out += MD.escape(plain); plain = "" }
        while i < chars.count {
            let c = chars[i]
            // [[link][description]]
            if c == "[", i + 1 < chars.count, chars[i + 1] == "[", let end = find(chars, "]]", from: i + 2) {
                flush()
                let inner = String(chars[(i + 2)..<end])
                let parts = inner.components(separatedBy: "][")
                var target = parts[0]
                let description = parts.count > 1 ? parts[1] : nil
                if target.hasPrefix("file:") { target = String(target.dropFirst(5)) }
                if description == nil, MD.isImage(target), let url = MD.url(target) {
                    out += "![](\(url))"
                } else if target.hasPrefix("*") || target.hasPrefix("#") {
                    let label = description.map(convert) ?? MD.escape(target.trimmingCharacters(in: CharacterSet(charactersIn: "*#")))
                    let slug = target.hasPrefix("#") ? String(target.dropFirst()) : slugify(String(target.dropFirst()))
                    out += "[\(label)](#\(slug))"
                } else {
                    let label = description.map { MD.isImage($0) ? "![](\(MD.url($0) ?? ""))" : convert($0) } ?? MD.escape(target)
                    out += MD.link(label, target)
                }
                i = end + 2
                continue
            }
            // Footnotes: [fn:1], [fn::inline], [fn:name:inline]
            if c == "[", i + 3 < chars.count, chars[i + 1] == "f", chars[i + 2] == "n", chars[i + 3] == ":",
               let end = chars[i...].firstIndex(of: "]") {
                flush()
                let body = String(chars[(i + 4)..<end])
                if let colon = body.firstIndex(of: ":") {
                    out += "^[" + convert(String(body[body.index(after: colon)...])) + "]"
                } else {
                    out += "[^\(body)]"
                }
                i = end + 1
                continue
            }
            // Timestamps <2026-11-20 Fri 10:00>
            if (c == "<" || c == "["), i + 11 < chars.count, chars[i + 1].isNumber,
               let end = chars[i...].firstIndex(of: c == "<" ? ">" : "]"), end - i < 40 {
                let stamp = String(chars[i...end])
                if let shown = timestampText(stamp) {
                    flush()
                    out += "<time class=\"org-time\(c == "[" ? " inactive" : "")\">\(MD.html(shown))</time>"
                    i = end + 1
                    continue
                }
            }
            // <<targets>>
            if c == "<", i + 1 < chars.count, chars[i + 1] == "<", let end = find(chars, ">>", from: i + 2) {
                i = end + 2
                continue
            }
            // Math: \( \) and \[ \] and $…$
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "(" || chars[i + 1] == "[", let end = find(chars, chars[i + 1] == "(" ? "\\)" : "\\]", from: i + 2) {
                flush()
                let tex = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespaces)
                out += chars[i + 1] == "(" ? "$\(tex)$" : "$$\(tex)$$"
                i = end + 2
                continue
            }
            if c == "$", i + 1 < chars.count, chars[i + 1] != " ", let end = chars[(i + 1)...].firstIndex(of: "$"), end > i + 1, chars[end - 1] != " " {
                flush()
                out += "$" + String(chars[(i + 1)..<end]) + "$"
                i = end + 1
                continue
            }
            // Entities: \alpha
            if c == "\\", i + 1 < chars.count, chars[i + 1].isLetter {
                var j = i + 1
                var name = ""
                while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
                if let symbol = entities[name] {
                    plain += symbol
                    if j + 1 < chars.count, chars[j] == "{", chars[j + 1] == "}" { j += 2 }
                    i = j
                    continue
                }
            }
            // Emphasis
            if markers.contains(c), i == 0 || pre.contains(chars[i - 1]), i + 1 < chars.count, !chars[i + 1].isWhitespace {
                var j = i + 2
                var found: Int?
                while j < chars.count {
                    if chars[j] == c, !chars[j - 1].isWhitespace, j + 1 == chars.count || post.contains(chars[j + 1]) || markers.contains(chars[j + 1]) { found = j; break }
                    j += 1
                }
                if let end = found {
                    flush()
                    let inner = String(chars[(i + 1)..<end])
                    switch c {
                    case "*": out += "<strong>\(convert(inner))</strong>"
                    case "/": out += "<em>\(convert(inner))</em>"
                    case "_": out += "<u>\(convert(inner))</u>"
                    case "+": out += "<del>\(convert(inner))</del>"
                    default: out += "<code>\(MD.html(inner))</code>"
                    }
                    i = end + 1
                    continue
                }
            }
            // @@html:…@@ export snippets
            if c == "@", i + 1 < chars.count, chars[i + 1] == "@", let end = find(chars, "@@", from: i + 2) {
                i = end + 2
                continue
            }
            plain.append(c)
            i += 1
        }
        flush()
        return out
    }

    static func timestampText(_ stamp: String) -> String? {
        let pattern = #"^[<\[](\d{4})-(\d{2})-(\d{2})(?:\s+[A-Za-z]{2,3}\.?)?(?:\s+(\d{1,2}:\d{2})(?:-(\d{1,2}:\d{2}))?)?[^>\]]*[>\]]$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: stamp, range: NSRange(stamp.startIndex..., in: stamp)) else { return nil }
        func group(_ n: Int) -> String? { Range(m.range(at: n), in: stamp).map { String(stamp[$0]) } }
        guard let y = group(1).flatMap(Int.init), let mo = group(2).flatMap(Int.init), let d = group(3).flatMap(Int.init),
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: mo, day: d)) else { return nil }
        var text = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        if let time = group(4) { text += " " + time + (group(5).map { "–" + $0 } ?? "") }
        return text
    }

    static func slugify(_ text: String) -> String {
        let lowered = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        return lowered.split(separator: " ").joined(separator: "-")
    }

    static func find(_ chars: [Character], _ needle: String, from start: Int) -> Int? {
        let n = Array(needle)
        guard start <= chars.count - n.count else { return nil }
        var i = start
        while i <= chars.count - n.count {
            if chars[i] == n[0], Array(chars[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return nil
    }
}
