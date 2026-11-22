import AppKit

/// A colour for status cells, resolved against the current appearance.
enum GridTint: Equatable {
    case accent, green, orange, red, purple, gray, teal

    var color: NSColor {
        switch self {
        case .accent: return .controlAccentColor
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .purple: return .systemPurple
        case .gray: return .tertiaryLabelColor
        case .teal: return .systemTeal
        }
    }
}

enum GridValue: Equatable {
    case text(String)
    case null
    case blob(Int)
    /// Not a value: "Missing", "Empty", an absent key. Italic and quiet.
    case placeholder(String)
    /// A value shown quietly: nested JSON, memo summaries.
    case secondary(String)
    /// A short state with a tinted dot: "Direct", "Needs Review".
    case status(String, GridTint)

    /// The value as plain text (for copying, sorting and filtering). Empty for nulls and placeholders.
    var plainText: String {
        switch self {
        case .text(let text), .secondary(let text), .status(let text, _): return text
        case .null, .placeholder: return ""
        case .blob(let size): return "BLOB \(size)"
        }
    }
}

/// What a column header shows under its title.
enum GridHeaderStrip {
    /// A quiet caption, e.g. a column's SQL type, with an optional SF Symbol before it.
    case caption(String, symbol: String?)
    /// A column profile: its kind, a detail, and a histogram or a share bar.
    case profile(kind: String, detail: String?, bars: [CGFloat], segments: [CGFloat], warning: Bool)
    /// Progress towards complete, e.g. a language's translations.
    case progress(Double, caption: String)
    /// Still being computed.
    case pending
}

/// Tabular data for `GridView`: delimited text, SQLite tables, records parsed from other formats.
protocol GridSource: AnyObject {
    var columnCount: Int { get }
    var rowCount: Int { get }
    func title(ofColumn column: Int) -> String
    func toolTip(ofColumn column: Int) -> String?
    func isNumeric(column: Int) -> Bool
    func value(row: Int, column: Int) -> GridValue
    func estimatedWidth(ofColumn column: Int) -> CGFloat
    /// Reorders the rows. `completion` runs on the main thread once the new order is in place
    /// (immediately for rows in memory, later for databases); false means the sort was abandoned.
    func sort(column: Int, ascending: Bool, completion: @escaping (Bool) -> Void)
    /// Rows shown struck through and dimmed (deleted dBase records).
    func isDimmed(row: Int) -> Bool
}

extension GridSource {
    func toolTip(ofColumn column: Int) -> String? { nil }
    func isDimmed(row: Int) -> Bool { false }
}

