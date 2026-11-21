import AppKit
import UniformTypeIdentifiers

/// Finder thumbnails for archives: a comic's cover, a package's card, a compressed text file's first
/// lines, and for everything else a small Finder-style list of what's inside.
extension ArchivesModule {
    /// Thumbnails share Quick Look's time budget: listing stops here and shows what it has.
    static let thumbnailBudget: TimeInterval = 0.8

    static func thumbnail(_ file: FileInfo, size: CGSize, settings: PreviewSettings) -> ThumbnailPage? {
        guard let identity = ArchiveSniffer.identify(file), let session = try? ArchiveSession(url: file.url, format: identity.format),
              let listing = try? session.listAll(budget: thumbnailBudget) else { return nil }
        let badge = ArchiveCard.badge(for: file.url)

        if identity.flavor == .comic, let page = comicCover(session, listing: listing, size: size, badge: badge) {
            return page
        }
        if let info = PackageInspector.inspect(session, listing: listing, flavor: identity.flavor, members: session.packageMembers) {
            let pageSize = Thumbnailer.pageSize(fitting: size)
            let icon = info.icon.flatMap(NSImage.init(data:))
            return ThumbnailPage(size: pageSize, badge: badge) { rect in ArchiveCard.drawPackage(info, icon: icon, in: rect) }
        }
        if listing.container == .compressedFile, let prefix = listing.innerPrefix, FileProbe(bytes: [UInt8](prefix.prefix(8192))).isText,
           let name = listing.entries.first?.path {
            var text = TextFile.decode(prefix.prefix(48 * 1024)).0
            let ext = (name as NSString).pathExtension.lowercased()
            var grammar = (LanguageCatalog.language(forFileName: name) ?? LanguageCatalog.language(forExtension: ext) ?? .plainText).grammar
            if ext == "json" || ext == "geojson" {
                grammar = "json"
                if JSONFormatter.looksMinified(text), let pretty = JSONFormatter.prettyPrinted(text, lenient: true) { text = pretty }
            }
            return ThumbnailPage(size: Thumbnailer.pageSize(fitting: size), badge: badge) { rect in
                CodePage.draw(text, grammar: grammar, in: rect, theme: settings.codeTheme)
            }
        }
        let content = ArchiveCard.ListContent(listing: listing, name: session.volumes.displayName, showHidden: settings.showHiddenFiles)
        return ThumbnailPage(size: Thumbnailer.pageSize(fitting: size), badge: badge) { rect in ArchiveCard.drawList(content, in: rect) }
    }

    private static func comicCover(_ session: ArchiveSession, listing: ArchiveListing, size: CGSize, badge: String) -> ThumbnailPage? {
        guard let book = ComicBook(session: session, listing: listing, scratch: ArchiveScratch()),
              let first = book.pages.first, let data = session.data(first, limit: ComicBook.pageLimit),
              let cover = ComicBook.downsample(data, maxPixels: Int(max(size.width, size.height) * 2)) else { return nil }
        let aspect = CGFloat(cover.width) / CGFloat(max(cover.height, 1))
        var fitted = CGSize(width: size.width, height: size.width / aspect)
        if fitted.height > size.height { fitted = CGSize(width: size.height * aspect, height: size.height) }
        fitted = CGSize(width: max(fitted.width.rounded(), 16), height: max(fitted.height.rounded(), 16))
        return ThumbnailPage(size: fitted, badge: badge) { rect in
            NSGraphicsContext.current?.cgContext.interpolationQuality = .high
            NSGraphicsContext.current?.cgContext.draw(cover, in: rect)
        }
    }
}

