import AppKit

/// Finder thumbnails for apps and their kin: the real app icon for .ipa, .apk and .exe files, and a
/// calm card for profiles and torrents. Drawn natively, light content regardless of appearance
/// (thumbnails are documents).
enum AppThumbnails {

    // MARK: - App icons

    static func appIcon(_ image: NSImage, shape: InspectorIcon.IconShape, size: CGSize, badge: String) -> ThumbnailPage {
        let shape = shape.resolved(for: image)
        let side = max(16, min(size.width, size.height)).rounded()
        return ThumbnailPage(size: CGSize(width: side, height: side), badge: badge) { rect in
            // Finder leaves a margin around app icons; match it so these sit well beside .app files.
            let inset = rect.width * (shape == .asIs ? 0.06 : 0.1)
            let target = rect.insetBy(dx: inset, dy: inset)
            NSGraphicsContext.current?.imageInterpolation = .high
            switch shape {
            case .asIs:
                let fitted = fit(image.size, in: target)
                image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
            case .iOS, .rounded:
                let radius = target.width * (shape == .iOS ? 0.2237 : 0.18)
                let path = NSBezierPath(roundedRect: target, xRadius: radius, yRadius: radius)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
                shadow.shadowBlurRadius = rect.width * 0.025
                shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.01)
                shadow.set()
                NSColor.white.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                NSColor.black.withAlphaComponent(0.08).setStroke()
                path.lineWidth = max(0.5, rect.width / 512)
                path.stroke()
            }
        }
    }

    private static func fit(_ size: NSSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    // MARK: - Cards

    struct Card {
        var symbol: String
        var tint: NSColor
        var eyebrow: String
        var title: String
        var lines: [(String, NSColor?)]
    }

    static func profileCard(for url: URL, size: CGSize) -> ThumbnailPage? {
        guard let data = try? ProfilePage.readLimited(url, limit: ProvisioningProfile.maxSize),
              let profile = ProvisioningProfile(data: data) else { return nil }
        var lines: [(String, NSColor?)] = []
        if let team = profile.teamName { lines.append((team, nil)) }
        if let expires = profile.expires {
            let expiry = Format.expiry(expires)
            lines.append((expiry.text, expiry.tone == .critical ? .systemRed : expiry.tone == .caution ? .systemOrange : nil))
        }
        if !profile.devices.isEmpty {
            lines.append((String(localized: "\(profile.devices.count) devices", bundle: .greeceKit, comment: "Thumbnail caption: how many devices a provisioning profile covers"), nil))
        }
        let expired = profile.expires.map { $0 < Date() } ?? false
        let card = Card(symbol: "person.text.rectangle.fill", tint: expired ? .systemGray : .systemBlue,
                        eyebrow: eyebrow(profile.kind), title: profile.name, lines: lines)
        return page(card, size: size, badge: url.pathExtension.lowercased() == "provisionprofile" ? "PROFILE" : "MOBILEPROVISION")
    }

    /// A provisioning profile's kind in small capitals. Apple's program names stay as they are.
    static func eyebrow(_ kind: ProvisioningProfile.Kind) -> String {
        switch kind {
        case .development: return String(localized: "DEVELOPMENT", bundle: .greeceKit, comment: "Thumbnail caption in capitals: a development provisioning profile")
        case .adHoc: return String(localized: "AD HOC", bundle: .greeceKit, comment: "Thumbnail caption in capitals: an ad hoc provisioning profile")
        case .appStore: return "APP STORE"
        case .enterprise: return String(localized: "ENTERPRISE", bundle: .greeceKit, comment: "Thumbnail caption in capitals: an enterprise provisioning profile")
        case .developerID: return "DEVELOPER ID"
        case .macDevelopment: return String(localized: "MAC DEVELOPMENT", bundle: .greeceKit, comment: "Thumbnail caption in capitals: a Mac development provisioning profile")
        case .macAppStore: return "MAC APP STORE"
        }
    }

    static func configurationCard(for url: URL, size: CGSize) -> ThumbnailPage? {
        guard let data = try? ProfilePage.readLimited(url, limit: 8 << 20) else { return nil }
        var content = data
        if SignedContainer.looksSigned([UInt8](data.prefix(4))) {
            guard let inner = SignedContainer(der: data)?.content else { return nil }
            content = inner
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: content, options: [], format: nil) as? [String: Any] else { return nil }
        let profile = ConfigurationProfile(plist: plist)
        var lines: [(String, NSColor?)] = []
        if let organization = profile.organization { lines.append((organization, nil)) }
        let kinds = profile.payloads.map { $0.displayName ?? PayloadCatalog.describe($0.type).title }
        for kind in kinds.prefix(3) { lines.append(("• " + kind, nil)) }
        if kinds.count > 3 {
            lines.append((String(localized: "and \(kinds.count - 3) more", bundle: .greeceKit, comment: "Thumbnail caption under a bulleted list of a profile’s first three payloads"), nil))
        }
        let card = Card(symbol: "gearshape.2.fill", tint: .systemGray,
                        eyebrow: String(localized: "CONFIGURATION PROFILE", bundle: .greeceKit, comment: "Thumbnail caption in capitals: a kind of file"), title: profile.name, lines: lines)
        return page(card, size: size, badge: "MOBILECONFIG")
    }

    static func torrentCard(for url: URL, size: CGSize) -> ThumbnailPage? {
        guard let data = try? ProfilePage.readLimited(url, limit: Torrent.maxSize), let torrent = try? Torrent(data: data) else { return nil }
        var lines: [(String, NSColor?)] = [
            (Format.bytes(torrent.totalSize), nil),
            (String(localized: "\(torrent.realFiles.count) files", bundle: .greeceKit, comment: "How many files a torrent downloads"), nil),
        ]
        if let host = torrent.trackers.first?.first.flatMap({ URL(string: $0)?.host }) { lines.append((host, nil)) }
        if torrent.isPrivate { lines.append((TorrentPage.privateTitle, nil)) }
        let card = Card(symbol: "arrow.down.circle.fill", tint: .systemTeal,
                        eyebrow: String(localized: "TORRENT", bundle: .greeceKit, comment: "Thumbnail caption in capitals: a kind of file (a .torrent file)"), title: torrent.name, lines: lines)
        return page(card, size: size, badge: "TORRENT")
    }

    /// A portrait page: a tinted tile, a small caps label, the title, then a few quiet facts.
    static func page(_ card: Card, size: CGSize, badge: String) -> ThumbnailPage {
        let pageSize = Thumbnailer.pageSize(fitting: size)
        return ThumbnailPage(size: pageSize, badge: badge) { rect in
            NSColor.white.setFill()
            rect.fill()
            let unit = rect.width / 100
            let margin = 10 * unit
            var top = rect.maxY - margin

            // Tile.
            let tileSide = 24 * unit
            let tile = CGRect(x: rect.minX + margin, y: top - tileSide, width: tileSide, height: tileSide)
            let path = NSBezierPath(roundedRect: tile, xRadius: tileSide * 0.2237, yRadius: tileSide * 0.2237)
            if let gradient = NSGradient(starting: card.tint.blended(withFraction: 0.18, of: .white) ?? card.tint, ending: card.tint) {
                gradient.draw(in: path, angle: -90)
            }
            if let symbol = NSImage(systemSymbolName: card.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: tileSide * 0.5, weight: .medium)) {
                let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
                    symbol.draw(in: bounds)
                    NSColor.white.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                let glyph = fit(tinted.size, in: tile.insetBy(dx: tileSide * 0.2, dy: tileSide * 0.2))
                tinted.draw(in: glyph)
            }
            top = tile.minY - 9 * unit

            func draw(_ text: String, font: NSFont, color: NSColor, maxLines: Int, spacingAfter: CGFloat) {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
                let width = rect.width - margin * 2
                let lineHeight = font.ascender - font.descender + font.leading
                let bounds = attributed.boundingRect(with: NSSize(width: width, height: lineHeight * CGFloat(maxLines) + 1),
                                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                let height = min(ceil(bounds.height), lineHeight * CGFloat(maxLines) + 1)
                let frame = CGRect(x: rect.minX + margin, y: top - height, width: width, height: height)
                guard frame.minY > rect.minY + margin * 0.5 else { return }
                attributed.draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                top = frame.minY - spacingAfter
            }

            draw(card.eyebrow, font: .systemFont(ofSize: 5.2 * unit, weight: .semibold), color: card.tint.blended(withFraction: 0.15, of: .black) ?? card.tint,
                 maxLines: 1, spacingAfter: 2.5 * unit)
            draw(card.title, font: .systemFont(ofSize: 9 * unit, weight: .bold), color: NSColor(white: 0.1, alpha: 1), maxLines: 3, spacingAfter: 6 * unit)
            NSColor(white: 0.88, alpha: 1).setFill()
            CGRect(x: rect.minX + margin, y: top + 2 * unit, width: rect.width - margin * 2, height: max(0.5, unit * 0.3)).fill()
            top -= 3 * unit
            for (line, color) in card.lines {
                draw(line, font: .systemFont(ofSize: 6 * unit), color: color ?? NSColor(white: 0.38, alpha: 1), maxLines: 1, spacingAfter: 2 * unit)
            }
        }
    }
}
