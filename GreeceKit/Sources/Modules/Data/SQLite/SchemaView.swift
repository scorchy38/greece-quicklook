import AppKit

/// A table drawn in one view: aligned columns, a quiet header, hairlines between rows. Used for
/// schema pages (columns, indexes, triggers), where a full NSTableView would be heavy. Its rows
/// can't be selected, so a right-click offers the copying instead.
final class SchemaTableView: NSView, NSMenuDelegate {
    struct Cell {
        enum Style { case name, code, secondary, link, tertiary }
        var text: String
        var style: Style = .secondary
        var symbol: String?
        var tint: NSColor?
        /// Quiet text after the value ("cascade").
        var detail: String?

        static func name(_ text: String, symbol: String? = nil, tint: NSColor? = nil) -> Cell { Cell(text: text, style: .name, symbol: symbol, tint: tint) }
        static func code(_ text: String) -> Cell { Cell(text: text, style: .code) }
        static func plain(_ text: String) -> Cell { Cell(text: text, style: .secondary) }
        static func link(_ text: String, detail: String? = nil) -> Cell { Cell(text: text, style: .link, detail: detail) }
        static let none = Cell(text: "—", style: .tertiary)
    }

    let headers: [String]
    let rows: [[Cell]]
    /// The column that takes the remaining width.
    let flexible: Int
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 30
    private var widths: [CGFloat] = []

