import AppKit

/// A package's identity above its file list: icon, name and version, what it is, then the facts
/// that matter in an App Store-style strip, and what it depends on.
final class PackageHeaderView: NSView {
    init(_ info: PackageInfo) {
        super.init(frame: .zero)

        let icon = PackageIconView(info: info)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 52), icon.heightAnchor.constraint(equalToConstant: 52)])

        let title = NSTextField(labelWithAttributedString: PackageHeaderView.title(info))
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.isSelectable = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var identity: [NSView] = [title]
        let subtitle = info.summary ?? info.kind.title
        let summary = NSTextField(wrappingLabelWithString: subtitle)
        summary.font = .systemFont(ofSize: 13)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 2
        summary.lineBreakMode = .byTruncatingTail
        summary.isSelectable = true
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identity.append(summary)
        if info.summary != nil {
            let kind = NSTextField(labelWithString: info.kind.title)
            kind.font = .systemFont(ofSize: 11.5)
            kind.textColor = .tertiaryLabelColor
            identity.append(kind)
        }
        let text = NSStackView(views: identity)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [icon, text])
        top.alignment = .centerY
        top.spacing = 14

        var rows: [NSView] = [top]
        if !info.facts.isEmpty { rows.append(FactStrip(info.facts)) }
        if !info.dependencies.isEmpty { rows.append(PackageHeaderView.dependencies(info.dependencies, kind: info.kind)) }

        // Text keeps its natural width while there's room and only truncates when the pane is narrow.
        for label in [title, summary] { label.setContentCompressionResistancePriority(PackageHeaderView.resistance, for: .horizontal) }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let items = PackageHeaderView.menuItems(info)
        if !items.isEmpty { menu = .context(items) }
    }

    /// Copying without ⌘C (Quick Look sends keys to Finder): the name, version and dependencies.
    static func menuItems(_ info: PackageInfo) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let name = info.name { items.append(ActionMenuItem(String(localized: "Copy Name", bundle: .greeceKit)) { Clipboard.copy(name) }) }
        if let version = info.version {
            items.append(ActionMenuItem(String(localized: "Copy Version", bundle: .greeceKit)) { Clipboard.copy(version) })
        }
        if !info.dependencies.isEmpty {
            let title = info.kind == .apk || info.kind == .aab
                ? String(localized: "Copy Permissions", bundle: .greeceKit) : String(localized: "Copy Dependencies", bundle: .greeceKit)
            items.append(ActionMenuItem(title) { Clipboard.copy(info.dependencies.joined(separator: "\n")) })
        }
        if let homepage = info.homepage {
            items.append(ActionMenuItem(String(localized: "Copy Homepage", bundle: .greeceKit, comment: "Menu item: copies a package’s website address")) {
                Clipboard.copy(homepage)
            })
        }
        return items
    }

    /// Above the stack views' hugging, below required: labels stay whole unless space runs out.
    static let resistance = NSLayoutConstraint.Priority(740)

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    private static func title(_ info: PackageInfo) -> NSAttributedString {
        let result = NSMutableAttributedString(string: info.name ?? info.kind.title, attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        if let version = info.version {
            result.append(NSAttributedString(string: "  " + version, attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return result
    }

    private static func dependencies(_ items: [String], kind: PackageKind) -> NSView {
        let label = NSTextField(labelWithString: kind == .apk || kind == .aab
            ? String(localized: "Permissions", bundle: .greeceKit, comment: "Package fact label: what an app or extension is allowed to do")
            : String(localized: "Depends on", bundle: .greeceKit, comment: "Label before the list of packages a package needs"))
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        var shown = Array(items.prefix(40))
        if items.count > 40 {
            let more = items.count - 40
            shown.append(String(localized: "and \(more) more", bundle: .greeceKit, comment: "Ends a list that was cut short; the argument is how many items are left out"))
        }
        let list = NSTextField(wrappingLabelWithString: shown.joined(separator: "  ·  "))
        list.font = .systemFont(ofSize: 12)
        list.textColor = .secondaryLabelColor
        list.maximumNumberOfLines = 2
        list.lineBreakMode = .byTruncatingTail
        list.isSelectable = true
        list.toolTip = items.prefix(200).joined(separator: "\n")
        list.setContentCompressionResistancePriority(resistance - 20, for: .horizontal)
        let row = NSStackView(views: [label, list])
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }
}

/// Facts side by side: a small label over its value, divided by hairlines.
private final class FactStrip: NSStackView {
    init(_ facts: [(String, String)]) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 16
        for (index, fact) in facts.prefix(5).enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 30).isActive = true
                addArrangedSubview(line)
            }
            let label = NSTextField(labelWithString: fact.0.localizedUppercase)
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            let value = NSTextField(labelWithString: fact.1)
            value.font = .systemFont(ofSize: 13)
            value.textColor = .labelColor
            value.lineBreakMode = .byTruncatingTail
            value.isSelectable = true
            value.toolTip = fact.1
            // Later facts give way first when the preview is narrow.
            value.setContentCompressionResistancePriority(PackageHeaderView.resistance - Float(index), for: .horizontal)
            label.setContentCompressionResistancePriority(PackageHeaderView.resistance - Float(index) - 5, for: .horizontal)
            value.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
            let column = NSStackView(views: [label, value])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 3
            addArrangedSubview(column)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The package's own icon, or a tinted tile with a symbol for its kind, like System Settings' icons.
final class PackageIconView: NSView {
    private let image: NSImage?
    private let symbol: String
    private let tint: NSColor

    init(info: PackageInfo) {
        image = info.icon.flatMap(NSImage.init(data:))
        symbol = info.symbol
        tint = PackageIconView.tint(for: info.kind)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func tint(for kind: PackageKind) -> NSColor {
        switch kind {
        case .wheel, .sdist: return .systemBlue
        case .jar, .war, .ear: return .systemOrange
        case .apk, .aab: return .systemGreen
        case .nuget: return .systemPurple
        case .vsix: return .systemIndigo
        case .xpi: return .systemOrange
        case .crx: return .systemTeal
        case .gem, .rpm, .npm: return .systemRed
        case .deb: return .systemPink
        case .skill: return .systemBrown
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        PackageIconView.draw(image: image, symbol: symbol, tint: tint, in: bounds)
    }

    /// Shared with the Finder thumbnail.
    static func draw(image: NSImage?, symbol: String, tint: NSColor, in rect: CGRect) {
        let radius = rect.width * 0.225
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if let image {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let base = tint.usingColorSpace(.sRGB) ?? tint
        let top = base.blended(withFraction: 0.22, of: .white) ?? base
        NSGradient(starting: top, ending: base)?.draw(in: path, angle: -90)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: rect.width * 0.46, weight: .medium)) else { return }
        let tinted = NSImage(size: glyph.size, flipped: false) { bounds in
            glyph.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        tinted.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }
}
