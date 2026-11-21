import AppKit

/// Everything an inspector shows about an app, installer, binary or profile: a header, status badges,
/// grouped sections in the style of System Settings, an optional file listing, and slow checks that
/// fill in after the first paint. Pure data: built off the main thread, rendered by `InspectorView`.
struct InspectorPage {
    var header: InspectorHeader
    var badges: [InspectorBadge] = []
    var sections: [InspectorSection] = []
    /// A second tab listing the files inside (bundle contents, payloads, archive members, torrent files).
    var contents: InspectorContents?
    /// The info bar.
    var summary: FileSummary
    /// Work too slow for first paint (deep signature validation). Each replaces a `.pending` row.
    var checks: [InspectorCheck] = []

    func section(_ id: String) -> InspectorSection? { sections.first { $0.id == id } }
    var allRows: [InspectorRow] { sections.flatMap(\.rows) }
}

struct InspectorHeader {
    var icon: InspectorIcon
    var title: String
    /// "Version 2.1 (214)".
    var subtitle: String?
    /// A bundle or package identifier, shown monospaced and selectable.
    var identifier: String?
}

enum InspectorIcon {
    /// Finder's icon for a file or bundle on disk.
    case file(URL)
    /// A decoded icon (from an .ipa, .apk or .exe).
    case image(NSImage, shape: IconShape)
    /// The system icon for a content type, e.g. "com.apple.installer-package-archive".
    case contentType(String)
    /// An SF Symbol on a tinted rounded square.
    case symbol(String, InspectorTint)

    enum IconShape { case asIs, iOS, rounded }
}

/// Status colours: what a badge or value means.
enum InspectorTone: Equatable {
    case neutral, positive, accent, caution, critical
}

/// Decorative colours for row icons, like the tiles in System Settings.
enum InspectorTint: String, CaseIterable {
    case blue, green, orange, red, purple, pink, teal, indigo, yellow, gray, brown, mint, cyan
}

struct InspectorBadge: Equatable {
    /// Lets a check replace a provisional badge (e.g. "notarization" once the ticket is read).
    var id: String
    var symbol: String
    var title: String
    var tone: InspectorTone
    /// Tooltip: what this means, in a sentence.
    var help: String?

    init(_ id: String, symbol: String, title: String, tone: InspectorTone = .neutral, help: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.tone = tone
        self.help = help
    }
}

struct InspectorSection {
    var id: String
    var title: String?
    var footer: String?
    var rows: [InspectorRow]
    /// Long lists show this many rows and a "Show All" button.
    var visibleLimit: Int?

    init(_ id: String, title: String?, footer: String? = nil, rows: [InspectorRow], visibleLimit: Int? = nil) {
        self.id = id
        self.title = title
        self.footer = footer
        self.rows = rows
        self.visibleLimit = visibleLimit
    }
}

enum InspectorRow {
    case item(InspectorItem)
    /// A script or document, collapsed behind a disclosure, highlighted when expanded.
    case code(InspectorCode)
    /// A stacked bar of sizes with a legend, like Storage in System Settings.
    case sizes(InspectorSizes)
    /// A callout: a warning or an explanation.
    case note(InspectorNote)
    /// A placeholder with a spinner, replaced by the matching `InspectorCheck`.
    case pending(id: String, title: String)

    var item: InspectorItem? { if case .item(let item) = self { return item } else { return nil } }
}

struct InspectorItem {
    var symbol: String?
    /// Set: a white glyph on a tinted rounded square. Nil: a plain secondary glyph.
    var tint: InspectorTint?
    var title: String
    /// A second line: a usage string, an explanation, a list of values.
    var subtitle: String?
    /// Trailing text.
    var value: String?
    var tone: InspectorTone = .neutral
    /// Tooltip: the raw key or technical detail behind a friendly title.
    var help: String?
    /// Monospaced, selectable value (identifiers, hashes, paths); a monospaced title when there's no value.
    var mono = false
    /// A status glyph shown before the value, in the tone's colour ("checkmark.seal.fill").
    var valueSymbol: String?
    /// Expands to show these rows (certificate details, per-architecture facts).
    var details: [InspectorItem] = []

    init(symbol: String? = nil, tint: InspectorTint? = nil, title: String, subtitle: String? = nil, value: String? = nil,
         tone: InspectorTone = .neutral, help: String? = nil, mono: Bool = false, valueSymbol: String? = nil, details: [InspectorItem] = []) {
        self.valueSymbol = valueSymbol
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.tone = tone
        self.help = help
        self.mono = mono
        self.details = details
    }

    /// A plain label and value, like LabeledContent.
    static func field(_ title: String, _ value: String?, mono: Bool = false, tone: InspectorTone = .neutral, help: String? = nil) -> InspectorItem {
        InspectorItem(title: title, value: value, tone: tone, help: help, mono: mono)
    }
}

struct InspectorCode {
    var symbol: String = "terminal"
    var title: String
    var subtitle: String?
    var text: String
    /// highlight.js grammar ("bash", "javascript", "xml").
    var grammar: String
    var tone: InspectorTone = .neutral
    var truncated = false
}

struct InspectorSizes {
    struct Segment {
        var title: String
        var bytes: UInt64
        var tint: InspectorTint
        var detail: String?
    }
    var total: UInt64
    var segments: [Segment]
}

struct InspectorNote {
    var symbol: String?
    var text: String
    var tone: InspectorTone
}

enum InspectorContents {
    /// A file tree with a tab title ("Files", "Contents", "Payload").
    case tree(FileNode, title: String, count: Int?)
}

struct InspectorCheck {
    /// The `.pending` row this check replaces.
    let id: String
    /// Runs off the main thread, once, after first paint.
    let run: () -> InspectorCheckResult
}

struct InspectorCheckResult {
    var rows: [InspectorRow] = []
    /// Added to the header, replacing any badge with the same id.
    var badges: [InspectorBadge] = []
    /// Badge ids to remove.
    var removeBadges: [String] = []
}

extension Array where Element == InspectorRow {
    static func items(_ items: [InspectorItem]) -> [InspectorRow] { items.map { .item($0) } }
}
