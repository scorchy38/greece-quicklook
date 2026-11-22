import AppKit

/// Tables and views on the left; their rows, schema, or the relationships between them on the right.
final class SQLiteBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, PreviewSettingsAware {
    private enum Item: Equatable {
        case header(String)
        case diagram
        case object(Int)
    }
    enum Mode: Int { case data, schema }

    private let database: SQLiteDatabase
    private let worker: SQLiteWorker
    private var settings: PreviewSettings
    private let split = NSSplitView()
    private let sidebar = NSTableView()
    private let content = NSView()
    private let toolbar = DataToolbar()
    private let modes = NSSegmentedControl(labels: ["Data", "Schema"], trackingMode: .selectOne, target: nil, action: nil)
    private let titleLabel = DataToolbar.label()
    private let countLabel = DataToolbar.label()
    /// The grid's active filters, each removable.
    private let tokens = NSStackView()
    private let spinner = NSProgressIndicator()
    private let status = DataToolbar.label()
    private var items: [Item] = []
    private var mode: Mode = .data
    private var current: Item?
    private var grid: GridView?
    private var source: SQLiteGridSource?
    private lazy var diagram = RelationshipDiagram(database: database)

    /// The selected table or view, or nil for the relationship diagram.
    var onSelectionChange: ((SQLiteDatabase.Object?) -> Void)?

