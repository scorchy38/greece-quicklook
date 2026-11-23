import AppKit
import UniformTypeIdentifiers

/// Finder's icon view: real thumbnails in a grid, names under them, group headings when grouped.
///
/// Thumbnails come from Quick Look for the items about to show and are cancelled when they scroll
/// away; type icons stand in until each arrives. Only the items on screen exist as views, so a
/// folder of thousands scrolls as smoothly as one of ten.
@MainActor
final class IconGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    static let iconSide: CGFloat = 72
    static let itemSize = NSSize(width: 112, height: 124)
    static let headerHeight: CGFloat = 32

    let scrollView = NSScrollView()
    let collectionView = IconCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private(set) var groups: [FileGroup] = []
    private var titled = false
    private var positions: [ObjectIdentifier: IndexPath] = [:]
    private var tickets: [ObjectIdentifier: ThumbnailLoader.Ticket] = [:]
    private let loader: ThumbnailLoader
    /// Off for tests and for lists of things that aren't files on disk.
    var loadsThumbnails = true

    /// Called with the selected files whenever the selection changes.
    var onSelectionChange: (([FileNode]) -> Void)?
    /// Opens a folder inside the browser.
    var onOpen: ((FileNode) -> Void)?
    /// The menu for a right-click on an item (the browser's shared file menu).
    var itemMenu: ((FileNode) -> [NSMenuItem])?
    /// The menu for a right-click on the background (view options).
    var backgroundMenu: (() -> [NSMenuItem])?
    /// Keys, where the host passes them on (not in Quick Look): ⌘↑, ⌘I.
    var onKey: ((NSEvent) -> Bool)?

    init(loader: ThumbnailLoader? = nil) {
        self.loader = loader ?? .shared
        super.init(frame: .zero)
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 10, left: 14, bottom: 14, right: 14)
        layout.sectionHeadersPinToVisibleBounds = true

        collectionView.collectionViewLayout = layout
        collectionView.owner = self
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collectionView.register(GroupHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: GroupHeaderView.identifier)
        collectionView.setAccessibilityLabel(String(localized: "Icons", bundle: .greeceKit, comment: "Accessibility label of a folder’s files shown as icons"))

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    /// Shows files in groups (one untitled group when not grouped), selecting `selection` again.
    func show(_ groups: [FileGroup], titled: Bool, selecting selection: [FileNode] = [], scrollToSelection: Bool = false) {
        cancelThumbnails()
        self.groups = groups
        self.titled = titled
        positions.removeAll(keepingCapacity: true)
        for (section, group) in groups.enumerated() {
            for (item, node) in group.nodes.enumerated() { positions[ObjectIdentifier(node)] = IndexPath(item: item, section: section) }
        }
        layout.headerReferenceSize = titled ? NSSize(width: 0, height: Self.headerHeight) : .zero
        // Under a heading the icons sit close to it; ungrouped they get a margin all round.
        layout.sectionInset = titled ? NSEdgeInsets(top: 2, left: 14, bottom: 10, right: 14) : NSEdgeInsets(top: 10, left: 14, bottom: 14, right: 14)
        collectionView.reloadData()
        select(selection, scroll: scrollToSelection)
    }

    var allNodes: [FileNode] { groups.flatMap(\.nodes) }

    var selectedNodes: [FileNode] {
        collectionView.selectionIndexPaths.sorted().compactMap(node(at:))
    }

    func node(at indexPath: IndexPath) -> FileNode? {
        guard indexPath.section < groups.count, indexPath.item < groups[indexPath.section].nodes.count else { return nil }
        return groups[indexPath.section].nodes[indexPath.item]
    }

    func indexPath(of node: FileNode) -> IndexPath? { positions[ObjectIdentifier(node)] }

    /// Selects files without reporting it (the browser already knows).
    func select(_ nodes: [FileNode], scroll: Bool = false) {
        let paths = Set(nodes.compactMap(indexPath(of:)))
        collectionView.selectionIndexPaths = paths
        if scroll, let first = paths.min() {
            collectionView.layoutSubtreeIfNeeded()
            collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
        refreshVisibleItems()
    }

    // MARK: - Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        groups[section].nodes.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        guard let icon = item as? IconItem, let node = node(at: indexPath) else { return item }
        configure(icon, node: node)
        return icon
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GroupHeaderView.identifier, for: indexPath)
        if let header = view as? GroupHeaderView, indexPath.section < groups.count {
            header.configure(title: groups[indexPath.section].title, count: groups[indexPath.section].nodes.count)
        }
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        titled ? NSSize(width: collectionView.bounds.width, height: Self.headerHeight) : .zero
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Type icons follow the appearance: show them again when it changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for case let item as IconItem in collectionView.visibleItems() {
            guard let node = item.node, item.cell.showsFallback else { continue }
            item.cell.setImage(fallbackIcon(for: node), fallback: true)
        }
    }

    private func configure(_ item: IconItem, node: FileNode) {
        item.node = node
        let cell = item.cell
        var image: NSImage?
        if let url = node.url, wantsThumbnail(node) {
            image = loader.cached(url, modified: node.modified, side: Self.iconSide, scale: scale)
        }
        cell.configure(name: node.name, image: image ?? fallbackIcon(for: node), dimmed: node.isHidden,
                       label: node.labelColor, alias: node.isSymlink, folder: node.isDirectory && !node.isPackage)
        cell.showsFallback = image == nil
        cell.isSelected = item.isSelected
        cell.isEmphasized = isEmphasized
        cell.onOpen = { [weak self, weak node] in
            guard let self, let node else { return }
            self.onOpen?(node)
        }
    }

    // MARK: - Thumbnails

    private static let iconCache = NSCache<NSString, NSImage>()

    /// The file's icon until its thumbnail comes, drawn once per kind and size: system icons hold
    /// many sizes and are slow to draw again and again while scrolling.
    private func fallbackIcon(for node: FileNode) -> NSImage {
        let scale = self.scale
        // Icons can differ between light and dark (macOS 26's dark folders), so each has its own.
        let appearance = effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "\(FileTreeView.displayIconKey(for: node))@\(Int(Self.iconSide * scale))\(dark ? "d" : "")" as NSString
        if let cached = Self.iconCache.object(forKey: key) { return cached }
        let source = FileTreeView.displayIcon(for: node)
        let pixels = Int(Self.iconSide * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return source }
        bitmap.size = NSSize(width: Self.iconSide, height: Self.iconSide)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        appearance.performAsCurrentDrawingAppearance {
            source.draw(in: NSRect(x: 0, y: 0, width: Self.iconSide, height: Self.iconSide))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        Self.iconCache.setObject(image, forKey: key)
        return image
    }

    /// Folders show their (possibly custom) icon; apps and bundles too. Everything else, including
    /// document packages, gets Quick Look's thumbnail.
    private func wantsThumbnail(_ node: FileNode) -> Bool {
        guard loadsThumbnails, node.url != nil else { return false }
        if node.isDirectory && !node.isPackage { return false }
        if node.isPackage {
            let ext = (node.name as NSString).pathExtension
            if let type = UTType(filenameExtension: ext), type.conforms(to: .bundle) { return false }
        }
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        scheduleThumbnails()
    }

    private var thumbnailsScheduled = false

    /// Asks for thumbnails a moment after items appear, for those still on screen then: a quick
    /// flick past a thousand files asks Quick Look for none of them.
    private func scheduleThumbnails() {
        guard loadsThumbnails, !thumbnailsScheduled else { return }
        thumbnailsScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thumbnailsScheduled = false
                self.requestVisibleThumbnails()
            }
        }
    }

    private func requestVisibleThumbnails() {
        // What's on screen, and half a screen beyond it either way.
        let visible = collectionView.visibleRect
        let near = visible.insetBy(dx: 0, dy: -visible.height / 2)
        for case let item as IconItem in collectionView.visibleItems() where item.view.frame.intersects(near) {
            guard let node = item.node, let url = node.url, wantsThumbnail(node) else { continue }
            let id = ObjectIdentifier(node)
            guard tickets[id] == nil else { continue }
            let ticket = loader.load(url, modified: node.modified, side: Self.iconSide, scale: scale) { [weak self, weak node] image, final in
                guard let self, let node else { return }
                if final { self.tickets[ObjectIdentifier(node)] = nil }
                guard let image else { return }
                self.visibleItem(for: node)?.cell.setImage(image)
            }
            if let ticket { tickets[id] = ticket }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard let node = (item as? IconItem)?.node, let ticket = tickets.removeValue(forKey: ObjectIdentifier(node)) else { return }
        loader.cancel(ticket)
    }

    private func visibleItem(for node: FileNode) -> IconItem? {
        guard let path = indexPath(of: node), let item = collectionView.item(at: path) as? IconItem, item.node === node else { return nil }
        return item
    }

    func cancelThumbnails() {
        for ticket in tickets.values { loader.cancel(ticket) }
        tickets.removeAll()
    }

    /// Thumbnails being waited for (for measurements).
    var pendingThumbnails: Int { tickets.count }

    override func removeFromSuperview() {
        cancelThumbnails()
        super.removeFromSuperview()
    }

    // MARK: - Selection

    private var reportScheduled = false

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

    /// A click deselects, then selects: report once, after both.
    private func selectionChanged() {
        refreshVisibleItems()
        guard !reportScheduled else { return }
        reportScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reportScheduled = false
                self.onSelectionChange?(self.selectedNodes)
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didChangeItemsAt indexPaths: Set<IndexPath>,
                        to highlightState: NSCollectionViewItem.HighlightState) {
        for path in indexPaths { (collectionView.item(at: path) as? IconItem)?.refresh() }
    }

    // MARK: - Emphasis

    /// Like a list's selection: the accent colour while the icons have focus in the key window,
    /// grey otherwise (always, in Quick Look, whose panel keeps the keys for Finder).
    private(set) var isEmphasized = false

    func refreshVisibleItems() {
        let emphasized = window?.isKeyWindow == true && window?.firstResponder === collectionView
        isEmphasized = emphasized
        for case let item as IconItem in collectionView.visibleItems() {
            item.cell.isEmphasized = emphasized
            item.refresh()
        }
    }

    private var keyObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibleItems() }
            })
        }
    }

    deinit {
        keyObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Pointer

    fileprivate func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        if let path = collectionView.indexPathForItem(at: point), let node = node(at: path) {
            if !collectionView.selectionIndexPaths.contains(path) {
                collectionView.selectionIndexPaths = [path]
                selectionChanged()
            }
            let items = itemMenu?(node) ?? []
            return items.isEmpty ? nil : .context(items)
        }
        let items = backgroundMenu?() ?? []
        return items.isEmpty ? nil : .context(items)
    }

    /// Double-clicking a folder opens it, only where that's the preview's to handle: in Quick Look
    /// a double-click opens the previewed folder in Finder, whatever the preview does.
    fileprivate func doubleClicked(at point: NSPoint) {
        guard PreviewHost.acceptsTyping, let path = collectionView.indexPathForItem(at: point), let node = node(at: path),
              node.isDirectory, !node.isPackage else { return }
        onOpen?(node)
    }
}

