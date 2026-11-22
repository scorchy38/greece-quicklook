import Foundation

/// Small LaTeX text utilities for the Swift side: plain text for thumbnails and summaries,
/// arguments and environments, word counts. The full typesetting happens in `latex.js`.
enum TeXText {

    private static let accents: [Character: Character] = [
        "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}", "\"": "\u{0308}", "~": "\u{0303}", "=": "\u{0304}", ".": "\u{0307}",
        "u": "\u{0306}", "v": "\u{030C}", "H": "\u{030B}", "c": "\u{0327}", "k": "\u{0328}", "r": "\u{030A}", "d": "\u{0323}",
    ]

    private static let symbols: [String: String] = [
        "ss": "ß", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "aa": "å", "AA": "Å", "o": "ø", "O": "Ø", "l": "ł", "L": "Ł",
        "i": "ı", "j": "ȷ", "dots": "…", "ldots": "…", "textendash": "–", "textemdash": "—", "S": "§", "P": "¶",
        "copyright": "©", "textregistered": "®", "texttrademark": "™", "pounds": "£", "euro": "€", "dag": "†", "ddag": "‡",
        "textbullet": "•", "LaTeX": "LaTeX", "TeX": "TeX", "BibTeX": "BibTeX", "LaTeXe": "LaTeX2ε", "today": "",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "theta": "θ", "lambda": "λ",
        "mu": "μ", "pi": "π", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ",
        "Lambda": "Λ", "Sigma": "Σ", "Phi": "Φ", "Omega": "Ω", "ell": "ℓ", "infty": "∞", "times": "×", "cdot": "·", "pm": "±",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "approx": "≈", "sim": "∼", "to": "→", "rightarrow": "→",
        "leftarrow": "←", "in": "∈", "sum": "∑", "prod": "∏", "int": "∫", "partial": "∂", "nabla": "∇", "sqrt": "√",
        "quad": " ", "qquad": " ", ",": " ", ";": " ", ":": " ", "!": "", " ": " ", "&": "&", "%": "%", "$": "$", "#": "#",
        "_": "_", "{": "{", "}": "}", "\\": "\n", "newline": "\n", "par": "\n\n", "item": "\n• ",
    ]

    /// Commands whose arguments are not text (dimensions, labels, files, options).
    private static let skipArgument: Set<String> = [
        "label", "ref", "eqref", "cite", "citep", "citet", "pageref", "autoref", "cref", "Cref", "vspace", "hspace", "includegraphics",
        "input", "include", "usepackage", "documentclass", "bibliography", "bibliographystyle", "setlength", "setcounter",
        "newcommand", "renewcommand", "def", "definecolor", "pagestyle", "thispagestyle", "url", "hypersetup", "geometry", "color",
        "addbibresource", "graphicspath", "nocite", "index", "begin", "end", "thanks", "footnote", "newtheorem", "DeclareMathOperator",
    ]