    init(database: SQLiteDatabase, settings: PreviewSettings) {
        self.database = database
        self.settings = settings
        worker = SQLiteWorker(url: database.url)
        super.init(frame: .zero)
        buildItems()

        sidebar.style = .sourceList
        sidebar.headerView = nil
        sidebar.rowHeight = 24
        sidebar.addTableColumn(NSTableColumn(identifier: .init("object")))
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.focusRingType = .none
        sidebar.floatsGroupRows = false
        let sidebarMenu = NSMenu()
        sidebarMenu.delegate = self
        sidebar.menu = sidebarMenu

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

        // The right pane: a toolbar over the selected view.
        modes.segmentStyle = .automatic
        modes.controlSize = .small
        modes.selectedSegment = 0
        modes.target = self
        modes.action = #selector(modeChanged(_:))
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        toolbar.leading.addArrangedSubview(modes)
        toolbar.leading.addArrangedSubview(titleLabel)
        toolbar.leading.addArrangedSubview(countLabel)
        tokens.spacing = 4
        tokens.alignment = .centerY
        tokens.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.leading.addArrangedSubview(tokens)
        toolbar.trailing.addArrangedSubview(status)
        toolbar.trailing.addArrangedSubview(spinner)

        let pane = NSView()
        for view in [toolbar, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: pane.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            content.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])

        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        let showsSidebar = items.filter { if case .object = $0 { return true }; return $0 == .diagram }.count > 1
        if showsSidebar { split.addArrangedSubview(sidebarEffect) }
        split.addArrangedSubview(pane)
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        if showsSidebar {
            sidebarEffect.widthAnchor.constraint(equalToConstant: 210).isActive = true
            split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        }
        sidebar.reloadData()
        if let first = items.firstIndex(where: { if case .object = $0 { return true }; return false }) {
            sidebar.selectRowIndexes([first], byExtendingSelection: false)
        } else {
            toolbar.isHidden = true
            let empty = NSTextField(labelWithString: "No tables")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .tertiaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }
        refineCounts()
        #if DEBUG
        applySnapshotState()
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ settings: PreviewSettings) {
        self.settings = settings
        grid?.setShowsRowNumbers(settings.rowNumbers)
    }

    func setShowsRowNumbers(_ show: Bool) { grid?.setShowsRowNumbers(show) }

    /// Tells `onSelectionChange` what's showing now.
    func reportSelection() {
        switch current {
        case .object(let index): onSelectionChange?(database.objects[index])
        case .diagram: onSelectionChange?(nil)
        default: break
        }
    }

    static func symbol(for object: SQLiteDatabase.Object) -> String {
        switch object.kind {
        case .view: return "eye"
        case .virtual: return "tablecells.badge.ellipsis"
        case .table: return "tablecells"
        }
    }

    // MARK: - Sidebar

    private func buildItems() {
        let tables = database.objects.indices.filter { !database.objects[$0].isView }
        let views = database.objects.indices.filter { database.objects[$0].isView }
        if database.objects.contains(where: { !$0.foreignKeys.isEmpty }) { items.append(.diagram) }
        if !tables.isEmpty {
            items.append(.header("Tables"))
            items += tables.map(Item.object)
        }
        if !views.isEmpty {
            items.append(.header("Views"))
            items += views.map(Item.object)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = items[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 26 }
        return 24
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let title):
            let cell = (tableView.makeView(withIdentifier: .init("header"), owner: nil) as? SidebarHeader) ?? SidebarHeader()
            cell.label.stringValue = title
            return cell
        case .diagram:
            let cell = (tableView.makeView(withIdentifier: .init("objectCell"), owner: nil) as? SidebarCell) ?? SidebarCell()
            cell.configure(name: "Relationships", symbol: "point.3.connected.trianglepath.dotted", count: nil)
            return cell
        case .object(let index):
            let object = database.objects[index]
            let cell = (tableView.makeView(withIdentifier: .init("objectCell"), owner: nil) as? SidebarCell) ?? SidebarCell()
            let count = object.rowCount.map { ColumnProfile.short(Double($0), integerBelow: 100_000) }
                ?? object.estimatedRows.map { "~" + ColumnProfile.short(Double($0)) }
            cell.configure(name: object.name, symbol: Self.symbol(for: object), count: count)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, row < items.count else { return }
        show(items[row])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for item in sidebarMenuItems(forRow: sidebar.clickedRow) { menu.addItem(item) }
    }

    /// A table's name and definition to copy, from a right-click in the sidebar.
    func sidebarMenuItems(forRow row: Int) -> [NSMenuItem] {
        guard row >= 0, row < items.count, case .object(let index) = items[row] else { return [] }
        let object = database.objects[index]
        var items: [NSMenuItem] = [ActionMenuItem("Copy Name") { Clipboard.copy(object.name) }]
        if let sql = object.sql {
            items.append(ActionMenuItem("Copy CREATE Statement") { Clipboard.copy(SQLFormatter.format(sql)) })
        }
        return items
    }

    /// Exact counts for tables that were only estimated, worked out off the main thread.
    private func refineCounts() {
        for (row, item) in items.enumerated() {
            guard case .object(let index) = item else { continue }
            let object = database.objects[index]
            guard object.rowCount == nil, !object.isView else { continue }
            worker.count(object.name) { [weak self] count in
                guard let self, let count else { return }
                object.rowCount = count
                self.sidebar.reloadData(forRowIndexes: [row], columnIndexes: [0])
                if self.current == item {
                    self.source?.updateRowCount(count)
                    self.grid?.reloadRows()
                    self.updateToolbar()
                    self.onSelectionChange?(object)
                }
            }
        }
    }

    // MARK: - Content

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = Mode(rawValue: sender.selectedSegment) ?? .data
        if let current { show(current, force: true) }
    }

    private func show(_ item: Item, force: Bool = false) {
        guard force || item != current else { return }
        current = item
        content.subviews.forEach { $0.removeFromSuperview() }
        grid = nil
        source = nil
        status.stringValue = ""
        spinner.stopAnimation(nil)
        let view: NSView
        switch item {
        case .header:
            return
        case .diagram:
            let diagramView = SQLiteDiagramView(diagram: diagram)
            diagramView.canvas.onOpen = { [weak self] name in self?.open(name) }
            diagramView.canvas.onShowSchema = { [weak self] name in self?.open(name, mode: .schema) }
            view = diagramView
            onSelectionChange?(nil)
        case .object(let index):
            let object = database.objects[index]
            if mode == .schema {
                view = SQLiteSchemaView(object: object, database: database, settings: settings)
            } else {
                let source = SQLiteGridSource(database: database, worker: worker, object: object)
                let grid = GridView(source: source, showsRowNumbers: settings.rowNumbers, stripHeight: 16)
                grid.headerStrip = { [weak source] column in source?.strip(forColumn: column) }
                grid.onBusy = { [weak self] busy in
                    guard let self else { return }
                    if busy { self.spinner.startAnimation(nil); self.status.stringValue = "Sorting…" }
                    else { self.spinner.stopAnimation(nil); self.status.stringValue = "" }
                    self.updateToolbar()
                }
                grid.onSortFailed = { [weak self] in self?.status.stringValue = "Too large to sort here" }
                grid.cellMenuItems = { [weak self] row, column in self?.filterMenuItems(row: row, column: column) ?? [] }
                self.grid = grid
                self.source = source
                view = grid
            }
            onSelectionChange?(object)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        updateToolbar()
        updateTokens()
    }

    // MARK: - Filters

    private var filterMenu: FilterMenu? {
        guard let source else { return nil }
        return FilterMenu(active: source.filters,
                          add: { [weak self] in self?.applyFilters(ColumnFilter.adding($0, to: source.filters)) },
                          remove: { [weak self] filter in self?.applyFilters(source.filters.filter { $0 != filter }) },
                          clear: source.filters.isEmpty ? nil : { [weak self] in self?.applyFilters([]) })
    }

    /// Filter items for a right-click on a cell of the data grid, then Clear Filters.
    func filterMenuItems(row: Int?, column: Int?) -> [NSMenuItem] {
        guard let source, let filterMenu else { return [] }
        let cell = row.flatMap { row in column.map { source.filterCell(row: row, column: $0) } }
        return filterMenu.items(column: column ?? 0, name: column.map(source.title(ofColumn:)) ?? "",
                                cell: cell, numeric: column.map(source.isNumeric(column:)) ?? false)
    }

    /// Filters the grid in SQL, on the worker; the tokens show at once, the rows when they're found.
    func applyFilters(_ filters: [ColumnFilter]) {
        guard let source, let grid else { return }
        spinner.startAnimation(nil)
        status.stringValue = "Filtering…"
        var finished = false
        source.setFilters(filters) { [weak self, weak source] ok in
            finished = true
            guard let self, let source, self.source === source else { return }
            self.spinner.stopAnimation(nil)
            self.status.stringValue = ok ? "" : "Too large to filter here"
            // The selection was of rows by position; after filtering those are other rows.
            grid.tableView.deselectAll(nil)
            grid.reloadRows()
            self.updateToolbar()
            self.updateTokens()
        }
        if !finished { updateTokens() }
    }

    private func updateTokens() {
        tokens.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let source, let filterMenu, mode == .data else { tokens.isHidden = true; return }
        for token in filterMenu.tokens(name: source.title(ofColumn:)) { tokens.addArrangedSubview(token) }
        tokens.isHidden = source.filters.isEmpty
    }

    private func updateToolbar() {
        switch current {
        case .diagram:
            modes.isHidden = true
            titleLabel.isHidden = false
            titleLabel.stringValue = "Relationships"
            let tables = diagram.cards.count, links = diagram.edges.count
            var text = "\(tables) \(tables == 1 ? "table" : "tables")  ·  \(links) \(links == 1 ? "foreign key" : "foreign keys")"
            if diagram.omitted > 0 { text += "  ·  \(diagram.omitted) more not shown" }
            countLabel.stringValue = text
        case .object(let index):
            modes.isHidden = false
            titleLabel.isHidden = true
            let object = database.objects[index]
            if mode == .schema {
                countLabel.stringValue = ""
            } else if let source {
                let about = object.rowCount != nil ? "" : "about "
                let rows = source.rowCount
                if source.filters.isEmpty {
                    countLabel.stringValue = about + "\(rows.formatted()) \(rows == 1 ? "row" : "rows")"
                        + (database.hasPendingLog ? "  ·  Unsaved changes in the write-ahead log aren’t shown" : "")
                } else {
                    countLabel.stringValue = "\(rows.formatted()) of \(about)\(source.tableRows.formatted()) rows"
                }
            }
        default:
            break
        }
    }

    /// Opens a table by name (from the diagram), in the data view or its schema.
    private func open(_ name: String, mode: Mode = .data) {
        guard let index = database.objects.firstIndex(where: { $0.name == name }),
              let row = items.firstIndex(of: .object(index)) else { return }
        self.mode = mode
        modes.selectedSegment = mode.rawValue
        sidebar.selectRowIndexes([row], byExtendingSelection: false)
        sidebar.scrollRowToVisible(row)
    }

    #if DEBUG
    /// `GREECE_STATE` for design review: `diagram`, `schema`, `schema:<table>`, `table:<name>`,
    /// `sort:<column>` (descending with a leading `-`), `show:` and `hide:<column>=<value>`, and
    /// `menu:<row>/<column>`.
    private func applySnapshotState() {
        guard let state = ProcessInfo.processInfo.environment["GREECE_STATE"] else { return }
        for part in state.split(separator: ",") {
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            switch pieces[0] {
            case "diagram":
                if let row = items.firstIndex(of: .diagram) { sidebar.selectRowIndexes([row], byExtendingSelection: false) }
            case "schema":
                mode = .schema
                modes.selectedSegment = 1
                if pieces.count > 1 { open(pieces[1]); mode = .schema; modes.selectedSegment = 1 }
                if let current { show(current, force: true) }
            case "table":
                if pieces.count > 1 { open(pieces[1]) }
            case "sort":
                guard pieces.count > 1, let source else { continue }
                let descending = pieces[1].hasPrefix("-")
                let name = descending ? String(pieces[1].dropFirst()) : pieces[1]
                if let column = source.object.columns.firstIndex(where: { $0.name == name }) {
                    grid?.tableView.sortDescriptors = [NSSortDescriptor(key: String(column), ascending: !descending)]
                }
            case "show", "hide":
                // `show:<column>=<value>`, `hide:<column>=<value>`.
                guard pieces.count > 1, let source, let equals = pieces[1].firstIndex(of: "=") else { continue }
                let name = String(pieces[1][..<equals]), value = String(pieces[1][pieces[1].index(after: equals)...])
                guard let column = source.object.columns.firstIndex(where: { $0.name == name }) else { continue }
                let filter = ColumnFilter(column: column, test: pieces[0] == "show" ? .equals(value) : .notEquals(value))
                applyFilters(ColumnFilter.adding(filter, to: source.filters))
            case "menu":
                // `menu:<row>/<column>` prints that cell's context menu.
                let cell = pieces.count > 1 ? pieces[1].split(separator: "/").compactMap { Int($0) } : []
                guard cell.count == 2, let grid else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    grid.tableView.selectRowIndexes([cell[0]], byExtendingSelection: false)
                    let menu = grid.menu(forRow: cell[0], column: cell[1])
                    print(menu.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓ " : "  ") + $0.title }.joined(separator: "\n"))
                }
            default:
                break
            }
        }
    }
    #endif
}

/// A rounded selection like Finder's sidebar: the accent colour while the list has focus, a quiet
/// fill otherwise.
private final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 10, dy: 1)
        let color = isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected && isEmphasized ? .emphasized : .normal }
}

private final class SidebarHeader: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = .init("header")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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
        count.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField = name
        imageView = icon
        let stack = NSStackView(views: [icon, name, count])
        stack.spacing = 6
        stack.alignment = .centerY
        stack.distribution = .fill
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
