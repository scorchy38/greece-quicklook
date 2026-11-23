import AppKit

/// Tables and their foreign keys as an entity-relationship diagram: referenced tables on the
/// left, the tables that point at them to the right, one card per table.
final class RelationshipDiagram {
    struct Card {
        let name: String
        let rows: Int?
        var columns: [(name: String, type: String, primary: Bool, foreign: Bool)]
        var hidden: Int
        var frame = NSRect.zero
        var rank = 0
    }
    struct Edge {
        let child: Int
        let parent: Int
        let childColumn: String
        let parentColumn: String
    }

    private(set) var cards: [Card] = []
    private(set) var edges: [Edge] = []
    private(set) var size = NSSize.zero
    /// Tables left out of a very large schema.
    private(set) var omitted = 0

    static let maxCards = 80
    static let maxColumns = 12
    static let width: CGFloat = 210
    static let headerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 20

    init(database: SQLiteDatabase) {
        var tables = database.objects.filter { $0.kind != .view }
        let related = Set(tables.flatMap { t in t.foreignKeys.isEmpty ? [] : [t.name.lowercased()] + t.foreignKeys.map { $0.table.lowercased() } })
        if tables.count > Self.maxCards {
            // Large schemas: the related tables first.
            tables.sort { related.contains($0.name.lowercased()) && !related.contains($1.name.lowercased()) }
            omitted = tables.count - Self.maxCards
            tables = Array(tables.prefix(Self.maxCards))
        }
        var index: [String: Int] = [:]
        for table in tables {
            let foreign = Set(table.foreignKeys.flatMap(\.from).map { $0.lowercased() })
            var columns: [(name: String, type: String, primary: Bool, foreign: Bool)] = table.columns.map {
                (name: $0.name, type: $0.type.uppercased(), primary: $0.isPrimaryKey, foreign: foreign.contains($0.name.lowercased()))
            }
            var hidden = 0
            if columns.count > Self.maxColumns {
                // Keys first, then the rest in order, so every edge has a row to attach to.
                let keys = columns.filter { $0.primary || $0.foreign }
                let others = columns.filter { !$0.primary && !$0.foreign }
                let kept = Array((keys + others).prefix(Self.maxColumns))
                hidden = columns.count - kept.count
                let keptNames = Set(kept.map(\.name))
                columns = columns.filter { keptNames.contains($0.name) }
            }
            index[table.name.lowercased()] = cards.count
            cards.append(Card(name: table.name, rows: table.rows, columns: columns, hidden: hidden))
        }
        for (childIndex, table) in tables.enumerated() {
            for key in table.foreignKeys {
                guard let parentIndex = index[key.table.lowercased()] else { continue }
                let parentPK = cards[parentIndex].columns.first(where: \.primary)?.name ?? cards[parentIndex].columns.first?.name ?? ""
                let target = key.to.first.flatMap { $0.isEmpty ? nil : $0 } ?? parentPK
                edges.append(Edge(child: childIndex, parent: parentIndex, childColumn: key.from.first ?? "", parentColumn: target))
            }
        }
        layout()
    }

    var isEmpty: Bool { cards.isEmpty }

    func height(of card: Card) -> CGFloat {
        Self.headerHeight + CGFloat(card.columns.count + (card.hidden > 0 ? 1 : 0)) * Self.rowHeight + 6
    }

    /// The y of a column's row (its centre), in diagram coordinates.
    func rowY(_ card: Card, column: String) -> CGFloat {
        let index = card.columns.firstIndex { $0.name.caseInsensitiveCompare(column) == .orderedSame } ?? 0
        return card.frame.minY + Self.headerHeight + 3 + CGFloat(index) * Self.rowHeight + Self.rowHeight / 2
    }

    // MARK: - Layout

