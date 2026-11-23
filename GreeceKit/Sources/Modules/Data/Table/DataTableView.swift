import AppKit

/// A slim bar above a table: what's showing on the left, tools on the right.
final class DataToolbar: NSView {
    static let height: CGFloat = 36
    let leading = NSStackView()
    let trailing = NSStackView()
    private let separator = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        separator.boxType = .separator
        leading.spacing = 8
        leading.alignment = .centerY
        trailing.spacing = 6
        trailing.alignment = .centerY
        for view in [separator, leading, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var clipsToBounds: Bool { get { true } set {} }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    static func label(_ text: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func searchField(placeholder: String) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 190).isActive = true
        return field
    }

    static func iconButton(_ symbol: String, toolTip: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageOnly
        button.controlSize = .small
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        return button
    }
}

/// A table in memory with a filter field, column filters and column profiles: delimited text,
/// JSON Lines, dBase files, lock files, string catalogs and Parquet previews. Column filters come
/// from a cell's context menu or a profile's common values and show as tokens in the toolbar, so
/// the table can be narrowed by pointer alone (Quick Look has no typing).
final class DataTableView: NSView, PreviewSettingsAware, NSSearchFieldDelegate {
    /// What the table's rows are, for its count: "1,204 rows", "12 of 40 packages".
    enum Unit {
        case rows, records, packages, strings, rules

        func count(_ n: Int) -> String {
            switch self {
            case .rows: return String(localized: "\(n) rows", bundle: .greeceKit, comment: "Rows in a table")
            case .records: return String(localized: "\(n) records", bundle: .greeceKit, comment: "Records (rows) in a data file")
            case .packages: return String(localized: "\(n) packages", bundle: .greeceKit, comment: "Packages a lock file pins")
            case .strings: return String(localized: "\(n) strings", bundle: .greeceKit, comment: "Translatable strings in a strings file or string catalog")
            case .rules: return String(localized: "\(n) rules", bundle: .greeceKit, comment: "Plural rules in a .stringsdict file")
            }
        }

        /// "12 of 1,204 rows" while a filter hides the others.
        func filtered(_ shown: Int, of total: Int) -> String {
            switch self {
            case .rows: return String(localized: "\(shown) of \(total) rows", bundle: .greeceKit, comment: "Rows a filter leaves in a table, of all its rows")
            case .records: return String(localized: "\(shown) of \(total) records", bundle: .greeceKit, comment: "Records a filter leaves in a table, of all its records")
            case .packages: return String(localized: "\(shown) of \(total) packages", bundle: .greeceKit, comment: "Packages a filter leaves in a lock file’s table, of all of them")
            case .strings: return String(localized: "\(shown) of \(total) strings", bundle: .greeceKit, comment: "Strings a filter leaves in a string catalog’s table, of all of them")
            case .rules: return String(localized: "\(shown) of \(total) rules", bundle: .greeceKit, comment: "Plural rules a filter leaves in a .stringsdict file’s table, of all of them")
            }
        }
    }

    struct Options {
        var unit = Unit.rows
        var filterPlaceholder = String(localized: "Filter", bundle: .greeceKit, comment: "Placeholder of a table’s filter field")
        /// Offer column profiles (a strip under each header, details on click).
        var profiles = true
        /// Strips that aren't profiles: field types, translation progress.
        var strip: ((Int) -> GridHeaderStrip?)?
        var stripHeight: CGFloat = 16
        /// Views at the toolbar's leading edge (a segmented control, a note). The row count follows them.
        var leading: [NSView] = []
        /// Extra text after the count ("3 deleted").
        var note: String?
    }

    let source: RecordGridSource
    let grid: GridView
    private let options: Options
    private let toolbar = DataToolbar()
    private let countLabel = DataToolbar.label()
    /// Active column filters, each removable.
    private let tokens = NSStackView()
    /// Only in hosts that take typing: in Quick Look, keys go to Finder.
    private let search: NSSearchField
    private var profileButton: NSButton?
    private var profiles: [Int: ColumnProfile] = [:]
    private var profilesShown: Bool
    private var popover: NSPopover?
    private var profiling = false