    init(headers: [String], rows: [[Cell]], flexible: Int = 0) {
        self.headers = headers
        self.rows = rows
        self.flexible = flexible
        super.init(frame: .zero)
        measure()
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
        setAccessibilityLabel(rows.map { $0.map(\.text).joined(separator: ", ") }.joined(separator: "; "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var clipsToBounds: Bool { get { true } set {} }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.headerHeight + CGFloat(rows.count) * Self.rowHeight)
    }

    private static func font(_ style: Cell.Style) -> NSFont {
        switch style {
        case .name: return .systemFont(ofSize: 12.5, weight: .medium)
        case .code: return .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        default: return .systemFont(ofSize: 12)
        }
    }

    private func measure() {
        widths = headers.indices.map { column in
            var widest = (headers[column] as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width
            for row in rows.prefix(400) where column < row.count {
                let cell = row[column]
                var width = (cell.text as NSString).size(withAttributes: [.font: Self.font(cell.style)]).width
                if cell.symbol != nil { width += 18 }
                if let detail = cell.detail { width += 8 + (detail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width }
                widest = max(widest, width)
            }
            return min(ceil(widest) + 24, 320)
        }
    }

    /// Column frames for the current width: fixed columns at their measured widths, the flexible
    /// one taking what's left.
    private func columnFrames() -> [(x: CGFloat, width: CGFloat)] {
        var widths = self.widths
        let fixed = widths.enumerated().filter { $0.offset != flexible }.reduce(0) { $0 + $1.element }
        if flexible < widths.count { widths[flexible] = max(widths[flexible], bounds.width - 16 - fixed) }
        var x: CGFloat = 8
        return widths.map { width in defer { x += width }; return (x, width) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frames = columnFrames()
        let line = 1 / (window?.backingScaleFactor ?? 2)
        func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            let height = ceil(string.size().height)
            string.draw(with: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        // Header
        for (index, title) in headers.enumerated() where index < frames.count {
            draw(title, font: .systemFont(ofSize: 11, weight: .medium), color: .tertiaryLabelColor,
                 in: NSRect(x: frames[index].x + 8, y: 0, width: frames[index].width - 16, height: Self.headerHeight))
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 8, y: Self.headerHeight - line, width: bounds.width - 16, height: line).fill()
        // Rows
        for (r, row) in rows.enumerated() {
            let y = Self.headerHeight + CGFloat(r) * Self.rowHeight
            guard NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight).intersects(dirtyRect) else { continue }
            for (index, cell) in row.enumerated() where index < frames.count {
                var rect = NSRect(x: frames[index].x + 8, y: y, width: frames[index].width - 16, height: Self.rowHeight)
                if let symbol = cell.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                    let tinted = image.tinted(cell.tint ?? .secondaryLabelColor)
                    let size = tinted.size
                    tinted.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    rect.origin.x += 18
                    rect.size.width -= 18
                }
                let color: NSColor
                switch cell.style {
                case .name: color = .labelColor
                case .code, .secondary: color = cell.tint ?? .secondaryLabelColor
                case .link: color = .linkColor
                case .tertiary: color = .tertiaryLabelColor
                }
                draw(cell.text, font: Self.font(cell.style), color: color, in: rect)
                if let detail = cell.detail {
                    let used = (cell.text as NSString).size(withAttributes: [.font: Self.font(cell.style)]).width + 8
                    if used < rect.width - 20 {
                        draw(detail, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor,
                             in: NSRect(x: rect.minX + used, y: rect.minY, width: rect.width - used, height: rect.height))
                    }
                }
            }
            if r < rows.count - 1 {
                NSColor.separatorColor.withAlphaComponent(0.4).setFill()
                NSRect(x: 16, y: y + Self.rowHeight - line, width: bounds.width - 24, height: line).fill()
            }
            if r == menuRow {
                // Like Finder's ring around the item a context menu is for.
                let ring = NSBezierPath(roundedRect: NSRect(x: 5, y: y + 2, width: bounds.width - 10, height: Self.rowHeight - 4), xRadius: 5, yRadius: 5)
                ring.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            }
        }
    }

    // MARK: - Context menu

    /// The row a context menu is open for.
    private var menuRow: Int? { didSet { needsDisplay = true } }

    func row(at point: NSPoint) -> Int? {
        guard point.y >= Self.headerHeight else { return nil }
        let index = Int((point.y - Self.headerHeight) / Self.rowHeight)
        return index < rows.count ? index : nil
    }

    private func column(at x: CGFloat) -> Int? {
        columnFrames().firstIndex { x >= $0.x && x < $0.x + $0.width }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = row(at: point) else { return nil }
        let menu = NSMenu.context(menuItems(row: row, column: column(at: point.x)))
        menu.delegate = self
        menuRow = row
        return menu
    }

    func menuDidClose(_ menu: NSMenu) { menuRow = nil }

    /// The clicked value, its row, or the whole table, as tab-separated text.
    func menuItems(row: Int, column: Int?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let column, column < rows[row].count, rows[row][column].style != .tertiary {
            let text = rows[row][column].text
            let value = MenuText.short(text)
            items.append(ActionMenuItem(String(localized: "Copy “\(value)”", bundle: .greeceKit, comment: "Menu item. The argument is the value it copies")) { Clipboard.copy(text) })
        }
        let line = Self.line(rows[row])
        items.append(ActionMenuItem(String(localized: "Copy Row", bundle: .greeceKit, comment: "Menu item: copies a table row as text")) { Clipboard.copy(line) })
        let table = ([headers.joined(separator: "\t")] + rows.map(Self.line)).joined(separator: "\n")
        items.append(ActionMenuItem(String(localized: "Copy Table", bundle: .greeceKit, comment: "Menu item: copies a whole table as text")) { Clipboard.copy(table) })
        return items
    }

    /// A row as tab-separated text, without the "—" that stands for nothing.
    private static func line(_ row: [Cell]) -> String {
        row.map { cell in
            guard cell.style != .tertiary else { return "" }
            return cell.detail.map { "\(cell.text) (\($0))" } ?? cell.text
        }.joined(separator: "\t")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A rounded group, like a System Settings section.
final class SchemaCard: NSView {
    init(content: NSView, inset: CGFloat = 4) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var clipsToBounds: Bool { get { true } set {} }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        SchemaPalette.card.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

enum SchemaPalette {
    /// The page behind the cards.
    static let page = NSColor(name: "greece.schema.page") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.965, alpha: 1)
    }
    static let card = NSColor(name: "greece.schema.card") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : .white
    }
}

/// A page that scrolls vertically and fills its width.
class SchemaPageView: NSView {
    let stack = NSStackView()
    private let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let document = FlippedView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 30, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = SchemaPalette.page
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Adds a view that spans the page's width.
    func addFullWidth(_ view: NSView, spacingAfter: CGFloat? = nil) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: view) }
    }

    // Words several schema pages share.
    static var dataMode: String { String(localized: "Data", bundle: .greeceKit, comment: "Segmented control: show a table’s rows") }
    static var schemaMode: String { String(localized: "Schema", bundle: .greeceKit, comment: "Segmented control: show a table’s structure") }
    static var columnsTitle: String { String(localized: "Columns", bundle: .greeceKit, comment: "Section title or column header: a table’s columns") }
    static var nameTitle: String { String(localized: "Name", bundle: .greeceKit, comment: "Column header in a schema table") }
    static var typeTitle: String { String(localized: "Type", bundle: .greeceKit, comment: "Column header in a schema table: a column’s data type") }
    static var sizeTitle: String { String(localized: "Size", bundle: .greeceKit, comment: "Column header in a schema table: bytes on disk") }

