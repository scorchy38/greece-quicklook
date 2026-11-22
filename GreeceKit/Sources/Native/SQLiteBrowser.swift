import AppKit
import SQLite3

/// A read-only, immutable connection: never writes, never creates journals next to the file, and
/// every statement runs against a deadline.
final class SQLiteDatabase {
    struct Column {
        let name: String
        let type: String
        let notNull: Bool
        let defaultValue: String?
        /// Position in the primary key (1-based), or 0.
        let primaryKey: Int
        /// Generated (computed) column.
        let generated: Bool
        var isPrimaryKey: Bool { primaryKey > 0 }
    }

    struct ForeignKey {
        let table: String
        let from: [String]
        let to: [String]
        let onUpdate: String
        let onDelete: String
    }

    struct Index {
        let name: String
        let unique: Bool
        /// "c" CREATE INDEX, "u" UNIQUE constraint, "pk" PRIMARY KEY.
        let origin: String
        let partial: Bool
        let columns: [String]
        let sql: String?
    }

    struct Trigger {
        let name: String
        let sql: String

        /// BEFORE, AFTER or INSTEAD OF, read from the statement's head.
        var timing: String {
            let head = self.head
            if head.contains("INSTEAD OF") { return "INSTEAD OF" }
            if head.contains(" AFTER ") { return "AFTER" }
            return "BEFORE"
        }

        var event: String {
            let head = self.head
            for word in ["INSERT", "UPDATE", "DELETE"] where head.contains(" \(word)") { return word }
            return ""
        }

        private var head: String {
            let upper = " " + sql.prefix(600).uppercased().replacingOccurrences(of: "\n", with: " ") + " "
            guard let on = upper.range(of: " ON ") else { return upper }
            return String(upper[..<on.lowerBound]) + " "
        }
    }

    enum Kind { case table, view, virtual }

    final class Object {
        let name: String
        let kind: Kind
        let sql: String?
        let columns: [Column]
        let foreignKeys: [ForeignKey]
        let indexes: [Index]
        let triggers: [Trigger]
        let withoutRowid: Bool
        /// An alias for the rowid that no column shadows, if the table has a rowid.
        let rowidAlias: String?
        /// Exact, when counting was cheap enough.
        var rowCount: Int?
        /// An estimate when counting was too slow (largest rowid, or sqlite_stat1).
        var estimatedRows: Int?

        init(name: String, kind: Kind, sql: String?, columns: [Column], foreignKeys: [ForeignKey], indexes: [Index],
             triggers: [Trigger], withoutRowid: Bool, rowidAlias: String?) {
            self.name = name
            self.kind = kind
            self.sql = sql
            self.columns = columns
            self.foreignKeys = foreignKeys
            self.indexes = indexes
            self.triggers = triggers
            self.withoutRowid = withoutRowid
            self.rowidAlias = rowidAlias
        }

        var isView: Bool { kind == .view }
        var rows: Int? { rowCount ?? estimatedRows }

        /// The foreign key a column belongs to, if any.
        func foreignKey(for column: String) -> ForeignKey? {
            foreignKeys.first { $0.from.contains { $0.caseInsensitiveCompare(column) == .orderedSame } }
        }
    }

    enum Binding: Equatable { case text(String), integer(Int64), real(Double) }

    let url: URL
    let handle: OpaquePointer
    private(set) var objects: [Object] = []
    /// A write-ahead log sits beside the file; an immutable connection can't see its changes.
    private(set) var hasPendingLog = false
    static let maxObjects = 2_000

