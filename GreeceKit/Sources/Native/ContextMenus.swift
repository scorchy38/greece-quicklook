import AppKit

/// A menu item that runs a closure. Context menus are built for one click, so their items carry
/// what they act on instead of looking it up through a target.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.state = state
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }

    /// Runs the item's action, as choosing it would.
    func perform() { handler() }
}

/// Writes text for "Copy" menu items. Tests point it at a private pasteboard.
enum Clipboard {
    nonisolated(unsafe) static var pasteboard: NSPasteboard = .general

    static func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

enum MenuText {
    /// A value as it reads inside a menu title: on one line, cut short, in curly quotes.
    static func quoted(_ value: String, limit: Int = 32) -> String {
        "“" + short(value, limit: limit) + "”"
    }

    /// One line, at most `limit` characters, with an ellipsis when cut.
    static func short(_ value: String, limit: Int = 32) -> String {
        var line = value.prefix(limit * 4).split(whereSeparator: \.isNewline).joined(separator: " ")
        line = line.trimmingCharacters(in: .whitespaces)
        guard line.count > limit else { return line }
        return line.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension NSMenu {
    /// A context menu whose items are enabled as built (no responder-chain validation).
    static func context(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        return menu
    }
}
