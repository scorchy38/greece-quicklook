import AppKit
import QuickLookThumbnailing
import os
import GreeceKit

/// Finder thumbnails: a miniature page of the file's real content, in the user's code theme.
final class ThumbnailProvider: QLThumbnailProvider {
    private static let log = Logger(subsystem: "com.scorchy.greece", category: "thumbnail")

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        Self.log.info("Thumbnail requested (\(request.fileURL.pathExtension.isEmpty ? "no extension" : request.fileURL.pathExtension, privacy: .public))")
        guard let page = Thumbnailer.page(for: request.fileURL, maximumSize: request.maximumSize, settings: SettingsStore.current()) else {
            // Nothing Greece can draw: macOS falls back to the file's icon.
            Self.log.info("Thumbnail declined")
            handler(nil, PreviewError.unsupported)
            return
        }
        let reply = QLThumbnailReply(contextSize: page.size) {
            page.draw()
            return true
        }
        reply.extensionBadge = page.badge
        Self.log.info("Thumbnail \(page.badge, privacy: .public) \(Int(page.size.width), privacy: .public)×\(Int(page.size.height), privacy: .public)")
        handler(reply, nil)
    }
}
