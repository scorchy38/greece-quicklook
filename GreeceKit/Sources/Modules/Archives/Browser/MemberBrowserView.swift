import AppKit

/// Where the files a browser lists come from (an archive, a disk image's volume), so the preview
/// pane can show any of them.
protocol MemberSource: AnyObject, Sendable {
    /// Copies the member into `scratch` and returns the copy.
    func extract(_ node: FileNode, to scratch: ArchiveScratch, cancel: CancelToken) throws -> URL
}

extension ArchiveSession: MemberSource {
    func extract(_ node: FileNode, to scratch: ArchiveScratch, cancel: CancelToken) throws -> URL {
        guard let entry = node.entry else { throw PreviewError.unsupported }
        return try extract(entry, to: scratch, cancel: cancel)
    }
}

/// A Finder-style browser: a toolbar (where you are; List or Icons; Sort By; Group By) over the
/// files, with the selected one's real preview (or Get Info) in a pane that opens beside them.
/// The body of folders, archives and disk images' Files tab.
///
/// Folders open inside the browser by pointer alone, since Quick Look turns any double-click into
/// opening the previewed item in its app: the chevron on a folder's icon, Open in its context
/// menu or its info pane. The back button and the path return.
@MainActor
final class MemberBrowserView: NSView, PreviewSettingsAware, NSSplitViewDelegate {
    let tree: FileTreeView
    private(set) var grid: IconGridView?
    private let pane: EntryPreviewPane
    let toolbar: BrowserToolbar
    private let split = NSSplitView()
    private let body = NSView()
    private var paneShown = false
    private var paneFraction: CGFloat = 0.5
    private var panePositionPending = false

    let root: FileNode
    /// The folders from the one previewed down to the one showing.
    private(set) var trail: [FileNode]
    var current: FileNode { trail.last ?? root }
    private(set) var state: BrowserViewState
    /// Folders on disk have thumbnails to show as icons; archives and disk images list only.
    let supportsIcons: Bool
    private let scope: BrowserMemory.Scope
    private let sortKeys: [BrowserViewState.SortKey]
    private var settings: PreviewSettings
    private let rootTitle: String
    private let rootIcon: NSImage?
    private(set) var selection: [FileNode] = []
    /// Choices are remembered for the next preview, except while a snapshot state is shown.
    private var remembers = true
    /// The folder showing changed (true when it's the one previewed), so the info bar can follow.
    var onFolderChange: ((FileNode, Bool) -> Void)?