    func addSection(_ title: String, count: Int? = nil) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        var views: [NSView] = [label]
        if let count {
            let number = NSTextField(labelWithString: count.formatted())
            number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            number.textColor = .tertiaryLabelColor
            views.append(number)
        }
        let row = NSStackView(views: views)
        row.spacing = 6
        row.alignment = .firstBaseline
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: last) }
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(8, after: row)
        row.setContentHuggingPriority(.required, for: .vertical)
    }

    func addHeader(symbol: String, title: String, subtitle: String) {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 19, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.spacing = 12
        row.alignment = .centerY
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(6, after: row)
    }

    func addNote(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        addFullWidth(label)
    }
}

/// Highlighted SQL, sized to its content, restyled for light and dark. Its context menu copies
/// all of it, since ⌘A doesn't reach it in Quick Look.
final class SQLTextView: NSView, NSTextViewDelegate {
    private let text: String
    private let theme: CodeTheme
    private let textView = NSTextView()
    private var height: NSLayoutConstraint!

    init(sql: String, theme: CodeTheme) {
        text = SQLFormatter.format(sql)
        self.theme = theme
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = false
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        height = heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func restyle() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let palette = dark ? theme.dark : theme.light
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.25
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(hex: palette.foreground), .paragraphStyle: style,
        ]
        let resolved = CodeTheme(id: theme.id, name: theme.name, light: palette, dark: palette, boldKeywords: theme.boldKeywords)
        let attributed = Highlighter.shared.attributed(text, grammar: "sql", base: base, theme: resolved)
            ?? NSAttributedString(string: text, attributes: base)
        textView.textStorage?.setAttributedString(attributed)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        container.containerSize = NSSize(width: max(bounds.width - 20, 50), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let needed = ceil(manager.usedRect(for: container).height) + 20
        if abs(height.constant - needed) > 0.5 { height.constant = needed }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        menu.insertItem(ActionMenuItem(String(localized: "Copy SQL", bundle: .greeceKit, comment: "Menu item: copies a table’s SQL definition")) { [text] in Clipboard.copy(text) }, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }
}

/// Lays out a single-line CREATE statement one column per line, and evens out the indentation of
/// statements written inside other code. Otherwise leaves hand-written SQL alone.
enum SQLFormatter {
    static func format(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\n") { return dedent(trimmed) }
        guard trimmed.count > 90, trimmed.count < 200_000,
              let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return trimmed }
        var result = String(trimmed[...open]) + "\n  "
        var depth = 0
        var quote: Character?
        for character in trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)] {
            if let q = quote {
                result.append(character)
                if character == q { quote = nil }
                continue
            }
            switch character {
            case "'", "\"", "`", "[": quote = character == "[" ? "]" : character; result.append(character)
            case "(": depth += 1; result.append(character)
            case ")": depth -= 1; result.append(character)
            case "," where depth == 0:
                result.append(",\n ")
            default: result.append(character)
            }
        }
        return result + "\n)"
    }

    /// Statements copied from source files keep that file's indentation after the first line;
    /// bring the body back to four spaces.
    static func dedent(_ sql: String) -> String {
        var lines = sql.components(separatedBy: "\n")
        guard lines.count > 1 else { return sql }
        let body = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indents = body.map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        guard let smallest = indents.min(), smallest > 4 else { return sql }
        // With a closing line ("  );") the structure is already there: just shift it left.
        // Without one, the body is uniformly indented: keep it four spaces in.
        let closes = body.last?.trimmingCharacters(in: .whitespaces).hasPrefix(")") == true
        let base = closes ? 0 : 4
        for i in lines.indices.dropFirst() {
            let lead = lines[i].prefix { $0 == " " || $0 == "\t" }.count
            guard lead >= smallest else { continue }
            lines[i] = String(repeating: " ", count: base) + String(lines[i].dropFirst(smallest))
        }
        return lines.joined(separator: "\n")
    }
}

