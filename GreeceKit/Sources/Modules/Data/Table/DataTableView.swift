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

/// A table in memory with a filter field and column profiles: delimited text, JSON Lines,
/// dBase files, lock files, string catalogs and Parquet previews.
final class DataTableView: NSView, PreviewSettingsAware, NSSearchFieldDelegate {
    struct Options {
        var unit = ("row", "rows")
        var filterPlaceholder = "Filter"
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
        if profileable {
            let button = DataToolbar.iconButton("chart.bar.xaxis", toolTip: "Column Profiles", target: self, action: #selector(toggleProfiles(_:)))
            button.state = .on
            toolbar.trailing.addArrangedSubview(button)
            profileButton = button
        }
        search.delegate = self
        search.target = self
        search.action = #selector(filterChanged(_:))
        toolbar.trailing.addArrangedSubview(search)

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
        let unit = total == 1 ? options.unit.0 : options.unit.1
        var text: String
        if source.filter.isEmpty {
            text = "\(total.formatted()) \(unit)"
        } else {
            text = "\(source.rowCount.formatted()) of \(total.formatted()) \(unit)"
        }
        if let note = options.note, source.filter.isEmpty { text += "  ·  " + note }
        countLabel.stringValue = text
    }

    // MARK: - Filter

    @objc private func filterChanged(_ sender: NSSearchField) {
        source.setFilter(sender.stringValue) { [weak self] in
            guard let self else { return }
            self.grid.reloadRows()
            self.updateCount()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        // Small tables filter as you type; large ones wait for a pause.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(filterNow), object: nil)
        perform(#selector(filterNow), with: nil, afterDelay: source.totalRows > 20_000 ? 0.25 : 0.05)
    }

    @objc private func filterNow() { filterChanged(search) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "f" {
            window?.makeFirstResponder(search)
            return true
        }
        return super.performKeyEquivalent(with: event)
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
        controller.view = ProfilePopoverView(title: source.title(ofColumn: column), profile: profile)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        self.popover = popover
    }

    // MARK: - Snapshots

    #if DEBUG
    /// `GREECE_STATE=filter:<text>` or `profile:<column>` shows a state for design review
    /// (the render command has no mouse).
    private func applySnapshotState() {
        guard let state = ProcessInfo.processInfo.environment["GREECE_STATE"] else { return }
        if state.hasPrefix("filter:") {
            search.stringValue = String(state.dropFirst(7))
            source.setFilter(search.stringValue) { [weak self] in self?.grid.reloadRows(); self?.updateCount() }
        } else if state.hasPrefix("profile:"), let column = Int(state.dropFirst(8)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pinProfile(column) }
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
        let content = ProfilePopoverView(title: source.title(ofColumn: column), profile: profile)
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