    private func layout() {
        guard !cards.isEmpty else { return }
        let connected = Set(edges.flatMap { [$0.child, $0.parent] })
        // Rank: a referenced table sits one column left of the tables that point at it (the
        // furthest-reaching of them), so tables stay beside the ones that use them and edges rarely
        // skip a column. Cycles are broken by ignoring edges back into tables being visited.
        var reach = [Int](repeating: -1, count: cards.count)
        var visiting = Set<Int>()
        let children = Dictionary(grouping: edges.filter { $0.child != $0.parent }, by: \.parent).mapValues { $0.map(\.child) }
        func depth(_ node: Int) -> Int {
            if reach[node] >= 0 { return reach[node] }
            if visiting.contains(node) { return 0 }
            visiting.insert(node)
            let value = (children[node] ?? []).map { depth($0) + 1 }.max() ?? 0
            visiting.remove(node)
            reach[node] = value
            return value
        }
        for node in cards.indices where connected.contains(node) { _ = depth(node) }
        let furthest = reach.max() ?? 0
        let rank = reach.map { $0 < 0 ? 0 : furthest - $0 }
        var columns: [[Int]] = []
        for node in cards.indices where connected.contains(node) {
            let r = rank[node]
            while columns.count <= r { columns.append([]) }
            columns[r].append(node)
        }
        // Order each column by the average position of its neighbours, a few sweeps each way.
        var neighbours: [Int: [Int]] = [:]
        for edge in edges where edge.child != edge.parent {
            neighbours[edge.child, default: []].append(edge.parent)
            neighbours[edge.parent, default: []].append(edge.child)
        }
        var position: [Int: Double] = [:]
        func record() { for column in columns { for (i, node) in column.enumerated() { position[node] = Double(i) } } }
        record()
        for sweep in 0..<6 {
            let order = sweep % 2 == 0 ? Array(columns.indices.dropFirst()) : Array(columns.indices.reversed().dropFirst())
            for c in order {
                columns[c].sort { a, b in
                    let pa = (neighbours[a] ?? []).compactMap { position[$0] }
                    let pb = (neighbours[b] ?? []).compactMap { position[$0] }
                    let ma = pa.isEmpty ? position[a] ?? 0 : pa.reduce(0, +) / Double(pa.count)
                    let mb = pb.isEmpty ? position[b] ?? 0 : pb.reduce(0, +) / Double(pb.count)
                    return ma < mb
                }
                record()
            }
        }
        // Place columns left to right; each card aims for the rows it connects to.
        let margin: CGFloat = 36, columnGap: CGFloat = 96, cardGap: CGFloat = 26
        var x = margin
        var bottom: CGFloat = margin
        var placed = Set<Int>()
        for column in columns {
            var desired: [(node: Int, y: CGFloat)] = column.map { node in
                let anchors = edges.compactMap { edge -> CGFloat? in
                    if edge.child == node, placed.contains(edge.parent) { return rowY(cards[edge.parent], column: edge.parentColumn) }
                    if edge.parent == node, placed.contains(edge.child) { return rowY(cards[edge.child], column: edge.childColumn) }
                    return nil
                }
                guard !anchors.isEmpty else { return (node, -1) }
                return (node, anchors.reduce(0, +) / CGFloat(anchors.count) - Self.headerHeight - 10)
            }
            if desired.allSatisfy({ $0.y < 0 }) {
                var y = margin
                for i in desired.indices { desired[i].y = y; y += height(of: cards[desired[i].node]) + cardGap }
            }
            var y = margin
            for (node, want) in desired {
                let top = max(y, want < 0 ? y : want)
                cards[node].frame = NSRect(x: x, y: top, width: Self.width, height: height(of: cards[node]))
                cards[node].rank = rank[node]
                y = top + cards[node].frame.height + cardGap
                placed.insert(node)
            }
            bottom = max(bottom, y)
            x += Self.width + columnGap
        }
        // Room on the right for self-references, which loop outside their card.
        var right = columns.isEmpty ? margin : x - columnGap + margin + (edges.contains { $0.child == $0.parent } ? 40 : 0)
        // Tables without relationships: a tidy grid underneath.
        let loose = cards.indices.filter { !connected.contains($0) }
        if !loose.isEmpty {
            let perRow = max(3, columns.count)
            var top = columns.isEmpty ? margin : bottom + 20
            var rowHeight: CGFloat = 0
            for (i, node) in loose.enumerated() {
                if i > 0, i % perRow == 0 { top += rowHeight + cardGap; rowHeight = 0 }
                let column = CGFloat(i % perRow)
                cards[node].frame = NSRect(x: margin + column * (Self.width + 40), y: top, width: Self.width, height: height(of: cards[node]))
                rowHeight = max(rowHeight, cards[node].frame.height)
            }
            bottom = top + rowHeight + cardGap
            right = max(right, margin + CGFloat(min(loose.count, perRow)) * (Self.width + 40) - 40 + margin)
        }
        size = NSSize(width: right, height: bottom - cardGap + margin)
    }
}

