import AppKit
import SQLite3

/// A read-only, immutable connection: never writes, never creates journals next to the file.
final class SQLiteDatabase {
    struct Column { let name: String; let type: String; let primaryKey: Bool; let notNull: Bool }
    struct Object {
        let name: String
        let isView: Bool
        var rowCount: Int?
        var columns: [Column]
    }

    let handle: OpaquePointer
    private(set) var objects: [Object] = []

    init(url: URL) throws {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1"), URLQueryItem(name: "mode", value: "ro")]
        var db: OpaquePointer?
        let uri = components.string ?? "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw ArchiveError.unsupported("This database can’t be opened.")
        }
        handle = db
        // Every statement runs against a deadline, so a hostile view (an endless recursive CTE,
        // a giant sort) can never hang the preview.
        sqlite3_progress_handler(db, 10_000, { context in
            let box = Unmanaged<DeadlineBox>.fromOpaque(context!).takeUnretainedValue()
            return CFAbsoluteTimeGetCurrent() > box.deadline ? 1 : 0
        }, Unmanaged.passUnretained(deadlineBox).toOpaque())
        // Don't let a database's schema run application-defined functions on our behalf.
        _ = try? query("PRAGMA trusted_schema = OFF", budget: 0.5)
        try loadSchema()
    }

    deinit {
        sqlite3_progress_handler(handle, 0, nil, nil)
        sqlite3_close(handle)
    }

    private let deadlineBox = DeadlineBox()

    private func loadSchema() throws {
        var names: [(String, Bool)] = []
        let rows = try query("SELECT name, type FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type = 'view', name COLLATE NOCASE")
        for row in rows {
            if case .text(let name) = row[0], case .text(let type) = row[1] { names.append((name, type == "view")) }
        }
        // Row counts are a nicety: stop counting once the whole schema has had a second and a half.
        let countingEnds = CFAbsoluteTimeGetCurrent() + 1.5
        objects = names.prefix(2000).map { name, isView in
            let counted = !isView && CFAbsoluteTimeGetCurrent() < countingEnds ? count(name) : nil
            return Object(name: name, isView: isView, rowCount: counted, columns: columns(of: name))
        }
    }

    func columns(of table: String) -> [Column] {
        guard let rows = try? query("PRAGMA table_info(\(quote(table)))") else { return [] }
        return rows.map { row in
            func text(_ i: Int) -> String { if case .text(let t) = row[i] { return t } else { return "" } }
            return Column(name: text(1), type: text(2), primaryKey: text(5) != "0" && !text(5).isEmpty, notNull: text(3) == "1")
        }
    }

    /// Counts rows within a time budget; very large unindexed tables report nil instead of stalling.
    func count(_ table: String, budget: TimeInterval = 0.35) -> Int? {
        guard let rows = try? query("SELECT count(*) FROM \(quote(table))", budget: budget),
              case .text(let value) = rows.first?.first else { return nil }
        return Int(value)
    }

    func rows(of table: String, orderBy: (column: String, ascending: Bool)?, offset: Int, limit: Int) -> [[GridValue]] {
        var sql = "SELECT * FROM \(quote(table))"
        if let orderBy { sql += " ORDER BY \(quote(orderBy.column)) \(orderBy.ascending ? "ASC" : "DESC")" }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return (try? query(sql, budget: 1.5)) ?? []
    }

    func quote(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    func query(_ sql: String, budget: TimeInterval = 2) throws -> [[GridValue]] {
        deadlineBox.deadline = CFAbsoluteTimeGetCurrent() + budget
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArchiveError.unsupported(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let columnCount = sqlite3_column_count(statement)
        var result: [[GridValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ArchiveError.unsupported(String(cString: sqlite3_errmsg(handle))) }
            var row: [GridValue] = []
            row.reserveCapacity(Int(columnCount))
            for i in 0..<columnCount {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_NULL: row.append(.null)
                case SQLITE_BLOB: row.append(.blob(Int(sqlite3_column_bytes(statement, i))))
                default:
                    if let text = sqlite3_column_text(statement, i) {
                        let length = Int(sqlite3_column_bytes(statement, i))
                        row.append(.text(String(decoding: UnsafeBufferPointer(start: text, count: min(length, 4096)), as: UTF8.self)))
                    } else {
                        row.append(.null)
                    }
                }
            }
            result.append(row)
        }
        return result
    }

    private final class DeadlineBox {
        var deadline = CFAbsoluteTimeGetCurrent() + 2
    }
}

