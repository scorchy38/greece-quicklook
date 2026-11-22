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

    init(url: URL, identity: ArchiveIdentity, showHidden: Bool, foldersFirst: Bool = true) throws {
        session = try ArchiveSession(url: url, format: identity.format)
        self.identity = identity
        lister = session.makeLister()
        builder = ArchiveTreeBuilder(showHidden: showHidden, foldersFirst: foldersFirst)
        let first = try lister.step(until: CFAbsoluteTimeGetCurrent() + ArchiveDocument.firstPaintBudget)
        builder.add(first)
        builder.finish()
        listing = lister.listing
        // Packages whose metadata lives outside the file list (.deb, .rpm, .gem) don't need to wait for it.
        if lister.isFinished || [.package(.deb), .package(.rpm), .package(.gem)].contains(identity.flavor) {
            package = inspectPackage(listing)
        }
    }

    var isLoading: Bool { !lister.isFinished }

    /// Lists the rest now (comics and thumbnails need every entry), within `budget` seconds.
    func finishListing(budget: TimeInterval) {
        let deadline = CFAbsoluteTimeGetCurrent() + budget
        while !lister.isFinished {
            let added = (try? lister.step(until: deadline)) ?? []
            builder.add(added)
            if CFAbsoluteTimeGetCurrent() >= deadline { lister.stop() }
        }
        builder.finish()
        listing = lister.listing
    }

    func inspectPackage(_ listing: ArchiveListing) -> PackageInfo? {
        guard !listing.headerEncrypted else { return nil }
        return PackageInspector.inspect(session, listing: listing, flavor: identity.flavor, members: session.packageMembers)
    }

    /// Set when the preview closes, so a huge archive stops listing with it.
    let loading = CancelToken()

    /// Keeps listing on a background queue, handing each batch to `update` on the main thread.
    func continueLoading(_ update: @escaping @MainActor (_ added: [ArchiveEntry], _ listing: ArchiveListing, _ finished: Bool, _ package: PackageInfo?) -> Void) {
        guard isLoading else { return }
        let hasPackage = package != nil
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var interval = 0.2
            while !lister.isFinished {
                if loading.isCancelled { lister.stop(); return }
                var added: [ArchiveEntry] = []
                do { added = try lister.step(until: CFAbsoluteTimeGetCurrent() + interval) } catch { lister.stop() }
                let snapshot = lister.listing
                let finished = lister.isFinished
                let package = finished && !hasPackage ? inspectPackage(snapshot) : nil
                DispatchQueue.main.async {
                    self.listing = snapshot
                    if let package { self.package = package }
                    update(added, snapshot, finished, package)
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
        if listing.headerEncrypted && listing.entries.isEmpty {
            details.append(String(localized: "File list encrypted", bundle: .greeceKit, comment: "Info bar detail: an archive whose list of files needs its password"))
        } else if listing.entries.isEmpty && !loading {
            details.append(listing.damage == nil
                ? String(localized: "Empty [archive]", defaultValue: "Empty", bundle: .greeceKit, comment: "Info bar detail: an archive with nothing inside")
                : String(localized: "Nothing readable", bundle: .greeceKit, comment: "Info bar detail: a damaged archive with nothing that can be read"))
        } else {
            details.append(String(localized: "\(files) files", bundle: .greeceKit, comment: "A count of files"))
            details.append(FileTreeView.bytes(listing.totalSize))
        }
        if listing.totalSize > 0, listing.archiveSize > 0, listing.archiveSize < listing.totalSize, !loading {
            let saved = 100 - Int((Double(listing.archiveSize) / Double(listing.totalSize) * 100).rounded())
            if saved > 0 {
                let percent = (Double(saved) / 100).formatted(.percent)
                details.append(String(localized: "\(percent) smaller", bundle: .greeceKit,
                                      comment: "Info bar detail: how much smaller an archive is than what it holds; the argument is a percentage, such as “42%”"))
            }
        }
        let volumes = listing.volumes
        if volumes > 1 {
            details.append(String(localized: "\(volumes) parts", bundle: .greeceKit, comment: "Info bar detail: how many files a multi-part archive is split into"))
        }
        if listing.isEncrypted && !listing.entries.isEmpty { details.append(String(localized: "Encrypted", bundle: .greeceKit, comment: "State of an archive or a file in it")) }
        if let encoding = listing.nameEncoding {
            details.append(String(localized: "\(encoding) names", bundle: .greeceKit,
                                  comment: "Info bar detail: the legacy text encoding an archive’s file names were read in, such as “Shift JIS names”"))
        }
        let listed = listing.entries.count
        if loading { details.append(String(localized: "Loading…", bundle: .greeceKit)) }
        else if listing.truncated {
            details.append(String(localized: "Showing first \(listed)", bundle: .greeceKit,
                                  comment: "Info bar detail: a huge archive lists only its first entries; the argument is how many, such as “200,000”"))
        }
        if listing.damage != nil { details.append(String(localized: "Damaged", bundle: .greeceKit, comment: "Info bar detail: the archive is damaged")) }
        let symbol: String
        if listing.isEncrypted { symbol = "lock.doc" }
        else if package != nil { symbol = "shippingbox" }
        else { symbol = "archivebox" }
        return FileSummary(symbol: symbol, title: package?.kind.title ?? listing.title, details: details, trailing: modified)
    }
}
