import Foundation

/// Lays out GraphQL documents and schemas: one field per line inside selection sets and type
/// bodies, arguments and input objects kept inline, a blank line between definitions. Every token
/// (commas and comments included) comes out exactly as it went in; only whitespace changes.
public enum GraphQLFormatter {

    static let maxBytes = 4 * 1024 * 1024
    static let maxDepth = 256

    enum Kind: Equatable { case name, number, string, punctuator, comment }

    struct Token {
        var kind: Kind
        var text: Substring
    }

    public static func prettyPrinted(_ source: String, indent: Int = 2) -> String? {
        guard source.utf8.count <= maxBytes, let tokens = tokenize(source), !tokens.isEmpty else { return nil }
        var out = ""
        out.reserveCapacity(source.utf8.count * 2)
        let pad = String(repeating: " ", count: indent)
        var level = 0          // block braces open
        var parens = 0         // inside arguments or variable definitions
        var braces: [Bool] = []   // per open brace: inline (an input object inside arguments)?
        var previous: Token?
        var beforePrevious: Token?

        func trimTrailingSpaces() { while out.last == " " { out.removeLast() } }
        func newline(blank: Bool = false) {
            trimTrailingSpaces()
            if out.isEmpty { return }
            if blank && !out.hasSuffix("\n\n") { out += out.hasSuffix("\n") ? "\n" : "\n\n" } else if !out.hasSuffix("\n") { out += "\n" }
            out += String(repeating: pad, count: level)
        }
        var inSelection: Bool { level > 0 && parens == 0 && braces.last == false }
        func endsValue(_ token: Token?) -> Bool {
            guard let token else { return false }
            switch token.kind {
            case .name, .number, .string: return true
            case .punctuator: return token.text == ")" || token.text == "]" || token.text == "}" || token.text == "!"
            case .comment: return false
            }
        }

        for token in tokens {
            defer { beforePrevious = previous; previous = token }
            if token.kind == .comment {
                if previous != nil && previous?.kind != .comment && !out.hasSuffix("\n") { out += " " }
                out += token.text
                newline()
                continue
            }
            if token.kind == .punctuator {
                switch token.text {
                case "{":
                    if parens > 0 || braces.last == true {
                        braces.append(true)
                        out += "{"
                    } else {
                        guard braces.count < maxDepth else { return nil }
                        trimTrailingSpaces()
                        if !out.isEmpty && !out.hasSuffix("\n") { out += " " }
                        out += "{"
                        braces.append(false)
                        level += 1
                        newline()
                    }
                case "}":
                    guard let inline = braces.popLast() else { return nil }
                    if inline { trimTrailingSpaces(); out += "}" } else {
                        level -= 1
                        newline()
                        out += "}"
                    }
                case "(":
                    trimTrailingSpaces()
                    out += "("
                    parens += 1
                case ")":
                    guard parens > 0 else { return nil }
                    trimTrailingSpaces()
                    out += ")"
                    parens -= 1
                case ":": trimTrailingSpaces(); out += ": "
                case ",": trimTrailingSpaces(); out += inSelection ? "," : ", "
                case "=", "|", "&":
                    trimTrailingSpaces()
                    out += " \(token.text) "
                case "...":
                    if inSelection && previous.map({ $0.text != "{" }) == true { newline() }
                    out += "..."
                case "@":
                    if endsValue(previous) { out += " " }
                    out += "@"
                default:
                    out += token.text
                }
                continue
            }
            // Names, numbers and strings.
            let after = previous?.text ?? ""
            if previous == nil {
            } else if level == 0 && parens == 0 && after == "}" {
                newline(blank: true)
            } else if inSelection && endsValue(previous) && !(beforePrevious?.text == "..." && after == "on") {
                newline()
            } else if after == "..." && token.text == "on" {
                out += " "
            } else if endsValue(previous) {
                out += " "
            }
            out += token.text
        }
        guard parens == 0, braces.isEmpty else { return nil }
        trimTrailingSpaces()
        out += "\n"
        guard CodeFormatter.sameNonWhitespace(source, out) else { return nil }
        return out
    }

    static func tokenize(_ source: String) -> [Token]? {
        var tokens: [Token] = []
        var i = source.startIndex
        let end = source.endIndex
        func isNameStart(_ c: Character) -> Bool { c == "_" || (c.isASCII && c.isLetter) }
        func isNameChar(_ c: Character) -> Bool { isNameStart(c) || (c.isASCII && c.isNumber) }
        while i < end {
            let c = source[i]
            if c.isWhitespace || c == "\u{FEFF}" { i = source.index(after: i); continue }
            let start = i
            if c == "#" {
                while i < end, !source[i].isNewline { i = source.index(after: i) }
                tokens.append(Token(kind: .comment, text: source[start..<i]))
            } else if source[i...].hasPrefix("\"\"\"") {
                i = source.index(i, offsetBy: 3)
                var closed = false
                while i < end {
                    if source[i] == "\\" && source[i...].hasPrefix("\\\"\"\"") { i = source.index(i, offsetBy: 4); continue }
                    if source[i...].hasPrefix("\"\"\"") { i = source.index(i, offsetBy: 3); closed = true; break }
                    i = source.index(after: i)
                }
                guard closed else { return nil }
                tokens.append(Token(kind: .string, text: source[start..<i]))
            } else if c == "\"" {
                i = source.index(after: i)
                var closed = false
                while i < end, !source[i].isNewline {
                    if source[i] == "\\" { i = source.index(after: i); if i < end { i = source.index(after: i) }; continue }
                    if source[i] == "\"" { i = source.index(after: i); closed = true; break }
                    i = source.index(after: i)
                }
                guard closed else { return nil }
                tokens.append(Token(kind: .string, text: source[start..<i]))
            } else if source[i...].hasPrefix("...") {
                i = source.index(i, offsetBy: 3)
                tokens.append(Token(kind: .punctuator, text: source[start..<i]))
            } else if "!$&()[]{}:=@|,".contains(c) {
                i = source.index(after: i)
                tokens.append(Token(kind: .punctuator, text: source[start..<i]))
            } else if isNameStart(c) {
                while i < end, isNameChar(source[i]) { i = source.index(after: i) }
                tokens.append(Token(kind: .name, text: source[start..<i]))
            } else if c == "-" || (c.isASCII && c.isNumber) {
                i = source.index(after: i)
                while i < end, source[i].isASCII, source[i].isNumber || source[i] == "." || source[i] == "e" || source[i] == "E" || source[i] == "+" || source[i] == "-" {
                    i = source.index(after: i)
                }
                tokens.append(Token(kind: .number, text: source[start..<i]))
            } else {
                return nil
            }
        }
        return tokens
    }
}
