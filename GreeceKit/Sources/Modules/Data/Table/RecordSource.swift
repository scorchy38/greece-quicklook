import AppKit

/// A column of a table held in memory.
struct RecordColumn {
    enum Sort { case natural, numeric }
    var title: String
    var toolTip: String?
    /// Right-aligned and sorted as numbers.
    var numeric = false
    /// Sorting rule; numeric columns sort numerically whatever this says.
    var sort: Sort = .natural
    /// Offer a column profile (types, distribution, top values).
    var profiled = true
    /// A width hint in points; nil measures the values.
    var width: CGFloat?
    /// A caption under the title (a field's type), when profiles aren't shown.
    var caption: String?
}

/// Rows held in memory: delimited text, JSON Lines, dBase, lock files, string catalogs, Parquet.
protocol RecordStore: AnyObject {
    var columns: [RecordColumn] { get }
    var rowCount: Int { get }
    func value(row: Int, column: Int) -> GridValue
    /// The raw text, for sorting, filtering and profiling ("" when empty).
    func text(row: Int, column: Int) -> String
    func isDimmed(row: Int) -> Bool
}

extension RecordStore {
    func text(row: Int, column: Int) -> String { value(row: row, column: column).plainText }
    func isDimmed(row: Int) -> Bool { false }
}

/// The simplest store: an array of rows of values.
final class RecordTable: RecordStore {
    var columns: [RecordColumn]
    var rows: [[GridValue]]
    var dimmed: Set<Int> = []

    init(columns: [RecordColumn], rows: [[GridValue]]) {
        self.columns = columns
        self.rows = rows
    }

    var rowCount: Int { rows.count }

    func value(row: Int, column: Int) -> GridValue {
        let values = rows[row]
        return column < values.count ? values[column] : .placeholder("")
    }

    func isDimmed(row: Int) -> Bool { dimmed.contains(row) }
}

/// Delimited text, without copying its fields.
final class DelimitedStore: RecordStore {
    let table: DelimitedTable
    let columns: [RecordColumn]

    init(table: DelimitedTable) {
        self.table = table
        let numeric = table.numericColumns()
        columns = (0..<table.columnCount).map { column in
            var title = DelimitedTable.columnLetter(column)
            if let header = table.header, column < header.count, !header[column].isEmpty { title = header[column] }
            return RecordColumn(title: title, numeric: numeric.contains(column), sort: numeric.contains(column) ? .numeric : .natural)
        }
    }

    var rowCount: Int { table.rows.count }

    func value(row: Int, column: Int) -> GridValue { .text(text(row: row, column: column)) }

    func text(row: Int, column: Int) -> String {
        let fields = table.rows[row]
        return column < fields.count ? fields[column] : ""
    }
}

/// Sorts, filters and measures a `RecordStore` for `GridView`.
final class RecordGridSource: GridSource {
    let store: RecordStore
    /// Visible rows, in display order, as indexes into the store.
    private(set) var order: [Int]
    private var sortState: (column: Int, ascending: Bool)?
    /// Text to find in any column.
    private(set) var filter = ""
    /// Conditions on single columns. A row shows when it meets all of them and the text filter.
    private(set) var columnFilters: [ColumnFilter] = []
    private var searchIndex: [[UInt8]]?
    private var widths: [CGFloat]
    /// Inferred kinds from profiles, used to sort dates and numbers properly.
    var sortKinds: [Int: ColumnProfile.Kind] = [:]
    /// Tables at least this long filter off the main thread.
    static let backgroundRows = 20_000

    init(store: RecordStore) {
        self.store = store
        order = Array(0..<store.rowCount)
        widths = []
        widths = store.columns.indices.map(measure)
    }

    var columns: [RecordColumn] { store.columns }
    var columnCount: Int { store.columns.count }
    var rowCount: Int { order.count }
    var totalRows: Int { store.rowCount }
    var isFiltered: Bool { !filter.isEmpty || !columnFilters.isEmpty }

    func title(ofColumn column: Int) -> String { store.columns[column].title }
    func toolTip(ofColumn column: Int) -> String? { store.columns[column].toolTip }
    func isNumeric(column: Int) -> Bool { store.columns[column].numeric }
    func estimatedWidth(ofColumn column: Int) -> CGFloat { widths[column] }
    func value(row: Int, column: Int) -> GridValue { store.value(row: order[row], column: column) }
    func isDimmed(row: Int) -> Bool { store.isDimmed(row: order[row]) }
    /// The raw text behind a visible cell: what column filters compare.
    func text(row: Int, column: Int) -> String { store.text(row: order[row], column: column) }