    /// Readable text from LaTeX: accents become letters, commands disappear, their text stays.
    static func plain(_ source: String, keepMath: Bool = true) -> String {
        let chars = Array(source)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        var mathDepth = false
        func readGroup(_ start: Int) -> (String, Int)? {
            guard start < chars.count, chars[start] == "{" else { return nil }
            var depth = 0
            var j = start
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "{" { depth += 1 } else if chars[j] == "}" { depth -= 1; if depth == 0 { return (String(chars[(start + 1)..<j]), j + 1) } }
                j += 1
            }
            return (String(chars[(start + 1)...]), chars.count)
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "%":
                while i < chars.count, chars[i] != "\n" { i += 1 }
            case "\\":
                i += 1
                guard i < chars.count else { break }
                let next = chars[i]
                if next.isLetter {
                    var name = ""
                    while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                    while i < chars.count, chars[i] == " " { i += 1 }
                    if name.count == 1, let accent = accents[Character(name)] {
                        // \c{c}, \v s
                        var base: String
                        if let (group, end) = readGroup(i) { base = plain(group); i = end } else if i < chars.count { base = String(chars[i]); i += 1 } else { base = "" }
                        if base == "ı" { base = "i" }
                        out += (base + String(accent)).precomposedStringWithCanonicalMapping
                    } else if skipArgument.contains(name) {
                        while i < chars.count, chars[i] == "*" { i += 1 }
                        if i < chars.count, chars[i] == "[" { while i < chars.count, chars[i] != "]" { i += 1 }; i += 1 }
                        if let (_, end) = readGroup(i) { i = end }
                        if name == "begin" || name == "end", i < chars.count, chars[i] == "[" { while i < chars.count, chars[i] != "]" { i += 1 }; i += 1 }
                    } else if let symbol = symbols[name] {
                        out += symbol
                    } else if i < chars.count, chars[i] == "[" {
                        while i < chars.count, chars[i] != "]" { i += 1 }
                        i += 1
                    }
                } else if let accent = accents[next], i + 1 < chars.count {
                    i += 1
                    var base: String
                    if let (group, end) = readGroup(i) { base = plain(group); i = end } else { base = String(chars[i]); i += 1 }
                    if base == "ı" || base == "\\i" { base = "i" }
                    out += (base + String(accent)).precomposedStringWithCanonicalMapping
                } else {
                    out += symbols[String(next)] ?? String(next)
                    i += 1
                }
            case "{", "}":
                i += 1
            case "$":
                mathDepth.toggle()
                i += 1
                if !keepMath {
                    while i < chars.count, chars[i] != "$" { i += 1 }
                    i += 1
                    mathDepth = false
                    out += "…"
                }
            case "~":
                out += "\u{00A0}"; i += 1
            case "^", "_":
                i += 1
            case "-":
                if i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2] == "-" { out += "—"; i += 3 }
                else if i + 1 < chars.count, chars[i + 1] == "-" { out += "–"; i += 2 }
                else { out += "-"; i += 1 }
            case "`":
                if i + 1 < chars.count, chars[i + 1] == "`" { out += "“"; i += 2 } else { out += "‘"; i += 1 }
            case "'":
                if i + 1 < chars.count, chars[i + 1] == "'" { out += "”"; i += 2 } else { out += "’"; i += 1 }
            default:
                out.append(c); i += 1
            }
        }
        return out
    }

    /// Collapses whitespace (paragraph breaks become single newlines when `paragraphs` is set).
    static func tidy(_ text: String, paragraphs: Bool = false) -> String {
        if paragraphs {
            return text.components(separatedBy: "\n\n").map { tidy($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
    }

    /// The first `{…}` argument after `\command` (outside comments), raw.
    static func argument(of command: String, in text: String) -> String? {
        let chars = Array(text)
        let needle = Array("\\" + command)
        var i = 0
        while i + needle.count <= chars.count {
            if chars[i] == "%" { while i < chars.count, chars[i] != "\n" { i += 1 }; continue }
            if chars[i] == "\\", Array(chars[i..<(i + needle.count)]) == needle,
               i + needle.count == chars.count || !chars[i + needle.count].isLetter {
                var j = i + needle.count
                while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "*" { j += 1 }
                if j < chars.count, chars[j] == "[" {
                    var depth = 0
                    while j < chars.count { if chars[j] == "[" { depth += 1 } else if chars[j] == "]" { depth -= 1; if depth == 0 { j += 1; break } }; j += 1 }
                }
                while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
                guard j < chars.count, chars[j] == "{" else { i += 1; continue }
                var depth = 0
                var k = j
                while k < chars.count {
                    if chars[k] == "\\" { k += 2; continue }
                    if chars[k] == "{" { depth += 1 } else if chars[k] == "}" { depth -= 1; if depth == 0 { return String(chars[(j + 1)..<k]) } }
                    k += 1
                }
                return String(chars[(j + 1)...])
            }
            i += 1
        }
        return nil
    }

    /// The body of the first `\begin{name}…\end{name}`.
    static func environment(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "\\begin{\(name)}") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "\\end{\(name)}") else { return String(rest.prefix(4000)) }
        return String(rest[..<end.lowerBound])
    }

    /// Everything after `\begin{document}` (or the whole file for fragments).
    static func body(_ text: String) -> String {
        guard let start = text.range(of: "\\begin{document}") else { return text }
        let rest = text[start.upperBound...]
        if let end = rest.range(of: "\\end{document}") { return String(rest[..<end.lowerBound]) }
        return String(rest)
    }

    static func stripComments(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var result = ""
            var previous: Character = " "
            for c in line {
                if c == "%" && previous != "\\" { break }
                result.append(c)
                previous = c
            }
            out += result + "\n"
        }
        return out
    }

    /// Words of running text: comments, math, environments of code and command names don't count.
    static func wordCount(_ source: String) -> Int {
        var text = stripComments(body(source))
        for env in ["equation", "equation*", "align", "align*", "gather", "gather*", "verbatim", "lstlisting", "minted", "tikzpicture", "tabular"] {
            text = text.replacingOccurrences(of: "\\\\begin\\{\(NSRegularExpression.escapedPattern(for: env))\\}[\\s\\S]*?\\\\end\\{\(NSRegularExpression.escapedPattern(for: env))\\}", with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\\$\\$[\\s\\S]*?\\$\\$|\\$[^$]*\\$|\\\\\\[[\\s\\S]*?\\\\\\]", with: " x ", options: .regularExpression)
        return PreviewFactory.wordCount(plain(text, keepMath: false))
    }

    /// Splits `\author{A \and B}` into names (first line of each).
    static func authors(_ raw: String) -> [String] {
        raw.components(separatedBy: "\\and").map { part -> String in
            let first = part.components(separatedBy: "\\\\").first ?? part
            let cleaned = first.replacingOccurrences(of: "\\\\thanks\\s*\\{[^{}]*(\\{[^{}]*\\}[^{}]*)*\\}", with: "", options: .regularExpression)
            return tidy(plain(cleaned))
        }.filter { !$0.isEmpty }
    }
}