    init(url: URL, loadSchema: Bool = true) throws {
        self.url = url
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1"), URLQueryItem(name: "mode", value: "ro")]
        var db: OpaquePointer?
        let uri = components.string ?? "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw ArchiveError.unsupported(String(localized: "This database can’t be opened.", bundle: .greeceKit))
        }
        handle = db
        // Every statement runs against a deadline, so a hostile view (an endless recursive CTE,
        // a giant sort) can never hang the preview.
        sqlite3_progress_handler(db, 1_000, { context in
            let box = Unmanaged<DeadlineBox>.fromOpaque(context!).takeUnretainedValue()
            return CFAbsoluteTimeGetCurrent() > box.deadline ? 1 : 0
        }, Unmanaged.passUnretained(deadlineBox).toOpaque())
        // Don't let a database's schema run application-defined functions on our behalf.
        _ = try? query("PRAGMA trusted_schema = OFF", budget: 0.5)
        // Bound memory for sorts and caches.
        _ = try? query("PRAGMA cache_size = -16000", budget: 0.5)
        _ = try? query("PRAGMA temp_store = MEMORY", budget: 0.5)
        if loadSchema {
            let wal = URL(fileURLWithPath: url.path + "-wal")
            hasPendingLog = ((try? wal.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
            try self.loadSchema()
        }
    }

    deinit {
        sqlite3_progress_handler(handle, 0, nil, nil)
        sqlite3_close(handle)
    }

    private let deadlineBox = DeadlineBox()

    // MARK: - Schema

    private func loadSchema() throws {
        let started = CFAbsoluteTimeGetCurrent()
        let rows = try query("SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' LIMIT 20000")
        var entries: [(type: String, name: String, table: String, sql: String?)] = []
        for row in rows {
            guard row.count == 4, case .text(let type) = row[0], case .text(let name) = row[1] else { continue }
            var table = name
            if case .text(let t) = row[2] { table = t }
            var sql: String?
            if case .text(let s) = row[3] { sql = s }
            entries.append((type, name, table, sql))
        }
        let triggersByTable = Dictionary(grouping: entries.filter { $0.type == "trigger" }) { $0.table.lowercased() }
        let indexSQL = Dictionary(entries.filter { $0.type == "index" }.map { ($0.name, $0.sql) }) { a, _ in a }
        let shadow = Self.shadowTables(entries.filter { $0.type == "table" }.map { ($0.name, $0.sql) })

        var result: [Object] = []
        for entry in entries where entry.type == "table" || entry.type == "view" {
            guard result.count < Self.maxObjects else { break }
            if shadow.contains(entry.name.lowercased()) { continue }
            let isVirtual = entry.sql?.range(of: #"^\s*CREATE\s+VIRTUAL\s+TABLE"#, options: [.regularExpression, .caseInsensitive]) != nil
            let kind: Kind = entry.type == "view" ? .view : isVirtual ? .virtual : .table
            let columns = self.columns(of: entry.name)
            let withoutRowid = kind == .table && (entry.sql?.range(of: #"\)\s*WITHOUT\s+ROWID\s*;?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil)
            var alias: String?
            if kind != .view, !withoutRowid {
                let names = Set(columns.map { $0.name.lowercased() })
                alias = ["rowid", "_rowid_", "oid"].first { !names.contains($0) }
            }
            let triggers = (triggersByTable[entry.name.lowercased()] ?? []).compactMap { t in t.sql.map { Trigger(name: t.name, sql: $0) } }
            result.append(Object(name: entry.name, kind: kind, sql: entry.sql, columns: columns,
                                 foreignKeys: kind == .table ? foreignKeys(of: entry.name) : [],
                                 indexes: kind == .table ? indexes(of: entry.name, sql: indexSQL) : [],
                                 triggers: triggers, withoutRowid: withoutRowid, rowidAlias: alias))
            // A schema with thousands of tables still opens promptly; details stop after a few seconds.
            if CFAbsoluteTimeGetCurrent() - started > 4 { break }
        }
        result.sort { a, b in
            if (a.kind == .view) != (b.kind == .view) { return a.kind != .view }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        objects = result
        countRows()
    }

    /// FTS and R*Tree keep their data in shadow tables named after the virtual table.
    private static func shadowTables(_ tables: [(String, String?)]) -> Set<String> {
        var result = Set<String>()
        let virtual = tables.filter { $0.1?.range(of: #"^\s*CREATE\s+VIRTUAL\s+TABLE"#, options: [.regularExpression, .caseInsensitive]) != nil }.map { $0.0.lowercased() }
        let suffixes = ["_content", "_segments", "_segdir", "_docsize", "_stat", "_data", "_idx", "_config", "_node", "_parent", "_rowid"]
        for name in virtual {
            for suffix in suffixes { result.insert(name + suffix) }
        }
        return result
    }

    func columns(of table: String) -> [Column] {
        var rows = (try? query("SELECT cid, name, type, \"notnull\", dflt_value, pk, hidden FROM pragma_table_xinfo(?) LIMIT 4000", bindings: [.text(table)])) ?? []
        if rows.isEmpty {
            rows = (try? query("SELECT cid, name, type, \"notnull\", dflt_value, pk, 0 FROM pragma_table_info(?) LIMIT 4000", bindings: [.text(table)])) ?? []
        }
        return rows.compactMap { row in
            guard row.count >= 7 else { return nil }
            let hidden = Int(row[6].plainText) ?? 0
            // 1: hidden columns of virtual tables (not in SELECT *).
            if hidden == 1 { return nil }
            var defaultValue: String?
            if case .text(let value) = row[4] { defaultValue = value }
            return Column(name: row[1].plainText, type: row[2].plainText, notNull: row[3].plainText == "1",
                          defaultValue: defaultValue, primaryKey: Int(row[5].plainText) ?? 0, generated: hidden == 2 || hidden == 3)
        }
    }

    private func foreignKeys(of table: String) -> [ForeignKey] {
        guard let rows = try? query("SELECT id, seq, \"table\", \"from\", \"to\", on_update, on_delete FROM pragma_foreign_key_list(?) ORDER BY id, seq LIMIT 2000", bindings: [.text(table)]) else { return [] }
        var keys: [Int: (table: String, from: [String], to: [String], update: String, delete: String)] = [:]
        var order: [Int] = []
        for row in rows where row.count == 7 {
            let id = Int(row[0].plainText) ?? 0
            if keys[id] == nil {
                keys[id] = (row[2].plainText, [], [], row[5].plainText, row[6].plainText)
                order.append(id)
            }
            keys[id]?.from.append(row[3].plainText)
            // An empty "to" means the referenced table's primary key.
            keys[id]?.to.append(row[4].plainText)
        }
        return order.compactMap { id in
            keys[id].map { ForeignKey(table: $0.table, from: $0.from, to: $0.to, onUpdate: $0.update, onDelete: $0.delete) }
        }
    }

    private func indexes(of table: String, sql: [String: String?]) -> [Index] {
        guard let rows = try? query("SELECT name, \"unique\", origin, partial FROM pragma_index_list(?) LIMIT 500", bindings: [.text(table)]) else { return [] }
        let expression = String(localized: "expression", bundle: .greeceKit,
                                comment: "Stands in for a column name in a database index’s list of columns when the index is on a computed expression")
        return rows.compactMap { row in
            guard row.count == 4 else { return nil }
            let name = row[0].plainText
            let columns = ((try? query("SELECT name FROM pragma_index_info(?) ORDER BY seqno LIMIT 200", bindings: [.text(name)])) ?? [])
                .map { $0.first.map { value -> String in if case .null = value { return expression } else { return value.plainText } } ?? "" }
            return Index(name: name, unique: row[1].plainText == "1", origin: row[2].plainText, partial: row[3].plainText == "1",
                         columns: columns, sql: sql[name] ?? nil)
        }
    }

    /// Exact counts while they're cheap (they usually are: SQLite counts a million rows in a few
    /// milliseconds); estimates for the rest, refined later off the main thread.
    private func countRows() {
        let ends = CFAbsoluteTimeGetCurrent() + 1.2
        var stats: [String: Int] = [:]
        if let rows = try? query("SELECT tbl, stat FROM sqlite_stat1 LIMIT 5000", budget: 0.2) {
            for row in rows where row.count == 2 {
                if let first = row[1].plainText.split(separator: " ").first, let value = Int(first) { stats[row[0].plainText.lowercased()] = value }
            }
        }
        for object in objects where object.kind != .view {
            let left = ends - CFAbsoluteTimeGetCurrent()
            if left > 0, let exact = count(object.name, budget: min(0.3, left)) {
                object.rowCount = exact
                continue
            }
            if let stat = stats[object.name.lowercased()] {
                object.estimatedRows = stat
            } else if let alias = object.rowidAlias,
                      let rows = try? query("SELECT max(\(alias)) FROM \(quote(object.name))", budget: 0.1), let value = Int(rows.first?.first?.plainText ?? "") {
                object.estimatedRows = max(0, value)
            }
        }
    }

    /// Counts rows within a time budget; nil when that would take longer.
    func count(_ table: String, budget: TimeInterval = 0.35) -> Int? {
        guard budget > 0, let rows = try? query("SELECT count(*) FROM \(quote(table))", budget: budget) else { return nil }
        return Int(rows.first?.first?.plainText ?? "")
    }

    func quote(_ identifier: String) -> String { Self.quote(identifier) }

    static func quote(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    // MARK: - Thumbnails

    struct ThumbnailSample {
        let name: String
        let rows: Int?
        let tables: Int
        let store: RecordTable
    }

    /// The first table with rows, read without loading the whole schema (Finder asks for many
    /// thumbnails at once).
    static func thumbnailSample(_ url: URL) -> ThumbnailSample? {
        guard let db = try? SQLiteDatabase(url: url, loadSchema: false),
              let tables = try? db.query("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name COLLATE NOCASE LIMIT 2000", budget: 0.4)
        else { return nil }
        let names = tables.map { $0.first?.plainText ?? "" }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let name = names.prefix(50).first { (try? db.query("SELECT 1 FROM \(db.quote($0)) LIMIT 1", budget: 0.1))?.isEmpty == false } ?? names[0]
        let columns = db.columns(of: name)
        guard !columns.isEmpty, let rows = try? db.query("SELECT * FROM \(db.quote(name)) LIMIT 40", budget: 0.5) else { return nil }
        let records = columns.map { column -> RecordColumn in
            let type = column.type.uppercased()
            let numeric = ["INT", "REAL", "FLOA", "DOUB", "NUM", "DEC"].contains { type.contains($0) }
            return RecordColumn(title: column.name, numeric: numeric)
        }
        return ThumbnailSample(name: name, rows: db.count(name, budget: 0.2), tables: names.count, store: RecordTable(columns: records, rows: rows))
    }

    // MARK: - Queries

    /// Runs one statement and returns its rows, giving up after `budget` seconds or `maxRows` rows.
    func query(_ sql: String, bindings: [Binding] = [], budget: TimeInterval = 2, maxRows: Int = 1_000_000) throws -> [[GridValue]] {
        var result: [[GridValue]] = []
        try forEachRow(sql, bindings: bindings, budget: budget) { statement, columns in
            var row: [GridValue] = []
            row.reserveCapacity(Int(columns))
            for i in 0..<columns { row.append(Self.value(statement, i)) }
            result.append(row)
            return result.count < maxRows
        }
        return result
    }

    /// Steps through a statement's rows; `body` returns false to stop early.
    func forEachRow(_ sql: String, bindings: [Binding] = [], budget: TimeInterval,
                    _ body: (OpaquePointer, Int32) throws -> Bool) throws {
        deadlineBox.deadline = CFAbsoluteTimeGetCurrent() + budget
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArchiveError.unsupported(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            switch binding {
            case .text(let text): sqlite3_bind_text(statement, Int32(index + 1), text, -1, Self.transient)
            case .integer(let value): sqlite3_bind_int64(statement, Int32(index + 1), value)
            case .real(let value): sqlite3_bind_double(statement, Int32(index + 1), value)
            }
        }
        let columns = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ArchiveError.unsupported(String(cString: sqlite3_errmsg(handle))) }
            if try !body(statement, columns) { break }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func value(_ statement: OpaquePointer, _ i: Int32) -> GridValue {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_NULL:
            return .null
        case SQLITE_BLOB:
            let size = Int(sqlite3_column_bytes(statement, i))
            guard size > 0, let bytes = sqlite3_column_blob(statement, i) else { return .blob(size) }
            let buffer = UnsafeRawBufferPointer(start: bytes, count: min(size, 16))
            if let kind = blobKind(Array(buffer)) {
                return .secondary("\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            }
            if size <= 16 {
                return .secondary("x'" + buffer.map { String(format: "%02x", $0) }.joined() + "'")
            }
            return .blob(size)
        default:
            guard let text = sqlite3_column_text(statement, i) else { return .null }
            let length = Int(sqlite3_column_bytes(statement, i))
            return .text(String(decoding: UnsafeBufferPointer(start: text, count: min(length, 4096)), as: UTF8.self))
        }
    }

    /// Recognisable payloads in blobs: images, archives, property lists.
    static func blobKind(_ head: [UInt8]) -> String? {
        func starts(_ prefix: [UInt8]) -> Bool { head.count >= prefix.count && Array(head.prefix(prefix.count)) == prefix }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return BlobKinds.png }
        if starts([0xFF, 0xD8, 0xFF]) { return BlobKinds.jpeg }
        if starts(Array("GIF8".utf8)) { return BlobKinds.gif }
        if starts(Array("RIFF".utf8)), head.count >= 12, Array(head[8..<12]) == Array("WEBP".utf8) { return BlobKinds.webP }
        if head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8) { return BlobKinds.heif }
        if starts(Array("%PDF".utf8)) { return "PDF" }
        if starts(Array("bplist".utf8)) { return BlobKinds.propertyList }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return BlobKinds.zip }
        if starts([0x1F, 0x8B]) { return BlobKinds.gzip }
        return nil
    }

    /// What a database cell's binary data holds, shown before its size ("PNG image · 4 KB").
    /// Looked up once: a page of rows can hold hundreds.
    private enum BlobKinds {
        static let png = String(localized: "PNG image", bundle: .greeceKit, comment: "What binary data in a database cell is")
        static let jpeg = String(localized: "JPEG image", bundle: .greeceKit, comment: "What binary data in a database cell is")
        static let gif = String(localized: "GIF image", bundle: .greeceKit, comment: "What binary data in a database cell is")
        static let webP = String(localized: "WebP image", bundle: .greeceKit, comment: "What binary data in a database cell is")
        static let heif = String(localized: "HEIF image", bundle: .greeceKit, comment: "What binary data in a database cell is")
        static let propertyList = String(localized: "Property list", bundle: .greeceKit, comment: "What binary data in a database cell is")
        static let zip = String(localized: "ZIP archive", bundle: .greeceKit, comment: "What binary data in a database cell is")
        static let gzip = String(localized: "Gzip data", bundle: .greeceKit, comment: "What binary data in a database cell is")
    }

    private final class DeadlineBox {
        var deadline = CFAbsoluteTimeGetCurrent() + 2
    }
}

// MARK: - Background work

/// A second connection on its own queue, for work that mustn't block scrolling: exact counts of
/// huge tables and sort orders.
final class SQLiteWorker {
    private let queue = DispatchQueue(label: "greece.sqlite.worker", qos: .userInitiated)
    private let url: URL
    private var connection: SQLiteDatabase?
    private var generation = 0
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    private func database() -> SQLiteDatabase? {
        if connection == nil { connection = try? SQLiteDatabase(url: url, loadSchema: false) }
        return connection
    }

    /// Cancels queued work (a newer sort replaces an older one).
    func cancelPending() {
        lock.lock(); generation += 1; lock.unlock()
    }

    private var currentGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }

    func count(_ table: String, completion: @escaping (Int?) -> Void) {
        queue.async { [self] in
            let result = database()?.count(table, budget: 15)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The rows meeting a condition, counted. Nil when too slow, or replaced by newer work.
    func count(_ table: String, where condition: SQLCondition, completion: @escaping (Int?) -> Void) {
        let expected = currentGeneration
        queue.async { [self] in
            var result: Int?
            if expected == currentGeneration, let db = database() {
                let sql = "SELECT count(*) FROM \(SQLiteDatabase.quote(table)) WHERE \(condition.sql)"
                result = (try? db.query(sql, bindings: condition.bindings, budget: 15))?.first?.first.flatMap { Int($0.plainText) }
            }
            if expected != currentGeneration { result = nil }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Every rowid in order: lets a page anywhere in the table start with an index lookup instead of
    /// an OFFSET scan.
    func rowids(table: String, alias: String, limit: Int, completion: @escaping ([Int64]?) -> Void) {
        queue.async { [self] in
            var ids: [Int64] = []
            var overflow = false
            let sql = "SELECT \(alias) FROM \(SQLiteDatabase.quote(table)) ORDER BY \(alias)"
            let ok = (try? database()?.forEachRow(sql, budget: 10) { statement, _ in
                ids.append(sqlite3_column_int64(statement, 0))
                if ids.count > limit { overflow = true; return false }
                return true
            }) != nil
            let result = ok && !overflow ? ids : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The rowids of a table in sorted order (ties broken by rowid), of the rows meeting a condition
    /// when there is one. Nil when too slow or too large.
    func sortedRowids(table: String, alias: String, order: (column: String, ascending: Bool)?, where condition: SQLCondition? = nil,
                      limit: Int, completion: @escaping ([Int64]?) -> Void) {
        let expected = currentGeneration
        queue.async { [self] in
            guard expected == currentGeneration, let db = database() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var sql = "SELECT \(alias) FROM \(SQLiteDatabase.quote(table))"
            if let condition { sql += " WHERE \(condition.sql)" }
            if let order {
                let direction = order.ascending ? "ASC" : "DESC"
                sql += " ORDER BY \(SQLiteDatabase.quote(order.column)) \(direction), \(alias) \(direction)"
            } else {
                sql += " ORDER BY \(alias)"
            }
            var ids: [Int64] = []
            var overflow = false
            do {
                try db.forEachRow(sql, bindings: condition?.bindings ?? [], budget: 20) { statement, _ in
                    ids.append(sqlite3_column_int64(statement, 0))
                    if ids.count > limit { overflow = true; return false }
                    return expected == currentGeneration
                }
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let result = overflow || expected != currentGeneration ? nil : ids
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// MARK: - Paging

/// A WHERE clause and the values bound into it.
struct SQLCondition: Equatable {
    var sql: String
    var bindings: [SQLiteDatabase.Binding] = []

    /// All of them at once.
    static func all(_ conditions: [SQLCondition]) -> SQLCondition? {
        guard !conditions.isEmpty else { return nil }
        return SQLCondition(sql: conditions.map(\.sql).joined(separator: " AND "), bindings: conditions.flatMap(\.bindings))
    }
}

extension ColumnFilter {
    /// The filter in SQL, matching what the grid shows: values compare as text (CAST reads numbers
    /// the way SQLite prints them in the grid), and NULL is told apart from empty text.
    func sql(column name: String) -> SQLCondition {
        let column = SQLiteDatabase.quote(name)
        let text = "CAST(\(column) AS TEXT)"
        let blank = "trim(\(text), ' ' || char(9, 10, 13)) = ''"
        switch test {
        case .equals(let value):
            return value.isEmpty ? SQLCondition(sql: "(\(column) IS NOT NULL AND \(blank))")
                : SQLCondition(sql: "\(text) = ?", bindings: [.text(value)])
        case .notEquals(let value):
            // Hiding a value keeps the NULLs, which SQL's <> alone would drop.
            return value.isEmpty ? SQLCondition(sql: "(\(column) IS NULL OR NOT \(blank))")
                : SQLCondition(sql: "(\(column) IS NULL OR \(text) <> ?)", bindings: [.text(value)])
        case .null:
            return SQLCondition(sql: "\(column) IS NULL")
        case .notNull:
            return SQLCondition(sql: "\(column) IS NOT NULL")
        case .atLeast(let bound, _):
            return SQLCondition(sql: "(typeof(\(column)) IN ('integer', 'real') AND \(column) >= ?)", bindings: [.real(bound)])
        case .atMost(let bound, _):
            return SQLCondition(sql: "(typeof(\(column)) IN ('integer', 'real') AND \(column) <= ?)", bindings: [.real(bound)])
        }
    }
}

/// Pages rows in on demand, so huge tables open instantly and scroll smoothly:
/// - rowid tables continue from the previous page's last rowid (no OFFSET scans while scrolling);
/// - sorted or filtered rowid tables fetch pages by rowid from an order built once, off the main thread;
/// - views and WITHOUT ROWID tables use LIMIT/OFFSET (and WHERE), each page against a deadline.
final class SQLiteGridSource: GridSource {
    private let database: SQLiteDatabase
    private let worker: SQLiteWorker
    let object: SQLiteDatabase.Object
    static let pageSize = 200
    private var pages: [Int: [[GridValue]]] = [:]
    private var lastRowids: [Int: Int64] = [:]
    private var recent: [Int] = []
    private var order: (column: String, ascending: Bool)?
    private var permutation: [Int64]?
    /// Every rowid in table order, once the worker has read them (large tables only).
    private var positions: [Int64]?
    /// Rows showing: the table's, or those meeting the filters.
    private(set) var rowCount: Int
    /// Rows in the table, filtered or not.
    private(set) var tableRows: Int
    /// Conditions on columns, all of which a row must meet. Applied in SQL.
    private(set) var filters: [ColumnFilter] = []
    private var numeric: [Bool]
    /// The largest table we'll sort in memory (8 bytes a row).
    static let sortLimit = 10_000_000
    /// Rows shown for views we couldn't count.
    static let viewWindow = 100_000
    /// Set when a page failed (a view that's too slow); the grid then shows what it has.
    private(set) var failed = false

    init(database: SQLiteDatabase, worker: SQLiteWorker, object: SQLiteDatabase.Object) {
        self.database = database
        self.worker = worker
        self.object = object
        if object.isView, object.rowCount == nil {
            object.rowCount = database.count(object.name, budget: 0.6)
        }
        rowCount = object.rowCount ?? object.estimatedRows ?? (object.isView ? Self.viewWindow : 0)
        tableRows = rowCount
        numeric = object.columns.map { column in
            let type = column.type.uppercased()
            return ["INT", "REAL", "FLOA", "DOUB", "NUM", "DEC"].contains { type.contains($0) }
        }
        // Large tables: learn where every page starts, so jumping anywhere is an index lookup.
        if let alias = object.rowidAlias, rowCount > 20_000, rowCount <= Self.sortLimit {
            worker.rowids(table: object.name, alias: alias, limit: Self.sortLimit) { [weak self] ids in
                guard let self, let ids else { return }
                self.tableRows = ids.count
                self.positions = ids
                guard self.order == nil, self.filters.isEmpty else { return }
                self.rowCount = ids.count
            }
        }
        // Columns without a declared type (view expressions): judge by the first page.
        if object.columns.contains(where: { $0.type.isEmpty }) {
            let sample = page(0)
            for (index, column) in object.columns.enumerated() where column.type.isEmpty {
                let values = sample.compactMap { index < $0.count ? $0[index] : nil }.filter { if case .text = $0 { return true }; return false }
                let numbers = values.filter { Double($0.plainText) != nil }.count
                numeric[index] = !values.isEmpty && numbers * 10 >= values.count * 9
            }
        }
    }

    /// A count that arrived later (exact for a huge table).
    func updateRowCount(_ count: Int) {
        tableRows = count
        if filters.isEmpty { rowCount = count }
    }

    /// What a visible cell offers to filter by.
    func filterCell(row: Int, column: Int) -> FilterMenu.Cell {
        switch value(row: row, column: column) {
        case .null: return .null
        // Longer text was cut short for the grid.
        case .text(let text): return text.utf8.count >= 4096 ? .unfilterable : ColumnFilter.isBlank(text) ? .empty : .text(text)
        default: return .unfilterable
        }
    }

    var columnCount: Int { object.columns.count }

    func title(ofColumn column: Int) -> String { object.columns[column].name }

    func toolTip(ofColumn column: Int) -> String? {
        let info = object.columns[column]
        var parts = [info.type.isEmpty ? "ANY" : info.type]
        if info.isPrimaryKey { parts.append("PRIMARY KEY") }
        if info.notNull { parts.append("NOT NULL") }
        if let value = info.defaultValue { parts.append("DEFAULT \(value)") }
        if info.generated { parts.append("GENERATED") }
        if let key = object.foreignKey(for: info.name), let index = key.from.firstIndex(where: { $0.caseInsensitiveCompare(info.name) == .orderedSame }) {
            let target = index < key.to.count && !key.to[index].isEmpty ? key.to[index]
                : String(localized: "primary key", bundle: .greeceKit,
                         comment: "In a database column’s tooltip, after the table a foreign key points to, such as “→ ferries.primary key”")
            parts.append("→ \(key.table).\(target)")
        }
        return parts.joined(separator: " · ")
    }

    /// The header strip: the column's declared type, with a key for primary keys and an arrow for
    /// foreign keys.
    func strip(forColumn column: Int) -> GridHeaderStrip {
        let info = object.columns[column]
        let type = info.type.uppercased()
        if info.isPrimaryKey { return .caption(type, symbol: "key.fill") }
        if object.foreignKey(for: info.name) != nil { return .caption(type, symbol: "arrow.up.right") }
        return .caption(type, symbol: nil)
    }

    func isNumeric(column: Int) -> Bool { numeric[column] }

    func estimatedWidth(ofColumn column: Int) -> CGFloat {
        let sample = page(0).prefix(100)
        let longest = sample.map { row -> Int in
            guard column < row.count else { return 0 }
            switch row[column] {
            case .text(let text): return min(text.count, 60)
            case .null: return 4
            case .blob: return 14
            case .secondary(let text): return min(text.count, 40)
            default: return 8
            }
        }.max() ?? 0
        let info = object.columns[column]
        let title = max(info.name.count, info.type.count + 2) + 3
        return min(max(CGFloat(max(longest, title)) * 7.4 + 22, 64), 360)
    }

    func value(row: Int, column: Int) -> GridValue {
        let rows = page(row / Self.pageSize)
        let index = row % Self.pageSize
        guard index < rows.count, column < rows[index].count else { return failed ? .placeholder("") : .null }
        return rows[index][column]
    }

    // MARK: Sorting

    func sort(column: Int, ascending: Bool, completion: @escaping (Bool) -> Void) {
        let name = object.columns[column].name
        worker.cancelPending()
        guard let alias = object.rowidAlias, tableRows <= Self.sortLimit else {
            // Views and WITHOUT ROWID tables sort in SQL, a page at a time.
            order = (name, ascending)
            permutation = nil
            resetPages()
            failed = false
            _ = page(0)
            completion(!failed)
            return
        }
        worker.sortedRowids(table: object.name, alias: alias, order: (name, ascending), where: condition, limit: Self.sortLimit) { [weak self] ids in
            guard let self else { return }
            guard let ids else { completion(false); return }
            self.order = (name, ascending)
            self.permutation = ids
            self.rowCount = ids.count
            self.resetPages()
            completion(true)
        }
    }

    // MARK: Filtering

    /// The filters as one WHERE clause; nil without filters.
    private var condition: SQLCondition? {
        SQLCondition.all(filters.map { $0.sql(column: object.columns[$0.column].name) })
    }

    /// Filters the rows in SQL. Rowid tables gather the matching rowids on the worker and page
    /// through them; views and WITHOUT ROWID tables add the condition to every page and count on
    /// the worker. `completion` runs on the main thread, false when the filter was too slow and
    /// the old filters stay; it doesn't run for a change that a newer one replaced.
    func setFilters(_ new: [ColumnFilter], completion: @escaping (Bool) -> Void) {
        let previous = filters
        filters = new
        worker.cancelPending()
        let condition = self.condition
        failed = false
        if let alias = object.rowidAlias, tableRows <= Self.sortLimit {
            guard condition != nil || order != nil else {
                // Back to the table as it is, paged by rowid.
                permutation = nil
                rowCount = positions?.count ?? tableRows
                resetPages()
                completion(true)
                return
            }
            worker.sortedRowids(table: object.name, alias: alias, order: order, where: condition, limit: Self.sortLimit) { [weak self] ids in
                guard let self, self.filters == new else { return }
                guard let ids else {
                    self.filters = previous
                    completion(false)
                    return
                }
                self.permutation = ids
                self.rowCount = ids.count
                self.resetPages()
                completion(true)
            }
            return
        }
        resetPages()
        guard let condition else {
            rowCount = tableRows
            completion(true)
            return
        }
        worker.count(object.name, where: condition) { [weak self] count in
            guard let self, self.filters == new else { return }
            self.resetPages()
            // Uncounted (too slow): page until the rows run out.
            self.rowCount = count ?? Self.viewWindow
            completion(true)
        }
    }

    private func resetPages() {
        pages.removeAll()
        lastRowids.removeAll()
        recent.removeAll()
    }

    // MARK: Pages

    private func page(_ number: Int) -> [[GridValue]] {
        if let cached = pages[number] { return cached }
        let rows = fetch(number)
        if pages.count >= 64, let oldest = recent.first {
            pages[oldest] = nil
            recent.removeFirst()
        }
        pages[number] = rows
        recent.append(number)
        return rows
    }

    private func fetch(_ number: Int) -> [[GridValue]] {
        let size = Self.pageSize
        let table = database.quote(object.name)
        if let permutation, let alias = object.rowidAlias {
            let start = number * size
            guard start < permutation.count else { return [] }
            let ids = permutation[start..<min(start + size, permutation.count)]
            let list = ids.map(String.init).joined(separator: ",")
            guard let rows = try? database.query("SELECT \(alias), * FROM \(table) WHERE \(alias) IN (\(list))", budget: 1.5) else { failed = true; return [] }
            var byRowid: [Int64: [GridValue]] = [:]
            for row in rows { if let id = Int64(row.first?.plainText ?? "") { byRowid[id] = Array(row.dropFirst()) } }
            return ids.map { byRowid[$0] ?? [] }
        }
        let condition = self.condition
        if let alias = object.rowidAlias, order == nil, condition == nil {
            // Continue from the previous page's last rowid when we know it: no OFFSET scan.
            var sql = "SELECT \(alias), * FROM \(table)"
            var bindings: [SQLiteDatabase.Binding] = []
            if number > 0, let last = lastRowids[number - 1] {
                sql += " WHERE \(alias) > ? ORDER BY \(alias) LIMIT \(size)"
                bindings = [.integer(last)]
            } else if let positions, number * size < positions.count {
                sql += " WHERE \(alias) >= ? ORDER BY \(alias) LIMIT \(size)"
                bindings = [.integer(positions[number * size])]
            } else {
                sql += " ORDER BY \(alias) LIMIT \(size) OFFSET \(number * size)"
            }
            guard let rows = try? database.query(sql, bindings: bindings, budget: 1.5) else { failed = true; return [] }
            if let last = rows.last, let id = Int64(last.first?.plainText ?? "") { lastRowids[number] = id }
            return rows.map { Array($0.dropFirst()) }
        }
        var sql = "SELECT * FROM \(table)"
        if let condition { sql += " WHERE \(condition.sql)" }
        if let order { sql += " ORDER BY \(database.quote(order.column)) \(order.ascending ? "ASC" : "DESC")" }
        sql += " LIMIT \(size) OFFSET \(number * size)"
        guard let rows = try? database.query(sql, bindings: condition?.bindings ?? [], budget: 2) else { failed = true; return [] }
        let total = number * size + rows.count
        if rows.count < size, total < rowCount {
            // Reached the end of an uncounted view or filter: now we know its size.
            if condition != nil {
                rowCount = total
            } else if object.isView, object.rowCount == nil {
                rowCount = total
                tableRows = total
                object.rowCount = total
            }
        }
        return rows
    }
}