    init(root: FileNode, source: MemberSource, scratch: ArchiveScratch, settings: PreviewSettings, showsKind: Bool = false,
         compressedSizes: Bool = false, title: String? = nil) {
        self.root = root
        trail = [root]
        self.settings = settings
        supportsIcons = root.url != nil
        scope = supportsIcons ? .folders : .archives
        var state = BrowserMemory.state(for: scope)
        if !supportsIcons { state.layout = .list }
        if state.sort == .compressed && !compressedSizes { state.sort = .name; state.ascending = true }
        self.state = state
        rootTitle = title ?? (root.name.isEmpty ? "Archive" : root.name)
        if let url = root.url {
            rootIcon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            rootIcon = FileTreeView.icon(forName: rootTitle, isDirectory: false)
        }
        tree = FileTreeView(root: root, settings: settings, showsKind: showsKind, compressedSizes: compressedSizes,
                            sort: state.sort, ascending: state.ascending, grouping: state.group)
        pane = EntryPreviewPane(source: source, scratch: scratch, settings: settings,
                                headerHeight: tree.outline.headerView?.frame.height ?? 28)
        sortKeys = [.name, .kind, .modified, .size] + (compressedSizes ? [.compressed] : [])
        toolbar = BrowserToolbar(showsLayouts: supportsIcons, sortKeys: sortKeys)
        super.init(frame: NSRect(x: 0, y: 0, width: 980, height: 600))

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(body)
        for view in [toolbar.view, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.view.topAnchor.constraint(equalTo: topAnchor),
            toolbar.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: toolbar.view.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tree.onSelectionChange = { [weak self] nodes in
            guard let self, self.state.layout == .list else { return }
            self.selectionChanged(nodes)
        }
        tree.onGetInfo = { [weak self] node in self?.getInfo(node) }
        tree.onOpen = { [weak self] node in self?.open(node) }
        tree.onSortChange = { [weak self] key, ascending in self?.listSorted(key, ascending: ascending) }
        pane.onOpenFolder = { [weak self] node in self?.open(node) }
        toolbar.onBack = { [weak self] in self?.goBack() }
        toolbar.onJump = { [weak self] depth in self?.goUp(to: depth) }
        toolbar.onLayout = { [weak self] layout in self?.setLayout(layout) }
        toolbar.onSort = { [weak self] key, ascending in self?.setSort(key, ascending: ascending) }
        toolbar.onGroup = { [weak self] key in self?.setGroup(key) }
        toolbar.update(state)
        updateTrail()
        showLayout(scrollToSelection: false)
        #if DEBUG
        applySnapshotState()
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ settings: PreviewSettings) {
        self.settings = settings
        pane.apply(settings)
    }

    /// Shows new or changed content (more entries of an archive that's still loading).
    func reload() {
        tree.reload()
        if state.layout == .icons { refreshGrid(scroll: false) }
    }

    // MARK: - Layout: list or icons

    private var activeView: NSView { state.layout == .icons ? (grid ?? tree) : tree }

    private func makeGrid() -> IconGridView {
        if let grid { return grid }
        let grid = IconGridView()
        grid.onSelectionChange = { [weak self] nodes in
            guard let self, self.state.layout == .icons else { return }
            self.selectionChanged(nodes)
        }
        grid.onOpen = { [weak self] node in self?.open(node) }
        grid.itemMenu = { [weak self] node in self?.itemMenu(for: node) ?? [] }
        grid.backgroundMenu = { [weak self] in self?.backgroundMenu() ?? [] }
        grid.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        self.grid = grid
        return grid
    }

    private func showLayout(scrollToSelection: Bool) {
        let active: NSView
        if state.layout == .icons, supportsIcons {
            let grid = makeGrid()
            refreshGrid(scroll: scrollToSelection)
            active = grid
        } else {
            tree.select(selection, scroll: scrollToSelection)
            active = tree
        }
        guard active.superview !== body else { return }
        let focused = window?.firstResponder as? NSView
        let hadFocus = focused != nil && (focused === tree.outline || focused === grid?.collectionView)
        body.subviews.forEach { $0.removeFromSuperview() }
        active.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(active)
        NSLayoutConstraint.activate([
            active.topAnchor.constraint(equalTo: body.topAnchor),
            active.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            active.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            active.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        if hadFocus { window?.makeFirstResponder(active === tree ? tree.outline : grid?.collectionView) }
    }

    /// The icons show the folder's files in the list's order (the list sorts them in place).
    private func refreshGrid(scroll: Bool) {
        guard let grid else { return }
        let files = current.children ?? []
        let groups = FileArrangement.groups(files, by: state.group, sort: state.sort, ascending: state.ascending,
                                            foldersFirst: settings.foldersFirst)
        grid.show(groups, titled: state.group != .none, selecting: selection, scrollToSelection: scroll)
    }

    func setLayout(_ layout: BrowserViewState.Layout) {
        guard layout != state.layout, layout == .list || supportsIcons else { return }
        state.layout = layout
        stateChanged()
        showLayout(scrollToSelection: true)
    }

    // MARK: - Sort and groups

    func setSort(_ key: BrowserViewState.SortKey, ascending: Bool) {
        guard key != state.sort || ascending != state.ascending else { return }
        state.sort = key
        state.ascending = ascending
        stateChanged()
        tree.setSort(key, ascending: ascending)
        if state.layout == .icons { refreshGrid(scroll: false) }
    }

    func setGroup(_ key: BrowserViewState.GroupKey) {
        guard key != state.group else { return }
        state.group = key
        stateChanged()
        tree.setGrouping(key)
        if state.layout == .icons { refreshGrid(scroll: false) }
    }

    /// A column header was clicked: the menu follows the list.
    private func listSorted(_ key: String, ascending: Bool) {
        guard let key = BrowserViewState.SortKey(rawValue: key) else { return }
        state.sort = key
        state.ascending = ascending
        stateChanged()
    }

    private func stateChanged() {
        toolbar.update(state)
        if remembers { BrowserMemory.remember(state, for: scope) }
    }

    // MARK: - Folders

    /// Shows a folder's files in place of the current one's.
    func open(_ folder: FileNode) {
        guard folder.isDirectory, !folder.isPackage, folder !== current else { return }
        trail += MemberBrowserView.chain(from: current, to: folder) ?? [folder]
        showCurrent(selecting: [])
    }

    /// Back to the folder above, with the one just left selected (as Finder does).
    func goBack() {
        goUp(to: trail.count - 2)
    }

    /// Back to the folder at `depth` in the path (0 is the one previewed).
    func goUp(to depth: Int) {
        guard depth >= 0, depth < trail.count - 1 else { return }
        let left = trail[depth + 1]
        trail.removeSubrange((depth + 1)...)
        showCurrent(selecting: [left])
    }

    /// The folders between `start` and `target` (inside it, through what's been loaded), ending
    /// with `target`. Lists expand folders in place, so Open can name one several levels down.
    static func chain(from start: FileNode, to target: FileNode) -> [FileNode]? {
        for child in start.children ?? [] {
            if child === target { return [child] }
            if child.isDirectory, child.children != nil, let rest = chain(from: child, to: target) { return [child] + rest }
        }
        return nil
    }

    private func showCurrent(selecting nodes: [FileNode]) {
        let folder = current
        if folder.children == nil, folder.url != nil { folder.loadChildren(showHidden: settings.showHiddenFiles) }
        selection = []
        tree.reload(root: folder)
        if state.layout == .icons {
            refreshGrid(scroll: true)
            grid?.select(nodes, scroll: true)
        } else {
            tree.select(nodes, scroll: true)
        }
        showSelection(nodes)
        updateTrail()
        onFolderChange?(folder, trail.count == 1)
    }

    private func updateTrail() {
        toolbar.update(trail: trail.enumerated().map { index, node in
            index == 0 ? (rootTitle, rootIcon) : (node.name, FileTreeView.displayIcon(for: node))
        })
    }

    // MARK: - Selection

    private func selectionChanged(_ nodes: [FileNode]) {
        guard nodes.count != selection.count || zip(nodes, selection).contains(where: { $0 !== $1 }) else { return }
        showSelection(nodes)
    }

    private func showSelection(_ nodes: [FileNode]) {
        selection = nodes
        guard !nodes.isEmpty else { hidePane(); return }
        if nodes.count == 1, nodes[0].isDirectory, nodes[0].url != nil { nodes[0].countItems(showHidden: settings.showHiddenFiles) }
        showPane()
        pane.show(nodes)
    }

    private func getInfo(_ node: FileNode) {
        pane.setMode(.info)
        showSelection(selection.isEmpty ? [node] : selection)
    }

    private func showPane() {
        guard !paneShown else { return }
        paneShown = true
        split.addArrangedSubview(pane)
        split.adjustSubviews()
        positionPane()
    }

    private func positionPane() {
        let width = split.bounds.width
        guard width > 0 else { panePositionPending = true; return }
        panePositionPending = false
        split.setPosition((width * (1 - paneFraction)).rounded(), ofDividerAt: 0)
    }

    private func hidePane() {
        guard paneShown else { return }
        if split.bounds.width > 0, !panePositionPending { paneFraction = min(max(pane.frame.width / split.bounds.width, 0.3), 0.75) }
        paneShown = false
        panePositionPending = false
        pane.show([])
        pane.removeFromSuperview()
        split.adjustSubviews()
    }

    override func layout() {
        super.layout()
        if panePositionPending, paneShown, split.bounds.width > 0 { positionPane() }
    }

    // MARK: - Menus and keys

    private func itemMenu(for node: FileNode) -> [NSMenuItem] {
        FileMenus.items(for: node, selection: selection, getInfo: { [weak self] in self?.getInfo($0) },
                        open: { [weak self] in self?.open($0) })
    }

    /// A right-click on the icons' background: Finder's view options.
    private func backgroundMenu() -> [NSMenuItem] {
        var items = ViewOptionMenus.layoutItems(state) { [weak self] in self?.setLayout($0) }
        items.append(.separator())
        items.append(ViewOptionMenus.submenu("Group By", ViewOptionMenus.groupItems(state) { [weak self] in self?.setGroup($0) }))
        items.append(ViewOptionMenus.submenu("Sort By", ViewOptionMenus.sortItems(state, keys: sortKeys) { [weak self] in
            self?.setSort($0, ascending: $1)
        }))
        if trail.count > 1 {
            items.append(.separator())
            items.append(ActionMenuItem("Back to “\(trail.count == 2 ? rootTitle : trail[trail.count - 2].name)”") { [weak self] in self?.goBack() })
        }
        return items
    }

    /// Keys, where the host passes them on (the app, not Quick Look): ⌘↑ back, ⌘↓ open, ⌘I info, Esc.
    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 126 where command:
            goBack()
            return true
        case 125 where command, 36, 76:
            if selection.count == 1, selection[0].isDirectory, !selection[0].isPackage { open(selection[0]); return true }
            return false
        case 53:
            guard !selection.isEmpty else { return false }
            grid?.select([])
            showSelection([])
            return true
        default:
            if command, event.charactersIgnoringModifiers == "i", let node = selection.first { getInfo(node); return true }
            return false
        }
    }

    /// The mouse's back button goes up a folder.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 3, trail.count > 1 { goBack() } else { super.otherMouseDown(with: event) }
    }

