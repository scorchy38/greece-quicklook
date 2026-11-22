import AppKit
import UniformTypeIdentifiers

/// Get Info for something inside an archive: its icon, name and kind, then the facts the archive
/// records about it, laid out like Finder's Info window.
final class EntryInfoView: NSView {
    private let scroll = NSScrollView()

    /// - Parameter open: for a folder, shows an Open button that browses into it.
    init(node: FileNode, kind: String, note: String? = nil, open: (() -> Void)? = nil) {
        super.init(frame: .zero)

        let icon = NSImageView()
        icon.image = FileTreeView.icon(forName: node.name, isDirectory: node.isDirectory)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 88), icon.heightAnchor.constraint(equalToConstant: 88)])

        let name = NSTextField(wrappingLabelWithString: node.name)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.alignment = .center
        name.maximumNumberOfLines = 3
        name.lineBreakMode = .byTruncatingMiddle
        name.isSelectable = true

        let subtitle = NSTextField(labelWithString: EntryInfoView.subtitle(node, kind: kind))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        var views: [NSView] = [icon, name, subtitle]
        if let open {
            let button = ActionButton(title: "Open", action: open)
            button.controlSize = .regular
            button.bezelStyle = .push
            button.toolTip = "Show what’s inside"
            views.append(button)
        }
        if let note {
            let message = NSTextField(wrappingLabelWithString: note)
            message.font = .systemFont(ofSize: 12)
            message.textColor = .tertiaryLabelColor
            message.alignment = .center
            message.maximumNumberOfLines = 3
            views.append(message)
        }

        let grid = NSGridView(views: EntryInfoView.rows(node, kind: kind).map { label, value in
            let key = NSTextField(labelWithString: label)
            key.font = .systemFont(ofSize: 12)
            key.textColor = .secondaryLabelColor
            key.alignment = .right
            let text = NSTextField(wrappingLabelWithString: value)
            text.font = .systemFont(ofSize: 12)
            text.textColor = .labelColor
            text.isSelectable = true
            text.maximumNumberOfLines = 4
            text.lineBreakMode = .byTruncatingMiddle
            text.preferredMaxLayoutWidth = 260
            return [key, text]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        views.append(grid)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(views.count > 4 ? 10 : 22, after: subtitle)
        if views.count > 4 { stack.setCustomSpacing(22, after: views[views.count - 2]) }
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 24, bottom: 36, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            stack.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])
        // Optically centred: a little above the middle when there's room.
        let centre = stack.centerYAnchor.constraint(equalTo: document.centerYAnchor, constant: -16)
        centre.priority = .defaultHigh
        centre.isActive = true
        menu = .context(EntryInfoView.menuItems(node, kind: kind))
    }

    /// Copying without ⌘C (Quick Look sends keys to Finder): the name, the path, or every fact.
    static func menuItems(_ node: FileNode, kind: String) -> [NSMenuItem] {
        var items: [NSMenuItem] = [ActionMenuItem("Copy Name") { Clipboard.copy(node.name) }]
        let path = node.url?.path ?? node.path
        if !path.isEmpty, path != node.name {
            items.append(ActionMenuItem("Copy Path") { Clipboard.copy(path) })
        }
        let info = [node.name, subtitle(node, kind: kind)] + rows(node, kind: kind).map { "\($0.0): \($0.1)" }
        items.append(ActionMenuItem("Copy Info") { Clipboard.copy(info.joined(separator: "\n")) })
        return items
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func subtitle(_ node: FileNode, kind: String) -> String {
        if node.isDirectory, node.url != nil, !node.isPackage {
            return [kind, node.itemCount.map { "\($0.formatted()) \($0 == 1 ? "item" : "items")" }].compactMap { $0 }.joined(separator: " · ")
        }
        if node.isDirectory {
            return [kind, node.fileCount > 0 ? "\(node.fileCount.formatted()) \(node.fileCount == 1 ? "file" : "files")" : nil,
                    node.size.map(FileTreeView.bytes)].compactMap { $0 }.joined(separator: " · ")
        }
        return [kind, node.size.map(FileTreeView.bytes)].compactMap { $0 }.joined(separator: " · ")
    }

    static func rows(_ node: FileNode, kind: String) -> [(String, String)] {
        var rows: [(String, String)] = []
        let entry = node.entry
        if let size = node.size, !node.isDirectory || size > 0 {
            rows.append(("Size", size >= 1000 ? "\(size.formatted()) bytes (\(FileTreeView.bytes(size)))" : "\(size.formatted()) bytes"))
        }
        if let packed = node.compressedSize, let size = node.size, size > 0, !(node.isDirectory && packed == 0) {
            var text = FileTreeView.bytes(packed)
            let ratio = Double(packed) / Double(size) * 100
            text += ratio < 0.5 ? ", under 1% of the original" : ", \(Int(ratio.rounded()))% of the original"
            if let method = entry?.method { text += " (\(method))" }
            rows.append(("Compressed", text))
        } else if let method = entry?.method, !node.isDirectory {
            rows.append(("Method", method))
        }
        if node.isDirectory, let items = node.itemCount {
            rows.append(("Contains", "\(items.formatted()) \(items == 1 ? "item" : "items")"))
        }
        if let modified = node.modified {
            rows.append(("Modified", modified.formatted(date: .long, time: .shortened)))
        }
        if let permissions = entry?.permissions, permissions != 0 {
            rows.append(("Permissions", permissionString(permissions, directory: node.isDirectory, link: node.isSymlink)))
        }
        if let target = entry?.linkTarget { rows.append(("Alias to", target)) }
        if node.isEncrypted { rows.append(("Encrypted", "Yes, it needs the archive’s password")) }
        if let crc = entry?.crc, !node.isDirectory, crc != 0 { rows.append(("CRC-32", String(format: "%08X", crc))) }
        if let url = node.url {
            rows.append(("Where", EntryInfoView.displayPath(url.deletingLastPathComponent())))
        } else {
            let folder = (node.path as NSString).deletingLastPathComponent
            rows.append(("Where", folder.isEmpty ? "Top level of the archive" : folder))
        }
        return rows
    }

    /// A folder's path as Finder writes it, with the real home folder (not a sandbox's) as ~.
    static func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory().components(separatedBy: "/Library/Containers/").first ?? NSHomeDirectory()
        let path = url.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func permissionString(_ mode: UInt16, directory: Bool, link: Bool) -> String {
        let flags: [(UInt16, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                            (0o004, "r"), (0o002, "w"), (0o001, "x")]
        let type: Character = link ? "l" : directory ? "d" : "-"
        return String([type] + flags.map { mode & $0.0 != 0 ? $0.1 : "-" }) + String(format: "  (%03o)", mode & 0o777)
    }
}

/// Lays out top-down, so short content sits at the top of a scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
