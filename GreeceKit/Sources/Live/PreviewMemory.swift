import Foundation

/// Where you were in each file, and how big you like the Quick Look window.
///
/// Kept in the Quick Look extension's own defaults: macOS lets preview extensions read the
/// shared App Group but not write to it. The app clears this memory by raising
/// `PreviewSettings.memoryGeneration`, which the extension notices on its next preview.
enum PreviewMemory {
    private static let scrollKey = "scroll-memory.v1"
    private static let windowKey = "window-memory.v1"
    private static let generationKey = "memory-generation"
    private static let maximumFiles = 500

    private static var defaults: UserDefaults { .standard }

    /// Forgets everything if the app asked for that since the last preview.
    static func honour(generation: Int) {
        guard defaults.integer(forKey: generationKey) != generation else { return }
        defaults.removeObject(forKey: scrollKey)
        defaults.removeObject(forKey: windowKey)
        defaults.set(generation, forKey: generationKey)
    }

    /// When this Mac last started up: positions from before it belong to an earlier session.
    static let bootTime: TimeInterval = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(boot.tv_sec)
    }()

    // MARK: - Scroll position

    static func scroll(for url: URL, mode: PreviewSettings.Memory) -> CGPoint? {
        guard mode != .off,
              let entry = (defaults.dictionary(forKey: scrollKey) ?? [:])[url.path] as? [Double], entry.count == 4 else { return nil }
        if mode == .session, entry[3] != bootTime { return nil }
        let point = CGPoint(x: entry[0], y: entry[1])
        return point == .zero ? nil : point
    }

    private static var pendingScroll: [String: CGPoint] = [:]
    private static var pendingMode: PreviewSettings.Memory = .off
    private static var flushScheduled = false

    /// Records a position; writes are batched so scrolling never touches the disk per frame.
    @MainActor
    static func remember(_ point: CGPoint, for url: URL, mode: PreviewSettings.Memory) {
        guard mode != .off else { return }
        pendingScroll[url.path] = point
        pendingMode = mode
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { flush() }
        }
    }

    @MainActor
    static func flush() {
        flushScheduled = false
        guard !pendingScroll.isEmpty else { return }
        var all = defaults.dictionary(forKey: scrollKey) ?? [:]
        let now = Date().timeIntervalSince1970
        for (path, point) in pendingScroll {
            all[path] = [Double(point.x), Double(point.y), now, bootTime]
        }
        pendingScroll.removeAll()
        if all.count > maximumFiles {
            // Forget the least recently read files.
            let oldest = all.compactMap { key, value -> (String, Double)? in
                guard let entry = value as? [Double], entry.count == 4 else { return (key, 0) }
                return (key, entry[2])
            }.sorted { $0.1 < $1.1 }.prefix(all.count - maximumFiles + 50)
            oldest.forEach { all.removeValue(forKey: $0.0) }
        }
        defaults.set(all, forKey: scrollKey)
    }

    // MARK: - Window size

    static func windowSize(kind: String, mode: PreviewSettings.WindowMemory) -> CGSize? {
        guard mode != .off, let all = defaults.dictionary(forKey: windowKey),
              let size = all[mode == .perKind ? kind : "*"] as? [Double], size.count == 2 else { return nil }
        return CGSize(width: size[0], height: size[1])
    }

    static func rememberWindowSize(_ size: CGSize, kind: String, mode: PreviewSettings.WindowMemory) {
        guard mode != .off, size.width >= 320, size.height >= 240 else { return }
        var all = defaults.dictionary(forKey: windowKey) ?? [:]
        all[mode == .perKind ? kind : "*"] = [Double(size.width.rounded()), Double(size.height.rounded())]
        defaults.set(all, forKey: windowKey)
    }

}