/// The drawings themselves: printed-page colours, since thumbnails sit among other documents.
enum ArchiveCard {
    static let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1)
    static let tertiary = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.62, alpha: 1)
    static let hairline = NSColor(srgbRed: 0.88, green: 0.88, blue: 0.9, alpha: 1)
    static let stripe = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1)

    /// "ZIP", "TAR.GZ", "CBZ": what Finder shows on the corner of the thumbnail.
    static func badge(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"] where name.hasSuffix(compound) {
            return String(compound.dropFirst()).uppercased()
        }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "ARCHIVE" : String(ext.prefix(7))
    }

    // MARK: - File list

    struct ListContent {
        struct Row { let name: String; let isDirectory: Bool; let size: String }
        var title: String
        var subtitle: String
        var rows: [Row]
        var more: Int
        var locked: Bool

        init(listing: ArchiveListing, name: String, showHidden: Bool) {
            var root = FileNode.tree(from: listing, showHidden: showHidden)
            title = name
            // A lone top-level folder (the usual zip of a folder) shows what's inside it.
            if let only = root.children, only.count == 1, only[0].isDirectory, only[0].children?.isEmpty == false {
                root = only[0]
                title = only[0].name
            }
            let children = (root.children ?? []).sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            rows = children.prefix(40).map { Row(name: $0.name, isDirectory: $0.isDirectory, size: $0.size.map(FileTreeView.bytes) ?? "") }
            more = max(children.count - rows.count, 0)
            let files = listing.fileCount
            subtitle = listing.headerEncrypted && listing.entries.isEmpty ? "Encrypted"
                : "\(files.formatted()) \(files == 1 ? "file" : "files") · \(FileTreeView.bytes(listing.totalSize))" + (listing.truncated ? "+" : "")
            locked = listing.isEncrypted
        }
    }

    static func drawList(_ content: ListContent, in rect: CGRect) {
        NSColor.white.setFill()
        rect.fill()
        let width = rect.width
        let padding = (width * 0.075).rounded()
        var top = rect.maxY - padding

        // Title and summary.
        let titleFont = NSFont.systemFont(ofSize: max(width / 15, 1), weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: max(width / 24, 1))
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingMiddle
        let title = NSAttributedString(string: content.title, attributes: [.font: titleFont, .foregroundColor: ink, .paragraphStyle: titleStyle])
        let titleHeight = titleFont.boundingRectForFont.height * 0.95
        title.draw(with: CGRect(x: rect.minX + padding, y: top - titleHeight, width: width - padding * 2, height: titleHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        top -= titleHeight + width * 0.012
        let detail = NSAttributedString(string: content.subtitle, attributes: [.font: detailFont, .foregroundColor: secondary])
        let detailHeight = detailFont.boundingRectForFont.height
        detail.draw(with: CGRect(x: rect.minX + padding, y: top - detailHeight, width: width - padding * 2, height: detailHeight),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        top -= detailHeight + width * 0.05

        if content.locked && content.rows.isEmpty {
            drawSymbol("lock.fill", size: width * 0.2, color: tertiary, center: CGPoint(x: rect.midX, y: rect.minY + (top - rect.minY) * 0.55))
            return
        }

        hairline.setFill()
        CGRect(x: rect.minX + padding, y: top, width: width - padding * 2, height: max(width / 400, 0.5)).fill()

        // Rows, Finder-style.
        let rowHeight = (width * 0.088).rounded(.down)
        let iconSize = rowHeight * 0.68
        let nameFont = NSFont.systemFont(ofSize: max(width / 26, 1))
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: max(width / 29, 1), weight: .regular)
        let nameStyle = NSMutableParagraphStyle()
        nameStyle.lineBreakMode = .byTruncatingMiddle
        let available = Int((top - (rect.minY + padding)) / rowHeight)
        let showMore = content.more > 0 || content.rows.count > available
        let count = min(content.rows.count, showMore ? max(available - 1, 0) : available)
        var y = top
        for (index, row) in content.rows.prefix(count).enumerated() {
            y -= rowHeight
            if index % 2 == 1 {
                stripe.setFill()
                CGRect(x: rect.minX + padding * 0.5, y: y, width: width - padding, height: rowHeight).fill()
            }
            let icon = FileTreeView.icon(forName: row.name, isDirectory: row.isDirectory)
            icon.draw(in: CGRect(x: rect.minX + padding, y: y + (rowHeight - iconSize) / 2, width: iconSize, height: iconSize),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let size = NSAttributedString(string: row.size, attributes: [.font: sizeFont, .foregroundColor: secondary])
            let sizeWidth = size.size().width
            let textY = y + (rowHeight - nameFont.boundingRectForFont.height) / 2
            size.draw(at: CGPoint(x: rect.maxX - padding - sizeWidth, y: y + (rowHeight - sizeFont.boundingRectForFont.height) / 2))
            let nameX = rect.minX + padding + iconSize + width * 0.025
            NSAttributedString(string: row.name, attributes: [.font: nameFont, .foregroundColor: ink, .paragraphStyle: nameStyle])
                .draw(with: CGRect(x: nameX, y: textY, width: rect.maxX - padding - sizeWidth - width * 0.04 - nameX, height: nameFont.boundingRectForFont.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if showMore {
            let remaining = content.more + content.rows.count - count
            y -= rowHeight
            NSAttributedString(string: "and \(remaining.formatted()) more", attributes: [.font: nameFont, .foregroundColor: tertiary])
                .draw(at: CGPoint(x: rect.minX + padding + iconSize + width * 0.025, y: y + (rowHeight - nameFont.boundingRectForFont.height) / 2))
        }
    }

    // MARK: - Package card

    static func drawPackage(_ info: PackageInfo, icon: NSImage?, in rect: CGRect) {
        NSColor.white.setFill()
        rect.fill()
        let width = rect.width
        let iconSize = (width * 0.36).rounded()
        var top = rect.maxY - width * 0.15
        PackageIconView.draw(image: icon, symbol: info.symbol, tint: PackageIconView.tint(for: info.kind),
                             in: CGRect(x: rect.midX - iconSize / 2, y: top - iconSize, width: iconSize, height: iconSize))
        top -= iconSize + width * 0.075

        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineBreakMode = .byTruncatingTail
        let wrapping = NSMutableParagraphStyle()
        wrapping.alignment = .center
        wrapping.lineBreakMode = .byWordWrapping
        func line(_ text: String, font: NSFont, color: NSColor, lines: Int = 1) {
            let height = font.boundingRectForFont.height * CGFloat(lines)
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: lines > 1 ? wrapping : centred])
                .draw(with: CGRect(x: rect.minX + width * 0.08, y: top - height, width: width * 0.84, height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            top -= height
        }
        line(info.name ?? info.kind.title, font: .systemFont(ofSize: max(width / 12.5, 1), weight: .semibold), color: ink)
        if let version = info.version {
            top -= width * 0.01
            line(version, font: .systemFont(ofSize: max(width / 18, 1)), color: secondary)
        }
        if let summary = info.summary {
            top -= width * 0.045
            line(summary, font: .systemFont(ofSize: max(width / 24, 1)), color: secondary, lines: 3)
        }

        // A few facts, label over value, like the card in the preview.
        let facts = info.facts.prefix(2)
        if !facts.isEmpty, top > rect.minY + width * 0.4 {
            top -= width * 0.06
            hairline.setFill()
            CGRect(x: rect.midX - width * 0.2, y: top, width: width * 0.4, height: max(width / 400, 0.5)).fill()
            top -= width * 0.05
            for (label, value) in facts where top > rect.minY + width * 0.2 {
                line(label.uppercased(), font: .systemFont(ofSize: max(width / 34, 1), weight: .semibold), color: tertiary)
                top -= width * 0.008
                line(value, font: .systemFont(ofSize: max(width / 26, 1)), color: ink)
                top -= width * 0.03
            }
        }
        let kind = NSAttributedString(string: info.kind.title, attributes: [.font: NSFont.systemFont(ofSize: max(width / 30, 1)), .foregroundColor: tertiary, .paragraphStyle: centred])
        kind.draw(with: CGRect(x: rect.minX, y: rect.minY + width * 0.06, width: width, height: width / 20), options: [.usesLineFragmentOrigin])
    }

    static func drawSymbol(_ name: String, size: CGFloat, color: NSColor, center: CGPoint) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(x: center.x - tinted.size.width / 2, y: center.y - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
    }
}
