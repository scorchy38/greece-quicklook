import Cocoa

/// Renders folders as a browsable directory tree with Spotlight metadata and Finder tags.
final class FolderRenderer: FileRenderer {

    func render(fileAt url: URL, completion: @escaping (Error?) -> Void) -> NSView {
        let settings = GreeceSettings.shared

        // Build folder tree
        let root = buildFolderTree(
            at: url,
            showHidden: settings.folderShowHidden,
            depth: 0,
            maxDepth: 10
        )

        // Create UI
        let container = NSView()
        container.wantsLayer = true

        // Header with folder info
        let itemCount = countItems(root)
        let headerLabel = NSTextField(labelWithString: "\(url.lastPathComponent) — \(itemCount) items")
        headerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view with outline view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let outlineView = NSOutlineView()
        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 18
        outlineView.gridStyleMask = [.solidVerticalGridLineMask]
        outlineView.gridColor = .separatorColor

        // Columns
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 200
        nameCol.width = 300
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        outlineView.addTableColumn(nameCol)
        outlineView.outlineTableColumn = nameCol

        if settings.bool(forKey: GreeceConstants.Keys.folderShowSize) {
            let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
            sizeCol.title = "Size"
            sizeCol.minWidth = 70
            sizeCol.width = 90
            sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
            outlineView.addTableColumn(sizeCol)
        }

        if settings.bool(forKey: GreeceConstants.Keys.folderShowDate) {
            let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
            dateCol.title = "Date Modified"
            dateCol.minWidth = 100
            dateCol.width = 150
            dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)
            outlineView.addTableColumn(dateCol)
        }

        if settings.bool(forKey: GreeceConstants.Keys.folderShowKind) {
            let kindCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
            kindCol.title = "Kind"
            kindCol.minWidth = 60
            kindCol.width = 120
            outlineView.addTableColumn(kindCol)
        }

        if settings.folderShowTags {
            let tagCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tags"))
            tagCol.title = "Tags"
            tagCol.minWidth = 60
            tagCol.width = 120
            outlineView.addTableColumn(tagCol)
        }

        let dataSource = FolderOutlineDataSource(root: root)
        outlineView.dataSource = dataSource
        outlineView.delegate = dataSource

        // Keep strong ref
        let holder = FolderStrongRefView()
        holder.ref = dataSource
        container.addSubview(holder)

        scrollView.documentView = outlineView
        container.addSubview(headerLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Expand top-level
        DispatchQueue.main.async {
            for child in root.children {
                if child.isDirectory {
                    outlineView.expandItem(child)
                }
            }
        }

        completion(nil)
        return container
    }

    // MARK: - Build Folder Tree

    private func buildFolderTree(at url: URL, showHidden: Bool, depth: Int, maxDepth: Int) -> FolderTreeNode {
        let root = FolderTreeNode(url: url)

        guard depth < maxDepth else { return root }

        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .localizedTypeDescriptionKey,
            .tagNamesKey, .isHiddenKey
        ]

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return root
        }

        for itemURL in contents {
            let node = FolderTreeNode(url: itemURL)
            root.children.append(node)

            if node.isDirectory {
                let childNode = buildFolderTree(at: itemURL, showHidden: showHidden, depth: depth + 1, maxDepth: maxDepth)
                node.children = childNode.children
            }
        }

        // Sort: directories first, then by name
        root.children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        return root
    }

    private func countItems(_ node: FolderTreeNode) -> Int {
        return node.children.count + node.children.reduce(0) { $0 + countItems($1) }
    }
}

// MARK: - Strong Ref View

private class FolderStrongRefView: NSView {
    var ref: AnyObject?
    override init(frame: NSRect) { super.init(frame: .zero); isHidden = true }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Tree Node

class FolderTreeNode: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modDate: Date?
    let kind: String
    let tags: [String]
    var children: [FolderTreeNode] = []

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [
            .nameKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .localizedTypeDescriptionKey,
            .tagNamesKey
        ])
        self.name = values?.name ?? url.lastPathComponent
        self.isDirectory = values?.isDirectory ?? false
        self.size = Int64(values?.fileSize ?? 0)
        self.modDate = values?.contentModificationDate
        self.kind = values?.localizedTypeDescription ?? ""
        self.tags = values?.tagNames ?? []
    }
}

// MARK: - Outline Data Source

final class FolderOutlineDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let root: FolderTreeNode
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    private let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    // Tag colors
    private static let tagColors: [String: NSColor] = [
        "Red": .systemRed, "Orange": .systemOrange, "Yellow": .systemYellow,
        "Green": .systemGreen, "Blue": .systemBlue, "Purple": .systemPurple,
        "Gray": .systemGray
    ]

    init(root: FolderTreeNode) { self.root = root }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FolderTreeNode ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FolderTreeNode ?? root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FolderTreeNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderTreeNode, let colID = tableColumn?.identifier.rawValue else { return nil }

        switch colID {
        case "name":
            let cell = NSTableCellView()
            let imageView = NSImageView()
            let textField = NSTextField(labelWithString: node.name)
            textField.font = .systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingMiddle

            // Use actual file icon from workspace
            let icon = NSWorkspace.shared.icon(forFile: node.url.path)
            icon.size = NSSize(width: 16, height: 16)
            imageView.image = icon

            imageView.translatesAutoresizingMaskIntoConstraints = false
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case "size":
            let text = node.isDirectory ? "--" : sizeFormatter.string(fromByteCount: node.size)
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label

        case "date":
            let text = node.modDate.map { dateFormatter.string(from: $0) } ?? "--"
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label

        case "kind":
            let label = NSTextField(labelWithString: node.kind)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label

        case "tags":
            if node.tags.isEmpty {
                return NSTextField(labelWithString: "")
            }
            let stackView = NSStackView()
            stackView.orientation = .horizontal
            stackView.spacing = 4
            for tag in node.tags.prefix(5) {
                let dot = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 5
                dot.layer?.backgroundColor = (Self.tagColors[tag] ?? .systemGray).cgColor
                dot.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    dot.widthAnchor.constraint(equalToConstant: 10),
                    dot.heightAnchor.constraint(equalToConstant: 10),
                ])

                let label = NSTextField(labelWithString: tag)
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor

                stackView.addArrangedSubview(dot)
                stackView.addArrangedSubview(label)
            }
            return stackView

        default:
            return nil
        }
    }
}
