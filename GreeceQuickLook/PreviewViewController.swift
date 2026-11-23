import Cocoa
import Quartz
import os
import GreeceKit

/// Quick Look entry point. All rendering lives in GreeceKit, shared with the app's live previews.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private static let log = Logger(subsystem: "com.scorchy.greece", category: "quicklook")
    private var session: PreviewSession?
    /// Sizes Quick Look sets while opening aren't the reader's choice; only later resizes are.
    private var tracksResizes = false

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 720))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let started = Date()
        Self.log.info("Preparing preview (\(url.pathExtension.isEmpty ? "no extension" : url.pathExtension, privacy: .public))")
        do {
            let session = PreviewSession(url: url)
            try await session.start()
            self.session?.stop()
            self.session?.view.removeFromSuperview()
            session.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(session.view)
            NSLayoutConstraint.activate([
                session.view.topAnchor.constraint(equalTo: view.topAnchor),
                session.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                session.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                session.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            self.session = session
            preferredContentSize = session.preferredSize
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tracksResizes = true }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Self.log.info("Rendered \(session.preview?.summary.title ?? "", privacy: .public) in \(ms, privacy: .public) ms")
        } catch {
            Self.log.error("Preview failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard tracksResizes, view.window?.styleMask.contains(.fullScreen) != true else { return }
        session?.windowResized(to: view.bounds.size)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        session?.stop()
    }
}
