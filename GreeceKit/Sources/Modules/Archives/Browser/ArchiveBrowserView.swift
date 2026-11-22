import AppKit

/// An archive's contents, Finder-style, with the selected file's real preview (or Get Info) in a
/// pane that opens beside the list. Packages get their metadata card above.
@MainActor
final class ArchiveBrowserView: NSView, PreviewSettingsAware, NSSplitViewDelegate {
    private let document: ArchiveDocument
    private var settings: PreviewSettings
    private let modified: String?
    private let split = NSSplitView()
    private let tree: FileTreeView
    private let pane: EntryPreviewPane
    private var paneShown = false
    private var paneFraction: CGFloat = 0.5
    private var state: NSView?

    /// Holds the package card; empty (zero height) for plain archives.
    private let headerSlot = NSView()

    init(document: ArchiveDocument, settings: PreviewSettings, modified: String?) {
        self.document = document
        self.settings = settings
        self.modified = modified
        tree = FileTreeView(root: document.builder.root, settings: settings, showsKind: false,
                            compressedSizes: document.listing.hasCompressedSizes)
        pane = EntryPreviewPane(session: document.session, scratch: document.scratch, settings: settings,
                                headerHeight: tree.outline.headerView?.frame.height ?? 28)
        super.init(frame: NSRect(x: 0, y: 0, width: 980, height: 660))

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(tree)

        headerSlot.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerSlot)
        addSubview(split)
        let collapsed = headerSlot.heightAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        NSLayoutConstraint.activate([
            headerSlot.topAnchor.constraint(equalTo: topAnchor),
            headerSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            collapsed,
            split.topAnchor.constraint(equalTo: headerSlot.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tree.onSelectionChange = { [weak self] nodes in self?.selectionChanged(nodes) }
        tree.onGetInfo = { [weak self] node in
            guard let self else { return }
            self.pane.setMode(.info)
            self.selectionChanged(self.tree.selectedNodes.isEmpty ? [node] : self.tree.selectedNodes)
        }
        if let package = document.package { showPackage(package) }
        updateState()
        if document.isLoading { startLoading() }
    }

    private func showPackage(_ info: PackageInfo) {
        headerSlot.subviews.forEach { $0.removeFromSuperview() }
        let header = PackageHeaderView(info)
        header.translatesAutoresizingMaskIntoConstraints = false
        headerSlot.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: headerSlot.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerSlot.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: headerSlot.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerSlot.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { document.loading.cancel() }

    func apply(_ settings: PreviewSettings) {
        self.settings = settings
        pane.apply(settings)
    }

    // MARK: - Loading

    private func startLoading() {
        document.continueLoading { [weak self] added, listing, finished, package in
            guard let self else { return }
            self.document.builder.add(added)
            self.document.builder.finish()
            self.tree.reload()
            if let package { self.showPackage(package) }
            self.updateState()
            self.setSummary(self.document.summary(modified: self.modified, loading: !finished))
        }
    }

    private func setSummary(_ summary: FileSummary) {
        var view = superview
        while let current = view, !(current is PreviewView) { view = current.superview }
        (view as? PreviewView)?.setSummary(summary)
    }

    /// Encrypted, empty and damaged archives say so instead of showing an empty list.
    private func updateState() {
        let listing = document.listing
        var replacement: ArchiveStateView?
        if listing.headerEncrypted && listing.entries.isEmpty {
            replacement = ArchiveStateView(symbol: "lock", title: "Encrypted Archive",
                                           message: "Even the list of files is protected by a password.")
        } else if listing.entries.isEmpty && !document.isLoading {
            if let damage = listing.damage {
                replacement = ArchiveStateView(symbol: "exclamationmark.triangle", title: "Damaged Archive", message: damage.prefix(1).uppercased() + damage.dropFirst() + ".")
            } else {
                replacement = ArchiveStateView(symbol: "archivebox", title: "Empty Archive", message: "There’s nothing inside.")
            }
        } else if document.builder.root.children?.isEmpty == true && document.builder.hiddenCount > 0 && !document.isLoading {
            replacement = ArchiveStateView(symbol: "eye.slash", title: "Only Hidden Files",
                                           message: "\(document.builder.hiddenCount.formatted()) hidden \(document.builder.hiddenCount == 1 ? "item" : "items"). Show hidden files in Greece’s settings to see them.")
        }
        state?.removeFromSuperview()
        state = nil
        split.isHidden = replacement != nil
        guard let replacement else { return }
        replacement.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replacement)
        NSLayoutConstraint.activate([
            replacement.topAnchor.constraint(equalTo: split.topAnchor),
            replacement.bottomAnchor.constraint(equalTo: bottomAnchor),
            replacement.leadingAnchor.constraint(equalTo: leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        state = replacement
    }

    // MARK: - Selection

    private func selectionChanged(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { hidePane(); return }
        showPane()
        pane.show(nodes)
    }

    private func showPane() {
        guard !paneShown else { return }
        paneShown = true
        split.addArrangedSubview(pane)
        split.adjustSubviews()
        let width = max(split.bounds.width, 1)
        split.setPosition((width * (1 - paneFraction)).rounded(), ofDividerAt: 0)
    }

    private func hidePane() {
        guard paneShown else { return }
        if split.bounds.width > 0 { paneFraction = min(max(pane.frame.width / split.bounds.width, 0.3), 0.75) }
        paneShown = false
        pane.show([])
        pane.removeFromSuperview()
        split.adjustSubviews()
    }

    // MARK: - Split view

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 240)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 280)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { true }
}
