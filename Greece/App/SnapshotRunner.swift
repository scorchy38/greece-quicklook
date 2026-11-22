import AppKit
import WebKit
import SwiftUI
import Quartz
import GreeceKit

/// Renders a preview to a PNG without any UI, for design review and regression checks.
///
///     Greece --render <file> <out.png> [--size 1000x720] [--appearance light|dark] [--theme xcode] [--settings <json>]
enum SnapshotRunner {

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await render()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @MainActor
    private static func render() async throws {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render"), index + 2 < args.count else {
            throw NSError(domain: "Greece", code: 1, userInfo: [NSLocalizedDescriptionKey: "usage: --render <file> <out.png>"])
        }
        let input = URL(fileURLWithPath: args[index + 1])
        let output = URL(fileURLWithPath: args[index + 2])

        var size = NSSize(width: 1000, height: 720)
        if let raw = value(after: "--size") {
            let parts = raw.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
        }
        var settings = PreviewSettings()
        // Any other settings as JSON, e.g. --settings '{"readingTheme":"paper","diagramTheme":"nord"}'.
        if let json = value(after: "--settings"), let overrides = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           var base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) as? [String: Any] {
            base.merge(overrides) { _, new in new }
            if let data = try? JSONSerialization.data(withJSONObject: base),
               let merged = try? JSONDecoder().decode(PreviewSettings.self, from: data) { settings = merged }
        }
        if let theme = value(after: "--theme") { settings.theme = theme }
        if let appearance = value(after: "--appearance").flatMap(PreviewSettings.Appearance.init(rawValue:)) { settings.appearance = appearance }
        if args.contains("--wrap") { settings.wrapLines = true }

        let preview = try await PreviewFactory.makePreview(for: input, settings: settings)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: settings.appearance == .dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        preview.frame = NSRect(origin: .zero, size: size)
        window.contentView = preview
        window.orderFrontRegardless()
        preview.layoutSubtreeIfNeeded()
        await preview.waitUntilReady()
        let wait = value(after: "--wait").flatMap(Double.init) ?? 0.7
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))

        guard let rep = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { return }
        preview.cacheDisplay(in: preview.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)

        var final = image
        if let web = preview.webView as? WKWebView {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: web.bounds.size)
            configuration.afterScreenUpdates = true
            let shot = try await web.takeSnapshot(configuration: configuration)
            let frame = web.convert(web.bounds, to: preview)
            final = NSImage(size: size, flipped: false) { _ in
                image.draw(in: NSRect(origin: .zero, size: size))
                shot.draw(in: frame)
                return true
            }
        }

        let scale = window.backingScaleFactor
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSAppearance(named: settings.appearance == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            final.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)
    }

    // MARK: - App pages

    ///     Greece --render-app <page> <out.png> [--appearance dark]
    static func runApp() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await renderApp()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    @MainActor
    private static func renderApp() async throws {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-app"), index + 2 < args.count,
              let page = Page(rawValue: args[index + 1]) else {
            throw NSError(domain: "Greece", code: 1, userInfo: [NSLocalizedDescriptionKey: "usage: --render-app <page> <out.png>"])
        }
        let output = URL(fileURLWithPath: args[index + 2])
        let dark = value(after: "--appearance") == "dark"
        var size = NSSize(width: 1060, height: 780)
        if let parts = value(after: "--size")?.split(separator: "x").compactMap({ Double($0) }), parts.count == 2 {
            size = NSSize(width: parts[0], height: parts[1])
        }

        let root = RootView(pinnedPage: page)
            .environmentObject(SettingsStore.shared)
            .environmentObject(ExtensionStatus())
            .frame(width: size.width, height: size.height)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.title = page.title
        let toolbar = NSToolbar(identifier: "snapshot")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 2_500_000_000)

        if args.contains("--print-window") {
            // Let an external `screencapture -l <id>` grab exactly this window, then quit.
            print(window.windowNumber)
            fflush(stdout)
            try await Task.sleep(nanoseconds: 4_000_000_000)
            return
        }

        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        let base = NSImage(size: bounds.size)
        base.addRepresentation(rep)

        // WKWebViews draw out of process; composite their snapshots over the window image.
        var shots: [(NSImage, NSRect)] = []
        for web in allWebViews(in: frameView) {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: web.bounds.size)
            if let shot = try? await web.takeSnapshot(configuration: configuration) {
                shots.append((shot, web.convert(web.bounds, to: frameView)))
            }
        }
        let final = NSImage(size: bounds.size, flipped: false) { _ in
            base.draw(in: bounds)
            for (shot, frame) in shots {
                let y = frameView.isFlipped ? bounds.height - frame.maxY : frame.minY
                shot.draw(in: NSRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
            }
            return true
        }
        guard let tiff = final.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)
    }

    @MainActor
    private static func allWebViews(in view: NSView) -> [WKWebView] {
        var result: [WKWebView] = []
        if let web = view as? WKWebView { result.append(web) }
        for subview in view.subviews { result += allWebViews(in: subview) }
        return result
    }

    // MARK: - Thumbnails

    /// Draws the Finder thumbnail for a file, exactly as the thumbnail extension does.
    ///     Greece --thumbnail <file> <out.png> [--size 512]
    static func runThumbnail() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--thumbnail"), index + 2 < args.count else { exit(1) }
        let side = value(after: "--size").flatMap(Double.init) ?? 512
        guard let page = Thumbnailer.page(for: URL(fileURLWithPath: args[index + 1]), maximumSize: CGSize(width: side, height: side),
                                          settings: SettingsStore.current()) else {
            FileHandle.standardError.write(Data("no thumbnail for this file\n".utf8))
            exit(1)
        }
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(page.size.width * scale), pixelsHigh: Int(page.size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        bitmap.size = page.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        page.draw()
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[index + 2]))
        print("badge \(page.badge) size \(Int(page.size.width))x\(Int(page.size.height))")
        exit(0)
    }

    // MARK: - Real Quick Look panel

    /// Opens the system Quick Look panel on a file (exactly what Finder shows) and prints its window
    /// number, so `screencapture -l` can grab that panel alone.
    ///     Greece --quicklook <file> [--size 1000x720] [--hold seconds]
    static func runQuickLook() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = QuickLookHost()
        app.delegate = delegate
        Task { @MainActor in
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: "--quicklook"), index + 1 < args.count else { exit(1) }
            let url = URL(fileURLWithPath: args[index + 1])
            // Without --size the panel opens at whatever size the extension asks for (as in Finder).
            var size: NSSize?
            if let raw = value(after: "--size") {
                let parts = raw.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
            }
            QuickLookPresenter.shared.show(url)
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let panel = QLPreviewPanel.shared() {
                if let size {
                    var frame = panel.frame
                    frame.size = size
                    panel.setFrame(frame, display: true)
                }
                print(panel.windowNumber)
                fflush(stdout)
            }
            let hold = value(after: "--hold").flatMap(Double.init) ?? 5
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            exit(0)
        }
        app.run()
    }
}

/// Owns the Quick Look panel for `--quicklook` runs.
private final class QuickLookHost: NSObject, NSApplicationDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookPresenter.shared.attach(to: panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookPresenter.shared.detach(from: panel) }
}