/// The grid itself: context menus, keys where they arrive, focus for the selection colour.
@MainActor
final class IconCollectionView: NSCollectionView {
    weak var owner: IconGridView?

    /// Quick Look's panel is never the key window, so without this the reader's first click on the preview would only activate it and do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            owner?.doubleClicked(at: point)
        }
    }

    override func keyDown(with event: NSEvent) {
        if owner?.onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.owner?.refreshVisibleItems() } }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.owner?.refreshVisibleItems() } }
        return resigned
    }
}

// MARK: - Items

final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")
    let cell = IconCell(frame: NSRect(origin: .zero, size: IconGridView.itemSize))
    var node: FileNode?

    override func loadView() { view = cell }

    override var isSelected: Bool {
        didSet { refresh() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { refresh() }
    }

    func refresh() {
        // A rubber band shows what it will select before it does.
        let selected = highlightState == .forSelection || (isSelected && highlightState != .forDeselection)
        if cell.isSelected != selected { cell.isSelected = selected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        node = nil
        cell.onOpen = nil
    }
}

/// One icon: the thumbnail on a rounded highlight when selected, the name under it on up to two
/// lines (the middle cut out of longer names, as Finder does) on an accent capsule when selected.
final class IconCell: NSView {
    private static let font = NSFont.systemFont(ofSize: 12)
    private static let textInset: CGFloat = 6
    private static let aliasBadge: NSImage? = {
        let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AliasBadgeIcon.icns"
        return FileManager.default.fileExists(atPath: path) ? NSImage(contentsOfFile: path) : nil
    }()

    private var image: NSImage?
    private var dimmed = false
    private var alias = false
    private var folder = false
    private var name = ""
    private var label: NSColor?
    var isSelected = false { didSet { if isSelected != oldValue { updateOpenButton(); needsDisplay = true } } }
    var isEmphasized = false { didSet { if isEmphasized != oldValue { restyleText(); needsDisplay = true } } }
    var onOpen: (() -> Void)?

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()
    private var textRect = NSRect.zero
    private let openButton = FirstClickButton()
    private var hovering = false { didSet { if hovering != oldValue { updateOpenButton() } } }

    private let side = IconGridView.iconSide
    private var iconBox: NSRect {
        NSRect(x: ((bounds.width - side) / 2).rounded(), y: 8, width: side, height: side)
    }
    private var textTop: CGFloat { iconBox.maxY + 7 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        container.maximumNumberOfLines = 2
        container.lineBreakMode = .byTruncatingMiddle
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            .applying(.init(paletteColors: [.white, .controlAccentColor]))
        let openTitle = String(localized: "Open", bundle: .greeceKit, comment: "Menu item and button: opens a folder in the browser")
        openButton.image = NSImage(systemSymbolName: "chevron.right.circle.fill", accessibilityDescription: openTitle)?
            .withSymbolConfiguration(config)
        openButton.isBordered = false
        openButton.imagePosition = .imageOnly
        openButton.toolTip = openTitle
        openButton.setAccessibilityLabel(openTitle)
        openButton.target = self
        openButton.action = #selector(open)
        openButton.isHidden = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        openButton.shadow = shadow
        addSubview(openButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Quick Look's panel is never the key window, so without this the reader's first click on the preview would only activate it and do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(name: String, image: NSImage, dimmed: Bool, label: NSColor?, alias: Bool, folder: Bool) {
        self.image = image
        self.dimmed = dimmed
        self.alias = alias
        self.folder = folder
        self.label = label
        if name != self.name || label != nil {
            self.name = name
            setAccessibilityLabel(name)
            toolTip = name
        }
        hovering = false
        restyleText()
        updateOpenButton()
        needsDisplay = true
    }

    /// True while the type icon stands in for a thumbnail.
    var showsFallback = true

    func setImage(_ image: NSImage, fallback: Bool = false) {
        self.image = image
        showsFallback = fallback
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func restyleText() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let color: NSColor = isSelected && isEmphasized ? .alternateSelectedControlTextColor : (dimmed ? .secondaryLabelColor : .labelColor)
        let text = NSMutableAttributedString(string: name, attributes: [.font: Self.font, .foregroundColor: color, .paragraphStyle: paragraph])
        if let label {
            // Finder's tag dot follows the name.
            text.append(NSAttributedString(string: " \u{25CF}", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: label,
                                                                              .paragraphStyle: paragraph, .baselineOffset: 1]))
        }
        storage.setAttributedString(text)
        container.size = NSSize(width: bounds.width - Self.textInset * 2, height: 100)
        layoutManager.ensureLayout(for: container)
        // Centred lines sit where the paragraph put them inside the container.
        let used = layoutManager.usedRect(for: container)
        textRect = NSRect(x: Self.textInset + used.minX, y: textTop + used.minY, width: used.width, height: used.height)
    }

    private func updateOpenButton() {
        openButton.isHidden = !(folder && (hovering || isSelected))
        let box = iconBox
        openButton.frame = NSRect(x: box.maxX - 14, y: box.maxY - 18, width: 22, height: 22)
    }

    @objc private func open() { onOpen?() }

    override func draw(_ dirtyRect: NSRect) {
        let box = iconBox
        if isSelected {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: -5, dy: -5), xRadius: 6, yRadius: 6).fill()
        }
        if let image {
            // Fitted inside the box and standing on its bottom edge, so names line up.
            let size = image.size
            let ratio = size.width > 0 && size.height > 0 ? min(box.width / size.width, box.height / size.height) : 1
            let drawn = NSSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
            let rect = NSRect(x: box.midX - drawn.width / 2, y: box.maxY - drawn.height, width: drawn.width, height: drawn.height)
            image.draw(in: rect.integral, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.55 : 1, respectFlipped: true, hints: nil)
        }
        if alias, let badge = Self.aliasBadge {
            badge.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if isSelected {
            (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
            NSBezierPath(roundedRect: textRect.insetBy(dx: -5, dy: -1), xRadius: 4, yRadius: 4).fill()
        }
        let range = layoutManager.glyphRange(for: container)
        layoutManager.drawGlyphs(forGlyphRange: range, at: NSPoint(x: Self.textInset, y: textTop))
    }

    // MARK: Hover

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Always active: Quick Look's panel shows previews without making them key.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// The pointer over the icon, for snapshots (which have no pointer).
    func showHover(_ on: Bool) { hovering = on }
}

/// A group's heading: its name and how many files it holds, over a hairline, pinned while its
/// files scroll under it.
final class GroupHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeader")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let separator = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        separator.boxType = .separator
        for view in [title, count, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 7),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title text: String, count number: Int) {
        title.stringValue = text
        count.stringValue = number.formatted()
        setAccessibilityLabel(String(localized: "\(text), \(number) items", bundle: .greeceKit,
                                     comment: "Accessibility label of a group heading: its title and how many files it holds, such as “Images, 12 items”"))
    }

    /// Views don't clip to their bounds (macOS 14 and later), and headings float above the files.
    override var clipsToBounds: Bool { get { true } set {} }

    /// Before macOS 26, opaque, so the files scrolling under a pinned heading don't show through
    /// it. From macOS 26 the scroll view puts its own edge effect under pinned headings, and the
    /// content background is no longer the flat control colour, so the heading stays clear.
    override func draw(_ dirtyRect: NSRect) {
        if #available(macOS 26, *) { return }
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}
