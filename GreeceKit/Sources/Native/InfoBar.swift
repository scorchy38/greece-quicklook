import AppKit

/// What the info bar says about a file.
public struct FileSummary: Equatable, Sendable {
    public var symbol: String
    public var title: String
    public var details: [String]
    public var trailing: String?

    public init(symbol: String, title: String, details: [String] = [], trailing: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.details = details
        self.trailing = trailing
    }
}

/// A slim, native footer: kind, key facts, and when the file last changed.
final class InfoBarView: NSView {
    static let height: CGFloat = 28

    private let effect = NSVisualEffectView()
    private let separator = NSBox()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    /// The file: its path as the tooltip, and the bar's menu acts on it.
    var fileURL: URL? {
        didSet { toolTip = fileURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } }
    }

    init(summary: FileSummary) {
        super.init(frame: .zero)

        effect.material = .titlebar
        effect.blendingMode = .withinWindow
        effect.state = .followsWindowActiveState
        separator.boxType = .separator

        let font = NSFont.systemFont(ofSize: 11.5)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = .labelColor
        details.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        details.textColor = .secondaryLabelColor
        trailing.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        trailing.textColor = .tertiaryLabelColor
        trailing.alignment = .right

        for label in [title, details, trailing] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
        }
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        details.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
        details.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let leading = NSStackView(views: [icon, title, details])
        leading.spacing = 6
        leading.setCustomSpacing(10, after: title)
        leading.alignment = .centerY

        for view in [effect, separator, leading, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 16),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
        ])
        configure(summary)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ summary: FileSummary) {
        icon.image = NSImage(systemSymbolName: summary.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        title.stringValue = summary.title
        details.stringValue = summary.details.joined(separator: "  ·  ")
        details.isHidden = summary.details.isEmpty
        trailing.stringValue = summary.trailing ?? ""
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(([summary.title] + summary.details + [summary.trailing].compactMap { $0 }).joined(separator: ", "))
    }

    /// The pointer's way to the file's whereabouts (Quick Look keeps ⌘C for Finder).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let url = fileURL else { return nil }
        return NSMenu.context([
            ActionMenuItem(String(localized: "Copy Path", bundle: .greeceKit)) { Clipboard.copy(url.path) },
            ActionMenuItem(String(localized: "Copy Name", bundle: .greeceKit)) { Clipboard.copy(url.lastPathComponent) },
            .separator(),
            ActionMenuItem(String(localized: "Show in Finder", bundle: .greeceKit)) { NSWorkspace.shared.activateFileViewerSelecting([url]) },
        ])
    }

    override func layout() {
        super.layout()
        // Narrow spaces (Finder's preview column) keep only what matters.
        trailing.isHidden = bounds.width < 460 || trailing.stringValue.isEmpty
    }
}
