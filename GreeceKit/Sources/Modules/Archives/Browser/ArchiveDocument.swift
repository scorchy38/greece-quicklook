import AppKit

/// One archive as the browser sees it: the open session, what's been listed so far, and its tree.
/// Prepared off the main thread; big archives keep listing in the background once on screen.
final class ArchiveDocument: @unchecked Sendable {
    let session: ArchiveSession
    let identity: ArchiveIdentity
    let lister: ArchiveLister
    let builder: ArchiveTreeBuilder
    let scratch = ArchiveScratch()
    private(set) var listing: ArchiveListing
    var package: PackageInfo?

    /// How long listing may hold up the first paint before the rest streams in.
    static let firstPaintBudget: TimeInterval = 0.25

    init(url: URL, identity: ArchiveIdentity, showHidden: Bool) throws {
        session = try ArchiveSession(url: url, format: identity.format)
        self.identity = identity
        lister = session.makeLister()
        builder = ArchiveTreeBuilder(showHidden: showHidden)
        let first = try lister.step(until: CFAbsoluteTimeGetCurrent() + ArchiveDocument.firstPaintBudget)
        builder.add(first)
        builder.finish()
        listing = lister.listing
    }

    var isLoading: Bool { !lister.isFinished }

    /// Keeps listing on a background queue, handing each batch to `update` on the main thread.
    func continueLoading(_ update: @escaping @MainActor (_ added: [ArchiveEntry], _ listing: ArchiveListing, _ finished: Bool) -> Void) {
        guard isLoading else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var interval = 0.2
            while !lister.isFinished {
                var added: [ArchiveEntry] = []
                do { added = try lister.step(until: CFAbsoluteTimeGetCurrent() + interval) } catch { lister.stop() }
                let snapshot = lister.listing
                let finished = lister.isFinished
                DispatchQueue.main.async {
                    self.listing = snapshot
                    update(added, snapshot, finished)
                }
                // Fewer, larger batches as the tree grows: re-sorting is what costs.
                interval = min(interval * 1.6, 1.5)
            }
        }
    }

    // MARK: - Summary

    func summary(modified: String?, loading: Bool = false) -> FileSummary {
        let listing = self.listing
        var details: [String] = []
        if let package {
            if let version = package.version { details.append(package.name.map { "\($0) \(version)" } ?? version) }
        }
        let files = listing.fileCount
        details.append("\(files.formatted()) \(files == 1 ? "file" : "files")")
        details.append(FileTreeView.bytes(listing.totalSize))
        if listing.totalSize > 0, listing.archiveSize > 0, listing.archiveSize < listing.totalSize, !loading {
            let saved = 100 - Int((Double(listing.archiveSize) / Double(listing.totalSize) * 100).rounded())
            if saved > 0 { details.append("\(saved)% smaller") }
        }
        if listing.volumes > 1 { details.append("\(listing.volumes) parts") }
        if listing.isEncrypted { details.append("Encrypted") }
        if let encoding = listing.nameEncoding { details.append("\(encoding) names") }
        if loading { details.append("Loading…") }
        else if listing.truncated { details.append("Showing first \(listing.entries.count.formatted())") }
        if listing.damage != nil { details.append("Damaged") }
        let symbol: String
        if listing.isEncrypted { symbol = "lock.doc" }
        else if package != nil { symbol = "shippingbox" }
        else { symbol = "archivebox" }
        return FileSummary(symbol: symbol, title: package?.kind.title ?? listing.title, details: details, trailing: modified)
    }
}
