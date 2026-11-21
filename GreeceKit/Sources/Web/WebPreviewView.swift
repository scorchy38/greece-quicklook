import AppKit
import WebKit

/// Hosts a `WebDocument` in a WKWebView with local assets, link handling and a ready signal.
final class WebPreviewView: NSView, WKNavigationDelegate {

    let webView: WKWebView
    private(set) var document: WebDocument
    private var settings: PreviewSettings
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var isReady = false
    private let messages = MessageProxy()

    init(document: WebDocument, settings: PreviewSettings, size: NSSize = NSSize(width: 900, height: 700)) {
        self.document = document
        self.settings = settings

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(GreeceSchemeHandler(), forURLScheme: GreeceSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false
        let controller = WKUserContentController()
        for name in ["ready", "copy", "log"] { controller.add(messages, name: name) }
        configuration.userContentController = controller

        // Lay out at the real size from the first frame: a zero-sized page measures and scrolls wrongly.
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
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
        for name in ["ready", "copy", "log"] {
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
            NSLog("[Greece] %@", String(describing: message.body))
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

/// Breaks the retain cycle between WKUserContentController and the view.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: WebPreviewView?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
