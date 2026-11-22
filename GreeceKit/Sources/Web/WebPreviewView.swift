import AppKit
import WebKit
import os

/// Hosts a `WebDocument` in a WKWebView with local assets, link handling and a ready signal.
final class WebPreviewView: NSView, WKNavigationDelegate {
    /// What preview pages report: script errors, renderer notes.
    static let pageLog = Logger(subsystem: "com.scorchy.greece", category: "page")

    let webView: PreviewWebView
    private(set) var document: WebDocument
    private var settings: PreviewSettings
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var isReady = false
    /// The page's scroll position, reported shortly after scrolling stops.
    var onScroll: ((CGPoint) -> Void)?
    private let messages = MessageProxy()
    private static let messageNames = ["ready", "copy", "log", "scroll", "menu"]

    init(document: WebDocument, settings: PreviewSettings, size: NSSize = NSSize(width: 900, height: 700)) {
        self.document = document
        self.settings = settings

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(GreeceSchemeHandler(readableDirectory: document.readableDirectory, resources: document.resources),
                                          forURLScheme: GreeceSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false
        let controller = WKUserContentController()
        for name in Self.messageNames { controller.add(messages, name: name) }
        configuration.userContentController = controller

        // Lay out at the real size from the first frame: a zero-sized page measures and scrolls wrongly.
        webView = PreviewWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif

        super.init(frame: NSRect(origin: .zero, size: size))
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        messages.owner = self
        applyAppearance()
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for name in Self.messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    // MARK: - Loading

    /// The only navigation a preview ever performs is loading its own page.
    private var expectingLoad = false
    private var crashReloads = 0

    private func load() {
        isReady = false
        expectingLoad = true
        webView.loadHTMLString(document.html(settings: settings), baseURL: GreeceSchemeHandler.baseURL(for: document.baseDirectory))
    }

    /// Waits until the page has rendered (or a timeout passes), so Quick Look never shows a blank frame.
    func waitUntilReady(timeout: TimeInterval = 2.5) async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            readyContinuations.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.markReady() }
        }
    }

    private func markReady() {
        isReady = true
        let pending = readyContinuations
        readyContinuations.removeAll()
        pending.forEach { $0.resume() }
    }

    // MARK: - Settings

    func update(settings newSettings: PreviewSettings) {
        let old = settings
        settings = newSettings
        if old.appearance != newSettings.appearance { applyAppearance() }
        if WebDocument.structuralKey(old) != WebDocument.structuralKey(newSettings) {
            load()
        } else {
            webView.evaluateJavaScript(WebDocument.liveUpdateScript(settings: newSettings, kind: document.kind))
        }
    }

    /// Where the page is scrolled to right now.
    func scrollPosition() async -> CGPoint? {
        guard let value = try? await webView.evaluateJavaScript("[window.scrollX, window.scrollY]") as? [Double], value.count == 2 else { return nil }
        return CGPoint(x: value[0], y: value[1])
    }

    func replace(document newDocument: WebDocument) {
        document = newDocument
        load()
    }

    private func applyAppearance() {
        switch settings.appearance {
        case .system: webView.appearance = nil
        case .light: webView.appearance = NSAppearance(named: .aqua)
        case .dark: webView.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Messages

    fileprivate func receive(_ message: WKScriptMessage) {
        // Only Greece's own page (never a frame or another origin) may talk to the app.
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == GreeceSchemeHandler.scheme else { return }
        switch message.name {
        case "ready":
            markReady()
        case "copy":
            if let text = message.body as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "log":
            Self.pageLog.info("\(String(describing: message.body), privacy: .public)")
        case "menu":
            // Sent from the page's contextmenu event, just before WebKit asks for the menu.
            webView.pageMenuItems = (message.body as? [[String: Any]] ?? []).compactMap(PreviewWebView.PageMenuItem.init)
        case "scroll":
            if let point = message.body as? [Double], point.count == 2, point.allSatisfy(\.isFinite) {
                onScroll?(CGPoint(x: point[0], y: point[1]))
            }
        default:
            break
        }
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if expectingLoad, action.targetFrame?.isMainFrame == true, action.navigationType == .other {
            expectingLoad = false
            decisionHandler(.allow)
            return
        }
        // Everything else (links, refreshes, redirects, frames) stays out of the preview.
        decisionHandler(.cancel)
        guard action.navigationType == .linkActivated, let url = action.request.url else { return }
        if url.scheme == GreeceSchemeHandler.scheme, url.host == "file" {
            // A link to a local file: show it in Finder rather than opening or running it.
            let file = URL(fileURLWithPath: url.path)
            if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { markReady() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { markReady() }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Retry once (memory pressure); a page that crashes every time is left alone.
        guard crashReloads < 1 else { markReady(); return }
        crashReloads += 1
        load()
    }
}

/// The preview's web view, with a context menu fit for a read-only preview: the page's own
/// commands first (Find “word”, Copy Line 12), then WebKit's useful ones (Copy, Look Up, Share),
/// without the ones that would navigate away or do nothing here.
final class PreviewWebView: WKWebView {
    struct PageMenuItem {
        var id: Int
        var title: String
        var enabled: Bool
        var checked: Bool
        /// Starts a new group of items.
        var separated: Bool

        init?(_ body: [String: Any]) {
            guard let id = body["id"] as? Int, let title = body["title"] as? String, !title.isEmpty else { return nil }
            self.id = id
            self.title = title
            enabled = body["enabled"] as? Bool ?? true
            checked = body["checked"] as? Bool ?? false
            separated = body["separated"] as? Bool ?? false
        }
    }

    /// The page's items for the menu that is about to open.
    var pageMenuItems: [PageMenuItem] = []

    /// WebKit's items that a preview has no use for: navigating, reloading, opening or downloading
    /// in a browser window, editing, and links to text highlights.
    private static let unwanted = ["Reload", "GoBack", "GoForward", "OpenLink", "OpenImage", "OpenMedia", "OpenFrame",
                                   "Download", "Highlight", "Paste", "Cut", "SpellingMenu", "Substitutions",
                                   "Transformations", "ToggleFullScreen", "ToggleEnhancedFullScreen", "InspectElement"]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            let identifier = item.identifier?.rawValue ?? ""
            if Self.unwanted.contains(where: identifier.contains) { menu.removeItem(item) }
        }
        var index = 0
        for page in pageMenuItems {
            if page.separated, index > 0 { menu.insertItem(.separator(), at: index); index += 1 }
            let item = NSMenuItem(title: page.title, action: page.enabled ? #selector(choosePageItem(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.tag = page.id
            item.isEnabled = page.enabled
            item.state = page.checked ? .on : .off
            menu.insertItem(item, at: index)
            index += 1
        }
        if index > 0, index < menu.items.count, !menu.items[index].isSeparatorItem { menu.insertItem(.separator(), at: index) }
        pageMenuItems = []
        Self.tidySeparators(menu)
    }

    @objc private func choosePageItem(_ sender: NSMenuItem) {
        evaluateJavaScript("window.greece && greece.chooseMenuItem(\(sender.tag))")
    }

    /// No separator at either end or next to another.
    static func tidySeparators(_ menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

/// Breaks the retain cycle between WKUserContentController and the view.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: WebPreviewView?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