    // MARK: - Carrying over

    /// Where the reader is: the folders opened below the one previewed and what's selected, by name.
    struct Location: Equatable {
        var path: [String]
        var selection: [String]
        var showsInfo: Bool
    }

    var location: Location {
        Location(path: trail.dropFirst().map(\.name), selection: selection.map(\.name), showsInfo: pane.mode == .info)
    }

    /// Goes back to a location (after the preview is rebuilt for a change on disk or in settings),
    /// as far as it still exists.
    func restore(_ location: Location) {
        guard location != Location(path: [], selection: [], showsInfo: false) else { return }
        var steps: [FileNode] = []
        var folder = root
        for name in location.path {
            if folder.children == nil, folder.url != nil { folder.loadChildren(showHidden: settings.showHiddenFiles) }
            guard let next = folder.children?.first(where: { $0.name == name && $0.isDirectory && !$0.isPackage }) else { break }
            steps.append(next)
            folder = next
        }
        trail = [root] + steps
        if folder.children == nil, folder.url != nil { folder.loadChildren(showHidden: settings.showHiddenFiles) }
        let names = Set(location.selection)
        let selected = (folder.children ?? []).filter { names.contains($0.name) }
        if location.showsInfo { pane.setMode(.info) }
        showCurrent(selecting: selected)
    }

