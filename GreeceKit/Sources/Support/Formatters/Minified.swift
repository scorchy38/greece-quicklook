import Foundation

/// Recognises code squashed onto a few very long lines, as bundlers and minifiers write it.
///
/// Conservative on purpose: a readable file with one long line (a data URI, a long string, a
/// generated table) is left alone. Most of the text has to sit on very long lines, and those lines
/// have to be dense with the separators a formatter would break at.
public enum Minified {

    /// Characters a formatter breaks lines at, per kind of source.
    public enum Separators {
        case braces      // ; { }  (JavaScript, CSS, GraphQL)
        case tags        // <      (XML, HTML)
        case clauses     // , (    (SQL)

        func contains(_ byte: UInt8) -> Bool {
            switch self {
            case .braces: return byte == 0x3B || byte == 0x7B || byte == 0x7D
            case .tags: return byte == 0x3C
            case .clauses: return byte == 0x2C || byte == 0x28
            }
        }
    }

    static let sampleSize = 256 * 1024
    static let longLine = 200

    public static func looksMinified(_ text: String, separators: Separators) -> Bool {
        var total = 0, longBytes = 0, longSeparators = 0
        var line = 0, lineSeparators = 0
        func endLine() {
            if line > longLine { longBytes += line; longSeparators += lineSeparators }
            line = 0
            lineSeparators = 0
        }
        for byte in text.utf8.prefix(sampleSize) {
            total += 1
            if byte == 0x0A { endLine(); continue }
            line += 1
            if separators.contains(byte) { lineSeparators += 1 }
        }
        endLine()
        guard total >= 160, longBytes > 0 else { return false }
        // Most of the text on very long lines…
        guard longBytes * 10 >= total * 6 else { return false }
        // …that are made of many statements, rules or tags, not one long literal.
        return longSeparators * 1000 >= longBytes * 8
    }
}
