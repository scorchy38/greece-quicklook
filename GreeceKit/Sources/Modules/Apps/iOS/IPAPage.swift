import AppKit

/// iOS app archives (.ipa): the app inside Payload/, read straight from the ZIP.
enum IPAPage {

    static func appPrefix(in zip: ZIPArchive) -> String? {
        var best: String?
        for member in zip.members.prefix(5000) where member.path.hasPrefix("Payload/") {
            let parts = member.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 3, parts[1].lowercased().hasSuffix(".app") else { continue }
            let prefix = "Payload/" + parts[1] + "/"
            if best == nil || prefix.count < best!.count { best = prefix }
        }
        return best
    }

    static func page(for url: URL, modified: String?) throws -> InspectorPage {
        let zip = try ZIPArchive(url: url)
        guard let prefix = appPrefix(in: zip) else { throw PreviewError.unsupported }
        let source = ZipBundle(zip: zip, prefix: prefix)
        guard var facts = BundleFacts(source: source) else { throw PreviewError.unsupported }
        let image = icon(in: source, info: facts.info)
        facts.icon = image
        let icon: InspectorIcon = image.map { .image($0, shape: .iOS) } ?? .symbol("app.fill", .blue)
        var page = BundlePage.page(for: facts, icon: icon, subject: .archived, modified: modified)
        page.summary.symbol = "iphone"
        page.summary.title = facts.isIOS ? "iOS App" : "App Archive"

        // App Store downloads carry their store listing.
        if let metadata = zip.contents(of: "iTunesMetadata.plist", limit: 1 << 20),
           let store = try? PropertyListSerialization.propertyList(from: metadata, options: [], format: nil) as? [String: Any] {
            var rows: [InspectorItem] = []
            if let artist = store["artistName"] as? String { rows.append(.field("Seller", Format.clean(artist, limit: 120))) }
            if let genre = store["genre"] as? String { rows.append(.field("Category", Format.clean(genre, limit: 80))) }
            if let date = store["releaseDate"] as? String { rows.append(.field("Released", Format.clean(date, limit: 40))) }
            if let account = (store["com.apple.iTunesStore.downloadInfo"] as? [String: Any])?["accountInfo"] as? [String: Any],
               let id = account["AppleID"] as? String { rows.append(.field("Purchased By", Format.clean(id, limit: 120))) }
            if let item = store["itemId"] as? Int { rows.append(.field("App Store ID", String(item), mono: true)) }
            if !rows.isEmpty { page.sections.insert(InspectorSection("store", title: "App Store", rows: rows.map(InspectorRow.item)), at: 0) }
        }

        let archiveSize = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if let index = page.sections.firstIndex(where: { $0.id == "size" }) {
            page.sections[index].rows.insert(.item(.field("Download Size", Format.bytes(archiveSize))), at: 1)
        }
        page.summary.details = [facts.shortVersion, Format.bytes(archiveSize)].compactMap { $0 }
        let entries = zip.members.map { ArchiveEntry(path: $0.path, isDirectory: $0.isDirectory, size: $0.size, compressedSize: $0.compressedSize) }
        let listing = ArchiveListing(format: .zip, container: .zip, entries: entries, archiveSize: archiveSize, truncated: zip.truncated)
        page.contents = .tree(FileNode.tree(from: listing, showHidden: false), title: "Files", count: listing.fileCount, members: ZIPMembers(url: url))
        return page
    }

    /// The app icon: the largest file the Info.plist names, else any AppIcon PNG at the top level.
    static func icon(in source: BundleSource, info: [String: Any]) -> NSImage? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let primary = (info[key] as? [String: Any])?["CFBundlePrimaryIcon"]
            if let files = (primary as? [String: Any])?["CFBundleIconFiles"] as? [String] { names += files }
            if let name = (primary as? [String: Any])?["CFBundleIconName"] as? String { names.append(name) }
        }
        names += (info["CFBundleIconFiles"] as? [String]) ?? []
        if let file = info["CFBundleIconFile"] as? String { names.append(file) }
        let topLevel = source.children("")
        var candidates: [String] = []
        for name in names {
            let base = (name as NSString).deletingPathExtension
            candidates += topLevel.filter { $0.hasPrefix(base) && $0.lowercased().hasSuffix(".png") }
        }
        if candidates.isEmpty {
            candidates = topLevel.filter { ($0.hasPrefix("AppIcon") || $0.hasPrefix("Icon")) && $0.lowercased().hasSuffix(".png") }
        }
        // Largest first: @3x beats @2x beats 1x.
        let scored = Set(candidates).map { name -> (String, Int) in
            let scale = name.contains("@3x") ? 3 : name.contains("@2x") ? 2 : 1
            let points = Int(name.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init).first ?? 60)
            return (name, scale * points)
        }.sorted { $0.1 > $1.1 }
        for (name, _) in scored.prefix(4) {
            if let data = source.data(name, limit: 4 << 20), let image = CgBIImage.image(from: data) { return image }
        }
        // Current Xcode keeps iOS icons only in the compiled asset catalog.
        if let catalog = source.data("Assets.car", limit: AssetCatalog.maxSize) {
            let primary = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
            return AssetCatalog.appIcon(in: catalog, named: primary?["CFBundleIconName"] as? String ?? info["CFBundleIconName"] as? String)
        }
        return nil
    }

    /// For thumbnails: just the icon, as fast as possible.
    static func icon(for url: URL) -> NSImage? {
        guard let zip = try? ZIPArchive(url: url), let prefix = appPrefix(in: zip) else { return nil }
        let source = ZipBundle(zip: zip, prefix: prefix)
        let info = source.plist("Info.plist") ?? [:]
        return icon(in: source, info: info)
    }
}
