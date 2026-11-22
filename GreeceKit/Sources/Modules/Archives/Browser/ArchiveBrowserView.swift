import AppKit

/// An archive's contents, Finder-style, with the selected file's real preview (or Get Info) in a
/// pane that opens beside the list. Packages get their metadata card above.
@MainActor
final class ArchiveBrowserView: NSView, PreviewSettingsAware {
    private let document: ArchiveDocument
    private var settings: PreviewSettings
    private let modified: String?
    private let browser: MemberBrowserView
    private var tree: FileTreeView { browser.tree }
    private var state: NSView?

    /// Holds the package card; empty (zero height) for plain archives.
    private let headerSlot = NSView()

    init(document: ArchiveDocument, settings: PreviewSettings, modified: String?) {
        self.document = document
        self.settings = settings
        self.modified = modified
        browser = MemberBrowserView(root: document.builder.root, source: document.session, scratch: document.scratch,
                                    settings: settings, compressedSizes: document.listing.hasCompressedSizes)
        super.init(frame: NSRect(x: 0, y: 0, width: 980, height: 660))

        headerSlot.translatesAutoresizingMaskIntoConstraints = false
        browser.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerSlot)
        addSubview(browser)
        let collapsed = headerSlot.heightAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        NSLayoutConstraint.activate([
            headerSlot.topAnchor.constraint(equalTo: topAnchor),
            headerSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            collapsed,
            browser.topAnchor.constraint(equalTo: headerSlot.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if let package = document.package {
            showPackage(package)
            // A skill opens on its instructions.
            if package.kind == .skill {
                opening = PackageInspector.skillFile(in: document.listing.entries.map { ArchiveSession.normalized($0.path) })
            }
        }
        updateState()
        if document.isLoading { startLoading() }
    }

    /// A member to show in the preview pane once the browser has its size.
    private var opening: String?

    override func layout() {
        super.layout()
        guard let path = opening, browser.bounds.width > 0 else { return }
        opening = nil
        DispatchQueue.main.async { [weak self] in self?.tree.select(path: path) }
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
        browser.apply(settings)
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
        browser.isHidden = replacement != nil
        guard let replacement else { return }
        replacement.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replacement)
        NSLayoutConstraint.activate([
            replacement.topAnchor.constraint(equalTo: browser.topAnchor),
            replacement.bottomAnchor.constraint(equalTo: bottomAnchor),
            replacement.leadingAnchor.constraint(equalTo: leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        state = replacement
    }
}
