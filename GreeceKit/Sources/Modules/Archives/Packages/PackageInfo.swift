import Foundation

/// What a software package says about itself: shown as a card above its file list, and as its
/// Finder thumbnail.
struct PackageInfo: Sendable {
    var kind: PackageKind
    var name: String?
    var version: String?
    /// One line: a wheel's Summary, a .deb's synopsis.
    var summary: String?
    /// Label and value pairs in display order ("Requires Python", "≥ 3.9").
    var facts: [(String, String)] = []
    /// Declared dependencies, as written ("requests>=2.31").
    var dependencies: [String] = []
    /// The package's own icon (PNG/JPEG/WebP bytes), when it ships one.
    var icon: Data?
    var homepage: String?

    init(kind: PackageKind, name: String? = nil, version: String? = nil, summary: String? = nil) {
        self.kind = kind
        self.name = name
        self.version = version
        self.summary = summary
    }

    /// An SF Symbol for the kind, used when the package has no icon of its own.
    var symbol: String {
        switch kind {
        case .wheel, .sdist: return "shippingbox"
        case .jar, .war, .ear: return "cup.and.saucer"
        case .apk, .aab: return "iphone.gen3"
        case .nuget: return "shippingbox"
        case .vsix: return "puzzlepiece.extension"
        case .xpi, .crx: return "puzzlepiece.extension"
        case .gem: return "diamond"
        case .deb, .rpm: return "terminal"
        case .npm: return "shippingbox"
        }
    }

    mutating func fact(_ label: String, _ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        facts.append((label, String(value.prefix(300))))
    }
}
