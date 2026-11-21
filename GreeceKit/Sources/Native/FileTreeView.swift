import AppKit
import UniformTypeIdentifiers

/// A node in an archive listing or a real folder. Folder children load lazily.
final class FileNode {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let isHidden: Bool
    var size: UInt64?
    var compressedSize: UInt64?
    var modified: Date?
    let kind: String?
    let labelColor: NSColor?
    let url: URL?
    let isPackage: Bool
    var children: [FileNode]?
    var itemCount: Int?

    init(name: String, isDirectory: Bool, isSymlink: Bool = false, isHidden: Bool = false, size: UInt64? = nil,
         compressedSize: UInt64? = nil, modified: Date? = nil, kind: String? = nil, labelColor: NSColor? = nil,
         url: URL? = nil, isPackage: Bool = false, children: [FileNode]? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.size = size
        self.compressedSize = compressedSize
        self.modified = modified
        self.kind = kind
        self.labelColor = labelColor
        self.url = url
        self.isPackage = isPackage
        self.children = children
    }

    var isExpandable: Bool { isDirectory && !isPackage && (children.map { !$0.isEmpty } ?? true) }

    // MARK: Archives

    /// Builds a tree from flat archive paths, inventing any folders the archive left implicit.
    static func tree(from listing: ArchiveListing, showHidden: Bool) -> FileNode {
        let root = FileNode(name: "", isDirectory: true, children: [])
        var directories: [String: FileNode] = ["": root]

        /// Finds or creates the folder chain for a path, iteratively (paths can be thousands deep).
        func directory(for path: String) -> FileNode {
            if let existing = directories[path] { return existing }
            var node = root
            var current = ""
            for component in path.split(separator: "/") {
                current = current.isEmpty ? String(component) : current + "/" + component
                if let existing = directories[current] { node = existing; continue }
                let name = String(component)
                let child = FileNode(name: name, isDirectory: true, isHidden: name.hasPrefix("."), children: [])
                node.children?.append(child)
                directories[current] = child
                node = child
            }
            return node
        }

        for entry in listing.entries {
            var path = entry.path.replacingOccurrences(of: "\\", with: "/")
            while path.hasSuffix("/") { path.removeLast() }
            while path.hasPrefix("/") { path.removeFirst() }
            guard !path.isEmpty else { continue }
            let components = path.split(separator: "/")
            // Real projects are never this deep; crafted archives are.
            guard components.count <= 128 else { continue }
            let hidden = components.contains { $0.hasPrefix(".") } || path.hasPrefix("__MACOSX")
            if hidden && !showHidden { continue }

            if entry.isDirectory {
                let node = directory(for: path)
                if node.modified == nil { node.modified = entry.modified }
                continue
            }
            let parent = directory(for: (path as NSString).deletingLastPathComponent)
            parent.children?.append(FileNode(
                name: (path as NSString).lastPathComponent,
                isDirectory: false,
                isSymlink: entry.isSymlink,
                isHidden: hidden,
                size: entry.size,
                compressedSize: entry.compressedSize,
                modified: entry.modified))
        }
        root.computeArchiveTotals()
        return root
    }

    @discardableResult
    private func computeArchiveTotals() -> (UInt64, Int) {
        guard isDirectory else { return (size ?? 0, 1) }
        var total: UInt64 = 0
        var count = 0
        for child in children ?? [] {
            let (size, items) = child.computeArchiveTotals()
            total = total.saturatingAdd(size)
            count += items
        }
        size = total
        itemCount = children?.count ?? 0
        return (total, count)
    }

    // MARK: Folders

    static let folderKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey,
                                               .totalFileAllocatedSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
                                               .labelNumberKey]

    static func folder(at url: URL, showHidden: Bool) -> FileNode {
        let values = try? url.resourceValues(forKeys: Set(folderKeys))
        let node = FileNode(name: url.lastPathComponent, isDirectory: true, modified: values?.contentModificationDate, url: url)
        node.loadChildren(showHidden: showHidden)
        return node
    }

    func loadChildren(showHidden: Bool) {
        guard children == nil, let url else { return }
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FileNode.folderKeys, options: options)) ?? []
        children = contents.prefix(5000).map { child in
            let v = try? child.resourceValues(forKeys: Set(FileNode.folderKeys))
            let isDirectory = v?.isDirectory ?? false
            let isPackage = v?.isPackage ?? false
            return FileNode(
                name: child.lastPathComponent,
                isDirectory: isDirectory,
                isSymlink: v?.isSymbolicLink ?? false,
                isHidden: v?.isHidden ?? child.lastPathComponent.hasPrefix("."),
                size: isDirectory ? (isPackage ? v?.totalFileAllocatedSize.map(UInt64.init) : nil) : v?.fileSize.map(UInt64.init),
                modified: v?.contentModificationDate,
                kind: v?.localizedTypeDescription,
                labelColor: FileNode.labelColor(v?.labelNumber),
                url: child,
                isPackage: isPackage)
        }
        itemCount = children?.count
    }

    private static func labelColor(_ number: Int?) -> NSColor? {
        switch number {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return nil
        }
    }
}

