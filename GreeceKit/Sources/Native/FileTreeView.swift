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
    /// For archive members: the entry itself (for extraction) and its full path inside the archive.
    var entry: ArchiveEntry?
    var path = ""
    /// Files below this folder, counted when an archive's totals are computed.
    var fileCount = 0

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
    var isEncrypted: Bool { entry?.isEncrypted ?? false }

    // MARK: Archives

    /// Builds a tree from flat archive paths, inventing any folders the archive left implicit.
    static func tree(from listing: ArchiveListing, showHidden: Bool) -> FileNode {
        let builder = ArchiveTreeBuilder(showHidden: showHidden)
        builder.add(listing.entries)
        builder.finish()
        return builder.root
    }

    /// Sums sizes, compressed sizes and file counts up the tree.
    @discardableResult
    func computeArchiveTotals() -> (size: UInt64, compressed: UInt64?, files: Int) {
        guard isDirectory else { return (size ?? 0, compressedSize, 1) }
        var total: UInt64 = 0
        var compressed: UInt64? = 0
        var files = 0
        var latest: Date?
        for child in children ?? [] {
            let (size, packed, count) = child.computeArchiveTotals()
            total = total.saturatingAdd(size)
            compressed = packed.flatMap { value in compressed.map { $0.saturatingAdd(value) } }
            files += count
            if let date = child.modified, latest.map({ date > $0 }) ?? true { latest = date }
        }
        // Folders an archive leaves implicit take the date of their newest item, as Finder shows them.
        if modified == nil && entry == nil { modified = latest }
        size = total
        compressedSize = (children ?? []).isEmpty ? nil : compressed
        itemCount = children?.count ?? 0
        fileCount = files
        return (total, compressedSize, files)
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

/// Grows an archive's folder tree as entries arrive, so big archives can be shown while still loading.
final class ArchiveTreeBuilder {
    let root = FileNode(name: "", isDirectory: true, children: [])
    let showHidden: Bool
    private var directories: [String: FileNode] = [:]
    private(set) var hiddenCount = 0

    init(showHidden: Bool) {
        self.showHidden = showHidden
        directories[""] = root
    }

    /// Finds or creates the folder chain for a path, iteratively (paths can be thousands deep).
    private func directory(for path: String) -> FileNode {
        if let existing = directories[path] { return existing }
        var node = root
        var current = ""
        for component in path.split(separator: "/") {
            current = current.isEmpty ? String(component) : current + "/" + component
            if let existing = directories[current] { node = existing; continue }
            let name = String(component)
            let child = FileNode(name: name, isDirectory: true, isHidden: name.hasPrefix("."), children: [])
            child.path = current
            node.children?.append(child)
            directories[current] = child
            node = child
        }
        return node
    }

    func add(_ entries: [ArchiveEntry]) {
        for entry in entries {
            var path = entry.path.replacingOccurrences(of: "\\", with: "/")
            while path.hasSuffix("/") { path.removeLast() }
            while path.hasPrefix("/") { path.removeFirst() }
            while path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, path != "." else { continue }
            let components = path.split(separator: "/")
            // Real projects are never this deep; crafted archives are.
            guard components.count <= 128 else { continue }
            let hidden = components.contains { $0.hasPrefix(".") } || path.hasPrefix("__MACOSX")
            if hidden && !showHidden { hiddenCount += 1; continue }

            if entry.isDirectory {
                let node = directory(for: path)
                if node.modified == nil { node.modified = entry.modified }
                if node.entry == nil { node.entry = entry }
                continue
            }
            let parent = directory(for: (path as NSString).deletingLastPathComponent)
            let node = FileNode(
                name: (path as NSString).lastPathComponent,
                isDirectory: false,
                isSymlink: entry.isSymlink,
                isHidden: hidden,
                size: entry.size,
                compressedSize: entry.compressedSize,
                modified: entry.modified)
            node.entry = entry
            node.path = path
            parent.children?.append(node)
        }
    }

    func finish() { root.computeArchiveTotals() }
}

/// Finder-style list: icons, sizes, dates, disclosure triangles, sortable and optional columns.
final class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let scrollView = NSScrollView()
    let outline = TreeOutlineView()
    private(set) var root: FileNode
    private var foldersFirst: Bool
    private let showHidden: Bool
    private let showsKind: Bool
    private let isArchive: Bool
    private var sortKey = "name"
    private var ascending = true
    private static let iconCache = NSCache<NSString, NSImage>()
    private static var kindCache: [String: String] = [:]
    private static let kindLock = NSLock()

    /// Called with the selected nodes whenever the selection changes.
    var onSelectionChange: (([FileNode]) -> Void)?
    /// Get Info (⌘I or the context menu) on a node.
    var onGetInfo: ((FileNode) -> Void)?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// - Parameters:
    ///   - showsKind: a real folder, whose Kind column comes from the file system and is shown.
    ///   - compressedSizes: the archive records compressed sizes, so the Compressed column is offered.
    init(root: FileNode, settings: PreviewSettings, showsKind: Bool, compressedSizes: Bool = false) {
        self.root = root
        foldersFirst = settings.foldersFirst
        showHidden = settings.showHiddenFiles
        self.showsKind = showsKind
        isArchive = root.url == nil
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
        outline.owner = self

        addColumn("name", title: "Name", width: 300, min: 160)
        addColumn("modified", title: "Date Modified", width: 170, min: 90)
        addColumn("size", title: "Size", width: 82, min: 60, alignment: .right)
        if isArchive && compressedSizes {
            addColumn("compressed", title: "Compressed", width: 92, min: 60, alignment: .right).isHidden = true
        }
        addColumn("kind", title: "Kind", width: 130, min: 70).isHidden = !showsKind
        outline.outlineTableColumn = outline.tableColumns.first
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        // Columns the person shows or hides stay that way, like Finder's.
        outline.autosaveName = isArchive ? (compressedSizes ? "GreeceArchiveColumns" : "GreeceArchiveColumnsPlain") : "GreeceFolderColumns"
        outline.autosaveTableColumns = true
        outline.tableColumns.first?.isHidden = false

        let headerMenu = NSMenu()
        headerMenu.delegate = self
        outline.headerView?.menu = headerMenu
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        outline.menu = rowMenu

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
        expandLoneFolder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A lone top-level folder (typical for archives) opens itself.
    private func expandLoneFolder() {
        if let only = root.children, only.count == 1, only[0].isExpandable, !outline.isItemExpanded(only[0]) {
            outline.expandItem(only[0])
        }
    }

    /// Shows new or changed content (more entries of an archive that's still loading), keeping
    /// what's expanded and selected.
    func reload(root newRoot: FileNode? = nil) {
        let selected = selectedNodes
        if let newRoot { root = newRoot }
        sortTree(root)
        outline.reloadData()
        expandLoneFolder()
        let rows = IndexSet(selected.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if !rows.isEmpty { outline.selectRowIndexes(rows, byExtendingSelection: false) }
    }

    @discardableResult
    private func addColumn(_ id: String, title: String, width: CGFloat, min: CGFloat, alignment: NSTextAlignment = .left) -> NSTableColumn {
        let column = NSTableColumn(identifier: .init(id))
        column.title = title
        column.width = width
        column.minWidth = min
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "name" || id == "kind")
        outline.addTableColumn(column)
        return column
    }

    @objc private func toggle(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
    }

    var selectedNodes: [FileNode] { outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode } }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === outline.headerView?.menu {
            for column in outline.tableColumns.dropFirst() {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
            return
        }
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if !outline.selectedRowIndexes.contains(row) { outline.selectRowIndexes([row], byExtendingSelection: false) }
        if onGetInfo != nil {
            let info = NSMenuItem(title: "Get Info", action: #selector(getInfo(_:)), keyEquivalent: "i")
            info.target = self
            info.representedObject = node
            menu.addItem(info)
            menu.addItem(.separator())
        }
        let copyName = NSMenuItem(title: "Copy Name", action: #selector(copyText(_:)), keyEquivalent: "")
        copyName.target = self
        copyName.representedObject = node.name
        menu.addItem(copyName)
        let path = node.url?.path ?? node.path
        if !path.isEmpty, path != node.name {
            let copyPath = NSMenuItem(title: "Copy Path", action: #selector(copyText(_:)), keyEquivalent: "")
            copyPath.target = self
            copyPath.representedObject = path
            menu.addItem(copyPath)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
        outline.sizeLastColumnToFit()
    }

    @objc private func getInfo(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode { onGetInfo?(node) }
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, !outline.selectedRowIndexes.isEmpty {        // Escape clears the selection
            outline.deselectAll(nil)
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "i", let node = selectedNodes.first, let onGetInfo {
            onGetInfo(node)
            return true
        }
        return false
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
            case "compressed":
                let x = a.compressedSize ?? 0, y = b.compressedSize ?? 0
                if x != y { return up ? x < y : x > y }
            case "modified":
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                if x != y { return up ? x < y : x > y }
            case "kind":
                let x = FileTreeView.kindName(of: a), y = FileTreeView.kindName(of: b)
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
        reload()
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

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(selectedNodes)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let file = node(item)
        let id = tableColumn?.identifier.rawValue ?? "name"
        if id == "name" {
            let cell = (outlineView.makeView(withIdentifier: NameCell.reuseID, owner: nil) as? NameCell) ?? NameCell()
            cell.configure(name: file.name, icon: icon(for: file), dimmed: file.isHidden, label: file.labelColor,
                           symlink: file.isSymlink, locked: file.isEncrypted)
            return cell
        }
        let cell = (outlineView.makeView(withIdentifier: TextCell.reuseID, owner: nil) as? TextCell) ?? TextCell()
        switch id {
        case "size":
            if file.isDirectory && !file.isPackage {
                if let size = file.size, isArchive { cell.configure(Self.bytes(size), alignment: .right) }
                else { cell.configure("--", alignment: .right, color: .tertiaryLabelColor) }
            } else {
                cell.configure(file.size.map(Self.bytes) ?? "--", alignment: .right)
            }
            cell.toolTip = nil
        case "compressed":
            if let packed = file.compressedSize, !(file.isDirectory && file.children?.isEmpty != false) {
                cell.configure(Self.bytes(packed), alignment: .right)
                if let size = file.size, size > 0 {
                    cell.toolTip = "\(Int((Double(packed) / Double(size) * 100).rounded()))% of the original size"
                }
            } else {
                cell.configure("--", alignment: .right, color: .tertiaryLabelColor)
                cell.toolTip = nil
            }
        case "modified":
            cell.configure(file.modified.map(dateFormatter.string(from:)) ?? "--", alignment: .left)
            cell.toolTip = nil
        default:
            cell.configure(FileTreeView.kindName(of: file), alignment: .left)
            cell.toolTip = nil
        }
        return cell
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    /// The Kind column: the file system's own description for real files, the type's for archive members.
    static func kindName(of file: FileNode) -> String {
        if let kind = file.kind { return kind }
        if file.isSymlink { return "Alias" }
        if file.isDirectory { return "Folder" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        FileTreeView.kindLock.lock()
        defer { FileTreeView.kindLock.unlock() }
        if let cached = FileTreeView.kindCache[ext] { return cached }
        let name = ext.isEmpty ? "Document" : (UTType(filenameExtension: ext).flatMap { $0.isDynamic ? nil : $0.localizedDescription } ?? "\(ext.uppercased()) File")
        FileTreeView.kindCache[ext] = name
        return name
    }

    private func icon(for file: FileNode) -> NSImage {
        if let url = file.url, file.isPackage || (file.isDirectory && FileTreeView.hasCustomIcon(url)) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return FileTreeView.icon(forName: file.name, isDirectory: file.isDirectory)
    }

    /// The system icon for a name's type, cached by extension.
    static func icon(forName name: String, isDirectory: Bool) -> NSImage {
        let key: String
        let type: UTType
        if isDirectory {
            key = "/folder"
            type = .folder
        } else {
            let ext = (name as NSString).pathExtension.lowercased()
            key = ext
            type = UTType(filenameExtension: ext) ?? .data
        }
        if let cached = iconCache.object(forKey: key as NSString) { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        iconCache.setObject(image, forKey: key as NSString)
        return image
    }

    private static func hasCustomIcon(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Icon\r").path)
    }
}

/// The outline itself, so Escape and ⌘I work while it has focus.
final class TreeOutlineView: NSOutlineView {
    weak var owner: FileTreeView?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, owner?.handleKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class NameCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("NameCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let labelDot = NSView()
    private let alias = NSImageView()
    private let lock = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        labelDot.wantsLayer = true
        labelDot.layer?.cornerRadius = 4
        alias.image = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: "Alias")
        alias.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        alias.contentTintColor = .tertiaryLabelColor
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Encrypted")
        lock.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        lock.contentTintColor = .tertiaryLabelColor
        textField = label
        imageView = icon
        let stack = NSStackView(views: [icon, label, alias, lock, labelDot])
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

    func configure(name: String, icon image: NSImage, dimmed: Bool, label color: NSColor?, symlink: Bool, locked: Bool = false) {
        icon.image = image
        label.stringValue = name
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
        icon.alphaValue = dimmed ? 0.55 : 1
        labelDot.isHidden = color == nil
        labelDot.layer?.backgroundColor = color?.cgColor
        alias.isHidden = !symlink
        lock.isHidden = !locked
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
