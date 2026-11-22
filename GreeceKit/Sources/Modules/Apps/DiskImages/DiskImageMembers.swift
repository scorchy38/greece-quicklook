import Foundation

/// Reads files from a disk image's volume for the Files tab's preview pane, without mounting it.
/// The image is opened on first use and kept, so browsing file after file stays quick.
final class DiskImageMembers: MemberSource, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var image: DiskImage?
    private var volume: DiskFileSystem?

    init(url: URL) { self.url = url }

    var displayName: String? { url.lastPathComponent }

    func extract(_ node: FileNode, to scratch: ArchiveScratch, cancel: CancelToken) throws -> URL {
        guard !node.isDirectory, !node.isSymlink else { throw PreviewError.unsupported }
        lock.lock()
        defer { lock.unlock() }
        if volume == nil {
            let image = try DiskImage(url: url)
            self.image = image
            volume = image.openVolume()
        }
        guard let volume, !cancel.isCancelled else { throw PreviewError.unsupported }
        // Read into memory before it's written out, so the cap is lower than archives' streamed one.
        let data = try volume.readFile(node.path, limit: 64 * 1024 * 1024)
        let file = scratch.location(for: node.name)
        try data.write(to: file)
        return file
    }
}
