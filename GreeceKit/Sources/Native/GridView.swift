import AppKit

enum GridValue {
    case text(String)
    case null
    case blob(Int)
}

/// Tabular data for `GridView`. Implemented by CSV tables and SQLite tables.
protocol GridSource: AnyObject {
    var columnCount: Int { get }
    var rowCount: Int { get }
    func title(ofColumn column: Int) -> String
    func toolTip(ofColumn column: Int) -> String?
    func isNumeric(column: Int) -> Bool
    func value(row: Int, column: Int) -> GridValue
    func estimatedWidth(ofColumn column: Int) -> CGFloat
    func sort(column: Int, ascending: Bool)
}

extension GridSource {
    func toolTip(ofColumn column: Int) -> String? { nil }
}

/// A spreadsheet-quality table: row numbers, numeric alignment, sorting, copy as TSV.
final class GridView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    let scrollView = NSScrollView()
    let tableView = GridTableView()
    private(set) var source: GridSource
    private var showsRowNumbers: Bool
    private static let rowNumberID = NSUserInterfaceItemIdentifier("#")
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    init(source: GridSource, showsRowNumbers: Bool) {
        self.source = source
        self.showsRowNumbers = showsRowNumbers
        super.init(frame: .zero)

        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = NSColor.separatorColor
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 22
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.copyHandler = { [weak self] in self?.copySelection() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        rebuildColumns()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSource(_ newSource: GridSource) {
        source = newSource
        rebuildColumns()
        tableView.scrollRowToVisible(0)
    }

    func setShowsRowNumbers(_ show: Bool) {
        guard show != showsRowNumbers else { return }
        showsRowNumbers = show
        rebuildColumns()
    }

    private func rebuildColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        tableView.sortDescriptors = []

        if showsRowNumbers {
            let digits = max(2, String(source.rowCount).count)
            let column = NSTableColumn(identifier: Self.rowNumberID)
            column.title = ""
            column.width = CGFloat(digits) * 7.5 + 18
            column.minWidth = column.width
            column.maxWidth = column.width
            column.resizingMask = []
            tableView.addTableColumn(column)
        }
        for index in 0..<source.columnCount {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            let header = PaddedHeaderCell(textCell: source.title(ofColumn: index))
            header.font = column.headerCell.font
            header.lineBreakMode = .byTruncatingTail
            column.headerCell = header
            column.headerToolTip = source.toolTip(ofColumn: index)
            column.width = source.estimatedWidth(ofColumn: index)
            column.minWidth = 36
            column.maxWidth = 2000
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            if source.isNumeric(column: index) { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        tableView.reloadData()
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
        switch source.value(row: row, column: column) {
        case .text(let text):
            cell.show(GridView.displayString(text), color: .labelColor, alignment: alignment, italic: false)
        case .null:
            cell.show("NULL", color: .tertiaryLabelColor, alignment: alignment, italic: true)
        case .blob(let size):
            cell.show("BLOB · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))", color: .secondaryLabelColor, alignment: alignment, italic: false)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let column = descriptor.key.flatMap(Int.init) else { return }
        source.sort(column: column, ascending: descriptor.ascending)
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, shouldSelect tableColumn: NSTableColumn?) -> Bool { false }

    static func displayString(_ text: String) -> String {
        var display = text.count > 400 ? String(text.prefix(400)) + "…" : text
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
        for row in rows {
            let fields = columns.map { column -> String in
                switch source.value(row: row, column: column) {
                case .text(let text): return text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                case .null: return ""
                case .blob: return ""
                }
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

/// Header titles aligned with the cell text below them.
final class PaddedHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: 4, dy: 0), in: controlView)
    }
}

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

    func show(_ text: String, color: NSColor, alignment: NSTextAlignment, italic isItalic: Bool) {
        label.stringValue = text
        label.textColor = color
        label.alignment = alignment
        label.font = isItalic ? italic : regular
    }
}

// MARK: - CSV source

final class DelimitedGridSource: GridSource {
    private let table: DelimitedTable
    private var order: [Int]
    private let numeric: Set<Int>
    private var widths: [CGFloat] = []

    init(table: DelimitedTable) {
        self.table = table
        order = Array(table.rows.indices)
        numeric = table.numericColumns()
        widths = (0..<table.columnCount).map { column in
            let sample = table.rows.prefix(200).map { column < $0.count ? $0[column].count : 0 }
            let longest = max(sample.max() ?? 0, (table.header.flatMap { column < $0.count ? $0[column].count : nil } ?? 1) + 2)
            return min(max(CGFloat(longest) * 7.4 + 22, 56), 360)
        }
    }

    var columnCount: Int { table.columnCount }
    var rowCount: Int { order.count }

    func title(ofColumn column: Int) -> String {
        if let header = table.header, column < header.count, !header[column].isEmpty { return header[column] }
        return DelimitedTable.columnLetter(column)
    }

    func isNumeric(column: Int) -> Bool { numeric.contains(column) }
    func estimatedWidth(ofColumn column: Int) -> CGFloat { widths[column] }

    func value(row: Int, column: Int) -> GridValue {
        let fields = table.rows[order[row]]
        return .text(column < fields.count ? fields[column] : "")
    }

    func sort(column: Int, ascending: Bool) {
        let rows = table.rows
        let isNumber = numeric.contains(column)
        func field(_ index: Int) -> String { column < rows[index].count ? rows[index][column] : "" }
        order.sort { a, b in
            let lhs = field(a), rhs = field(b)
            if isNumber {
                let x = DelimitedTable.number(lhs) ?? -.infinity, y = DelimitedTable.number(rhs) ?? -.infinity
                return ascending ? x < y : x > y
            }
            let result = lhs.localizedStandardCompare(rhs)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}
