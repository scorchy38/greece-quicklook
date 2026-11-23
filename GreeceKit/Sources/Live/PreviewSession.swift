import AppKit
import os

/// One open preview: shows the file, keeps it current as the file is saved, and remembers
/// where you were. The view stays the same object; the preview inside is swapped seamlessly.
@MainActor
public final class PreviewSession {
    private static let log = Logger(subsystem: "com.scorchy.greece", category: "live")

    /// Add this to your view hierarchy once.
    public let view = NSView()
    public private(set) var preview: PreviewView?
    public let url: URL

    private var settings: PreviewSettings
    private var watcher: FileWatcher?
    private var lastScroll: CGPoint?
    private var reloading = false
    private var reloadAgain = false

    public init(url: URL, settings: PreviewSettings = SettingsStore.current()) {
        self.url = url
        self.settings = settings
    }

    /// Builds the first preview, opening where you left off if that's remembered.
    public func start() async throws {
        PreviewMemory.honour(generation: settings.memoryGeneration)
        let remembered = PreviewMemory.scroll(for: url, mode: settings.rememberScroll)
        let preview = try await PreviewFactory.makePreview(for: url, settings: settings, scroll: remembered)
        lastScroll = remembered
        install(preview)
        PreviewMemory.recordRecent(url, enabled: settings.recordRecents)
        if settings.liveUpdates {
            watcher = FileWatcher(url: url) { [weak self] in
                Task { await self?.reload() }
            }
        }
    }

    /// The window size to ask Quick Look for: the remembered one, or what suits this file.
    public var preferredSize: NSSize {
        guard let preview else { return NSSize(width: 920, height: 720) }
        return PreviewMemory.windowSize(kind: preview.summary.title, mode: settings.rememberWindowSize) ?? preview.preferredSize
    }

    /// Call when the reader resizes the window, to open the next preview at the same size.
    public func windowResized(to size: NSSize) {
        guard let preview else { return }
        PreviewMemory.rememberWindowSize(size, kind: preview.summary.title, mode: settings.rememberWindowSize)
    }

    /// Re-renders after a save, at the same scroll position. The old preview stays on screen
    /// until the new one has painted, so there's no flash.
    func reload() async {
        guard !reloading else { reloadAgain = true; return }
        reloading = true
        defer { reloading = false }
        let started = Date()
        let scroll = await preview?.scrollPosition() ?? lastScroll
        settings = SettingsStore.current()
        do {
            let fresh = try await PreviewFactory.makePreview(for: url, settings: settings, scroll: scroll)
            install(fresh)
            Self.log.info("Updated after save in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
        } catch {
            // Mid-save or briefly unreadable: keep showing the last good preview.
            Self.log.info("Kept the previous preview: \(error.localizedDescription, privacy: .public)")
        }
        if reloadAgain {
            reloadAgain = false
            await reload()
        }
    }

    /// Stops watching and saves your place.
    public func stop() {
        watcher = nil
        PreviewMemory.flush()
    }

    private func install(_ fresh: PreviewView) {
        let old = preview
        fresh.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fresh)
        NSLayoutConstraint.activate([
            fresh.topAnchor.constraint(equalTo: view.topAnchor),
            fresh.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            fresh.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fresh.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        if let old { fresh.carryOver(from: old) }
        preview = fresh
        old?.removeFromSuperview()
        fresh.onScroll = { [weak self] point in
            guard let self else { return }
            self.lastScroll = point
            PreviewMemory.remember(point, for: self.url, mode: self.settings.rememberScroll)
        }
    }
}