/// The schema of one table or view: its columns and keys, indexes, triggers, the tables that point
/// at it, and its CREATE statement.
final class SQLiteSchemaView: SchemaPageView {
    init(object: SQLiteDatabase.Object, database: SQLiteDatabase, settings: PreviewSettings) {
        super.init(frame: .zero)
        let kind = object.kind == .view
            ? String(localized: "View [database]", defaultValue: "View", bundle: .greeceKit, comment: "Kind of database object: a stored query that reads like a table")
            : object.kind == .virtual
            ? String(localized: "Virtual Table", bundle: .greeceKit, comment: "Kind of database object: a table a module computes (full-text search, R-tree…)")
            : String(localized: "Table", bundle: .greeceKit, comment: "Kind of database object")
        var facts = [kind]
        if let rows = object.rowCount {
            facts.append(String(localized: "\(rows) rows", bundle: .greeceKit, comment: "Rows in a table"))
        } else if let estimate = object.estimatedRows {
            facts.append(String(localized: "about \(estimate) rows", bundle: .greeceKit, comment: "Rows in a database table, estimated"))
        }
        let columnCount = object.columns.count
        facts.append(String(localized: "\(columnCount) columns", bundle: .greeceKit, comment: "Columns in a table"))
        if object.withoutRowid {
            facts.append(String(localized: "Without rowid", bundle: .greeceKit, comment: "An SQLite table created WITHOUT ROWID; “rowid” is SQLite’s term, as is"))
        }
        addHeader(symbol: SQLiteBrowserView.symbol(for: object), title: object.name, subtitle: facts.joined(separator: " · "))

        // Columns
        let autoincrement = object.sql?.range(of: "AUTOINCREMENT", options: .caseInsensitive) != nil
        let uniqueColumns = Set(object.indexes.filter { $0.unique && $0.columns.count == 1 && $0.origin != "pk" }.compactMap { $0.columns.first?.lowercased() })
        let showReferences = !object.foreignKeys.isEmpty
        let rows: [[SchemaTableView.Cell]] = object.columns.prefix(2000).map { column in
            let key = object.foreignKey(for: column.name)
            let symbol = column.isPrimaryKey ? "key.fill" : key != nil ? "arrow.up.right" : nil
            let tint: NSColor? = column.isPrimaryKey ? .systemOrange : key != nil ? .controlAccentColor : nil
            var constraints: [String] = []
            if column.isPrimaryKey {
                let position = String(column.primaryKey)
                constraints.append(object.columns.filter(\.isPrimaryKey).count > 1
                    ? String(localized: "Primary key (\(position))", bundle: .greeceKit, comment: "Column constraint: part of a primary key of several columns. The argument is its position in the key")
                    : Self.primaryKeyTitle)
            }
            if column.isPrimaryKey, autoincrement, column.type.uppercased() == "INTEGER" {
                constraints.append(String(localized: "Autoincrement", bundle: .greeceKit, comment: "Column constraint: numbered automatically"))
            }
            if column.notNull, !column.isPrimaryKey { constraints.append(String(localized: "Not null", bundle: .greeceKit, comment: "Column constraint: must hold a value")) }
            if uniqueColumns.contains(column.name.lowercased()) { constraints.append(Self.uniqueTitle) }
            if column.generated { constraints.append(String(localized: "Generated", bundle: .greeceKit, comment: "Column constraint: computed from other columns")) }
            var row: [SchemaTableView.Cell] = [
                .name(column.name, symbol: symbol, tint: tint),
                column.type.isEmpty ? .none : .code(column.type.uppercased()),
                constraints.isEmpty ? .none : .plain(constraints.joined(separator: " · ")),
                column.defaultValue.map { .code($0) } ?? .none,
            ]
            if showReferences {
                if let key, let index = key.from.firstIndex(where: { $0.caseInsensitiveCompare(column.name) == .orderedSame }) {
                    let target = index < key.to.count && !key.to[index].isEmpty ? key.to[index] : primaryKey(of: key.table, in: database)
                    let rule = key.onDelete.lowercased()
                    let action = key.onDelete != "NO ACTION" && !key.onDelete.isEmpty
                        ? String(localized: "on delete \(rule)", bundle: .greeceKit, comment: "After a foreign key: what deleting the row it points at does. The argument is an SQL action, such as “cascade”")
                        : nil
                    row.append(.link("\(key.table).\(target)", detail: action))
                } else {
                    row.append(.none)
                }
            }
            return row
        }
        addSection(Self.columnsTitle, count: object.columns.count)
        var headers = [Self.nameTitle, Self.typeTitle,
                       String(localized: "Constraints", bundle: .greeceKit, comment: "Column header in a table’s schema: primary key, not null, unique…"),
                       String(localized: "Default [value]", defaultValue: "Default", bundle: .greeceKit, comment: "Column header in a table’s schema: a column’s default value")]
        if showReferences {
            headers.append(String(localized: "References", bundle: .greeceKit, comment: "Column header in a table’s schema: the table and column a foreign key points at"))
        }
        addFullWidth(SchemaCard(content: SchemaTableView(headers: headers, rows: rows, flexible: 2)))

        // Indexes
        if !object.indexes.isEmpty {
            addSection(String(localized: "Indexes", bundle: .greeceKit, comment: "Section title in a table’s schema"), count: object.indexes.count)
            let rows: [[SchemaTableView.Cell]] = object.indexes.map { index in
                var kind: [String] = []
                if index.origin == "pk" { kind.append(Self.primaryKeyTitle) } else if index.unique { kind.append(Self.uniqueTitle) }
                if index.partial { kind.append(String(localized: "Partial", bundle: .greeceKit, comment: "Kind of index: covers only some rows")) }
                if index.origin == "u" { kind.append(String(localized: "Constraint", bundle: .greeceKit, comment: "Kind of index: made for a UNIQUE constraint")) }
                return [.name(index.name), .code(index.columns.joined(separator: ", ")), kind.isEmpty ? .none : .plain(kind.joined(separator: " · "))]
            }
            let kindTitle = String(localized: "Kind", bundle: .greeceKit, comment: "Column header in a table’s schema: what kind of index it is")
            addFullWidth(SchemaCard(content: SchemaTableView(headers: [Self.nameTitle, Self.columnsTitle, kindTitle], rows: rows, flexible: 1)))
        }

        // Incoming references
        let incoming = database.objects.flatMap { other in
            other.foreignKeys.filter { $0.table.caseInsensitiveCompare(object.name) == .orderedSame }.map { (other.name, $0) }
        }
        if !incoming.isEmpty {
            addSection(String(localized: "Referenced By", bundle: .greeceKit, comment: "Section title in a table’s schema: tables whose foreign keys point at this one"), count: incoming.count)
            let rows: [[SchemaTableView.Cell]] = incoming.prefix(500).map { table, key in
                let rule = key.onDelete.lowercased()
                return [.name(table, symbol: "arrow.down.right", tint: .controlAccentColor), .code(key.from.joined(separator: ", ")),
                        key.onDelete == "NO ACTION" || key.onDelete.isEmpty ? .none
                            : .plain(String(localized: "On delete \(rule)", bundle: .greeceKit,
                                            comment: "What deleting a row does to the rows that point at it. The argument is an SQL action, such as “cascade”"))]
            }
            let headers = [String(localized: "Table", bundle: .greeceKit, comment: "Kind of database object"), Self.columnsTitle,
                           String(localized: "Action", bundle: .greeceKit, comment: "Column header in a table’s schema: what deleting a row does (cascade, set null…)")]
            addFullWidth(SchemaCard(content: SchemaTableView(headers: headers, rows: rows, flexible: 1)))
        }

        // Triggers
        if !object.triggers.isEmpty {
            addSection(String(localized: "Triggers", bundle: .greeceKit, comment: "Section title in a table’s schema"), count: object.triggers.count)
            let rows: [[SchemaTableView.Cell]] = object.triggers.map { [.name($0.name), .code("\($0.timing) \($0.event)".trimmingCharacters(in: .whitespaces))] }
            let when = String(localized: "When", bundle: .greeceKit, comment: "Column header in a table’s schema: when a trigger runs, such as “AFTER INSERT”")
            addFullWidth(SchemaCard(content: SchemaTableView(headers: [Self.nameTitle, when], rows: rows, flexible: 0)))
        }

        // Definition
        var statements = [object.sql].compactMap { $0 }
        statements += object.indexes.compactMap(\.sql)
        statements += object.triggers.map(\.sql)
        if !statements.isEmpty {
            addSection(String(localized: "Definition", bundle: .greeceKit, comment: "Section title in a table’s schema: its CREATE statements"))
            let sql = statements.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + ($0.hasSuffix(";") ? "" : ";") }.joined(separator: "\n\n")
            addFullWidth(SchemaCard(content: SQLTextView(sql: String(sql.prefix(200_000)), theme: settings.codeTheme)))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static var primaryKeyTitle: String { String(localized: "Primary key", bundle: .greeceKit, comment: "Column constraint or kind of index") }
    private static var uniqueTitle: String { String(localized: "Unique", bundle: .greeceKit, comment: "Column constraint or kind of index: no two rows share a value") }

    private func primaryKey(of table: String, in database: SQLiteDatabase) -> String {
        database.objects.first { $0.name.caseInsensitiveCompare(table) == .orderedSame }?
            .columns.filter(\.isPrimaryKey).map(\.name).joined(separator: ", ") ?? "rowid"
    }
}
