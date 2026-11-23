import Foundation

/// A syntax theme. Most come as a pair of a light and a dark palette and follow the Mac's
/// appearance (unless the person pins one variant); some were only ever designed light or dark.
/// The catalog itself lives in `CodeThemeCatalog.swift`.
public struct CodeTheme: Identifiable, Hashable, Sendable {

    /// Which appearances the original theme was designed for.
    public enum Variants: String, Sendable, CaseIterable {
        /// A light and a dark palette: follows the system appearance unless one is pinned.
        case pair
        /// Light only: stays light in Dark Mode.
        case light
        /// Dark only: stays dark in Light Mode.
        case dark
    }

    /// Colours for every token class Greece highlights, as `#RRGGBB`.
    public struct Palette: Hashable, Sendable {
        public var background: String
        public var foreground: String
        public var comment: String
        public var keyword: String
        public var string: String
        public var number: String
        public var function: String
        public var type: String
        public var tag: String
        public var attribute: String
        public var variable: String
        public var builtIn: String
        public var regexp: String
        public var meta: String
        public var added: String
        public var removed: String
        public var selection: String

        /// Every token colour that's drawn as text on the background, by name (comments excluded).
        public var tokens: [(name: String, color: String)] {
            [("keyword", keyword), ("string", string), ("number", number), ("function", function), ("type", type),
             ("tag", tag), ("attribute", attribute), ("variable", variable), ("builtIn", builtIn), ("regexp", regexp),
             ("meta", meta), ("added", added), ("removed", removed)]
        }

        /// Whether the page is dark (relative luminance below the midpoint of the contrast scale).
        public var isDark: Bool { ThemeColor.luminance(background) < 0.18 }
    }

    public let id: String
    public let name: String
    public let light: Palette
    public let dark: Palette
    /// Bold keywords, as Xcode does.
    public var boldKeywords: Bool
    /// Italic comments, as Monokai Pro, Night Owl and friends do.
    public var italicComments: Bool
    public var variants: Variants
    /// The original names of the variants ("Latte", "Mocha"), shown in Settings.
    public var lightName: String?
    public var darkName: String?
    /// Extra words that find the theme in search: family, author, variant names.
    public var keywords: String

    /// A pair of palettes that follows the system appearance.
    public init(id: String, name: String, light: Palette, dark: Palette, boldKeywords: Bool = false,
                italicComments: Bool = false, lightName: String? = nil, darkName: String? = nil, keywords: String = "") {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
        self.boldKeywords = boldKeywords
        self.italicComments = italicComments
        self.variants = .pair
        self.lightName = lightName
        self.darkName = darkName
        self.keywords = keywords
    }

    /// A theme with a single palette, light or dark, used whatever the appearance.
    public init(id: String, name: String, only palette: Palette, boldKeywords: Bool = false,
                italicComments: Bool = false, keywords: String = "") {
        self.init(id: id, name: name, light: palette, dark: palette, boldKeywords: boldKeywords,
                  italicComments: italicComments, keywords: keywords)
        self.variants = palette.isDark ? .dark : .light
    }

    public static func named(_ id: String) -> CodeTheme? { index[id] }

    public static let `default` = xcode

    private static let index: [String: CodeTheme] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// The themes in a gallery group, in catalog order.
    public static func group(_ variants: Variants) -> [CodeTheme] { all.filter { $0.variants == variants } }

    /// This theme with one variant used for both appearances. Single-palette themes are unchanged.
    public func pinned(_ variant: PreviewSettings.ThemeVariant) -> CodeTheme {
        guard variants == .pair, variant != .automatic else { return self }
        let palette = variant == .light ? light : dark
        var copy = CodeTheme(id: id, name: name, light: palette, dark: palette, boldKeywords: boldKeywords,
                             italicComments: italicComments, lightName: lightName, darkName: darkName, keywords: keywords)
        copy.variants = variants
        return copy
    }

    /// The palette shown for an appearance.
    public func palette(dark isDark: Bool) -> Palette { isDark ? dark : light }

    public func matches(_ query: String) -> Bool {
        let haystack = [name, lightName ?? "", darkName ?? "", keywords, variants.rawValue].joined(separator: " ")
        return query.split(separator: " ").allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - CSS

    /// CSS custom properties for both appearances. The page decides via `prefers-color-scheme`,
    /// which WebKit resolves from the hosting view's effective appearance.
    public var css: String {
        // Keywords sit one step above the code weight when a theme bolds them.
        let keywordWeight = boldKeywords ? "calc(var(--code-weight, 400) + 200)" : "var(--code-weight, 400)"
        func block(_ p: Palette) -> String {
            """
            --bg:\(p.background);--fg:\(p.foreground);--t-comment:\(p.comment);--t-keyword:\(p.keyword);\
            --t-string:\(p.string);--t-number:\(p.number);--t-function:\(p.function);--t-type:\(p.type);\
            --t-tag:\(p.tag);--t-attr:\(p.attribute);--t-variable:\(p.variable);--t-builtin:\(p.builtIn);\
            --t-regexp:\(p.regexp);--t-meta:\(p.meta);--t-added:\(p.added);--t-removed:\(p.removed);\
            --t-selection:\(p.selection);--t-keyword-weight:\(keywordWeight);
            """
        }
        var css = ":root{\(block(light))}"
        if dark != light { css += "\n@media (prefers-color-scheme: dark){:root{\(block(dark))}}" }
        if italicComments { css += "\n.hljs-comment,.hljs-quote{font-style:italic}" }
        return css
    }
}

/// Colour arithmetic for themes: parsing, WCAG luminance and contrast.
public enum ThemeColor {
    /// sRGB components 0…1 of `#RRGGBB` (or `RRGGBB`).
    public static func components(_ hex: String) -> (r: Double, g: Double, b: Double) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// WCAG 2 relative luminance.
    public static func luminance(_ hex: String) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = components(hex)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG 2 contrast ratio, 1…21.
    public static func contrast(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `#RRGGBB` for a mix of two colours (`amount` of `b`), in sRGB like CSS `color-mix`.
    public static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        let (x, y) = (components(a), components(b))
        func channel(_ p: Double, _ q: Double) -> Int { Int(((p * (1 - amount) + q * amount) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(x.r, y.r), channel(x.g, y.g), channel(x.b, y.b))
    }
}
