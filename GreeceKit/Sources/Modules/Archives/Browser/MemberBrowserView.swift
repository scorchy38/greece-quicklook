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

/// A Finder-style list of files with the selected one's real preview (or Get Info) in a pane that
/// opens beside it: the body of the archive browser, folders, and disk images' Files tab.
@MainActor
final class MemberBrowserView: NSView, PreviewSettingsAware, NSSplitViewDelegate {
    let tree: FileTreeView
    private let pane: EntryPreviewPane
    private let split = NSSplitView()
    private var paneShown = false
    private var paneFraction: CGFloat = 0.5

    init(root: FileNode, source: MemberSource, scratch: ArchiveScratch, settings: PreviewSettings, showsKind: Bool = false, compressedSizes: Bool = false) {
        tree = FileTreeView(root: root, settings: settings, showsKind: showsKind, compressedSizes: compressedSizes)
        pane = EntryPreviewPane(source: source, scratch: scratch, settings: settings,
                                headerHeight: tree.outline.headerView?.frame.height ?? 28)
        super.init(frame: NSRect(x: 0, y: 0, width: 980, height: 600))

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(tree)
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ settings: PreviewSettings) { pane.apply(settings) }

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

/// Files listed straight from disk (an app bundle's contents): the file itself, no copy.
final class LocalMembers: MemberSource {
    func extract(_ node: FileNode, to scratch: ArchiveScratch, cancel: CancelToken) throws -> URL {
        guard let url = node.url, !node.isDirectory else { throw PreviewError.unsupported }
        return url
    }
}
