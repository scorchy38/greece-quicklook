import AppKit

/// A condition on one column, chosen from a cell's context menu or a column profile.
struct ColumnFilter: Equatable {
    enum Test: Equatable {
        /// The cell reads exactly this. "" stands for an empty cell (blank, or missing in memory).
        case equals(String)
        case notEquals(String)
        /// A database NULL, which a database grid tells apart from empty text. In memory, where
        /// there's no such thing, these behave like `equals("")` and `notEquals("")`.
        case null
        case notNull
        /// A number at least, or at most, `bound`, as `text` was written in the cell it came
        /// from. Cells that aren't numbers don't match.
        case atLeast(Double, text: String)
        case atMost(Double, text: String)
    }

    var column: Int
    var test: Test

    func matches(_ text: String) -> Bool {
        switch test {
        case .equals(let value): return Self.same(text, value)
        case .notEquals(let value): return !Self.same(text, value)
        case .null: return Self.isBlank(text)
        case .notNull: return !Self.isBlank(text)
        case .atLeast(let bound, _): return DataValueParser.number(text).map { $0 >= bound } ?? false
        case .atMost(let bound, _): return DataValueParser.number(text).map { $0 <= bound } ?? false
        }
    }

    /// Nothing there, or only spaces.
    static func isBlank(_ text: String) -> Bool {
        text.isEmpty || text.utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    private static func same(_ text: String, _ value: String) -> Bool {
        value.isEmpty ? isBlank(text) : text == value
    }

    /// True when this newer filter makes an older one pointless or contradicts it, so it takes the
    /// older one's place: one value is shown at a time, and showing what was hidden (or hiding what
    /// was shown) undoes the earlier choice.
    func replaces(_ older: ColumnFilter) -> Bool {
        guard column == older.column else { return false }
        switch (test, older.test) {
        case (.equals, .equals), (.equals, .notEquals), (.equals, .null), (.equals, .notNull),
             (.null, .equals), (.null, .notEquals), (.null, .null), (.null, .notNull),
             (.notNull, .null), (.notNull, .notNull),
             (.atLeast, .atLeast), (.atMost, .atMost):
            return true
        case (.notEquals(let hidden), .equals(let other)), (.notEquals(let hidden), .notEquals(let other)):
            return hidden == other
        default:
            return false
        }
    }

    /// Filters with `new` added in place of any it replaces.
    static func adding(_ new: ColumnFilter, to filters: [ColumnFilter]) -> [ColumnFilter] {
        filters.filter { !new.replaces($0) && $0 != new } + [new]
    }

    /// How its token reads: "group = Cyclades", "notes is empty", "size ≥ 42".
    func label(columnTitle title: String) -> String {
        switch test {
        case .equals(let value): return value.isEmpty ? "\(title) is empty" : "\(title) = \(MenuText.short(value, limit: 40))"
        case .notEquals(let value): return value.isEmpty ? "\(title) is not empty" : "\(title) ≠ \(MenuText.short(value, limit: 40))"
        case .null: return "\(title) is NULL"
        case .notNull: return "\(title) is not NULL"
        case .atLeast(_, let text): return "\(title) ≥ \(MenuText.short(text, limit: 40))"
        case .atMost(_, let text): return "\(title) ≤ \(MenuText.short(text, limit: 40))"
        }
    }
}

/// The filter items of a cell's context menu, worded the same in every table.
struct FilterMenu {
    /// What the clicked cell holds, as far as filtering goes.
    enum Cell {
        case text(String)
        /// Blank text, or nothing.
        case empty
        /// A database NULL.
        case null
        /// Nothing a filter could match exactly (a blob, a cut-short value).
        case unfilterable
    }

    var active: [ColumnFilter]
    var add: (ColumnFilter) -> Void
    var remove: (ColumnFilter) -> Void
    /// Clears everything; nil while nothing is filtered.
    var clear: (() -> Void)?

    /// Show Only and Hide for the cell's value (and ≥, ≤ for numbers), then Clear Filters.
    /// `cell` is nil off the rows. An active filter's item is checked, and choosing it turns it off.
    func items(column: Int, name: String, cell: Cell?, numeric: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func toggle(_ title: String, _ test: ColumnFilter.Test) {
            let filter = ColumnFilter(column: column, test: test)
            let on = active.contains(filter)
            items.append(ActionMenuItem(title, state: on ? .on : .off) { [add, remove] in on ? remove(filter) : add(filter) })
        }
        switch cell {
        case .text(let text):
            toggle("Show Only Rows Where \(name) Is \(MenuText.quoted(text))", .equals(text))
            toggle("Hide Rows Where \(name) Is \(MenuText.quoted(text))", .notEquals(text))
            if numeric, let number = DataValueParser.number(text) {
                let shown = MenuText.short(text)
                toggle("Show Only Rows Where \(name) ≥ \(shown)", .atLeast(number, text: text))
                toggle("Show Only Rows Where \(name) ≤ \(shown)", .atMost(number, text: text))
            }
        case .empty:
            toggle("Show Only Rows Where \(name) Is Empty", .equals(""))
            toggle("Hide Rows Where \(name) Is Empty", .notEquals(""))
        case .null:
            toggle("Show Only Rows Where \(name) Is NULL", .null)
            toggle("Hide Rows Where \(name) Is NULL", .notNull)
        case .unfilterable, nil:
            break
        }
        if let clear {
            if !items.isEmpty { items.append(.separator()) }
            items.append(ActionMenuItem("Clear Filters", handler: clear))
        }
        return items
    }

    /// The toolbar's tokens for the active filters, each removable.
    func tokens(name: (Int) -> String) -> [FilterToken] {
        active.map { filter in
            let token = FilterToken(text: filter.label(columnTitle: name(filter.column))) { [remove] in remove(filter) }
            var items: [NSMenuItem] = [ActionMenuItem("Remove Filter") { [remove] in remove(filter) }]
            if let clear { items.append(ActionMenuItem("Clear Filters", handler: clear)) }
            token.menu = .context(items)
            return token
        }
    }
}

/// An active filter in the toolbar, like a search token: what it keeps, and a button that removes it.
final class FilterToken: NSView {
    private let label = NSTextField(labelWithString: "")
    private let remove: NSButton
    private let onRemove: () -> Void

    init(text: String, onRemove: @escaping () -> Void) {
        self.onRemove = onRemove
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove Filter")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) ?? NSImage()
        remove = NSButton(image: image, target: nil, action: nil)
        super.init(frame: .zero)
        label.stringValue = text
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = "Remove Filter"
        remove.target = self
        remove.action = #selector(removeClicked)
        for view in [label, remove] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            remove.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 3),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 14),
            remove.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Filter: \(text)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        shape.fill()
    }

    @objc private func removeClicked() { onRemove() }
}