/// Pages rows in on demand, so huge tables open instantly.
final class SQLiteGridSource: GridSource {
    private let database: SQLiteDatabase
    let object: SQLiteDatabase.Object
    private let pageSize = 400
    private var pages: [Int: [[GridValue]]] = [:]
    private var order: (column: String, ascending: Bool)?
    let rowCount: Int
    private let numeric: [Bool]

    init(database: SQLiteDatabase, object: SQLiteDatabase.Object, rowLimit: Int) {
        self.database = database
        self.object = object
        // Views and huge tables may not have a cheap count: fall back to the display limit.
        let known = object.rowCount ?? database.count(object.name) ?? rowLimit
        rowCount = min(known, rowLimit)
        numeric = object.columns.map { column in
            let type = column.type.uppercased()
            return ["INT", "REAL", "FLOA", "DOUB", "NUM", "DEC"].contains { type.contains($0) }
        }
    }

    var columnCount: Int { object.columns.count }

    func title(ofColumn column: Int) -> String { object.columns[column].name }

    func toolTip(ofColumn column: Int) -> String? {
        let info = object.columns[column]
        var parts = [info.type.isEmpty ? "ANY" : info.type]
        if info.primaryKey { parts.append("PRIMARY KEY") }
        if info.notNull { parts.append("NOT NULL") }
        return parts.joined(separator: " · ")
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
            default: return 8
            }
        }.max() ?? 0
        let title = object.columns[column].name.count + 3
        return min(max(CGFloat(max(longest, title)) * 7.4 + 22, 56), 360)
    }

    func value(row: Int, column: Int) -> GridValue {
        let rows = page(row / pageSize)
        let index = row % pageSize
        guard index < rows.count, column < rows[index].count else { return .null }
        return rows[index][column]
    }

    func sort(column: Int, ascending: Bool, completion: @escaping (Bool) -> Void) {
        order = (object.columns[column].name, ascending)
        pages.removeAll()
        completion(true)
    }

    private func page(_ number: Int) -> [[GridValue]] {
        if let cached = pages[number] { return cached }
        let rows = database.rows(of: object.name, orderBy: order, offset: number * pageSize, limit: pageSize)
        if pages.count > 24 { pages.removeAll() }
        pages[number] = rows
        return rows
    }
}

/// Tables and views on the left, rows on the right.
final class SQLiteBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let database: SQLiteDatabase
    private let split = NSSplitView()
    private let sidebar = NSTableView()
    private let grid: GridView
    private let rowLimit: Int
    var onSelectionChange: ((SQLiteDatabase.Object) -> Void)?

    init(database: SQLiteDatabase, settings: PreviewSettings) {
        self.database = database
        rowLimit = settings.maxRows
        let first = database.objects.first ?? SQLiteDatabase.Object(name: "", isView: false, rowCount: 0, columns: [])
        grid = GridView(source: SQLiteGridSource(database: database, object: first, rowLimit: settings.maxRows), showsRowNumbers: settings.rowNumbers)
        super.init(frame: .zero)

        sidebar.style = .sourceList
        sidebar.headerView = nil
        sidebar.rowHeight = 26
        sidebar.addTableColumn(NSTableColumn(identifier: .init("object")))
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.focusRingType = .none

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        let sidebarEffect = NSVisualEffectView()
        sidebarEffect.material = .sidebar
        sidebarEffect.blendingMode = .withinWindow
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarEffect.addSubview(sidebarScroll)
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: sidebarEffect.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarEffect.bottomAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarEffect.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
        ])

        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        if database.objects.count > 1 { split.addArrangedSubview(sidebarEffect) }
        split.addArrangedSubview(grid)
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        if database.objects.count > 1 {
            sidebarEffect.widthAnchor.constraint(equalToConstant: 196).isActive = true
            split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        }
        sidebar.reloadData()
        sidebar.selectRowIndexes([0], byExtendingSelection: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setShowsRowNumbers(_ show: Bool) { grid.setShowsRowNumbers(show) }

    func numberOfRows(in tableView: NSTableView) -> Int { database.objects.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let object = database.objects[row]
        let cell = (tableView.makeView(withIdentifier: .init("objectCell"), owner: nil) as? SidebarCell) ?? SidebarCell()
        cell.configure(name: object.name, symbol: object.isView ? "eye" : "tablecells", count: object.rowCount.map { $0.formatted() })
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, row < database.objects.count else { return }
        let object = database.objects[row]
        grid.setSource(SQLiteGridSource(database: database, object: object, rowLimit: rowLimit))
        onSelectionChange?(object)
    }
}

private final class SidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = .init("objectCell")
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.alignment = .right
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = name
        imageView = icon
        let stack = NSStackView(views: [icon, name, count])
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(name text: String, symbol: String, count value: String?) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        name.stringValue = text
        count.stringValue = value ?? ""
    }
}