    init(store: RecordStore, settings: PreviewSettings, options: Options = Options()) {
        source = RecordGridSource(store: store)
        let profileable = options.profiles && store.columns.contains(where: \.profiled) && store.rowCount > 0
        profilesShown = profileable
        grid = GridView(source: source, showsRowNumbers: settings.rowNumbers,
                        stripHeight: profileable ? Self.profileStripHeight : options.strip != nil ? options.stripHeight : 0)
        self.options = options
        search = DataToolbar.searchField(placeholder: options.filterPlaceholder)
        super.init(frame: .zero)

        for view in options.leading { toolbar.leading.addArrangedSubview(view) }
        toolbar.leading.addArrangedSubview(countLabel)
        tokens.spacing = 4
        tokens.alignment = .centerY
        tokens.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.leading.addArrangedSubview(tokens)
        if profileable {
            let button = DataToolbar.iconButton("chart.bar.xaxis", toolTip: String(localized: "Column Profiles", bundle: .greeceKit, comment: "Tooltip of a toolbar button that shows each column’s type and spread"),
                                                target: self, action: #selector(toggleProfiles(_:)))
            button.state = .on
            toolbar.trailing.addArrangedSubview(button)
            profileButton = button
        }
        search.delegate = self
        search.target = self
        search.action = #selector(filterChanged(_:))
        if PreviewHost.acceptsTyping { toolbar.trailing.addArrangedSubview(search) }

        for view in [toolbar, grid] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        grid.headerStrip = { [weak self] column in self?.strip(for: column) }
        grid.onStripClick = { [weak self] column, rect, view in self?.showProfile(column, rect: rect, in: view) }
        grid.cellMenuItems = { [weak self] row, column in self?.filterMenuItems(row: row, column: column) ?? [] }
        updateStrips()
        updateCount()
        if profileable { startProfiling() }
        #if DEBUG
        applySnapshotState()
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ settings: PreviewSettings) {
        grid.setShowsRowNumbers(settings.rowNumbers)
    }

    private var alternate: NSView?

    /// Shows another view (a schema page) in place of the grid, under the same toolbar; nil
    /// brings the grid back.
    func setAlternateContent(_ view: NSView?) {
        alternate?.removeFromSuperview()
        alternate = view
        grid.isHidden = view != nil
        countLabel.isHidden = view != nil
        toolbar.trailing.isHidden = view != nil
        updateTokens()
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }


    // MARK: - Count

    private func updateCount() {
        let total = source.totalRows
        var text = source.isFiltered ? options.unit.filtered(source.rowCount, of: total) : options.unit.count(total)
        if let note = options.note, !source.isFiltered { text += "  ·  " + note }
        countLabel.stringValue = text
    }

    // MARK: - Filter

    @objc private func filterChanged(_ sender: NSSearchField) {
        refilter { source.setFilter(sender.stringValue, completion: $0) }
    }

    func controlTextDidChange(_ obj: Notification) {
        // Small tables filter as you type; large ones wait for a pause.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(filterNow), object: nil)
        perform(#selector(filterNow), with: nil, afterDelay: source.totalRows > 20_000 ? 0.25 : 0.05)
    }

    @objc private func filterNow() { filterChanged(search) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if search.superview != nil, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" {
            window?.makeFirstResponder(search)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Column filters

    private var filterMenu: FilterMenu {
        FilterMenu(active: source.columnFilters,
                   add: { [weak self] in self?.addFilter($0) },
                   remove: { [weak self] in self?.removeFilter($0) },
                   clear: source.isFiltered ? { [weak self] in self?.clearFilters() } : nil)
    }

    /// Filter items for a right-click on a cell, then Clear Filters whenever anything is filtered.
    func filterMenuItems(row: Int?, column: Int?) -> [NSMenuItem] {
        var cell: FilterMenu.Cell?
        if let row, let column, row < source.rowCount {
            let text = source.text(row: row, column: column)
            cell = ColumnFilter.isBlank(text) ? .empty : .text(text)
        }
        return filterMenu.items(column: column ?? 0, name: column.map(columnName) ?? "",
                                cell: cell, numeric: column.map(source.holdsNumbers) ?? false)
    }

    func addFilter(_ filter: ColumnFilter) {
        refilter { source.addColumnFilter(filter, completion: $0) }
    }

    func removeFilter(_ filter: ColumnFilter) {
        refilter { source.removeColumnFilter(filter, completion: $0) }
    }

    /// Clears the column filters and the text filter.
    func clearFilters() {
        search.stringValue = ""
        refilter { source.clearFilters(completion: $0) }
    }

    /// Starts a change to the filters; the tokens follow at once, the rows when they're ready
    /// (a moment later for large tables, filtered off the main thread).
    private func refilter(_ change: (@escaping () -> Void) -> Void) {
        var finished = false
        change { [weak self] in
            finished = true
            guard let self else { return }
            // The selection was of rows by position; after filtering those are other rows.
            self.grid.tableView.deselectAll(nil)
            self.grid.reloadRows()
            self.updateCount()
            self.updateTokens()
        }
        if !finished {
            updateTokens()
            countLabel.stringValue = String(localized: "Filtering…", bundle: .greeceKit, comment: "In a table’s toolbar while a filter is applied")
        }
    }

    private func columnName(_ column: Int) -> String {
        let title = source.title(ofColumn: column).trimmingCharacters(in: .whitespaces)
        let letter = DelimitedTable.columnLetter(column)
        return title.isEmpty ? String(localized: "Column \(letter)", bundle: .greeceKit, comment: "A table column without a name. The argument is its letter, such as “C”") : title
    }

    private func updateTokens() {
        tokens.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for token in filterMenu.tokens(name: columnName) { tokens.addArrangedSubview(token) }
        tokens.isHidden = source.columnFilters.isEmpty || alternate != nil
    }

    // MARK: - Profiles

    static let profileStripHeight: CGFloat = 31

    private func updateStrips() {
        if profilesShown {
            grid.stripHeight = Self.profileStripHeight
        } else if options.strip != nil {
            grid.stripHeight = options.stripHeight
        } else {
            grid.stripHeight = 0
        }
    }

    private func strip(for column: Int) -> GridHeaderStrip? {
        if profilesShown {
            guard source.columns[column].profiled else { return options.strip?(column) }
            return profiles[column]?.strip ?? .pending
        }
        return options.strip?(column)
    }

    @objc private func toggleProfiles(_ sender: NSButton) {
        profilesShown = sender.state == .on
        updateStrips()
        grid.widenColumnsToFitStrips()
        grid.refreshHeader()
    }

    private func startProfiling() {
        guard !profiling else { return }
        profiling = true
        let store = source.store
        let columns = store.columns.indices.filter { store.columns[$0].profiled }.prefix(300)
        let rows = store.rowCount
        // Keep the work bounded on wide tables: about four million cells in all.
        let limit = max(2_000, min(200_000, 4_000_000 / max(columns.count, 1)))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var batch: [Int: ColumnProfile] = [:]
            var lastFlush = CFAbsoluteTimeGetCurrent()
            for column in columns {
                guard self != nil else { return }
                batch[column] = ColumnProfile.make(rows: rows, limit: limit) { store.text(row: $0, column: column) }
                if CFAbsoluteTimeGetCurrent() - lastFlush > 0.08 || column == columns.last {
                    let ready = batch
                    batch = [:]
                    lastFlush = CFAbsoluteTimeGetCurrent()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        for (index, profile) in ready {
                            self.profiles[index] = profile
                            if profile.kind != .text, profile.kind != .empty { self.source.sortKinds[index] = profile.kind }
                        }
                        self.grid.widenColumnsToFitStrips()
                        self.grid.refreshHeader()
                    }
                }
            }
        }
    }

    private func showProfile(_ column: Int, rect: NSRect, in view: NSView) {
        guard profilesShown, let profile = profiles[column] else { return }
        popover?.close()
        let controller = NSViewController()
        controller.view = profileView(column, profile)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        self.popover = popover
    }

    /// A column's profile; choosing one of its common values shows only the rows with it.
    private func profileView(_ column: Int, _ profile: ColumnProfile) -> ProfilePopoverView {
        ProfilePopoverView(title: columnName(column), profile: profile) { [weak self] value in
            self?.popover?.close()
            self?.addFilter(ColumnFilter(column: column, test: .equals(value)))
        }
    }

    // MARK: - Snapshots

    #if DEBUG
    /// `GREECE_STATE` shows a state for design review (the render command has no mouse). Parts,
    /// separated by `;`: `filter:<text>`, `profile:<column>`, `show:<column>=<value>`,
    /// `hide:<column>=<value>`, and `menu:<row>,<column>`, which prints that cell's menu.
    private func applySnapshotState() {
        guard let state = ProcessInfo.processInfo.environment["GREECE_STATE"] else { return }
        for part in state.split(separator: ";").map(String.init) {
            let (name, argument) = part.firstIndex(of: ":").map { (String(part[..<$0]), String(part[part.index(after: $0)...])) } ?? (part, "")
            let pair = argument.firstIndex(of: "=").map { (Int(argument[..<$0]), String(argument[argument.index(after: $0)...])) }
            switch name {
            case "filter":
                search.stringValue = argument
                filterChanged(search)
            case "profile":
                guard let column = Int(argument) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pinProfile(column) }
            case "show", "hide":
                guard let pair, let column = pair.0, column < source.columnCount else { continue }
                addFilter(ColumnFilter(column: column, test: name == "show" ? .equals(pair.1) : .notEquals(pair.1)))
            case "menu":
                let cell = argument.split(separator: ",").compactMap { Int($0) }
                guard cell.count == 2 else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    self.grid.tableView.selectRowIndexes([cell[0]], byExtendingSelection: false)
                    let menu = self.grid.menu(forRow: cell[0], column: cell[1])
                    print(menu.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓ " : "  ") + $0.title }.joined(separator: "\n"))
                }
            default:
                continue
            }
        }
    }

    private func pinProfile(_ column: Int) {
        guard column < source.columnCount, let profile = profiles[column] else { return }
        let card = NSVisualEffectView()
        card.material = .popover
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        let content = profileView(column, profile)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        let x = grid.tableView.rect(ofColumn: grid.tableView.column(withIdentifier: .init(String(column)))).minX
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            card.topAnchor.constraint(equalTo: grid.topAnchor, constant: GridHeaderBar.titleHeight + grid.stripHeight + 4),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: max(8, min(x, bounds.width - 316))),
        ])
    }
    #endif
}