    /// Holds numbers, as declared by its store or as its profile found.
    func holdsNumbers(column: Int) -> Bool {
        let info = store.columns[column]
        return info.numeric || info.sort == .numeric || sortKinds[column] == .integer || sortKinds[column] == .number
    }

    private func measure(_ column: Int) -> CGFloat {
        let info = store.columns[column]
        if let width = info.width { return width }
        var longest = info.title.count + 3
        let sample = min(store.rowCount, 200)
        for row in 0..<sample {
            longest = max(longest, min(store.value(row: row, column: column).plainText.count, 60))
        }
        if let caption = info.caption { longest = max(longest, caption.count + 2) }
        return min(max(CGFloat(longest) * 7.4 + 22, 64), 360)
    }

    // MARK: - Sorting

    func sort(column: Int, ascending: Bool, completion: @escaping (Bool) -> Void) {
        sortState = (column, ascending)
        // Supersedes a filter still running in the background: this order already includes it.
        generation &+= 1
        order = rows(for: query)
        completion(true)
    }

    /// Everything that decides the visible rows, captured on the main thread so it can be
    /// evaluated on any.
    private struct Query {
        var text: String
        var filters: [ColumnFilter]
        var sort: (column: Int, ascending: Bool, kind: ColumnProfile.Kind?)?
    }

    private var query: Query {
        Query(text: filter, filters: columnFilters, sort: sortState.map { ($0.column, $0.ascending, sortKinds[$0.column]) })
    }

    /// The visible rows for a query. Reads only the store and the search index, so it can run on
    /// any thread.
    private func rows(for query: Query) -> [Int] {
        var rows = query.text.isEmpty ? Array(0..<store.rowCount) : matchingRows(query.text)
        if !query.filters.isEmpty {
            let store = self.store
            rows = rows.filter { row in query.filters.allSatisfy { $0.matches(store.text(row: row, column: $0.column)) } }
        }
        if let sort = query.sort {
            rows = sorted(rows, column: sort.column, ascending: sort.ascending, kind: sort.kind)
        }
        return rows
    }

    private func sorted(_ rows: [Int], column: Int, ascending: Bool, kind: ColumnProfile.Kind?) -> [Int] {
        let info = store.columns[column]
        if info.numeric || info.sort == .numeric || kind == .integer || kind == .number || kind == .date {
            // Numbers (or dates) first, in order; then anything that isn't one, in text order.
            let keys: [Double] = rows.map { row in
                let text = store.text(row: row, column: column)
                if kind == .date { return DataValueParser.date(text) ?? .nan }
                return DataValueParser.number(text) ?? .nan
            }
            var indices = Array(rows.indices)
            indices.sort { a, b in
                let x = keys[a], y = keys[b]
                if x.isNaN || y.isNaN {
                    if x.isNaN && y.isNaN { return rows[a] < rows[b] }
                    return !x.isNaN
                }
                if x == y { return rows[a] < rows[b] }
                return ascending ? x < y : x > y
            }
            return indices.map { rows[$0] }
        }
        // Natural-order keys compare with memcmp: sorting stays fast on large tables.
        let keys: [[UInt8]] = rows.map { NaturalOrder.key(store.text(row: $0, column: column)) }
        var indices = Array(rows.indices)
        indices.sort { a, b in
            let lhs = keys[a], rhs = keys[b]
            // Empty values always go last.
            if lhs.isEmpty || rhs.isEmpty {
                if lhs.isEmpty && rhs.isEmpty { return rows[a] < rows[b] }
                return !lhs.isEmpty
            }
            let result = NaturalOrder.compareKeys(lhs, rhs)
            if result == 0 { return rows[a] < rows[b] }
            return ascending ? result < 0 : result > 0
        }
        return indices.map { rows[$0] }
    }

    // MARK: - Filtering

    /// Keeps rows containing `query` in any column (case-insensitive). `completion` runs on the
    /// main thread once the rows are in place.
    func setFilter(_ query: String, completion: @escaping () -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed != filter else { completion(); return }
        filter = trimmed
        refilter(completion: completion)
    }

    /// Adds a column filter in place of any it makes pointless (see `ColumnFilter.replaces`).
    func addColumnFilter(_ new: ColumnFilter, completion: @escaping () -> Void) {
        setColumnFilters(ColumnFilter.adding(new, to: columnFilters), completion: completion)
    }

    func removeColumnFilter(_ old: ColumnFilter, completion: @escaping () -> Void) {
        setColumnFilters(columnFilters.filter { $0 != old }, completion: completion)
    }

    func setColumnFilters(_ filters: [ColumnFilter], completion: @escaping () -> Void) {
        guard filters != columnFilters else { completion(); return }
        columnFilters = filters
        refilter(completion: completion)
    }

