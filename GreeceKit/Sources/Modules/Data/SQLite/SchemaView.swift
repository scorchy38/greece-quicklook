import AppKit

/// A table drawn in one view: aligned columns, a quiet header, hairlines between rows. Used for
/// schema pages (columns, indexes, triggers), where a full NSTableView would be heavy.
final class SchemaTableView: NSView {
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
        }
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

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Highlighted SQL, sized to its content, restyled for light and dark.
final class SQLTextView: NSView {
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
        let kind = object.kind == .view ? "View" : object.kind == .virtual ? "Virtual Table" : "Table"
        var facts = [kind]
        if let rows = object.rowCount { facts.append("\(rows.formatted()) \(rows == 1 ? "row" : "rows")") }
        else if let estimate = object.estimatedRows { facts.append("about \(estimate.formatted()) rows") }
        facts.append("\(object.columns.count) \(object.columns.count == 1 ? "column" : "columns")")
        if object.withoutRowid { facts.append("Without rowid") }
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
            if column.isPrimaryKey { constraints.append(object.columns.filter(\.isPrimaryKey).count > 1 ? "Primary key (\(column.primaryKey))" : "Primary key") }
            if column.isPrimaryKey, autoincrement, column.type.uppercased() == "INTEGER" { constraints.append("Autoincrement") }
            if column.notNull, !column.isPrimaryKey { constraints.append("Not null") }
            if uniqueColumns.contains(column.name.lowercased()) { constraints.append("Unique") }
            if column.generated { constraints.append("Generated") }
            var row: [SchemaTableView.Cell] = [
                .name(column.name, symbol: symbol, tint: tint),
                column.type.isEmpty ? .none : .code(column.type.uppercased()),
                constraints.isEmpty ? .none : .plain(constraints.joined(separator: " · ")),
                column.defaultValue.map { .code($0) } ?? .none,
            ]
            if showReferences {
                if let key, let index = key.from.firstIndex(where: { $0.caseInsensitiveCompare(column.name) == .orderedSame }) {
                    let target = index < key.to.count && !key.to[index].isEmpty ? key.to[index] : primaryKey(of: key.table, in: database)
                    let action = key.onDelete != "NO ACTION" && !key.onDelete.isEmpty ? "on delete \(key.onDelete.lowercased())" : nil
                    row.append(.link("\(key.table).\(target)", detail: action))
                } else {
                    row.append(.none)
                }
            }
            return row
        }
        addSection("Columns", count: object.columns.count)
        var headers = ["Name", "Type", "Constraints", "Default"]
        if showReferences { headers.append("References") }
        addFullWidth(SchemaCard(content: SchemaTableView(headers: headers, rows: rows, flexible: 2)))

        // Indexes
        if !object.indexes.isEmpty {
            addSection("Indexes", count: object.indexes.count)
            let rows: [[SchemaTableView.Cell]] = object.indexes.map { index in
                var kind: [String] = []
                if index.origin == "pk" { kind.append("Primary key") } else if index.unique { kind.append("Unique") }
                if index.partial { kind.append("Partial") }
                if index.origin == "u" { kind.append("Constraint") }
                return [.name(index.name), .code(index.columns.joined(separator: ", ")), kind.isEmpty ? .none : .plain(kind.joined(separator: " · "))]
            }
            addFullWidth(SchemaCard(content: SchemaTableView(headers: ["Name", "Columns", "Kind"], rows: rows, flexible: 1)))
        }

        // Incoming references
        let incoming = database.objects.flatMap { other in
            other.foreignKeys.filter { $0.table.caseInsensitiveCompare(object.name) == .orderedSame }.map { (other.name, $0) }
        }
        if !incoming.isEmpty {
            addSection("Referenced By", count: incoming.count)
            let rows: [[SchemaTableView.Cell]] = incoming.prefix(500).map { table, key in
                [.name(table, symbol: "arrow.down.right", tint: .controlAccentColor), .code(key.from.joined(separator: ", ")),
                 key.onDelete == "NO ACTION" || key.onDelete.isEmpty ? .none : .plain("On delete \(key.onDelete.lowercased())")]
            }
            addFullWidth(SchemaCard(content: SchemaTableView(headers: ["Table", "Columns", "Action"], rows: rows, flexible: 1)))
        }

        // Triggers
        if !object.triggers.isEmpty {
            addSection("Triggers", count: object.triggers.count)
            let rows: [[SchemaTableView.Cell]] = object.triggers.map { [.name($0.name), .code("\($0.timing) \($0.event)".trimmingCharacters(in: .whitespaces))] }
            addFullWidth(SchemaCard(content: SchemaTableView(headers: ["Name", "When"], rows: rows, flexible: 0)))
        }

        // Definition
        var statements = [object.sql].compactMap { $0 }
        statements += object.indexes.compactMap(\.sql)
        statements += object.triggers.map(\.sql)
        if !statements.isEmpty {
            addSection("Definition")
            let sql = statements.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + ($0.hasSuffix(";") ? "" : ";") }.joined(separator: "\n\n")
            addFullWidth(SchemaCard(content: SQLTextView(sql: String(sql.prefix(200_000)), theme: settings.codeTheme)))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func primaryKey(of table: String, in database: SQLiteDatabase) -> String {
        database.objects.first { $0.name.caseInsensitiveCompare(table) == .orderedSame }?
            .columns.filter(\.isPrimaryKey).map(\.name).joined(separator: ", ") ?? "rowid"
    }
}