/// Draws a `RelationshipDiagram`. Hover a table to light up its relationships; double-click it, or
/// use its context menu, to open it (Quick Look takes double-clicks for itself).
final class DiagramCanvas: NSView {
    /// Quick Look's panel is never the key window, so without this the reader's first click
    /// on the preview would only activate it and do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    let diagram: RelationshipDiagram
    /// Shows a table's rows.
    var onOpen: ((String) -> Void)?
    /// Shows a table's schema.
    var onShowSchema: ((String) -> Void)?
    /// Items for a right-click between the tables (zooming).
    var backgroundMenuItems: (() -> [NSMenuItem])?
    private var hovered: Int?

    init(diagram: RelationshipDiagram) {
        self.diagram = diagram
        super.init(frame: NSRect(origin: .zero, size: diagram.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var clipsToBounds: Bool { get { true } set {} }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Always active: a Quick Look panel is never the key window, and hovering should still work.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = diagram.cards.firstIndex(where: { $0.frame.contains(point) }) else {
            let items = backgroundMenuItems?() ?? []
            return items.isEmpty ? nil : .context(items)
        }
        // Light up the table the menu is for.
        if hovered != index { hovered = index; needsDisplay = true }
        return .context(menuItems(forTable: diagram.cards[index].name))
    }

    func menuItems(forTable name: String) -> [NSMenuItem] {
        [
            ActionMenuItem(String(localized: "Show Data", bundle: .greeceKit, comment: "Menu item on a table in a database diagram: shows its rows")) { [weak self] in self?.onOpen?(name) },
            ActionMenuItem(String(localized: "Show Schema", bundle: .greeceKit, comment: "Menu item on a table in a database diagram: shows its structure")) { [weak self] in
                self?.onShowSchema?(name)
            },
            .separator(),
            ActionMenuItem(SQLiteBrowserView.copyName) { Clipboard.copy(name) },
        ]
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = diagram.cards.firstIndex { $0.frame.contains(point) }
        if index != hovered { hovered = index; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        // In Quick Look a double-click opens the database in its app instead; there, tables open
        // from their context menus.
        guard event.clickCount == 2, PreviewHost.acceptsTyping else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let card = diagram.cards.first(where: { $0.frame.contains(point) }) { onOpen?(card.name) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SchemaPalette.page.setFill()
        dirtyRect.intersection(bounds).fill()
        // Edges under cards.
        for edge in diagram.edges {
            let lit = hovered != nil && (edge.child == hovered || edge.parent == hovered)
            drawEdge(edge, lit: lit)
        }
        for (index, card) in diagram.cards.enumerated() where card.frame.insetBy(dx: -12, dy: -12).intersects(dirtyRect) {
            drawCard(card, lit: index == hovered)
        }
    }

    private func drawEdge(_ edge: RelationshipDiagram.Edge, lit: Bool) {
        let child = diagram.cards[edge.child], parent = diagram.cards[edge.parent]
        let childY = diagram.rowY(child, column: edge.childColumn)
        let parentY = diagram.rowY(parent, column: edge.parentColumn)
        let color = lit ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lit ? 1.75 : 1.25
        if edge.child == edge.parent {
            // A self-reference loops around the card's right edge.
            let x = child.frame.maxX
            path.move(to: NSPoint(x: x, y: childY))
            path.curve(to: NSPoint(x: x, y: parentY), controlPoint1: NSPoint(x: x + 46, y: childY), controlPoint2: NSPoint(x: x + 46, y: parentY))
            path.stroke()
            drawCrowFoot(at: NSPoint(x: x, y: childY), direction: 1, color: color)
            drawBar(at: NSPoint(x: x, y: parentY), direction: 1, color: color)
            return
        }
        let childLeft = child.frame.midX > parent.frame.midX
        let start = NSPoint(x: childLeft ? child.frame.minX : child.frame.maxX, y: childY)
        let end = NSPoint(x: childLeft ? parent.frame.maxX : parent.frame.minX, y: parentY)
        let reach = max(40, abs(start.x - end.x) * 0.45)
        path.move(to: start)
        path.curve(to: end, controlPoint1: NSPoint(x: start.x + (childLeft ? -reach : reach), y: start.y),
                   controlPoint2: NSPoint(x: end.x + (childLeft ? reach : -reach), y: end.y))
        path.stroke()
        drawCrowFoot(at: start, direction: childLeft ? -1 : 1, color: color)
        drawBar(at: end, direction: childLeft ? 1 : -1, color: color)
    }

    /// "Many": three short lines fanning into the card.
    private func drawCrowFoot(at point: NSPoint, direction: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 1.25
        let tip = NSPoint(x: point.x + 9 * direction, y: point.y)
        for dy: CGFloat in [-5, 0, 5] {
            path.move(to: tip)
            path.line(to: NSPoint(x: point.x, y: point.y + dy))
        }
        color.setStroke()
        path.stroke()
    }

    /// "One": a short bar across the line.
    private func drawBar(at point: NSPoint, direction: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 1.25
        let x = point.x + 7 * direction
        path.move(to: NSPoint(x: x, y: point.y - 5))
        path.line(to: NSPoint(x: x, y: point.y + 5))
        color.setStroke()
        path.stroke()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
    }

    private func drawCard(_ card: RelationshipDiagram.Card, lit: Bool) {
        let frame = card.frame
        let path = NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        SchemaPalette.card.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (lit ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = lit ? 1.5 : 1 / (window?.backingScaleFactor ?? 2)
        path.stroke()

        // Header: the table's name and size.
        let header = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: RelationshipDiagram.headerHeight)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.controlAccentColor.withAlphaComponent(lit ? 0.14 : 0.07).setFill()
        header.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setFill()
        NSRect(x: frame.minX, y: header.maxY - 0.5, width: frame.width, height: 0.5).fill()
        let count = card.rows.map { ColumnProfile.short(Double($0)) } ?? ""
        let countWidth = text(count, font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), color: .secondaryLabelColor,
                              in: NSRect(x: frame.minX + 10, y: header.minY, width: frame.width - 20, height: header.height), align: .right)
        text(card.name, font: .systemFont(ofSize: 12.5, weight: .semibold), color: .labelColor,
             in: NSRect(x: frame.minX + 11, y: header.minY, width: frame.width - 26 - countWidth, height: header.height), align: .left)

        // Columns
        var y = header.maxY + 3
        for column in card.columns {
            let row = NSRect(x: frame.minX, y: y, width: frame.width, height: RelationshipDiagram.rowHeight)
            var nameX = row.minX + 11
            if column.primary || column.foreign,
               let image = NSImage(systemSymbolName: column.primary ? "key.fill" : "arrow.up.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8.5, weight: .bold)) {
                let tinted = image.tinted(column.primary ? .systemOrange : .controlAccentColor)
                let size = tinted.size
                tinted.draw(in: NSRect(x: nameX, y: row.midY - size.height / 2, width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            nameX += 15
            let typeWidth = text(column.type, font: .monospacedSystemFont(ofSize: 10, weight: .regular), color: .tertiaryLabelColor,
                                 in: NSRect(x: row.minX + 10, y: row.minY, width: row.width - 20, height: row.height), align: .right)
            text(column.name, font: .systemFont(ofSize: 11.5, weight: column.primary ? .medium : .regular), color: .labelColor,
                 in: NSRect(x: nameX, y: row.minY, width: row.maxX - nameX - 16 - typeWidth, height: row.height), align: .left)
            y += RelationshipDiagram.rowHeight
        }
        if card.hidden > 0 {
            let hidden = card.hidden
            text(String(localized: "\(hidden) more", bundle: .greeceKit, comment: "Last line of a table in a database diagram: columns not shown"), font: .systemFont(ofSize: 11), color: .tertiaryLabelColor,
                 in: NSRect(x: frame.minX + 26, y: y, width: frame.width - 36, height: RelationshipDiagram.rowHeight), align: .left)
        }
    }

    /// Draws one line of text vertically centred in `rect`; returns its width.
    @discardableResult
    private func text(_ string: String, font: NSFont, color: NSColor, in rect: NSRect, align: NSTextAlignment) -> CGFloat {
        guard !string.isEmpty, rect.width > 4 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let size = attributed.size()
        attributed.draw(with: NSRect(x: rect.minX, y: rect.midY - ceil(size.height) / 2, width: rect.width, height: ceil(size.height)),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return min(ceil(size.width), rect.width)
    }
}

/// The diagram in a zoomable scroll view.
final class SQLiteDiagramView: NSView {
    let canvas: DiagramCanvas
    private let scroll = NSScrollView()

    init(diagram: RelationshipDiagram) {
        canvas = DiagramCanvas(diagram: diagram)
        super.init(frame: .zero)
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.3
        scroll.maxMagnification = 2
        scroll.drawsBackground = true
        scroll.backgroundColor = SchemaPalette.page
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        canvas.backgroundMenuItems = { [weak self] in self?.zoomMenuItems() ?? [] }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Zooming by pointer: there's no ⌘+ in Quick Look, and not every pointer can pinch.
    func zoomMenuItems() -> [NSMenuItem] {
        let scale = scroll.magnification
        return [
            ActionMenuItem(String(localized: "Zoom In", bundle: .greeceKit, comment: "Menu item"), enabled: scale < scroll.maxMagnification - 0.01) { [weak self] in self?.zoom(by: 1.25) },
            ActionMenuItem(String(localized: "Zoom Out", bundle: .greeceKit, comment: "Menu item"), enabled: scale > scroll.minMagnification + 0.01) { [weak self] in self?.zoom(by: 0.8) },
            .separator(),
            ActionMenuItem(String(localized: "Zoom to Fit", bundle: .greeceKit, comment: "Menu item")) { [weak self] in self?.zoomToFit() },
            ActionMenuItem(String(localized: "Actual Size", bundle: .greeceKit, comment: "Menu item: zoom to 100%"), enabled: abs(scale - 1) > 0.01) { [weak self] in self?.zoom(by: 1 / scale) },
        ]
    }

    /// Zooms about the middle of what's showing.
    private func zoom(by factor: CGFloat) {
        let visible = scroll.contentView.bounds
        let scale = min(max(scroll.magnification * factor, scroll.minMagnification), scroll.maxMagnification)
        scroll.setMagnification(scale, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
    }

    private var fitted = false

    override func layout() {
        super.layout()
        guard !fitted, bounds.width > 50 else { return }
        fitted = true
        zoomToFit()
    }

    /// Shows the whole diagram when it's larger than the view, never enlarging it.
    func zoomToFit() {
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(1, max(scroll.minMagnification, min(bounds.width / size.width, bounds.height / size.height)))
        scroll.magnification = scale
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
