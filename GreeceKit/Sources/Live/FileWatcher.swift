import Foundation

/// Calls back when a file's contents change, including saves that replace the file
/// (most editors write a new file and rename it over the old one).
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var snapshot: Snapshot?
    private var pending: DispatchWorkItem?
    private var reopenAttempts = 0

    /// What counts as "changed": a different file, size or modification time. Tag and
    /// permission changes leave this alone, so they don't cause a reload.
    private struct Snapshot: Equatable {
        var inode: UInt64
        var size: Int64
        var modified: TimeInterval

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        }
    }

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        snapshot = Snapshot(path: url.path)
        open()
    }

    deinit {
        source?.cancel()
    }

    private func open() {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return scheduleReopen() }
        reopenAttempts = 0
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib, .link, .revoke], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            MainActor.assumeIsolated {
                if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                    // The file we're watching is gone or moved: watch whatever is at the path now.
                    self.source?.cancel()
                    self.source = nil
                    self.scheduleReopen()
                }
                self.changed()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// An atomic save leaves the path empty for a moment; retry for up to two seconds.
    private func scheduleReopen() {
        guard reopenAttempts < 20 else { return }
        reopenAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.source == nil else { return }
                self.open()
                if self.source != nil { self.changed() }
            }
        }
    }

    /// Coalesces bursts of events (a save is often several writes) into one reload.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Snapshot(path: self.url.path)
                guard let now, now != self.snapshot else { return }
                self.snapshot = now
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