/// Finder-style list: icons, sizes, dates, disclosure triangles and sortable columns.
final class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scrollView = NSScrollView()
    let outline = NSOutlineView()
    private let root: FileNode
    private var foldersFirst: Bool
    private let showHidden: Bool
    private let showsKind: Bool
    private var sortKey = "name"
    private var ascending = true
    private static let iconCache = NSCache<NSString, NSImage>()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(root: FileNode, settings: PreviewSettings, showsKind: Bool) {
        self.root = root
        foldersFirst = settings.foldersFirst
        showHidden = settings.showHiddenFiles
        self.showsKind = showsKind
        super.init(frame: .zero)

        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowSizeStyle = .default
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(toggle(_:))

        addColumn("name", title: "Name", width: 300, min: 160)
        addColumn("modified", title: "Date Modified", width: 170, min: 90)
        addColumn("size", title: "Size", width: 82, min: 60, alignment: .right)
        if showsKind { addColumn("kind", title: "Kind", width: 130, min: 70) }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        sortTree(root)
        outline.reloadData()

        // A lone top-level folder (typical for archives) opens itself.
        if let only = root.children, only.count == 1, only[0].isExpandable {
            outline.expandItem(only[0])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func addColumn(_ id: String, title: String, width: CGFloat, min: CGFloat, alignment: NSTextAlignment = .left) {
        let column = NSTableColumn(identifier: .init(id))
        column.title = title
        column.width = width
        column.minWidth = min
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        outline.addTableColumn(column)
    }

    @objc private func toggle(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
    }

    // MARK: - Sorting

    private func sortTree(_ node: FileNode) {
        guard var children = node.children else { return }
        let key = sortKey, up = ascending, folders = foldersFirst
        children.sort { a, b in
            if folders && a.isDirectory != b.isDirectory && !(a.isPackage || b.isPackage) { return a.isDirectory }
            switch key {
            case "size":
                let x = a.size ?? 0, y = b.size ?? 0
                if x != y { return up ? x < y : x > y }
            case "modified":
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                if x != y { return up ? x < y : x > y }
            case "kind":
                let x = a.kind ?? "", y = b.kind ?? ""
                if x != y { return up ? x.localizedStandardCompare(y) == .orderedAscending : x.localizedStandardCompare(y) == .orderedDescending }
            default: break
            }
            let order = a.name.localizedStandardCompare(b.name)
            return (key == "name" && !up) ? order == .orderedDescending : order == .orderedAscending
        }
        node.children = children
        children.forEach { if $0.children != nil { sortTree($0) } }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key
        ascending = descriptor.ascending
        sortTree(root)
        outlineView.reloadData()
    }

    // MARK: - Data source

    private func node(_ item: Any?) -> FileNode { (item as? FileNode) ?? root }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let parent = node(item)
        if parent.children == nil, parent.url != nil {
            parent.loadChildren(showHidden: showHidden)
            sortTree(parent)
        }
        return parent.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        node(item).isExpandable
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let file = node(item)
        let id = tableColumn?.identifier.rawValue ?? "name"
        if id == "name" {
            let cell = (outlineView.makeView(withIdentifier: NameCell.reuseID, owner: nil) as? NameCell) ?? NameCell()
            cell.configure(name: file.name, icon: icon(for: file), dimmed: file.isHidden, label: file.labelColor, symlink: file.isSymlink)
            return cell
        }
        let cell = (outlineView.makeView(withIdentifier: TextCell.reuseID, owner: nil) as? TextCell) ?? TextCell()
        switch id {
        case "size":
            if file.isDirectory && !file.isPackage {
                if let size = file.size, root.url == nil { cell.configure(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file), alignment: .right) }
                else { cell.configure("--", alignment: .right, color: .tertiaryLabelColor) }
            } else {
                cell.configure(file.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "--", alignment: .right)
            }
        case "modified":
            cell.configure(file.modified.map(dateFormatter.string(from:)) ?? "--", alignment: .left)
        default:
            cell.configure(file.kind ?? "", alignment: .left)
        }
        return cell
    }

    private func icon(for file: FileNode) -> NSImage {
        if let url = file.url, file.isPackage || (file.isDirectory && FileTreeView.hasCustomIcon(url)) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let key: String
        let type: UTType
        if file.isDirectory {
            key = "/folder"
            type = .folder
        } else {
            let ext = (file.name as NSString).pathExtension.lowercased()
            key = ext
            type = UTType(filenameExtension: ext) ?? .data
        }
        if let cached = FileTreeView.iconCache.object(forKey: key as NSString) { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        FileTreeView.iconCache.setObject(image, forKey: key as NSString)
        return image
    }

    private static func hasCustomIcon(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Icon\r").path)
    }
}

private final class NameCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("NameCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let labelDot = NSView()
    private let alias = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        icon.imageScaling = .scaleProportionallyUpOrDown
        labelDot.wantsLayer = true
        labelDot.layer?.cornerRadius = 4
        alias.image = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: "Alias")
        alias.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        alias.contentTintColor = .tertiaryLabelColor
        textField = label
        imageView = icon
        let stack = NSStackView(views: [icon, label, alias, labelDot])
        stack.spacing = 5
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            labelDot.widthAnchor.constraint(equalToConstant: 8),
            labelDot.heightAnchor.constraint(equalToConstant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(name: String, icon image: NSImage, dimmed: Bool, label color: NSColor?, symlink: Bool) {
        icon.image = image
        label.stringValue = name
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
        icon.alphaValue = dimmed ? 0.55 : 1
        labelDot.isHidden = color == nil
        labelDot.layer?.backgroundColor = color?.cgColor
        alias.isHidden = !symlink
    }
}

private final class TextCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("TextCell")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ text: String, alignment: NSTextAlignment, color: NSColor = .secondaryLabelColor) {
        label.stringValue = text
        label.alignment = alignment
        label.textColor = color
    }
}