    // MARK: - Split view

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 280)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 280)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { true }

    // MARK: - Snapshots

    #if DEBUG
    /// `GREECE_STATE` shows a state for design review (the render command has no mouse). Parts,
    /// separated by `;`: `layout:icons`, `sort:<key>`, `order:asc|desc`, `group:<key>`,
    /// `open:<folder>/<folder>`, `select:<name>,<name>`, `info`, `hover:<name>`, `scroll:<y>`, `dump`
    /// (the icons' views), and `itemmenu:<name>` or `bgmenu`, which print that menu. Nothing shown
    /// this way is remembered.
    private func applySnapshotState() {
        guard let raw = ProcessInfo.processInfo.environment["GREECE_STATE"] else { return }
        remembers = false
        var later: [(String, String)] = []
        for part in raw.split(separator: ";").map(String.init) {
            let (name, argument) = part.firstIndex(of: ":").map { (String(part[..<$0]), String(part[part.index(after: $0)...])) } ?? (part, "")
            switch name {
            case "open", "select", "info", "hover", "itemmenu", "bgmenu", "dump", "scroll":
                // Once the preview around the browser is built and on screen, as a reader would find it.
                later.append((name, argument))
            default:
                applySnapshotPart(name, argument)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            for (name, argument) in later { self?.applySnapshotPart(name, argument) }
        }
    }

    private func applySnapshotPart(_ name: String, _ argument: String) {
        switch name {
        case "layout":
            if let layout = BrowserViewState.Layout(rawValue: argument) { setLayout(layout) }
        case "sort":
            if let key = BrowserViewState.SortKey(rawValue: argument) { setSort(key, ascending: key.startsAscending) }
        case "order":
            setSort(state.sort, ascending: argument != "desc")
        case "group":
            if let key = BrowserViewState.GroupKey(rawValue: argument) { setGroup(key) }
        case "open":
            for folderName in argument.split(separator: "/").map(String.init) {
                if current.children == nil, current.url != nil { current.loadChildren(showHidden: settings.showHiddenFiles) }
                if let folder = current.children?.first(where: { $0.name == folderName }) { open(folder) }
            }
        case "select":
            selectForSnapshot(argument.split(separator: ",").map(String.init))
        case "info":
            pane.setMode(.info)
        case "hover", "itemmenu", "bgmenu", "dump", "scroll":
            snapshotAction(name, argument)
        default:
            break
        }
    }

    private func selectForSnapshot(_ names: [String]) {
        let nodes = (current.children ?? []).filter { names.contains($0.name) }
        if state.layout == .icons { grid?.select(nodes, scroll: true) } else { tree.select(nodes, scroll: true) }
        showSelection(nodes)
    }

    private func snapshotAction(_ name: String, _ argument: String) {
        let node = (current.children ?? []).first { $0.name == argument }
        switch name {
        case "hover":
            guard let node, let grid, let path = grid.indexPath(of: node), let item = grid.collectionView.item(at: path) as? IconItem else { return }
            item.cell.showHover(true)
        case "scroll":
            let scroll = state.layout == .icons ? grid?.scrollView : tree.scrollView
            guard let scroll, let y = Double(argument) else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        case "dump":
            func dump(_ view: NSView, _ depth: Int) {
                guard depth < 8 else { return }
                print(String(repeating: "  ", count: depth), type(of: view), view.frame, view.isHidden ? "hidden" : "", view.layer.map { "layer \($0.frame) hidden=\($0.isHidden) opacity=\($0.opacity)" } ?? "")
                for sub in view.subviews { dump(sub, depth + 1) }
            }
            if let grid { dump(grid, 0) }
        case "itemmenu":
            guard let node else { return }
            print(itemMenu(for: node).map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: "\n"))
        default:
            let titles = backgroundMenu().map { item -> String in
                if item.isSeparatorItem { return "—" }
                let sub = item.submenu.map { " ▸ " + $0.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓" : "") + $0.title }.joined(separator: " | ") } ?? ""
                return (item.state == .on ? "✓ " : "  ") + item.title + sub
            }
            print(titles.joined(separator: "\n"))
        }
        fflush(stdout)
    }
    #endif
}

/// Files listed straight from disk (a folder, an app bundle's contents): the file itself, no copy.
final class LocalMembers: MemberSource {
    func extract(_ node: FileNode, to scratch: ArchiveScratch, cancel: CancelToken) throws -> URL {
        guard let url = node.url, !node.isDirectory else { throw PreviewError.unsupported }
        return url
    }
}
