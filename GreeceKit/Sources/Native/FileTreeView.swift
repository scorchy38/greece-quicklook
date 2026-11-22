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

    /// How many items a folder on disk holds, for Get Info. Counted by name alone, which stays
    /// quick for thousands of files.
    func countItems(showHidden: Bool) {
        guard isDirectory, itemCount == nil, let url else { return }
        if let children { itemCount = children.count; return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        itemCount = showHidden ? names.count : names.filter { !$0.hasPrefix(".") }.count
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
    let foldersFirst: Bool
    private var directories: [String: FileNode] = [:]
    private(set) var hiddenCount = 0

    init(showHidden: Bool, foldersFirst: Bool = true) {
        self.showHidden = showHidden
        self.foldersFirst = foldersFirst
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
            var path = entry.path
            if path.contains("\\") { path = path.replacingOccurrences(of: "\\", with: "/") }
            while path.hasSuffix("/") { path.removeLast() }
            while path.hasPrefix("/") { path.removeFirst() }
            while path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, path != "." else { continue }
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            // Real projects are never this deep; crafted archives are.
            guard components.count <= 128, let last = components.last else { continue }
            let hidden = components.contains { $0.first == "." } || path.hasPrefix("__MACOSX")
            if hidden && !showHidden { hiddenCount += 1; continue }

            if entry.isDirectory {
                let node = directory(for: path)
                if node.modified == nil { node.modified = entry.modified }
                if node.entry == nil { node.entry = entry }
                continue
            }
            let parentPath = components.count > 1 ? components.dropLast().joined(separator: "/") : ""
            let parent = directory(for: parentPath)
            let node = FileNode(
                name: String(last),
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

    /// Totals and Finder's default order. Sorting here, off the main thread, leaves the list view
    /// only an already-sorted tree to check, which is linear.
    func finish() {
        root.computeArchiveTotals()
        FileTreeView.sort(root, foldersFirst: foldersFirst)
    }
}

/// A heading row in a grouped list. Kept from one reload to the next, so the outline keeps the
/// folders inside it open.
final class FileGroupItem {
    let id: String
    var title = ""
    var nodes: [FileNode] = []
    init(id: String) { self.id = id }
}

/// Finder-style list: icons, sizes, dates, disclosure triangles, sortable and optional columns,
/// and Finder's groups.
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
    /// Opens a folder in the browser around the list (the context menu's Open).
    var onOpen: ((FileNode) -> Void)?
    /// The reader sorted by clicking a column header: the column's key and direction.
    var onSortChange: ((String, Bool) -> Void)?
    /// Groups at the top level, as Finder's Use Groups; `.none` lists files plainly.
    private(set) var grouping = BrowserViewState.GroupKey.none
    private var groupItems: [FileGroupItem] = []
    private var groupCache: [String: FileGroupItem] = [:]
    var isGrouped: Bool { grouping != .none }
    /// While true, a sort change comes from the browser (its Sort By menu), not a header click.
    private var applyingSort = false

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
    ///   - sort, ascending, grouping: how to arrange the files to begin with.
    init(root: FileNode, settings: PreviewSettings, showsKind: Bool, compressedSizes: Bool = false,
         sort: BrowserViewState.SortKey = .name, ascending: Bool = true, grouping: BrowserViewState.GroupKey = .none) {
        self.root = root
        self.grouping = grouping
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
        // In Quick Look a double-click opens the previewed file in its app, whatever the preview
        // does with it; there, folders open by their triangles or the context menu instead.
        if PreviewHost.acceptsTyping { outline.doubleAction = #selector(toggle(_:)) }
        outline.owner = self

        addColumn("name", title: "Name", width: 300, min: 160)
        addColumn("modified", title: "Date Modified", width: 170, min: 90)
        addColumn("size", title: "Size", width: 82, min: 60, alignment: .right)
        if isArchive && compressedSizes {
            addColumn("compressed", title: "Compressed", width: 92, min: 60, alignment: .right)
        }
        addColumn("kind", title: "Kind", width: 130, min: 70)
        outline.outlineTableColumn = outline.tableColumns.first
        let initialSort = sort == .compressed && !(isArchive && compressedSizes) ? .name : sort
        outline.sortDescriptors = [NSSortDescriptor(key: initialSort.rawValue, ascending: ascending)]
        columnsKey = isArchive ? "GreeceArchiveColumns" : "GreeceFolderColumns"
        chosenColumns = Set(UserDefaults.standard.stringArray(forKey: columnsKey) ?? (showsKind ? ["modified", "size", "kind"] : ["modified", "size"]))
        applyColumns()

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
        // Sort descriptors set above (and any autosave restored) only took note of the order;
        // apply it once, now that the outline sits in its scroll view.
        configuring = false
        sortTree(root)
        rebuildGroups()
        outline.reloadData()
        expandGroups()
        expandLoneFolder()
    }

    /// While true, sort changes are recorded but not applied (setting up columns reports several).
    private var configuring = true

    // MARK: - Columns

    /// The optional columns the person chose (from the header's menu), remembered like Finder's.
    private var chosenColumns: Set<String> = []
    private var columnsKey = ""
    /// Narrow (a preview pane open beside the list, Finder's preview column): only Name and Size.
    private var compact = false

    private static let naturalWidths: [String: CGFloat] = ["modified": 170, "size": 82, "compressed": 92, "kind": 130]

    private func applyColumns() {
        for column in outline.tableColumns.dropFirst() {
            let id = column.identifier.rawValue
            column.isHidden = !chosenColumns.contains(id) || (compact && id != "size")
            if let natural = FileTreeView.naturalWidths[id], column.width < natural { column.width = natural }
        }
        fitNameColumn()
    }

    override func layout() {
        super.layout()
        let narrow = bounds.width > 0 && bounds.width < 600
        if narrow != compact {
            compact = narrow
            applyColumns()
        }
        fitNameColumn()
    }

    /// Name takes whatever the other visible columns leave, so nothing hides off to the right.
    private func fitNameColumn() {
        guard let name = outline.tableColumns.first else { return }
        let available = scrollView.contentView.bounds.width
        guard available > 0 else { return }
        let others = outline.tableColumns.dropFirst().filter { !$0.isHidden }
        let used = others.reduce(CGFloat(0)) { $0 + $1.width } + outline.intercellSpacing.width * CGFloat(others.count + 1)
        let width = max(name.minWidth, (available - used).rounded(.down))
        if abs(name.width - width) > 0.5, outline.frame.width > available + 0.5 || name.width < width - 0.5 {
            name.width = width
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Selects the member at `path` (as `ArchiveSession.normalized` writes it), opening the
    /// folders above it. False when there's no such member.
    @discardableResult
    func select(path: String) -> Bool {
        func chain(_ node: FileNode) -> [FileNode]? {
            if ArchiveSession.normalized(node.path) == path { return [node] }
            for child in node.children ?? [] { if let rest = chain(child) { return [node] + rest } }
            return nil
        }
        guard let nodes = chain(root), let target = nodes.last, target !== root else { return false }
        for folder in nodes.dropLast() where folder !== root { outline.expandItem(folder) }
        let row = outline.row(forItem: target)
        guard row >= 0 else { return false }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        return true
    }

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
        rebuildGroups()
        outline.reloadData()
        expandGroups()
        expandLoneFolder()
        let rows = IndexSet(selected.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if !rows.isEmpty { outline.selectRowIndexes(rows, byExtendingSelection: false) }
    }

    /// Selects these files (those showing), without opening folders to reach others.
    func select(_ nodes: [FileNode], scroll: Bool = false) {
        let rows = IndexSet(nodes.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { outline.scrollRowToVisible(first) }
    }

    // MARK: - Sort and groups from the browser

    /// Sorts as the browser's Sort By menu says, showing it in the column headers.
    func setSort(_ key: BrowserViewState.SortKey, ascending: Bool) {
        guard key.rawValue != sortKey || ascending != self.ascending else { return }
        applyingSort = true
        outline.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: ascending)]
        applyingSort = false
    }

    func setGrouping(_ key: BrowserViewState.GroupKey) {
        guard key != grouping else { return }
        grouping = key
        reload()
    }

    private func rebuildGroups() {
        guard isGrouped else { groupItems = []; return }
        if root.children == nil, root.url != nil {
            root.loadChildren(showHidden: showHidden)
            sortTree(root)
        }
        let groups = FileArrangement.groups(root.children ?? [], by: grouping, sort: BrowserViewState.SortKey(rawValue: sortKey) ?? .name,
                                            ascending: ascending, foldersFirst: foldersFirst)
        groupItems = groups.map { group in
            let item = groupCache[group.id] ?? FileGroupItem(id: group.id)
            item.title = group.title
            item.nodes = group.nodes
            groupCache[group.id] = item
            return item
        }
    }

    private func expandGroups() {
        for group in groupItems where !outline.isItemExpanded(group) { outline.expandItem(group) }
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
        guard row >= 0, let item = outline.item(atRow: row) as? FileNode else { return }
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
                item.representedObject = column.identifier.rawValue
                item.state = chosenColumns.contains(column.identifier.rawValue) ? .on : .off
                menu.addItem(item)
            }
            return
        }
        for item in rowMenuItems(forRow: outline.clickedRow) { menu.addItem(item) }
    }

    /// The items for a right-click on a row: Get Info, then its name and path to copy, or those of
    /// the whole selection when the row is part of one.
    func rowMenuItems(forRow row: Int) -> [NSMenuItem] {
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return [] }
        if !outline.selectedRowIndexes.contains(row) { outline.selectRowIndexes([row], byExtendingSelection: false) }
        var folder: [NSMenuItem] = []
        if node.isExpandable {
            let expanded = outline.isItemExpanded(node)
            folder.append(ActionMenuItem(expanded ? "Collapse" : "Expand") { [weak self] in
                guard let self else { return }
                if expanded { self.outline.collapseItem(node) } else { self.outline.expandItem(node) }
            })
            folder.append(ActionMenuItem(expanded ? "Collapse All" : "Expand All") { [weak self] in
                guard let self else { return }
                if expanded { self.outline.collapseItem(node, collapseChildren: true) } else { self.expandAll(node) }
            })
        }
        let getInfo: ((FileNode) -> Void)? = onGetInfo == nil ? nil : { [weak self] in self?.onGetInfo?($0) }
        let open: ((FileNode) -> Void)? = onOpen == nil ? nil : { [weak self] in self?.onOpen?($0) }
        return FileMenus.items(for: node, selection: selectedNodes, getInfo: getInfo, open: open, folderItems: folder)
    }

    /// Expands a folder and the folders inside it, breadth first, stopping after a few thousand
    /// rows so a huge archive or folder stays quick.
    private func expandAll(_ node: FileNode) {
        var queue = [node]
        var index = 0
        var shown = 0
        while index < queue.count, shown < 5_000 {
            let next = queue[index]
            index += 1
            outline.expandItem(next)
            let children = next.children ?? []
            shown += children.count
            queue += children.filter(\.isExpandable)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if chosenColumns.contains(id) { chosenColumns.remove(id) } else { chosenColumns.insert(id) }
        UserDefaults.standard.set(chosenColumns.sorted(), forKey: columnsKey)
        // In a narrow list the column may stay hidden for now; widening shows it.
        applyColumns()
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
        FileTreeView.sort(node, key: sortKey, ascending: ascending, foldersFirst: foldersFirst)
    }

    /// Sorts a tree in place. Also used off the main thread to hand the view an already-sorted tree.
    static func sort(_ node: FileNode, key: String = "name", ascending up: Bool = true, foldersFirst folders: Bool) {
        guard var children = node.children else { return }
        let sortKey = BrowserViewState.SortKey(rawValue: key) ?? .name
        children.sort { FileArrangement.precedes($0, $1, by: sortKey, ascending: up, foldersFirst: folders) }
        node.children = children
        children.forEach { if $0.children != nil { sort($0, key: key, ascending: up, foldersFirst: folders) } }
    }

    /// Finder's name order: case-insensitive, numbers by value ("file 9" before "file 10"),
    /// punctuation before digits before letters. ASCII names are compared directly, which is
    /// what keeps a 100,000-entry archive quick to sort; anything else goes to the system collation.
    static func finderOrder(_ a: String, _ b: String) -> ComparisonResult {
        var a = a, b = b
        a.makeContiguousUTF8()
        b.makeContiguousUTF8()
        let fast = a.utf8.withContiguousStorageIfAvailable { x in
            b.utf8.withContiguousStorageIfAvailable { y in asciiOrder(x, y) } ?? nil
        } ?? nil
        if let fast { return fast }
        return a.localizedStandardCompare(b)
    }

    /// Nil when either name has non-ASCII bytes (the system collation decides those).
    private static func asciiOrder(_ x: UnsafeBufferPointer<UInt8>, _ y: UnsafeBufferPointer<UInt8>) -> ComparisonResult? {
        @inline(__always) func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
        /// Punctuation and spaces first, then digits, then letters (case folded).
        @inline(__always) func rank(_ byte: UInt8) -> Int {
            switch byte {
            case 0x30...0x39: return 500
            case 0x41...0x5A: return 1000 + Int(byte) + 0x20
            case 0x61...0x7A: return 1000 + Int(byte)
            default: return Int(byte)
            }
        }
        var i = 0, j = 0
        while i < x.count && j < y.count {
            let p = x[i], q = y[j]
            if p >= 0x80 || q >= 0x80 { return nil }
            if isDigit(p) && isDigit(q) {
                // Whole numbers by value: skip leading zeros, then the longer run is larger.
                var si = i, sj = j
                while si < x.count && x[si] == 0x30 { si += 1 }
                while sj < y.count && y[sj] == 0x30 { sj += 1 }
                var ei = si, ej = sj
                while ei < x.count && isDigit(x[ei]) { ei += 1 }
                while ej < y.count && isDigit(y[ej]) { ej += 1 }
                if ei - si != ej - sj { return ei - si < ej - sj ? .orderedAscending : .orderedDescending }
                var k = 0
                while k < ei - si {
                    if x[si + k] != y[sj + k] { return x[si + k] < y[sj + k] ? .orderedAscending : .orderedDescending }
                    k += 1
                }
                i = ei
                j = ej
                continue
            }
            let (rp, rq) = (rank(p), rank(q))
            if rp != rq { return rp < rq ? .orderedAscending : .orderedDescending }
            i += 1
            j += 1
        }
        if x[i...].contains(where: { $0 >= 0x80 }) || y[j...].contains(where: { $0 >= 0x80 }) { return nil }
        if i < x.count { return .orderedDescending }
        if j < y.count { return .orderedAscending }
        // Equal ignoring case and zero padding: fall back to byte order, so the sort is stable.
        return x.lexicographicallyPrecedes(y) ? .orderedAscending : (y.lexicographicallyPrecedes(x) ? .orderedDescending : .orderedSame)
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key
        ascending = descriptor.ascending
        guard !configuring else { return }
        reload()
        if !applyingSort { onSortChange?(key, descriptor.ascending) }
    }

    // MARK: - Data source

    private func node(_ item: Any?) -> FileNode { (item as? FileNode) ?? root }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? FileGroupItem { return group.nodes.count }
        if item == nil, isGrouped { return groupItems.count }
        let parent = node(item)
        if parent.children == nil, parent.url != nil {
            parent.loadChildren(showHidden: showHidden)
            sortTree(parent)
        }
        return parent.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? FileGroupItem { return group.nodes[index] }
        if item == nil, isGrouped { return groupItems[index] }
        return node(item).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is FileGroupItem { return true }
        return node(item).isExpandable
    }

    // Group headings: full width, never selected, never closed.

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is FileGroupItem }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is FileGroupItem) }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { !(item is FileGroupItem) }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { !(item is FileGroupItem) }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is FileGroupItem ? 28 : outlineView.rowHeight
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(selectedNodes)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? FileGroupItem {
            guard tableColumn == nil else { return nil }
            let cell = (outlineView.makeView(withIdentifier: GroupRowCell.reuseID, owner: nil) as? GroupRowCell) ?? GroupRowCell()
            cell.configure(title: group.title, count: group.nodes.count)
            return cell
        }
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

    private func icon(for file: FileNode) -> NSImage { FileTreeView.displayIcon(for: file) }

    private static let fileIconCache = NSCache<NSString, NSImage>()

    /// Names the icon `displayIcon` gives a file: files of one kind share theirs.
    static func displayIconKey(for file: FileNode) -> String {
        if let url = file.url, file.isPackage || (file.isDirectory && FileTreeView.hasCustomIcon(url)) { return url.path }
        return file.isDirectory ? "/folder" : (file.name as NSString).pathExtension.lowercased()
    }

    /// What a file looks like before (or without) a thumbnail: its own icon for packages and
    /// folders with custom icons, its type's icon otherwise.
    static func displayIcon(for file: FileNode) -> NSImage {
        if let url = file.url, file.isPackage || (file.isDirectory && FileTreeView.hasCustomIcon(url)) {
            if let cached = fileIconCache.object(forKey: url.path as NSString) { return cached }
            let image = NSWorkspace.shared.icon(forFile: url.path)
            fileIconCache.setObject(image, forKey: url.path as NSString)
            return image
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

    /// Quick Look's panel is never the key window, so without this the reader's first click
    /// on the preview would only activate it and do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, owner?.handleKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    // Grouped, files sit under their heading at the list's left edge, as in Finder, rather than
    // one level in.

    private func outdents(_ row: Int) -> Bool { owner?.isGrouped == true && level(forRow: row) > 0 }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        if outdents(row) { frame.origin.x -= indentationPerLevel }
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        if column >= 0, column < tableColumns.count, tableColumns[column] === outlineTableColumn, outdents(row) {
            frame.origin.x -= indentationPerLevel
            frame.size.width += indentationPerLevel
        }
        return frame
    }
}

/// A group's heading in the list: its name and count.
private final class GroupRowCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("GroupRowCell")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        count.textColor = .secondaryLabelColor
        textField = title
        for view in [title, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title text: String, count number: Int) {
        title.stringValue = text
        count.stringValue = number.formatted()
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
