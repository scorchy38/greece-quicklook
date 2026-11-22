import AppKit

/// A finished preview: the content plus the info bar. Shared by the Quick Look extension and the app.
public final class PreviewView: NSView {

    public let content: NSView
    public private(set) var summary: FileSummary
    /// A comfortable size for Quick Look's panel when it opens.
    public let preferredSize: NSSize
    private var infoBar: InfoBarView?
    private var bottomConstraint: NSLayoutConstraint?

    init(content: NSView, summary: FileSummary, preferredSize: NSSize, settings: PreviewSettings) {
        self.content = content
        self.summary = summary
        self.preferredSize = preferredSize
        super.init(frame: NSRect(origin: .zero, size: preferredSize))
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        apply(settings)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Applies new settings in place. Returns false when the preview must be rebuilt instead.
    @discardableResult
    public func update(settings: PreviewSettings, previous: PreviewSettings) -> Bool {
        let rebuild = settings.prettyPrint != previous.prettyPrint
            || settings.maxRows != previous.maxRows
            || settings.showHiddenFiles != previous.showHiddenFiles
            || settings.foldersFirst != previous.foldersFirst
        if rebuild { return false }
        apply(settings)
        return true
    }

    private func apply(_ settings: PreviewSettings) {
        switch settings.appearance {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        if let web = content as? WebPreviewView { web.update(settings: settings) }
        if let grid = content as? GridView { grid.setShowsRowNumbers(settings.rowNumbers) }
        if let browser = content as? SQLiteBrowserView { browser.setShowsRowNumbers(settings.rowNumbers) }
        if let aware = content as? PreviewSettingsAware { aware.apply(settings) }
        setInfoBarVisible(settings.showInfoBar)
    }

    func setSummary(_ summary: FileSummary) {
        self.summary = summary
        infoBar?.configure(summary)
    }

    private func setInfoBarVisible(_ visible: Bool) {
        // A preview created with the bar hidden still needs its content pinned to the bottom.
        if visible == (infoBar != nil), bottomConstraint != nil { return }
        bottomConstraint?.isActive = false
        if visible {
            let bar = InfoBarView(summary: summary)
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            bottomConstraint = content.bottomAnchor.constraint(equalTo: bar.topAnchor)
            infoBar = bar
        } else {
            infoBar?.removeFromSuperview()
            infoBar = nil
            bottomConstraint = content.bottomAnchor.constraint(equalTo: bottomAnchor)
        }
        bottomConstraint?.isActive = true
    }

    /// Resolves once web content has painted; native content is ready immediately.
    public func waitUntilReady() async {
        if let web = content as? WebPreviewView { await web.waitUntilReady() }
    }

    /// The web view inside, if any (used for snapshots).
    public var webView: NSView? { (content as? WebPreviewView)?.webView }

    // MARK: - Scroll position

    /// Called when the reader scrolls (after scrolling settles for web pages).
    public var onScroll: ((CGPoint) -> Void)? {
        didSet {
            if let web = content as? WebPreviewView {
                web.onScroll = onScroll
            } else if let clip = scrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                scrollObserver.map(NotificationCenter.default.removeObserver)
                scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let origin = self.scrollView?.contentView.bounds.origin else { return }
                        self.onScroll?(self.flipped(origin))
                    }
                }
            }
        }
    }
    private var scrollObserver: NSObjectProtocol?

    public func scrollPosition() async -> CGPoint? {
        if let web = content as? WebPreviewView { return await web.scrollPosition() }
        return scrollView.map { flipped($0.contentView.bounds.origin) }
    }

    /// Native content: scrolls to a position recorded earlier (web pages restore it themselves).
    func restoreScroll(_ point: CGPoint) {
        guard !(content is WebPreviewView), let scrollView, let document = scrollView.documentView else { return }
        layoutSubtreeIfNeeded()
        var origin = point
        if !document.isFlipped { origin.y = max(0, document.bounds.height - scrollView.contentView.bounds.height - point.y) }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Positions are measured from the top, whichever way the document view is flipped.
    private func flipped(_ origin: CGPoint) -> CGPoint {
        guard let scrollView, let document = scrollView.documentView, !document.isFlipped else { return origin }
        return CGPoint(x: origin.x, y: max(0, document.bounds.height - scrollView.contentView.bounds.height - origin.y))
    }

    /// The main scrolling area of native content (the first scroll view, depth-first).
    private var scrollView: NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(content)
    }

    deinit {
        scrollObserver.map(NotificationCenter.default.removeObserver)
    }
}