    /// Clears the text filter and every column filter.
    func clearFilters(completion: @escaping () -> Void) {
        guard isFiltered else { completion(); return }
        filter = ""
        columnFilters = []
        refilter(completion: completion)
    }

    /// Bumped by every change to the rows, so a slow filter that finishes late can't bring back
    /// an older state.
    private var generation = 0

    /// Works the rows out again: at once for small tables, off the main thread for large ones.
    private func refilter(completion: @escaping () -> Void) {
        generation &+= 1
        let current = generation
        let query = self.query
        guard store.rowCount >= Self.backgroundRows else {
            order = rows(for: query)
            completion()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let rows = self.rows(for: query)
            DispatchQueue.main.async { [self] in
                if generation == current { order = rows }
                completion()
            }
        }
    }

    private let indexLock = NSLock()

    private func buildSearchIndex() -> [[UInt8]] {
        indexLock.lock()
        defer { indexLock.unlock() }
        if let searchIndex { return searchIndex }
        let columns = store.columns.count
        var index: [[UInt8]] = []
        index.reserveCapacity(store.rowCount)
        for row in 0..<store.rowCount {
            var bytes: [UInt8] = []
            for column in 0..<columns {
                bytes.append(0x1F)
                for byte in store.text(row: row, column: column).utf8.prefix(2048) { bytes.append(NaturalOrder.fold(byte)) }
            }
            index.append(bytes)
        }
        searchIndex = index
        return index
    }

    private func matchingRows(_ query: String) -> [Int] {
        let index = buildSearchIndex()
        // Non-ASCII queries fold through Foundation; ASCII ones use a byte search.
        let needle = Array(query.lowercased().utf8).map(NaturalOrder.fold)
        guard !needle.isEmpty else { return Array(0..<store.rowCount) }
        var result: [Int] = []
        for (row, haystack) in index.enumerated() where NaturalOrder.contains(haystack, needle) {
            result.append(row)
        }
        return result
    }

    /// The store's row behind a visible row.
    func storeRow(_ row: Int) -> Int { order[row] }
}

/// Fast, locale-independent "natural" ordering on UTF-8: digit runs compare as numbers,
/// ASCII letters compare without case, so "file9" < "File10".
enum NaturalOrder {
    @inline(__always) static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var i = 0, j = 0
        let n = a.count, m = b.count
        while i < n && j < m {
            let x = a[i], y = b[j]
            let xDigit = x >= 48 && x <= 57, yDigit = y >= 48 && y <= 57
            if xDigit && yDigit {
                // Skip leading zeros, then compare run lengths, then digits.
                var si = i, sj = j
                while si < n && a[si] == 48 { si += 1 }
                while sj < m && b[sj] == 48 { sj += 1 }
                var ei = si, ej = sj
                while ei < n && a[ei] >= 48 && a[ei] <= 57 { ei += 1 }
                while ej < m && b[ej] >= 48 && b[ej] <= 57 { ej += 1 }
                let li = ei - si, lj = ej - sj
                if li != lj { return li < lj ? -1 : 1 }
                var k = 0
                while k < li {
                    if a[si + k] != b[sj + k] { return a[si + k] < b[sj + k] ? -1 : 1 }
                    k += 1
                }
                i = ei; j = ej
                continue
            }
            let fx = fold(x), fy = fold(y)
            if fx != fy { return fx < fy ? -1 : 1 }
            i += 1; j += 1
        }
        if n - i != m - j { return (n - i) < (m - j) ? -1 : 1 }
        return 0
    }

    /// A key whose plain byte order is natural order: ASCII letters folded to lower case, and each
    /// run of digits written as its length then its digits (leading zeros dropped), so "9" < "10".
    static func key(_ text: String) -> [UInt8] {
        var key: [UInt8] = []
        let bytes = Array(text.utf8.prefix(256))
        key.reserveCapacity(bytes.count + 8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b >= 48 && b <= 57 {
                var start = i
                while start < bytes.count - 1, bytes[start] == 48, bytes[start + 1] >= 48, bytes[start + 1] <= 57 { start += 1 }
                var end = start
                while end < bytes.count, bytes[end] >= 48, bytes[end] <= 57 { end += 1 }
                // Digits sort before letters; the length byte keeps longer numbers after shorter ones.
                key.append(0x01)
                key.append(UInt8(min(end - start, 200)))
                key.append(contentsOf: bytes[start..<end])
                i = end
            } else {
                key.append(fold(b))
                i += 1
            }
        }
        return key
    }

    static func compareKeys(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let common = min(a.count, b.count)
        let result = a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in memcmp(x.baseAddress!, y.baseAddress!, common) } }
        if result != 0 { return result < 0 ? -1 : 1 }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return haystack.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
            }
        }
    }
}
