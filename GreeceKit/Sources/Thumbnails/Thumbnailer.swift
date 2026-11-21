import AppKit
import JavaScriptCore

/// A Finder thumbnail: a small page of the file's real content, drawn natively.
public struct ThumbnailPage {
    public let size: CGSize
    public let badge: String
    fileprivate let drawing: (CGRect) -> Void

    /// Draws into the current AppKit graphics context.
    public func draw() { drawing(CGRect(origin: .zero, size: size)) }
}

public enum Thumbnailer {

    /// Letter-paper proportions, like every other document page in Finder.
    static let aspect: CGFloat = 8.5 / 11

    public static func page(for url: URL, maximumSize: CGSize, settings: PreviewSettings) -> ThumbnailPage? {
        let kind = FileKind.detect(url)
        guard let file = try? TextFile(url: url, limit: 48 * 1024) else { return nil }
        var height = min(maximumSize.height, maximumSize.width / aspect)
        height = max(height, 16)
        let size = CGSize(width: (height * aspect).rounded(), height: height.rounded())
        let palette = settings.codeTheme.light
        let ext = url.pathExtension.uppercased()

        switch kind {
        case .markdown:
            return ThumbnailPage(size: size, badge: ext.isEmpty ? "MD" : ext) { rect in
                MarkdownPage.draw(file.text, in: rect, palette: palette)
            }
        case .code(let language):
            let short = ["Dockerfile": "DOCKER", "Makefile": "MAKE", "Git Ignore": "GIT", "Shell": "SH", "Plain Text": "TXT"]
            let badge = ext.isEmpty ? (short[language.name] ?? String(language.name.split(separator: " ").first ?? "").uppercased().prefix(6).description) : ext
            return ThumbnailPage(size: size, badge: badge) { rect in
                CodePage.draw(file.text, grammar: language.grammar, in: rect, theme: settings.codeTheme)
            }
        case .json:
            var text = file.text
            if JSONFormatter.looksMinified(text), let pretty = JSONFormatter.prettyPrinted(text, lenient: true) { text = pretty }
            return ThumbnailPage(size: size, badge: "JSON") { rect in
                CodePage.draw(text, grammar: "json", in: rect, theme: settings.codeTheme)
            }
        case .diff:
            return ThumbnailPage(size: size, badge: ext.isEmpty ? "DIFF" : ext) { rect in
                CodePage.draw(file.text, grammar: "diff", in: rect, theme: settings.codeTheme)
            }
        case .propertyList:
            var text = file.text
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
               let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) {
                text = String(decoding: xml, as: UTF8.self)
            }
            return ThumbnailPage(size: size, badge: ext.isEmpty ? "PLIST" : ext) { rect in
                CodePage.draw(text, grammar: "xml", in: rect, theme: settings.codeTheme)
            }
        case .notebook:
            guard let document = NotebookOutline.markdown(from: url) else { return nil }
            return ThumbnailPage(size: size, badge: "IPYNB") { rect in
                MarkdownPage.draw(document, in: rect, palette: palette)
            }
        case .delimited(let separator):
            let table = DelimitedTable.parse(file.text, separator: separator, maxRows: 80)
            guard table.columnCount > 0 else { return nil }
            return ThumbnailPage(size: size, badge: ext.isEmpty ? "CSV" : ext) { rect in
                TablePage.draw(table, in: rect, palette: palette)
            }
        default:
            return nil
        }
    }
}

// MARK: - Shared drawing

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

private func fillPage(_ rect: CGRect, _ color: NSColor) {
    color.setFill()
    rect.fill()
}

// MARK: - Code

