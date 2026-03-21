import Cocoa
import SQLite3

/// Renders SQLite databases with multi-table switching and column metadata.
final class SQLiteRenderer: FileRenderer {

    func render(fileAt url: URL, completion: @escaping (Error?) -> Void) -> NSView {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = db else {
            completion(NSError(domain: "GreeceQL", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot open SQLite database"]))
            return NSView()
        }

        defer { sqlite3_close(database) }

        // Get table names
        let tables = getTableNames(database)
        guard !tables.isEmpty else {
            completion(NSError(domain: "GreeceQL", code: 5, userInfo: [NSLocalizedDescriptionKey: "No tables found"]))
            return NSView()
        }

        // Create the container
        let container = NSView()
        container.wantsLayer = true

        // Tab bar for table switching
        let tabBar = NSSegmentedControl(labels: tables, trackingMode: .selectOne, target: nil, action: nil)
        tabBar.selectedSegment = 0
        tabBar.segmentStyle = .texturedRounded
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        // Column info label
        let columnInfoLabel = NSTextField(labelWithString: "")
        columnInfoLabel.font = .systemFont(ofSize: 11)
        columnInfoLabel.textColor = .secondaryLabelColor
        columnInfoLabel.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view with table
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tableView = GreeceTableView()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 8, height: 2)

        scrollView.documentView = tableView

        // Load first table
        let firstTable = tables[0]
        let columnInfo = getColumnInfo(database, table: firstTable)
        let rows = queryTable(database, table: firstTable, limit: GreeceSettings.shared.csvMaxRows)
        let columns = columnInfo.map { $0.name }

        setupTableColumns(tableView, columns: columns, columnInfo: columnInfo)
        columnInfoLabel.stringValue = formatColumnInfo(columnInfo)

        let dataSource = SQLiteDataSource(columns: columns, rows: rows)
        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.dataSourceRef = dataSource

        // Table switching handler
        let coordinator = SQLiteCoordinator(
            database: url,
            tableView: tableView,
            columnInfoLabel: columnInfoLabel,
            tables: tables
        )
        tabBar.target = coordinator
        tabBar.action = #selector(SQLiteCoordinator.tableChanged(_:))

        // Store coordinator to prevent dealloc
        container.layer?.setValue(coordinator, forKey: "coordinator")

        container.addSubview(tabBar)
        container.addSubview(columnInfoLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),

            columnInfoLabel.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 6),
            columnInfoLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            columnInfoLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: columnInfoLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        completion(nil)
        return container
    }

    // MARK: - SQLite Helpers

    func getTableNames(_ db: OpaquePointer) -> [String] {
        var tables: [String] = []
        var stmt: OpaquePointer?
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 0) {
                    tables.append(String(cString: name))
                }
            }
        }
        sqlite3_finalize(stmt)
        return tables
    }

    struct ColumnMetadata {
        let name: String
        let type: String
        let notNull: Bool
        let isPrimaryKey: Bool
        let defaultValue: String?
    }

    func getColumnInfo(_ db: OpaquePointer, table: String) -> [ColumnMetadata] {
        var columns: [ColumnMetadata] = []
        var stmt: OpaquePointer?
        let query = "PRAGMA table_info('\(table.replacingOccurrences(of: "'", with: "''"))');"
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "TEXT"
                let notNull = sqlite3_column_int(stmt, 3) != 0
                let defaultVal = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let pk = sqlite3_column_int(stmt, 5) != 0
                columns.append(ColumnMetadata(name: name, type: type, notNull: notNull, isPrimaryKey: pk, defaultValue: defaultVal))
            }
        }
        sqlite3_finalize(stmt)
        return columns
    }

    func queryTable(_ db: OpaquePointer, table: String, limit: Int) -> [[String]] {
        var rows: [[String]] = []
        var stmt: OpaquePointer?
        let query = "SELECT * FROM '\(table.replacingOccurrences(of: "'", with: "''"))' LIMIT \(limit);"
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            let colCount = sqlite3_column_count(stmt)
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String] = []
                for i in 0..<colCount {
                    if let text = sqlite3_column_text(stmt, i) {
                        row.append(String(cString: text))
                    } else {
                        row.append("NULL")
                    }
                }
                rows.append(row)
            }
        }
        sqlite3_finalize(stmt)
        return rows
    }

    func setupTableColumns(_ tableView: NSTableView, columns: [String], columnInfo: [ColumnMetadata]) {
        // Remove existing columns
        while let col = tableView.tableColumns.first {
            tableView.removeTableColumn(col)
        }

        for (index, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
            column.title = name
            column.minWidth = 60
            column.maxWidth = 400
            column.width = max(80, CGFloat(name.count * 9))

            // Add tooltip with type info
            if index < columnInfo.count {
                let info = columnInfo[index]
                var tooltip = info.type
                if info.isPrimaryKey { tooltip += " PK" }
                if info.notNull { tooltip += " NOT NULL" }
                if let def = info.defaultValue { tooltip += " DEFAULT \(def)" }
                column.headerToolTip = tooltip
            }

            column.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
            tableView.addTableColumn(column)
        }
    }

    private func formatColumnInfo(_ columns: [ColumnMetadata]) -> String {
        let parts = columns.map { col -> String in
            var s = "\(col.name): \(col.type)"
            if col.isPrimaryKey { s += " 🔑" }
            if col.notNull { s += " ⊘" }
            return s
        }
        return parts.joined(separator: "  |  ")
    }
}

