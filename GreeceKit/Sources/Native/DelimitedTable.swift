import Foundation

/// A parsed CSV / TSV document.
public struct DelimitedTable: Sendable {
    public var header: [String]?
    public var rows: [[String]]
    public var columnCount: Int
    /// Columns in the widest row, before the display cap.
    public var totalColumns: Int
    public var separator: UInt8
    public var totalRows: Int
    public var truncated: Bool { totalRows > rows.count }

    public var separatorName: String {
        switch separator {
        case UInt8(ascii: ","): return "Comma-separated"
        case UInt8(ascii: ";"): return "Semicolon-separated"
        case UInt8(ascii: "\t"): return "Tab-separated"
        case UInt8(ascii: "|"): return "Pipe-separated"
        default: return "Delimited"
        }
    }

    /// More columns than this is not a table anyone reads; it would only stall the UI.
    public static let maxColumns = 1_000

    public static func parse(_ text: String, separator: UInt8? = nil, maxRows: Int = 100_000) -> DelimitedTable {
        let bytes = Array(text.utf8)
        let sep = separator ?? sniffSeparator(bytes)
        var records = parseRecords(bytes, separator: sep, maxRows: maxRows + 1)
        let total = records.total
        var rows = records.rows

        let totalColumns = rows.reduce(0) { max($0, $1.count) }
        let columnCount = min(totalColumns, maxColumns)
        var header: [String]?
        if rows.count > 1, looksLikeHeader(rows) {
            header = rows.removeFirst()
            records.total -= 1
        } else if rows.count == 1 {
            header = nil
        }
        let dataTotal = header == nil ? total : total - 1
        if rows.count > maxRows { rows.removeLast(rows.count - maxRows) }
        return DelimitedTable(header: header, rows: rows, columnCount: columnCount, totalColumns: totalColumns, separator: sep, totalRows: dataTotal)
    }

    // MARK: - Separator

    static func sniffSeparator(_ bytes: [UInt8]) -> UInt8 {
        let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]
        var counts: [UInt8: [Int]] = [:]
        var lineCounts: [UInt8: Int] = [:]
        var inQuotes = false
        var lines = 0
        for byte in bytes.prefix(64 * 1024) {
            if byte == UInt8(ascii: "\"") { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if byte == 0x0A {
                for c in candidates { counts[c, default: []].append(lineCounts[c, default: 0]) }
                lineCounts = [:]
                lines += 1
                if lines >= 30 { break }
            } else if candidates.contains(byte) {
                lineCounts[byte, default: 0] += 1
            }
        }
        if lines < 30, !lineCounts.isEmpty { for c in candidates { counts[c, default: []].append(lineCounts[c, default: 0]) } }

        var best = UInt8(ascii: ",")
        var bestScore = 0.0
        for c in candidates {
            let perLine = counts[c] ?? []
            guard let first = perLine.first, first > 0 else { continue }
            let consistent = perLine.filter { $0 == first }.count
            let score = Double(consistent) / Double(perLine.count) * Double(min(first, 50) + 1)
            if score > bestScore { bestScore = score; best = c }
        }
        return best
    }

    // MARK: - Records

    static func parseRecords(_ bytes: [UInt8], separator: UInt8, maxRows: Int) -> (rows: [[String]], total: Int) {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var total = 0
        var index = 0
        let count = bytes.count
        let quote = UInt8(ascii: "\"")

        @inline(__always) func endField() {
            if row.count <= maxColumns { row.append(String(decoding: field, as: UTF8.self)) }
            field.removeAll(keepingCapacity: true)
        }
        @inline(__always) func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) {
                total += 1
                if rows.count < maxRows { rows.append(row) }
            }
            row = []
            row.reserveCapacity(rows.first?.count ?? 8)
        }

        while index < count {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    if index + 1 < count && bytes[index + 1] == quote { field.append(quote); index += 1 }
                    else { inQuotes = false }
                } else {
                    field.append(byte)
                }
            } else if byte == quote && field.isEmpty {
                inQuotes = true
            } else if byte == separator {
                endField()
            } else if byte == 0x0A {
                endRow()
            } else if byte == 0x0D {
                if index + 1 < count && bytes[index + 1] == 0x0A { index += 1 }
                endRow()
            } else {
                field.append(byte)
            }
            index += 1
            // Past the display limit only count rows; skip building strings.
            if rows.count >= maxRows && !inQuotes {
                var remaining = 0
                var quoted = false
                while index < count {
                    let b = bytes[index]
                    if b == quote { quoted.toggle() } else if b == 0x0A && !quoted { remaining += 1 }
                    index += 1
                }
                total += remaining + (bytes.last == 0x0A ? 0 : 1)
                return (rows, total)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return (rows, total)
    }

    // MARK: - Header heuristic

    static func looksLikeHeader(_ rows: [[String]]) -> Bool {
        let first = rows[0]
        let sample = rows.dropFirst().prefix(50)
        // A column whose first value is text while the rest are numbers is a strong header signal.
        for column in 0..<first.count {
            let values = sample.compactMap { column < $0.count ? $0[column] : nil }.filter { !$0.isEmpty }
            guard values.count >= 2 else { continue }
            let numeric = values.filter { DelimitedTable.number($0) != nil }.count
            if numeric * 10 >= values.count * 8 && DelimitedTable.number(first[column]) == nil && !first[column].isEmpty { return true }
        }
        // Otherwise: all distinct, non-empty, non-numeric labels.
        let labels = first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !labels.contains(where: \.isEmpty), Set(labels).count == labels.count else { return false }
        return !labels.contains { DelimitedTable.number($0) != nil }
    }

    /// Parses numbers as people write them in spreadsheets: 1,234.5  -12%  $40  1e6.
    static func number(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count < 40 else { return nil }
        for symbol in ["$", "€", "£", "¥", "%", "_"] { s = s.replacingOccurrences(of: symbol, with: "") }
        if s.contains(",") && !s.contains(" ") { s = s.replacingOccurrences(of: ",", with: "") }
        guard let first = s.first, first.isNumber || first == "-" || first == "+" || first == "." else { return nil }
        return Double(s)
    }

    /// Columns where most sampled values are numeric get right alignment.
    public func numericColumns() -> Set<Int> {
        var result = Set<Int>()
        let sample = rows.prefix(300)
        for column in 0..<columnCount {
            let values = sample.compactMap { column < $0.count ? $0[column] : nil }.filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            let numeric = values.filter { DelimitedTable.number($0) != nil }.count
            if numeric * 100 >= values.count * 85 { result.insert(column) }
        }
        return result
    }

    /// Spreadsheet-style column letters: A … Z, AA, AB …
    public static func columnLetter(_ index: Int) -> String {
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }
}
