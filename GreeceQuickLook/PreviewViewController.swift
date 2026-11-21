import Cocoa
import Quartz
import os
import GreeceKit

/// Quick Look entry point. All rendering lives in GreeceKit, shared with the app's live previews.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private static let log = Logger(subsystem: "com.scorchy.greece", category: "quicklook")
    private var preview: PreviewView?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 720))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let started = Date()
        Self.log.info("Preparing preview (\(url.pathExtension.isEmpty ? "no extension" : url.pathExtension, privacy: .public))")
        do {
            let settings = SettingsStore.current()
            let preview = try await PreviewFactory.makePreview(for: url, settings: settings)
            self.preview?.removeFromSuperview()
            preview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: view.topAnchor),
                preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            self.preview = preview
            preferredContentSize = preview.preferredSize
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Self.log.info("Rendered \(preview.summary.title, privacy: .public) in \(ms, privacy: .public) ms")
        } catch {
            Self.log.error("Preview failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
