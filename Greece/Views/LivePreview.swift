import SwiftUI
import GreeceKit

/// The real Quick Look renderer, embedded in Settings. Appearance changes apply in place;
/// structural changes rebuild the preview with a quick crossfade.
struct LivePreview: NSViewRepresentable {
    let url: URL
    let settings: PreviewSettings

    func makeNSView(context: Context) -> PreviewHost { PreviewHost() }

    func updateNSView(_ host: PreviewHost, context: Context) {
        host.show(url: url, settings: settings)
    }
}

final class PreviewHost: NSView {
    private var current: PreviewView?
    private var currentURL: URL?
    private var currentSettings: PreviewSettings?
    private var task: Task<Void, Never>?
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var requested: (url: URL, settings: PreviewSettings)?
    private var building: (url: URL, settings: PreviewSettings)?
    private var failed: (url: URL, settings: PreviewSettings)?

    func show(url: URL, settings: PreviewSettings) {
        requested = (url, settings)
        // A rebuild for this file is already underway: it reconciles with the latest request when it lands.
        if let building, building.url == url { return }
        reconcile()
    }

    /// Brings what's on screen in line with the latest request: restyle in place when possible, rebuild otherwise.
    private func reconcile() {
        guard let requested else { return }
        if let current, currentURL == requested.url, let previous = currentSettings {
            if previous == requested.settings { return }
            if current.update(settings: requested.settings, previous: previous) {
                currentSettings = requested.settings
                return
            }
        }
        if let failed, failed.url == requested.url, failed.settings == requested.settings { return }
        rebuild(url: requested.url, settings: requested.settings)
    }

    private func rebuild(url: URL, settings: PreviewSettings) {
        task?.cancel()
        building = (url, settings)
        if current == nil { spinner.startAnimation(nil) }
        task = Task { @MainActor [weak self] in
            let preview = try? await PreviewFactory.makePreview(for: url, settings: settings)
            guard let self, !Task.isCancelled else { return }
            self.building = nil
            self.spinner.stopAnimation(nil)
            if let preview {
                self.failed = nil
                self.install(preview)
                self.currentURL = url
                self.currentSettings = settings
            } else {
                self.failed = (url, settings)
            }
            self.reconcile()
        }
    }

    private func install(_ preview: PreviewView) {
        spinner.stopAnimation(nil)
        let old = current
        if let old { preview.carryOver(from: old) }
        preview.frame = bounds
        preview.autoresizingMask = [.width, .height]
        preview.alphaValue = old == nil ? 1 : 0
        addSubview(preview, positioned: .below, relativeTo: spinner)
        current = preview
        guard let old else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            preview.animator().alphaValue = 1
        }, completionHandler: {
            old.removeFromSuperview()
        })
    }
}
