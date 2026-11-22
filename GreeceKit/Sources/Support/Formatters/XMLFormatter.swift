import Foundation

/// Re-indents XML one element per line without parsing it into a tree, so attributes, quoting,
/// entities, comments and CDATA come out byte for byte as they went in. Only whitespace between
/// tags changes. Elements holding text keep it on their own line exactly as written, and mixed
/// content (text beside child elements) and `xml:space="preserve"` are copied untouched.
/// Malformed documents are refused rather than guessed at.
public enum XMLFormatter {

    static let maxBytes = 8 * 1024 * 1024
    static let maxTokens = 2_000_000
    static let maxDepth = 1_000

    enum Kind { case text, cdata, open, close, empty, other }

    struct Token {
        var kind: Kind
        var start: Int
        var end: Int
        var name: ArraySlice<UInt8> = []
    }

    public static func prettyPrinted(_ text: String, indent: Int = 2) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.count <= maxBytes, let tokens = tokenize(bytes), !tokens.isEmpty else { return nil }

        func isBlank(_ token: Token) -> Bool {
            bytes[token.start..<token.end].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        }

        // Match every element with its end tag (anything unbalanced means we don't understand it)
        // and note what each element directly holds.
        var match = [Int](repeating: -1, count: tokens.count)
        var hasText = [Bool](repeating: false, count: tokens.count)
        var hasChildren = [Bool](repeating: false, count: tokens.count)
        var blank = [Bool](repeating: false, count: tokens.count)
        var stack: [Int] = []
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .text:
                blank[index] = isBlank(token)
                if !blank[index], let parent = stack.last { hasText[parent] = true }
            case .open:
                if let parent = stack.last { hasChildren[parent] = true }
                stack.append(index)
                guard stack.count <= maxDepth else { return nil }
            case .close:
                guard let open = stack.popLast(), tokens[open].name == token.name else { return nil }
                match[open] = index
            case .cdata:
                if let parent = stack.last { hasText[parent] = true }
            case .empty, .other:
                if let parent = stack.last { hasChildren[parent] = true }
            }
        }
        guard stack.isEmpty else { return nil }

        /// Elements copied as written: empty, text-only, mixed content, or whitespace-preserving.
        func isVerbatim(_ open: Int) -> Bool {
            if !hasChildren[open] || hasText[open] { return true }
            return contains(bytes[tokens[open].start..<tokens[open].end], Array("xml:space".utf8))
        }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + bytes.count / 3)
        let pad = [UInt8](repeating: 0x20, count: indent)
        var depth = 0
        func newline() {
            if !output.isEmpty { output.append(0x0A) }
            for _ in 0..<depth { output.append(contentsOf: pad) }
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .text:
                if !blank[index] {
                    newline()
                    output.append(contentsOf: trimmed(bytes[token.start..<token.end]))
                }
            case .open:
                newline()
                if isVerbatim(index) {
                    let close = match[index]
                    output.append(contentsOf: bytes[token.start..<tokens[close].end])
                    index = close + 1
                    continue
                }
                output.append(contentsOf: bytes[token.start..<token.end])
                depth += 1
            case .close:
                depth -= 1
                newline()
                output.append(contentsOf: bytes[token.start..<token.end])
            case .cdata, .empty, .other:
                newline()
                output.append(contentsOf: bytes[token.start..<token.end])
            }
            index += 1
        }
        output.append(0x0A)
        let result = String(decoding: output, as: UTF8.self)
        guard CodeFormatter.sameNonWhitespace(text, result) else { return nil }
        return result
    }

    // MARK: - Tokens

    static func tokenize(_ bytes: [UInt8]) -> [Token]? {
        var tokens: [Token] = []
        var i = 0
        let n = bytes.count
        func has(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix.utf8)
            return index + p.count <= n && bytes[index..<(index + p.count)].elementsEqual(p)
        }
        func find(_ terminator: String, from index: Int) -> Int? {
            let t = Array(terminator.utf8)
            var j = index
            while j + t.count <= n {
                if bytes[j] == t[0] && bytes[j..<(j + t.count)].elementsEqual(t) { return j + t.count }
                j += 1
            }
            return nil
        }
        func name(from index: Int) -> ArraySlice<UInt8> {
            var j = index
            while j < n, !(bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D || bytes[j] == 0x2F || bytes[j] == 0x3E) { j += 1 }
            return bytes[index..<j]
        }

        while i < n {
            guard tokens.count < maxTokens else { return nil }
            if bytes[i] != 0x3C {
                var j = i
                while j < n, bytes[j] != 0x3C { j += 1 }
                tokens.append(Token(kind: .text, start: i, end: j))
                i = j
                continue
            }
            let end: Int?
            var kind = Kind.other
            var tagName: ArraySlice<UInt8> = []
            let next = i + 1 < n ? bytes[i + 1] : 0
            if next == 0x21, has("<!--", at: i) {
                end = find("-->", from: i + 4)
            } else if next == 0x21, has("<![CDATA[", at: i) {
                end = find("]]>", from: i + 9)
                kind = .cdata
            } else if next == 0x3F {
                end = find("?>", from: i + 2)
            } else if next == 0x21 {
                // A declaration, perhaps with an internal subset in brackets.
                var j = i + 2, brackets = 0, quote: UInt8 = 0
                var found: Int?
                while j < n {
                    let b = bytes[j]
                    if quote != 0 { if b == quote { quote = 0 } }
                    else if b == 0x22 || b == 0x27 { quote = b }
                    else if b == 0x5B { brackets += 1 }
                    else if b == 0x5D { brackets -= 1 }
                    else if b == 0x3E && brackets <= 0 { found = j + 1; break }
                    j += 1
                }
                end = found
            } else {
                // A start or end tag; attribute values may hold '>'.
                var j = i + 1, quote: UInt8 = 0
                var found: Int?
                while j < n {
                    let b = bytes[j]
                    if quote != 0 { if b == quote { quote = 0 } }
                    else if b == 0x22 || b == 0x27 { quote = b }
                    else if b == 0x3C { return nil }
                    else if b == 0x3E { found = j + 1; break }
                    j += 1
                }
                end = found
                if let found {
                    if i + 1 < n, bytes[i + 1] == 0x2F {
                        kind = .close
                        tagName = name(from: i + 2)
                    } else {
                        kind = bytes[found - 2] == 0x2F ? .empty : .open
                        tagName = name(from: i + 1)
                    }
                    if tagName.isEmpty { return nil }
                }
            }
            guard let end else { return nil }
            tokens.append(Token(kind: kind, start: i, end: end, name: tagName))
            i = end
        }
        return tokens
    }

    private static func contains(_ haystack: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        var i = haystack.startIndex
        while i + needle.count <= haystack.endIndex {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) { return true }
            i += 1
        }
        return false
    }

    private static func trimmed(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        guard let first = slice.firstIndex(where: { !isSpace($0) }), let last = slice.lastIndex(where: { !isSpace($0) }) else { return [] }
        return slice[first...last]
    }
}