enum CodePage {
    static func draw(_ text: String, grammar: String, in rect: CGRect, theme: CodeTheme) {
        let palette = theme.light
        fillPage(rect, NSColor(hex: palette.background))
        let padding = rect.width * 0.075
        let fontSize = max(rect.width / 52, 1)
        let lineHeight = fontSize * 1.45
        let visibleLines = Int((rect.height - padding * 2) / lineHeight) + 1
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let excerpt = lines.prefix(visibleLines).joined(separator: "\n").replacingOccurrences(of: "\t", with: "    ")

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: palette.foreground), .paragraphStyle: style]
        let attributed = Highlighter.shared.attributed(excerpt, grammar: grammar, base: base, theme: theme)
            ?? NSAttributedString(string: excerpt, attributes: base)
        attributed.draw(with: rect.insetBy(dx: padding, dy: padding), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// highlight.js running in JavaScriptCore: real grammars, no web view.
final class Highlighter {
    static let shared = Highlighter()
    private let lock = NSLock()
    private var context: JSContext?
    private var loaded = Set<String>()

    func attributed(_ code: String, grammar: String, base: [NSAttributedString.Key: Any], theme: CodeTheme) -> NSAttributedString? {
        lock.lock()
        defer { lock.unlock() }
        guard let context = prepare(grammar),
              let hljs = context.objectForKeyedSubscript("hljs"),
              let result = hljs.invokeMethod("highlight", withArguments: [code, ["language": grammar, "ignoreIllegals": true]]),
              let markup = result.objectForKeyedSubscript("value")?.toString(), context.exception == nil else { return nil }
        return Highlighter.parse(markup, base: base, theme: theme)
    }

    private func prepare(_ grammar: String) -> JSContext? {
        if context == nil {
            guard let url = WebAssets.url("vendor/highlight/highlight.min.js"), let source = try? String(contentsOf: url, encoding: .utf8),
                  let fresh = JSContext() else { return nil }
            fresh.evaluateScript(source)
            context = fresh
        }
        guard let context else { return nil }
        if !LanguageCatalog.commonGrammars.contains(grammar), !loaded.contains(grammar), WebAssets.bundledGrammars.contains(grammar),
           let url = WebAssets.url("vendor/highlight/languages/\(grammar).min.js"), let source = try? String(contentsOf: url, encoding: .utf8) {
            context.evaluateScript(source)
            loaded.insert(grammar)
        }
        let known = context.evaluateScript("!!hljs.getLanguage(\(Highlighter.jsString(grammar)))")?.toBool() ?? false
        return known ? context : nil
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// Turns highlight.js spans into attributed text coloured by the theme.
    static func parse(_ markup: String, base: [NSAttributedString.Key: Any], theme: CodeTheme) -> NSAttributedString {
        let palette = theme.light
        let output = NSMutableAttributedString()
        var stack: [String] = []
        var index = markup.startIndex
        let baseFont = base[.font] as? NSFont ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)

        func color(for classes: String) -> (NSColor, Bool)? {
            let names = classes.split(separator: " ").map { $0.replacingOccurrences(of: "hljs-", with: "") }
            guard let first = names.first else { return nil }
            let hex: String?
            switch first {
            case "comment", "quote": hex = palette.comment
            case "keyword", "selector-tag", "literal", "doctag": hex = palette.keyword
            case "string", "char", "template-string": hex = palette.string
            case "number", "symbol", "bullet": hex = palette.number
            case "title": hex = names.contains("class_") ? palette.type : palette.function
            case "section": hex = palette.function
            case "type": hex = palette.type
            case "built_in": hex = palette.builtIn
            case "tag", "name", "selector-id", "selector-class": hex = palette.tag
            case "attr", "attribute", "property", "selector-attr", "selector-pseudo": hex = palette.attribute
            case "variable", "template-variable": hex = palette.variable
            case "regexp", "link": hex = palette.regexp
            case "meta": hex = palette.meta
            case "addition": hex = palette.added
            case "deletion": hex = palette.removed
            default: hex = nil
            }
            let bold = theme.boldKeywords && ["keyword", "selector-tag", "literal", "doctag"].contains(first)
            return hex.map { (NSColor(hex: $0), bold) }
        }

        func append(_ text: Substring) {
            guard !text.isEmpty else { return }
            var attributes = base
            if let classes = stack.last(where: { !$0.isEmpty }), let (tint, bold) = color(for: classes) {
                attributes[.foregroundColor] = tint
                if bold { attributes[.font] = boldFont }
            }
            let decoded = text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#x27;", with: "'")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
            output.append(NSAttributedString(string: decoded, attributes: attributes))
        }

        while index < markup.endIndex {
            if markup[index...].hasPrefix("<span"), let close = markup[index...].firstIndex(of: ">") {
                let tag = markup[index...close]
                if let start = tag.range(of: "class=\""), let end = tag[start.upperBound...].firstIndex(of: "\"") {
                    stack.append(String(tag[start.upperBound..<end]))
                } else {
                    stack.append("")
                }
                index = markup.index(after: close)
            } else if markup[index...].hasPrefix("</span>") {
                if !stack.isEmpty { stack.removeLast() }
                index = markup.index(index, offsetBy: 7)
            } else {
                let next = markup[index...].firstIndex(of: "<") ?? markup.endIndex
                let segment = markup[index..<(next == index ? markup.index(after: index) : next)]
                append(segment)
                index = segment.endIndex
            }
        }
        return output
    }
}

// MARK: - Markdown

enum MarkdownPage {
    static func draw(_ text: String, in rect: CGRect, palette: CodeTheme.Palette) {
        fillPage(rect, .white)
        let padding = rect.width * 0.09
        let body = max(rect.width / 30, 1)
        let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        let secondary = NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1)
        let accent = NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
        let output = NSMutableAttributedString()

        func paragraph(spacingBefore: CGFloat, spacingAfter: CGFloat, indent: CGFloat = 0, lineHeight: CGFloat = 1.35, size: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacingAfter
            style.headIndent = indent
            style.firstLineHeadIndent = 0
            style.lineHeightMultiple = lineHeight
            style.lineBreakMode = .byWordWrapping
            return style
        }

        /// Light inline formatting: **bold**, `code`, [links](…), and stripped images.
        func inline(_ line: String, font: NSFont, color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
            let result = NSMutableAttributedString()
            var rest = Substring(line
                .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            let code = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.88, weight: .regular)
            while !rest.isEmpty {
                if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**") {
                    result.append(NSAttributedString(string: String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]),
                                                     attributes: [.font: bold, .foregroundColor: color, .paragraphStyle: style]))
                    rest = rest[end.upperBound...]
                } else if (rest.hasPrefix("*") || rest.hasPrefix("_")), let mark = rest.first,
                          let end = rest.dropFirst().firstIndex(of: mark), end > rest.index(after: rest.startIndex) {
                    result.append(NSAttributedString(string: String(rest[rest.index(after: rest.startIndex)..<end]),
                                                     attributes: [.font: italic, .foregroundColor: color, .paragraphStyle: style]))
                    rest = rest[rest.index(after: end)...]
                } else if rest.hasPrefix("`"), let end = rest.dropFirst().firstIndex(of: "`") {
                    result.append(NSAttributedString(string: String(rest[rest.index(after: rest.startIndex)..<end]),
                                                     attributes: [.font: code, .foregroundColor: NSColor(hex: palette.string), .paragraphStyle: style]))
                    rest = rest[rest.index(after: end)...]
                } else if rest.hasPrefix("["), let close = rest.firstIndex(of: "]"), rest[rest.index(after: close)...].hasPrefix("("),
                          let paren = rest[close...].firstIndex(of: ")") {
                    result.append(NSAttributedString(string: String(rest[rest.index(after: rest.startIndex)..<close]),
                                                     attributes: [.font: font, .foregroundColor: accent, .paragraphStyle: style]))
                    rest = rest[rest.index(after: paren)...]
                } else {
                    let next = rest.dropFirst().firstIndex { "*_`[".contains($0) } ?? rest.endIndex
                    result.append(NSAttributedString(string: String(rest[rest.startIndex..<next]).replacingOccurrences(of: "__", with: ""),
                                                     attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
                    rest = rest[next...]
                }
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
            return result
        }

        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }
        var inCode = false
        let regular = NSFont.systemFont(ofSize: body)
        for raw in lines.prefix(160) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inCode.toggle(); continue }
            if inCode {
                let style = paragraph(spacingBefore: 0, spacingAfter: 0, indent: body, lineHeight: 1.2, size: body)
                output.append(NSAttributedString(string: "  " + raw + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: body * 0.8, weight: .regular),
                    .foregroundColor: NSColor(hex: palette.foreground), .paragraphStyle: style,
                    .backgroundColor: NSColor(hex: palette.background).blended(withFraction: 0.06, of: .black) ?? .clear]))
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let scale: CGFloat = level == 1 ? 1.75 : level == 2 ? 1.38 : 1.15
                let font = NSFont.systemFont(ofSize: body * scale, weight: level <= 2 ? .bold : .semibold)
                let style = paragraph(spacingBefore: body * 0.9, spacingAfter: body * 0.35, lineHeight: 1.1, size: body * scale)
                output.append(inline(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces), font: font, color: ink, style: style))
            } else if let marker = ["- [ ] ", "- [x] ", "- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) {
                let bullet = marker.contains("[x]") ? "☑︎  " : marker.contains("[ ]") ? "☐  " : "•  "
                let style = paragraph(spacingBefore: 0, spacingAfter: body * 0.2, indent: body * 1.1, size: body)
                output.append(inline(bullet + line.dropFirst(marker.count), font: regular, color: ink, style: style))
            } else if line.hasPrefix(">") {
                let style = paragraph(spacingBefore: body * 0.2, spacingAfter: body * 0.4, indent: 0, size: body)
                let quote = line.drop { $0 == ">" || $0 == " " }.replacingOccurrences(of: #"^\[!(\w+)\]"#, with: "$1", options: .regularExpression)
                output.append(inline("▎ " + quote, font: NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask), color: secondary, style: style))
            } else if line.hasPrefix("|") {
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "   ")
                let style = paragraph(spacingBefore: 0, spacingAfter: body * 0.15, size: body)
                output.append(inline(cells, font: NSFont.systemFont(ofSize: body * 0.85), color: secondary, style: style))
            } else {
                let style = paragraph(spacingBefore: 0, spacingAfter: body * 0.55, size: body)
                output.append(inline(line, font: regular, color: ink, style: style))
            }
        }
        output.draw(with: rect.insetBy(dx: padding, dy: padding), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - Tables

enum TablePage {
    static func draw(_ table: DelimitedTable, in rect: CGRect, palette: CodeTheme.Palette) {
        fillPage(rect, .white)
        let padding = rect.width * 0.06
        let fontSize = max(rect.width / 40, 1)
        let rowHeight = fontSize * 1.9
        let columns = min(table.columnCount, 5)
        let area = rect.insetBy(dx: padding, dy: padding)
        let columnWidth = area.width / CGFloat(columns)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let header = table.header ?? (0..<columns).map { DelimitedTable.columnLetter($0) }
        let rows = [header] + table.rows
        let line = NSColor(white: 0.85, alpha: 1)

        for (index, row) in rows.enumerated() {
            let top = area.maxY - CGFloat(index + 1) * rowHeight
            if top < area.minY { break }
            let rowRect = CGRect(x: area.minX, y: top, width: area.width, height: rowHeight)
            if index == 0 {
                NSColor(white: 0.93, alpha: 1).setFill()
                rowRect.fill()
            } else if index % 2 == 0 {
                NSColor(white: 0.975, alpha: 1).setFill()
                rowRect.fill()
            }
            line.setFill()
            CGRect(x: area.minX, y: top, width: area.width, height: max(rect.width / 900, 0.5)).fill()
            for column in 0..<columns {
                let text = column < row.count ? row[column] : ""
                let cell = CGRect(x: area.minX + CGFloat(column) * columnWidth + fontSize * 0.4, y: top + (rowHeight - fontSize * 1.25) / 2,
                                  width: columnWidth - fontSize * 0.8, height: fontSize * 1.3)
                let font = index == 0 ? NSFont.systemFont(ofSize: fontSize, weight: .semibold) : NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: index == 0 ? 0.1 : 0.2, alpha: 1), .paragraphStyle: style])
                    .draw(with: cell, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }
}

// MARK: - Notebooks

/// A notebook's cells as Markdown: prose stays prose, code becomes fenced blocks.
enum NotebookOutline {
    static func markdown(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 64 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = json["cells"] as? [[String: Any]] else { return nil }
        func source(_ value: Any?) -> String {
            if let lines = value as? [String] { return lines.joined() }
            return value as? String ?? ""
        }
        var parts: [String] = []
        for cell in cells.prefix(30) {
            let text = source(cell["source"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if cell["cell_type"] as? String == "markdown" {
                parts.append(text)
            } else {
                parts.append("```\n" + text + "\n```")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