/// A spreadsheet-quality table: row numbers, numeric alignment, sorting, copy as TSV, and an
/// optional strip under each header (column types, profiles, progress).
final class GridView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    let scrollView = NSScrollView()
    let tableView = GridTableView()
    private(set) var source: GridSource
    private var showsRowNumbers: Bool
    static let rowNumberID = NSUserInterfaceItemIdentifier("#")
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let header = GridHeaderBar()
    private var headerHeight: NSLayoutConstraint!

    /// The strip under a column's title, or nil for none. Set `stripHeight` to make room for it.
    var headerStrip: ((Int) -> GridHeaderStrip?)? { didSet { header.needsDisplay = true } }
    var stripHeight: CGFloat = 0 {
        didSet {
            headerHeight.constant = GridHeaderBar.titleHeight + stripHeight
            header.needsDisplay = true
        }
    }
    /// A click on a column's strip, with the strip's rect in the header bar.
    var onStripClick: ((Int, NSRect, NSView) -> Void)?
    /// Reports long-running work (database sorts) so the owner can show progress.
    var onBusy: ((Bool) -> Void)?
    /// Called when a sort couldn't finish (too slow, failed).
    var onSortFailed: (() -> Void)?

    private var ignoreSortChange = false

    init(source: GridSource, showsRowNumbers: Bool, stripHeight: CGFloat = 0) {
        self.source = source
        self.showsRowNumbers = showsRowNumbers
        self.stripHeight = stripHeight
        super.init(frame: .zero)

        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = NSColor.separatorColor
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 22
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.copyHandler = { [weak self] in self?.copySelection() }
        // The header is drawn by `GridHeaderBar` above the scroll view: full control over its
        // height and strips, and nothing for the scroll view to inset.
        tableView.headerView = nil
        header.grid = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        for view in [header, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        headerHeight = header.heightAnchor.constraint(equalToConstant: GridHeaderBar.titleHeight + stripHeight)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeight,
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(columnsResized(_:)), name: NSTableView.columnDidResizeNotification, object: tableView)
        rebuildColumns()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled(_ note: Notification) {
        let x = scrollView.contentView.bounds.origin.x
        if header.offset != x { header.offset = x }
    }

    @objc private func columnsResized(_ note: Notification) { header.needsDisplay = true; header.window?.invalidateCursorRects(for: header) }

    func setSource(_ newSource: GridSource) {
        source = newSource
        onBusy?(false)
        rebuildColumns()
        scrollToTop()
    }

    func scrollToTop() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    func setShowsRowNumbers(_ show: Bool) {
        guard show != showsRowNumbers else { return }
        showsRowNumbers = show
        rebuildColumns()
    }

    /// Rows changed (filtering, a count that arrived later): keeps columns and sort indicators.
    func reloadRows() {
        if showsRowNumbers, let column = tableView.tableColumn(withIdentifier: Self.rowNumberID) {
            let width = rowNumberWidth()
            if column.width != width { column.minWidth = width; column.maxWidth = width; column.width = width }
        }
        tableView.reloadData()
    }

    func refreshHeader() { header.needsDisplay = true }

    private func rowNumberWidth() -> CGFloat {
        CGFloat(max(2, String(source.rowCount).count)) * 7.5 + 18
    }

    private func rebuildColumns() {
        ignoreSortChange = true
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        tableView.sortDescriptors = []
        ignoreSortChange = false

        if showsRowNumbers {
            let column = NSTableColumn(identifier: Self.rowNumberID)
            column.title = ""
            column.width = rowNumberWidth()
            column.minWidth = column.width
            column.maxWidth = column.width
            column.resizingMask = []
            tableView.addTableColumn(column)
        }
        for index in 0..<source.columnCount {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = source.title(ofColumn: index)
            column.headerToolTip = source.toolTip(ofColumn: index)
            column.width = source.estimatedWidth(ofColumn: index)
            column.minWidth = 36
            column.maxWidth = 2000
            column.resizingMask = .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            tableView.addTableColumn(column)
        }
        tableView.reloadData()
        header.columnsChanged()
    }

    func strip(forColumn column: Int) -> GridHeaderStrip? {
        stripHeight > 0 ? headerStrip?(column) : nil
    }

    /// Sorts by a column: ascending first, then flips.
    func toggleSort(column: Int) {
        let current = tableView.sortDescriptors.first
        let ascending = current?.key == String(column) ? !(current?.ascending ?? false) : true
        tableView.sortDescriptors = [NSSortDescriptor(key: String(column), ascending: ascending)]
    }

    // MARK: - Data source

    func numberOfRows(in tableView: NSTableView) -> Int { source.rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: GridCellView.reuseID, owner: nil) as? GridCellView) ?? GridCellView(font: font)

        if identifier == Self.rowNumberID {
            cell.show(String(row + 1), color: .tertiaryLabelColor, alignment: .right, italic: false)
            return cell
        }
        let column = Int(identifier.rawValue) ?? 0
        let alignment: NSTextAlignment = source.isNumeric(column: column) ? .right : .left
        let dimmed = source.isDimmed(row: row)
        switch source.value(row: row, column: column) {
        case .text(let text):
            cell.show(GridView.displayString(text), color: dimmed ? .tertiaryLabelColor : .labelColor, alignment: alignment, italic: false, struck: dimmed)
        case .null:
            cell.show("NULL", color: .tertiaryLabelColor, alignment: alignment, italic: true)
        case .placeholder(let text):
            cell.show(text, color: .tertiaryLabelColor, alignment: alignment, italic: true)
        case .secondary(let text):
            cell.show(GridView.displayString(text), color: dimmed ? .tertiaryLabelColor : .secondaryLabelColor, alignment: alignment, italic: false, struck: dimmed)
        case .blob(let size):
            cell.show("BLOB · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))", color: .secondaryLabelColor, alignment: alignment, italic: false)
        case .status(let text, let tint):
            cell.showStatus(text, tint: tint, alignment: alignment, dimmed: dimmed)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        header.needsDisplay = true
        guard !ignoreSortChange else { return }
        guard let descriptor = tableView.sortDescriptors.first, let column = descriptor.key.flatMap(Int.init) else { return }
        onBusy?(true)
        let expected = source
        source.sort(column: column, ascending: descriptor.ascending) { [weak self] finished in
            guard let self, self.source === expected else { return }
            self.onBusy?(false)
            if !finished {
                self.ignoreSortChange = true
                tableView.sortDescriptors = oldDescriptors
                self.ignoreSortChange = false
                self.header.needsDisplay = true
                self.onSortFailed?()
            }
            tableView.reloadData()
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelect tableColumn: NSTableColumn?) -> Bool { false }

    static func displayString(_ text: String) -> String {
        var display = text.utf16.count > 400 ? String(text.prefix(400)) + "…" : text
        if display.contains(where: { $0.isNewline }) {
            display = display.split(whereSeparator: \.isNewline).joined(separator: " ↵ ")
        }
        return display
    }

    // MARK: - Copy

    private func copySelection() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let columns = tableView.tableColumns.compactMap { Int($0.identifier.rawValue) }
        var lines: [String] = []
        for row in rows.prefix(100_000) {
            let fields = columns.map { column -> String in
                source.value(row: row, column: column).plainText
                    .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            }
            lines.append(fields.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

final class GridTableView: NSTableView {
    var copyHandler: (() -> Void)?

    /// Grid lines stop at the last row, like Numbers, instead of striping empty space.
    override func drawGrid(inClipRect clipRect: NSRect) {
        guard numberOfRows > 0 else { return }
        let lastRow = rect(ofRow: numberOfRows - 1)
        super.drawGrid(inClipRect: clipRect.intersection(NSRect(x: clipRect.minX, y: 0, width: clipRect.width, height: lastRow.maxY)))
    }

    @objc func copy(_ sender: Any?) { copyHandler?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

// MARK: - Header

/// Column titles above the grid, with an optional strip under each (types, profiles, progress).
/// Click a title to sort, drag an edge to resize, click a strip for details. Follows the
/// table's horizontal scrolling.
final class GridHeaderBar: NSView, NSViewToolTipOwner {
    static let titleHeight: CGFloat = 28
    weak var grid: GridView?
    /// The table's horizontal scroll offset.
    var offset: CGFloat = 0 { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    private enum Drag { case resize(NSTableColumn, start: CGFloat, width: CGFloat), press(column: Int) }
    private var drag: Drag?
    private var pressed: Int?

    override var isFlipped: Bool { true }

    private var table: NSTableView? { grid?.tableView }

    func columnsChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // One tooltip area; the text depends on the column under the pointer.
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    /// A column's rect in this view's coordinates.
    func rect(ofColumn index: Int) -> NSRect {
        guard let table else { return .zero }
        let rect = table.rect(ofColumn: index)
        return NSRect(x: rect.minX - offset, y: 0, width: rect.width, height: bounds.height)
    }

    private func columnIndex(at x: CGFloat) -> Int? {
        guard let table else { return nil }
        let index = table.column(at: NSPoint(x: x + offset, y: 0))
        return index >= 0 ? index : nil
    }

    // MARK: Drawing

    override var clipsToBounds: Bool { get { true } set {} }

    override func draw(_ dirtyRect: NSRect) {
        // Views don't clip to their bounds by default: never paint outside ours.
        let dirtyRect = dirtyRect.intersection(bounds)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        guard let table, let grid else { return }
        let line = 1 / (window?.backingScaleFactor ?? 2)
        let sort = table.sortDescriptors.first
        for index in 0..<table.numberOfColumns {
            let rect = rect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            let column = table.tableColumns[index]
            if pressed == index {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
                rect.fill()
            }
            if let data = Int(column.identifier.rawValue) {
                let numeric = grid.source.isNumeric(column: data)
                let sorted = sort?.key == column.identifier.rawValue
                drawTitle(column.title, in: rect, rightAligned: numeric, sorted: sorted ? sort?.ascending : nil)
                if grid.stripHeight > 0, let strip = grid.strip(forColumn: data) {
                    let frame = NSRect(x: rect.minX + 9, y: Self.titleHeight - 3, width: rect.width - 18, height: grid.stripHeight - 3)
                    GridStripRenderer.draw(strip, in: frame, alignRight: numeric)
                }
            }
            NSColor.separatorColor.setFill()
            NSRect(x: rect.maxX - line, y: 7, width: line, height: Self.titleHeight - 14).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.maxY - line, width: dirtyRect.width, height: line).fill()
    }

    private func drawTitle(_ title: String, in rect: NSRect, rightAligned: Bool, sorted ascending: Bool?) {
        let style = NSMutableParagraphStyle()
        style.alignment = rightAligned ? .right : .left
        style.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 12, weight: ascending == nil ? .regular : .semibold)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.headerTextColor, .paragraphStyle: style])
        var textRect = NSRect(x: rect.minX + 9, y: 0, width: rect.width - 18, height: Self.titleHeight)
        if let ascending, let chevron = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
            let image = chevron.tinted(.secondaryLabelColor)
            let size = image.size
            let x = rightAligned ? rect.minX + 7 : rect.maxX - 7 - size.width
            image.draw(in: NSRect(x: x, y: (Self.titleHeight - size.height) / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if rightAligned { textRect.origin.x += size.width + 4 }
            textRect.size.width -= size.width + 4
        }
        let height = ceil(text.size().height)
        textRect.origin.y = (Self.titleHeight - height) / 2
        textRect.size.height = height
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Mouse

    private func resizeTarget(at point: NSPoint) -> NSTableColumn? {
        guard let table, point.y < Self.titleHeight + (grid?.stripHeight ?? 0) else { return nil }
        for index in 0..<table.numberOfColumns {
            let rect = rect(ofColumn: index)
            let column = table.tableColumns[index]
            if abs(point.x - rect.maxX) <= 3, column.resizingMask.contains(.userResizingMask) { return column }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let column = resizeTarget(at: point) {
            drag = .resize(column, start: point.x, width: column.width)
            return
        }
        guard let index = columnIndex(at: point.x), let table, let grid,
              let data = Int(table.tableColumns[index].identifier.rawValue) else { return }
        if point.y > Self.titleHeight, grid.stripHeight > 0, grid.onStripClick != nil {
            var rect = rect(ofColumn: index)
            rect.origin.y = Self.titleHeight
            rect.size.height = grid.stripHeight
            grid.onStripClick?(data, rect, self)
            return
        }
        drag = .press(column: data)
        pressed = index
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .resize(let column, let start, let width) = drag else { return }
        let x = convert(event.locationInWindow, from: nil).x
        column.width = min(max(width + x - start, column.minWidth), column.maxWidth)
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; pressed = nil; needsDisplay = true }
        guard case .press(let column) = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), let index = columnIndex(at: point.x), let table,
           Int(table.tableColumns[index].identifier.rawValue) == column {
            grid?.toggleSort(column: column)
        }
    }

    override func resetCursorRects() {
        guard let table, let grid else { return }
        for index in 0..<table.numberOfColumns {
            let rect = rect(ofColumn: index)
            if table.tableColumns[index].resizingMask.contains(.userResizingMask) {
                addCursorRect(NSRect(x: rect.maxX - 3, y: 0, width: 6, height: bounds.height), cursor: .resizeLeftRight)
            }
            if grid.stripHeight > 0, grid.onStripClick != nil, Int(table.tableColumns[index].identifier.rawValue) != nil {
                addCursorRect(NSRect(x: rect.minX + 4, y: Self.titleHeight, width: rect.width - 8, height: grid.stripHeight), cursor: .pointingHand)
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let table, let index = columnIndex(at: point.x) else { return "" }
        let column = table.tableColumns[index]
        return column.headerToolTip ?? column.title
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        table?.tableColumns.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum GridStripRenderer {
    static func draw(_ strip: GridHeaderStrip, in rect: NSRect, alignRight: Bool) {
        let small = NSFont.systemFont(ofSize: 10, weight: .medium)
        let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        func text(_ string: String, font: NSFont, color: NSColor, in frame: NSRect, align: NSTextAlignment) {
            let style = NSMutableParagraphStyle()
            style.alignment = align
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
                .draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        switch strip {
        case .pending:
            return
        case .caption(let caption, let symbol):
            var frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 13)
            if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold)) {
                let tinted = image.tinted(symbol.hasPrefix("key") ? .systemOrange : .secondaryLabelColor)
                let size = tinted.size
                let iconX = alignRight ? rect.maxX - size.width : rect.minX
                tinted.draw(in: NSRect(x: iconX, y: rect.minY + (13 - size.height) / 2, width: size.width, height: size.height))
                if alignRight { frame.size.width -= size.width + 3 } else { frame.origin.x += size.width + 3; frame.size.width -= size.width + 3 }
            }
            text(caption, font: small, color: .tertiaryLabelColor, in: frame, align: alignRight ? .right : .left)
        case .progress(let fraction, let caption):
            let barY = rect.minY + 15
            let track = NSRect(x: rect.minX, y: barY, width: rect.width, height: 4)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let clamped = min(max(fraction, 0), 1)
            if clamped > 0 {
                (clamped >= 0.999 ? NSColor.systemGreen : NSColor.controlAccentColor).setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: barY, width: max(4, track.width * clamped), height: 4), xRadius: 2, yRadius: 2).fill()
            }
            text(caption, font: detailFont, color: .secondaryLabelColor, in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 13), align: .left)
        case .profile(let kind, let detail, let bars, let segments, let warning):
            let line = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 13)
            text(kind, font: small, color: .tertiaryLabelColor, in: line, align: .left)
            if let detail, rect.width > 90 {
                let kindWidth = (kind as NSString).size(withAttributes: [.font: small]).width + 6
                text(detail, font: detailFont, color: warning ? .systemOrange : .tertiaryLabelColor,
                     in: NSRect(x: line.minX + kindWidth, y: line.minY, width: line.width - kindWidth, height: 13), align: .right)
            }
            let chart = NSRect(x: rect.minX, y: rect.minY + 14, width: rect.width, height: max(rect.height - 15, 4))
            if !bars.isEmpty {
                let gap: CGFloat = bars.count > 24 ? 0.5 : 1
                let width = (chart.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
                NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
                for (i, value) in bars.enumerated() where value > 0 {
                    let height = max(1, chart.height * value)
                    // Flipped header: bars grow upward from the strip's bottom edge.
                    NSRect(x: chart.minX + CGFloat(i) * (width + gap), y: chart.maxY - height, width: max(width, 0.5), height: height).fill()
                }
                NSColor.separatorColor.setFill()
                NSRect(x: chart.minX, y: chart.maxY - 0.5, width: chart.width, height: 0.5).fill()
            } else if !segments.isEmpty {
                let bar = NSRect(x: chart.minX, y: chart.maxY - 5, width: chart.width, height: 5)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).addClip()
                NSColor.quaternaryLabelColor.setFill()
                bar.fill()
                var x = bar.minX
                for (i, share) in segments.enumerated() {
                    let width = bar.width * share
                    let alpha = max(0.18, 0.75 - CGFloat(i) * 0.14)
                    NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
                    NSRect(x: x, y: bar.minY, width: max(0, width - 1), height: bar.height).fill()
                    x += width
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

extension NSImage {
    /// A template symbol drawn in one colour.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Cells

final class GridCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("GridCell")
    private let label = NSTextField(labelWithString: "")
    private let regular: NSFont
    private let italic: NSFont

    init(font: NSFont) {
        regular = font
        italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        super.init(frame: .zero)
        identifier = Self.reuseID
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, color: NSColor, alignment: NSTextAlignment, italic isItalic: Bool, struck: Bool = false) {
        if struck {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineBreakMode = .byTruncatingTail
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: regular, .foregroundColor: color, .paragraphStyle: style,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor.tertiaryLabelColor,
            ])
            return
        }
        label.stringValue = text
        label.textColor = color
        label.alignment = alignment
        label.font = isItalic ? italic : regular
    }

    func showStatus(_ text: String, tint: GridTint, alignment: NSTextAlignment, dimmed: Bool) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: tint.color, .baselineOffset: 1.5, .paragraphStyle: style,
        ])
        result.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor, .paragraphStyle: style,
        ]))
        label.attributedStringValue = result
    }
}
