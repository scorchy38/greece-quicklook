import Foundation

/// Lays out minified source so it can be read: JavaScript, TypeScript, CSS, HTML, XML, SQL and
/// GraphQL (JSON has `JSONFormatter`). Only files that are clearly minified are touched, and a
/// result is used only if it differs from the original in whitespace alone.
public enum CodeFormatter {

    public enum Style: Equatable {
        case javascript(jsx: Bool)
        case typescript(jsx: Bool)
        case css, scss, less
        case html
        case xml
        case sql(dialect: String)
        case graphql

        /// Larger files are left as they are: formatting them would hold up the preview.
        var maxBytes: Int {
            switch self {
            case .javascript, .typescript, .css, .scss, .less, .html: return 1024 * 1024
            case .xml: return XMLFormatter.maxBytes
            case .sql: return 16 * 1024
            case .graphql: return GraphQLFormatter.maxBytes
            }
        }

        var separators: Minified.Separators {
            switch self {
            case .html, .xml: return .tags
            case .sql: return .clauses
            default: return .braces
            }
        }
    }

    /// How a file would be formatted, if it's a kind Greece formats.
    public static func style(for language: Language, fileExtension: String) -> Style? {
        let ext = fileExtension.lowercased()
        switch language.grammar {
        case "javascript": return language.name == "JavaScript" ? .javascript(jsx: ext == "jsx") : nil
        case "typescript": return .typescript(jsx: ext == "tsx")
        case "css": return .css
        case "scss": return ext == "sass" ? nil : .scss
        case "less": return .less
        case "graphql": return .graphql
        case "sql":
            let dialects = ["psql": "postgresql", "pgsql": "postgresql", "mysql": "mysql", "hql": "hive", "sqlite-sql": "sqlite"]
            return .sql(dialect: dialects[ext] ?? "sql")
        case "xml":
            if language.name == "HTML" { return ["html", "htm", "xhtml", "shtml"].contains(ext) ? .html : nil }
            // Only real XML documents: component templates (Vue, Svelte…) share the grammar but not the rules.
            let xml: Set<String> = ["xml", "xsd", "xsl", "xslt", "svg", "plist", "xaml", "csproj", "fsproj", "vbproj", "props", "targets",
                                    "resx", "storyboard", "xib", "wsdl", "rss", "atom", "opml", "xliff", "xlf", "nuspec", "config", "manifest"]
            return language.name == "XML" || xml.contains(ext) ? .xml : nil
        default: return nil
        }
    }

    /// The formatted text when `text` is minified and formats cleanly; nil to show it as it is.
    public static func formatIfMinified(_ text: String, language: Language, fileExtension: String) -> String? {
        guard let style = style(for: language, fileExtension: fileExtension), text.utf8.count <= style.maxBytes,
              Minified.looksMinified(text, separators: style.separators) else { return nil }
        return format(text, style: style)
    }

    public static func format(_ text: String, style: Style) -> String? {
        guard text.utf8.count <= style.maxBytes else { return nil }
        let result: String?
        switch style {
        case .javascript(let jsx), .typescript(let jsx):
            result = ScriptFormatter.shared.call(.beautifier, "beautifier.js(__input, \(beautifyOptions(jsx: jsx)))", input: text, timeout: 3)
        case .css, .scss, .less:
            result = ScriptFormatter.shared.call(.beautifier, "beautifier.css(__input, \(beautifyOptions(jsx: false)))", input: text, timeout: 3)
        case .html:
            result = ScriptFormatter.shared.call(.beautifier, "beautifier.html(__input, \(beautifyOptions(jsx: false)))", input: text, timeout: 3)
        case .sql(let dialect):
            let options = "{language: '\(dialect.filter { $0.isLetter || $0 == "-" })', tabWidth: 2, keywordCase: 'preserve', linesBetweenQueries: 1}"
            result = ScriptFormatter.shared.call(.sql, "sqlFormatter.format(__input, \(options))", input: text, timeout: 1.5)
        case .xml:
            result = XMLFormatter.prettyPrinted(text)
        case .graphql:
            result = GraphQLFormatter.prettyPrinted(text)
        }
        guard var formatted = result, formatted != text, sameNonWhitespace(text, formatted) else { return nil }
        if !formatted.hasSuffix("\n") { formatted += "\n" }
        return formatted
    }

    private static func beautifyOptions(jsx: Bool) -> String {
        "{indent_size: 2, indent_char: ' ', preserve_newlines: true, max_preserve_newlines: 2, wrap_line_length: 0, end_with_newline: true, e4x: \(jsx), indent_inner_html: false, extra_liners: []}"
    }

    /// True when the two texts differ only in whitespace: a formatter may move code around but
    /// never change a token.
    public static func sameNonWhitespace(_ a: String, _ b: String) -> Bool {
        var left = a.utf8.makeIterator()
        var right = b.utf8.makeIterator()
        func next(_ iterator: inout String.UTF8View.Iterator) -> UInt8? {
            while let byte = iterator.next() {
                if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x0B && byte != 0x0C { return byte }
            }
            return nil
        }
        while true {
            let x = next(&left)
            let y = next(&right)
            if x != y { return false }
            if x == nil { return true }
        }
    }
}
