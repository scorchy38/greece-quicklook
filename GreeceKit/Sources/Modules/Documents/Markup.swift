import Foundation

/// A forgiving HTML/XML tokenizer: tags, attributes, text and entities. Never throws; anything it
/// can't make sense of is text. Used for EPUB navigation and chapters.
enum Markup {
    enum Token {
        case start(name: String, attributes: [(String, String)], selfClosing: Bool)
        case end(name: String)
        case text(String)
    }

    static let tokenLimit = 400_000

    static func tokens(_ source: String, limit: Int = tokenLimit) -> [Token] {
        let s = Array(source.unicodeScalars)
        var out: [Token] = []
        out.reserveCapacity(min(limit, s.count / 8 + 16))
        var i = 0
        var text = String.UnicodeScalarView()
        func flushText() {
            if !text.isEmpty { out.append(.text(decodeEntities(String(text)))); text = String.UnicodeScalarView() }
        }
        func isNameChar(_ c: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(c) || c == ":" || c == "-" || c == "_" || c == "."
        }
        while i < s.count {
            if out.count >= limit { break }
            let c = s[i]
            guard c == "<", i + 1 < s.count else { text.append(c); i += 1; continue }
            let next = s[i + 1]
            // Comments, CDATA, doctype, processing instructions.
            if next == "!" {
                if matches(s, i, "<!--") {
                    flushText()
                    i = find(s, "-->", from: i + 4).map { $0 + 3 } ?? s.count
                    continue
                }
                if matches(s, i, "<![CDATA[") {
                    flushText()
                    let end = find(s, "]]>", from: i + 9) ?? s.count
                    out.append(.text(String(String.UnicodeScalarView(s[(i + 9)..<end]))))
                    i = min(s.count, end + 3)
                    continue
                }
                flushText()
                i = (s[i...].firstIndex(of: ">") ?? s.count - 1) + 1
                continue
            }
            if next == "?" {
                flushText()
                i = find(s, "?>", from: i + 2).map { $0 + 2 } ?? s.count
                continue
            }
            // End tag.
            if next == "/" {
                var j = i + 2
                var name = String.UnicodeScalarView()
                while j < s.count, isNameChar(s[j]) { name.append(s[j]); j += 1 }
                guard !name.isEmpty else { text.append(c); i += 1; continue }
                flushText()
                while j < s.count, s[j] != ">" { j += 1 }
                out.append(.end(name: String(name).lowercased()))
                i = j + 1
                continue
            }
            // Start tag.
            guard CharacterSet.letters.contains(next) else { text.append(c); i += 1; continue }
            var j = i + 1
            var name = String.UnicodeScalarView()
            while j < s.count, isNameChar(s[j]) { name.append(s[j]); j += 1 }
            var attributes: [(String, String)] = []
            var selfClosing = false
            while j < s.count {
                while j < s.count, CharacterSet.whitespacesAndNewlines.contains(s[j]) { j += 1 }
                guard j < s.count else { break }
                if s[j] == ">" { j += 1; break }
                if s[j] == "/" { selfClosing = true; j += 1; continue }
                var attrName = String.UnicodeScalarView()
                while j < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[j]), s[j] != "=", s[j] != ">", s[j] != "/" || attrName.isEmpty == false && false { attrName.append(s[j]); j += 1 }
                if attrName.isEmpty { j += 1; continue }
                while j < s.count, CharacterSet.whitespacesAndNewlines.contains(s[j]) { j += 1 }
                var value = ""
                if j < s.count, s[j] == "=" {
                    j += 1
                    while j < s.count, CharacterSet.whitespacesAndNewlines.contains(s[j]) { j += 1 }
                    if j < s.count, s[j] == "\"" || s[j] == "'" {
                        let quote = s[j]
                        let end = s[(j + 1)...].firstIndex(of: quote) ?? s.count
                        value = String(String.UnicodeScalarView(s[(j + 1)..<end]))
                        j = min(s.count, end + 1)
                    } else {
                        var v = String.UnicodeScalarView()
                        while j < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[j]), s[j] != ">" { v.append(s[j]); j += 1 }
                        value = String(v)
                    }
                }
                if attributes.count < 64 { attributes.append((String(attrName).lowercased(), decodeEntities(value))) }
            }
            flushText()
            out.append(.start(name: String(name).lowercased(), attributes: attributes, selfClosing: selfClosing))
            i = j
        }
        flushText()
        return out
    }

    private static func matches(_ s: [Unicode.Scalar], _ i: Int, _ needle: String) -> Bool {
        let n = Array(needle.unicodeScalars)
        guard i + n.count <= s.count else { return false }
        for k in 0..<n.count where s[i + k] != n[k] { return false }
        return true
    }

    private static func find(_ s: [Unicode.Scalar], _ needle: String, from start: Int) -> Int? {
        let n = Array(needle.unicodeScalars)
        var i = start
        while i + n.count <= s.count {
            if s[i] == n[0], matches(s, i, needle) { return i }
            i += 1
        }
        return nil
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™",
        "shy": "\u{00AD}", "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "laquo": "«", "raquo": "»",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "ouml": "ö",
        "uuml": "ü", "szlig": "ß", "ccedil": "ç", "ntilde": "ñ", "oacute": "ó", "iacute": "í", "uacute": "ú", "deg": "°",
        "middot": "·", "bull": "•", "dagger": "†", "Dagger": "‡", "sect": "§", "para": "¶", "times": "×", "frac12": "½",
        "pound": "£", "euro": "€", "yen": "¥", "cent": "¢", "iexcl": "¡", "iquest": "¿", "zwnj": "\u{200C}", "zwj": "\u{200D}",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semi = after.prefix(12).firstIndex(of: ";") else { out += "&"; rest = after; continue }
            let entity = String(after[..<semi])
            var decoded: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                decoded = named[entity]
            }
            if let decoded, decoded != "\0" { out += decoded; rest = after[after.index(after: semi)...] }
            else { out += "&"; rest = after }
        }
        return out + rest
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// Visible text of markup (for titles, word counts and descriptions).
    static func text(_ source: String, limit: Int = tokenLimit) -> String {
        var out = ""
        var skip = 0
        for token in tokens(source, limit: limit) {
            switch token {
            case .start(let name, _, let selfClosing):
                if ["script", "style", "head", "title"].contains(name), !selfClosing { skip += 1 }
                if ["p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "blockquote", "section"].contains(name) { out += "\n" }
            case .end(let name):
                if ["script", "style", "head", "title"].contains(name) { skip = max(0, skip - 1) }
                if ["p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name) { out += "\n" }
            case .text(let t):
                if skip == 0 { out += t }
            }
        }
        return out
    }
}

/// Turns untrusted (X)HTML into a small, inert subset: known elements and attributes only,
/// no scripts, styles, forms, frames, event handlers or remote resources. Links and images are
/// rewritten by the caller.
struct HTMLSanitizer {
    /// Resolves an image source to a page URL (or nil to drop the image).
    var image: (String) -> String? = { _ in nil }
    /// Rewrites a link: returns attributes for the <a>, or nil to keep only its text.
    var link: (String) -> [(String, String)]? = { _ in nil }
    /// Prefix for ids, so a chapter's anchors can't collide with the page's own.
    var idPrefix = "x-"

    static let allowed: Set<String> = [
        "p", "div", "span", "h1", "h2", "h3", "h4", "h5", "h6", "em", "i", "strong", "b", "u", "s", "strike", "sub", "sup", "small",
        "big", "br", "hr", "blockquote", "q", "cite", "pre", "code", "kbd", "samp", "var", "abbr", "acronym", "dfn", "ul", "ol",
        "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col", "figure",
        "figcaption", "img", "a", "section", "article", "aside", "header", "footer", "nav", "main", "ruby", "rt", "rp", "rb",
        "mark", "del", "ins", "time", "wbr", "center", "font", "address", "bdi", "bdo", "hgroup", "details", "summary", "tt",
        "math", "mi", "mn", "mo", "ms", "mtext", "mrow", "msup", "msub", "msubsup", "mfrac", "msqrt", "mroot", "mtable", "mtr",
        "mtd", "munder", "mover", "munderover", "mspace", "mstyle", "mpadded", "mphantom", "menclose", "mfenced", "semantics",
    ]
    /// Elements dropped together with everything inside them.
    static let dropped: Set<String> = [
        "script", "style", "head", "title", "noscript", "template", "iframe", "frame", "frameset", "object", "embed", "applet",
        "form", "input", "button", "select", "textarea", "option", "link", "meta", "base", "audio", "video", "source", "track",
        "canvas", "annotation-xml", "annotation", "portal", "xml", "svg:script", "foreignobject", "marquee",
    ]
    static let renamed: [String: String] = ["center": "div", "font": "span", "nav": "div", "main": "div", "tt": "code", "strike": "s", "acronym": "abbr", "big": "span"]
    static let voidElements: Set<String> = ["br", "hr", "img", "wbr", "col", "mspace"]
    static let keptClasses: Set<String> = ["verse", "poem", "poetry", "epigraph", "center", "centered", "centre", "right", "smallcaps", "small-caps", "sc", "dedication", "noindent", "no-indent", "first", "attribution", "signature", "letter", "salutation", "stanza", "chapter-number", "chapter-title", "subtitle", "byline", "quote", "blockquote", "illustration", "caption", "footnote", "note", "dropcap", "initial"]
    static let keptTypes: Set<String> = ["footnote", "endnote", "rearnote", "noteref", "epigraph", "dedication", "subtitle", "title", "bridgehead", "pullquote", "sidebar", "z3998:poem", "z3998:verse", "z3998:stanza"]

    func sanitize(_ source: String, limit: Int = Markup.tokenLimit) -> String {
        var out = ""
        out.reserveCapacity(source.utf8.count / 2)
        var stack: [String] = []
        var drop = 0
        var dropStack: [String] = []
        var svgImage = false
        var inSVG = 0
        var inBody = !source.contains("<body")
        for token in Markup.tokens(source, limit: limit) {
            switch token {
            case .start(let rawName, let attributes, let selfClosing):
                let name = rawName.split(separator: ":").last.map(String.init) ?? rawName
                if rawName == "body" { inBody = true; continue }
                if drop > 0 {
                    if !selfClosing && !Self.voidElements.contains(name) { dropStack.append(name); drop += 1 }
                    continue
                }
                if Self.dropped.contains(rawName) || Self.dropped.contains(name) {
                    if !selfClosing { dropStack.append(name); drop += 1 }
                    continue
                }
                guard inBody else { continue }
                if name == "svg" { if !selfClosing { inSVG += 1 }; continue }
                if inSVG > 0 {
                    // A cover wrapped in SVG: keep its <image>.
                    if name == "image", let href = attributes.first(where: { $0.0 == "xlink:href" || $0.0 == "href" })?.1, let src = image(href) {
                        out += "<img src=\"\(Markup.escape(src))\" alt=\"\">"
                        svgImage = true
                    }
                    continue
                }
                guard Self.allowed.contains(name) else { continue }
                let tag = Self.renamed[name] ?? name
                var attrs: [String] = []
                var classes: [String] = []
                for (key, value) in attributes {
                    let k = key.split(separator: ":").last.map(String.init) ?? key
                    switch k {
                    case "id": if key == "id" || key == "xml:id" { attrs.append("id=\"\(Markup.escape(idPrefix + value))\"") }
                    case "title", "alt", "lang", "dir": attrs.append("\(k)=\"\(Markup.escape(value))\"")
                    case "colspan", "rowspan", "start", "value", "span":
                        if let n = Int(value.trimmingCharacters(in: .whitespaces)), n >= 0, n < 10000 { attrs.append("\(k)=\"\(n)\"") }
                    case "reversed": if name == "ol" { attrs.append("reversed") }
                    case "type": if name == "ol", ["1", "a", "A", "i", "I"].contains(value) { attrs.append("type=\"\(value)\"") }
                        else if key == "epub:type" { classes += value.split(separator: " ").map(String.init).filter { Self.keptTypes.contains($0) }.map { "et-" + $0.replacingOccurrences(of: ":", with: "-") } }
                    case "class": classes += value.split(separator: " ").map { $0.lowercased() }.filter { Self.keptClasses.contains($0) }.map { "ec-" + $0 }
                    case "mathvariant", "display", "displaystyle", "scriptlevel", "linethickness", "fence", "separator", "stretchy", "accent", "accentunder", "columnalign", "rowalign", "notation":
                        if inMath(stack) || name == "math" { attrs.append("\(k)=\"\(Markup.escape(value))\"") }
                    case "align": if ["left", "right", "center", "justify"].contains(value.lowercased()) { classes.append("align-" + value.lowercased()) }
                    case "width", "height":
                        if name == "img", let n = Int(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "")), n > 0, n < 10000 { attrs.append("\(k)=\"\(n)\"") }
                    default: break
                    }
                }
                if name == "img" {
                    guard let source = attributes.first(where: { $0.0 == "src" })?.1, let src = image(source) else { continue }
                    attrs.append("src=\"\(Markup.escape(src))\"")
                    attrs.append("loading=\"lazy\"")
                }
                if name == "a" {
                    if let href = attributes.first(where: { $0.0 == "href" })?.1, let rewritten = link(href) {
                        for (k, v) in rewritten { attrs.append("\(k)=\"\(Markup.escape(v))\"") }
                    }
                }
                if let typeClass = attributes.first(where: { $0.0 == "epub:type" })?.1, typeClass.contains("pagebreak") { continue }
                if !classes.isEmpty { attrs.append("class=\"\(classes.joined(separator: " "))\"") }
                out += "<\(tag)\(attrs.isEmpty ? "" : " " + attrs.joined(separator: " "))>"
                if Self.voidElements.contains(name) { continue }
                if selfClosing { out += "</\(tag)>"; continue }
                stack.append(tag)
                if stack.count > 200 { return out + stack.reversed().map { "</\($0)>" }.joined() }
            case .end(let rawName):
                let name = rawName.split(separator: ":").last.map(String.init) ?? rawName
                if drop > 0 {
                    if let index = dropStack.lastIndex(of: name) { drop -= dropStack.count - index; dropStack.removeSubrange(index...) }
                    continue
                }
                if name == "svg" { inSVG = max(0, inSVG - 1); continue }
                if inSVG > 0 { continue }
                if rawName == "body" { inBody = false; continue }
                let tag = Self.renamed[name] ?? name
                guard let index = stack.lastIndex(of: tag) else { continue }
                // Close anything left open inside it.
                for open in stack[index...].reversed() { out += "</\(open)>" }
                stack.removeSubrange(index...)
            case .text(let text):
                guard drop == 0, inSVG == 0, inBody else { continue }
                out += Markup.escape(text)
            }
        }
        _ = svgImage
        for open in stack.reversed() { out += "</\(open)>" }
        return out
    }

    private func inMath(_ stack: [String]) -> Bool { stack.contains("math") }
}