// MARK: - Data Source

final class SQLiteDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let columns: [String]
    var rows: [[String]]

    init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn,
              let colIndex = Int(tableColumn.identifier.rawValue.replacingOccurrences(of: "col_", with: "")) else {
            return nil
        }
        let cell = NSTextField(labelWithString: "")
        cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.lineBreakMode = .byTruncatingTail
        if colIndex < rows[row].count {
            let value = rows[row][colIndex]
            cell.stringValue = value
            if value == "NULL" {
                cell.textColor = .tertiaryLabelColor
                cell.font = .monospacedSystemFont(ofSize: 12, weight: .light)
            }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sd = tableView.sortDescriptors.first, let key = sd.key, let idx = Int(key) else { return }
        rows.sort { r1, r2 in
            let v1 = idx < r1.count ? r1[idx] : ""
            let v2 = idx < r2.count ? r2[idx] : ""
            if let n1 = Double(v1), let n2 = Double(v2) {
                return sd.ascending ? n1 < n2 : n1 > n2
            }
            let r = v1.localizedStandardCompare(v2)
            return sd.ascending ? r == .orderedAscending : r == .orderedDescending
        }
        tableView.reloadData()
    }
}

// MARK: - Table Switch Coordinator

final class SQLiteCoordinator: NSObject {
    let databaseURL: URL
    weak var tableView: GreeceTableView?
    weak var columnInfoLabel: NSTextField?
    let tables: [String]
    private let renderer = SQLiteRenderer()

    init(database: URL, tableView: GreeceTableView, columnInfoLabel: NSTextField, tables: [String]) {
        self.databaseURL = database
        self.tableView = tableView
        self.columnInfoLabel = columnInfoLabel
        self.tables = tables
    }

    @objc func tableChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < tables.count else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = db else { return }
        defer { sqlite3_close(database) }

        let table = tables[index]
        let columnInfo = renderer.getColumnInfo(database, table: table)
        let rows = renderer.queryTable(database, table: table, limit: GreeceSettings.shared.csvMaxRows)
        let columns = columnInfo.map { $0.name }

        guard let tv = tableView else { return }
        renderer.setupTableColumns(tv, columns: columns, columnInfo: columnInfo)

        let ds = SQLiteDataSource(columns: columns, rows: rows)
        tv.dataSource = ds
        tv.delegate = ds
        tv.dataSourceRef = ds
        tv.reloadData()

        let parts = columnInfo.map { col -> String in
            var s = "\(col.name): \(col.type)"
            if col.isPrimaryKey { s += " 🔑" }
            if col.notNull { s += " ⊘" }
            return s
        }
        columnInfoLabel?.stringValue = parts.joined(separator: "  |  ")
    }
}
