import Foundation

/// A Markdown reading theme: typefaces and a light and a dark palette. Colours are generated here
/// (so Settings, thumbnails and tests share them); each theme's typographic details live in
/// `Web/themes/reading.css`, under `html.reading.rt-<id>`.
public struct ReadingTheme: Identifiable, Hashable, Sendable {

    public struct Palette: Hashable, Sendable {
        public var page: String
        public var text: String
        /// Quotes, captions, secondary text.
        public var secondary: String
        /// Markers, rules and other quiet details (not body text).
        public var tertiary: String
        public var heading: String
        /// Links.
        public var accent: String

        public init(page: String, text: String, secondary: String, tertiary: String, heading: String, accent: String) {
            self.page = page
            self.text = text
            self.secondary = secondary
            self.tertiary = tertiary
            self.heading = heading
            self.accent = accent
        }
    }

    /// A typeface for Settings' page previews: a system design or an installed family.
    public enum Face: Hashable, Sendable {
        case system, serif, mono, rounded
        case family(String)
    }

    public let id: String
    public let name: String
    /// A few words about the theme for Settings.
    public let summary: String
    public let light: Palette
    public let dark: Palette
    /// CSS font stacks.
    public let bodyFont: String
    public let headingFont: String
    /// The faces Settings uses to draw the theme's page preview.
    public let bodyFace: Face
    public let headingFace: Face
    /// Uses macOS's own semantic colours and the person's accent colour instead of its palette.
    public var isNative = false

    public static let `default` = greece

    public static func named(_ id: String) -> ReadingTheme? { all.first { $0.id == id } }

    public func palette(dark isDark: Bool) -> Palette { isDark ? dark : light }

    // MARK: - CSS

    /// Colour variables for reading pages, both appearances. Empty for the native theme.
    public var css: String {
        guard !isNative else { return "" }
        func block(_ p: Palette) -> String {
            """
            --page:\(p.page);--text:\(p.text);--text-2:\(p.secondary);--text-3:\(p.tertiary);--heading:\(p.heading);\
            --accent:\(p.accent);--hairline:color-mix(in srgb,\(p.text) 13%,transparent);\
            --hairline-strong:color-mix(in srgb,\(p.text) 21%,transparent);\
            --fill:color-mix(in srgb,\(p.text) 4.5%,transparent);--fill-2:color-mix(in srgb,\(p.text) 8%,transparent);
            """
        }
        return "html.reading{\(block(light))}\n@media (prefers-color-scheme: dark){html.reading{\(block(dark))}}"
    }

    // MARK: - Catalog

    private static let systemStack = "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif"
    private static let monoStack = "ui-monospace, 'SF Mono', Menlo, monospace"

    public static let all: [ReadingTheme] = [
        greece, github, docs, notes, newsprint, academic, paper, story, writer, graphite,
        whitey, gothic, pixyll, solarized, nord, dracula, terminal,
    ]

    public static let greece = ReadingTheme(
        id: "greece", name: "Greece",
        summary: String(localized: "Native, follows your accent colour", bundle: .greeceKit, comment: "Summary of the Greece reading theme, in Settings"),
        light: Palette(page: "#FFFFFF", text: "#1D1D1F", secondary: "#6E6E73", tertiary: "#AEAEB2", heading: "#1D1D1F", accent: "#0066CC"),
        dark: Palette(page: "#1E1E1E", text: "#F5F5F7", secondary: "#A1A1A6", tertiary: "#636366", heading: "#F5F5F7", accent: "#3F9BFF"),
        bodyFont: systemStack, headingFont: systemStack, bodyFace: .system, headingFace: .system, isNative: true)

    public static let github = ReadingTheme(
        id: "github", name: "GitHub",
        summary: String(localized: "READMEs as GitHub shows them", bundle: .greeceKit, comment: "Summary of the GitHub reading theme, in Settings"),
        light: Palette(page: "#FFFFFF", text: "#1F2328", secondary: "#59636E", tertiary: "#9AA3AD", heading: "#1F2328", accent: "#0969DA"),
        dark: Palette(page: "#0D1117", text: "#F0F6FC", secondary: "#9198A1", tertiary: "#5A626C", heading: "#F0F6FC", accent: "#4493F8"),
        bodyFont: "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif",
        headingFont: "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif",
        bodyFace: .system, headingFace: .system)

    public static let docs = ReadingTheme(
        id: "docs", name: String(localized: "Docs", bundle: .greeceKit, comment: "Reading theme name: styled like documentation"),
        summary: String(localized: "Like Apple’s developer documentation", bundle: .greeceKit, comment: "Summary of the Docs reading theme, in Settings"),
        light: Palette(page: "#FFFFFF", text: "#1D1D1F", secondary: "#6E6E73", tertiary: "#B0B0B5", heading: "#1D1D1F", accent: "#0066CC"),
        dark: Palette(page: "#000000", text: "#F5F5F7", secondary: "#A1A1A6", tertiary: "#5B5B60", heading: "#F5F5F7", accent: "#2997FF"),
        bodyFont: "-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif",
        headingFont: "-apple-system, 'SF Pro Display', 'Helvetica Neue', sans-serif",
        bodyFace: .system, headingFace: .system)

    public static let notes = ReadingTheme(
        id: "notes", name: String(localized: "Notes", bundle: .greeceKit, comment: "Reading theme name, after Apple’s Notes app"),
        summary: String(localized: "Clean and friendly, like Notes", bundle: .greeceKit, comment: "Summary of the Notes reading theme, in Settings. “Notes” is Apple’s app"),
        light: Palette(page: "#FFFFFF", text: "#1C1C1E", secondary: "#6C6C70", tertiary: "#B4B4B8", heading: "#1C1C1E", accent: "#966200"),
        dark: Palette(page: "#1C1C1E", text: "#F2F2F7", secondary: "#AEAEB2", tertiary: "#5C5C61", heading: "#F2F2F7", accent: "#FFD60A"),
        bodyFont: systemStack, headingFont: systemStack, bodyFace: .system, headingFace: .system)

    public static let newsprint = ReadingTheme(
        id: "newsprint", name: String(localized: "Newsprint", bundle: .greeceKit, comment: "Reading theme name: like a newspaper"),
        summary: String(localized: "Editorial serif on newsprint", bundle: .greeceKit, comment: "Summary of the Newsprint reading theme, in Settings"),
        light: Palette(page: "#F4F1EA", text: "#1F1D1A", secondary: "#5A544C", tertiary: "#A59F95", heading: "#111111", accent: "#8E2B14"),
        dark: Palette(page: "#1B1A18", text: "#E8E3D9", secondary: "#ABA499", tertiary: "#5F5A52", heading: "#F6F2EA", accent: "#EE8C70"),
        bodyFont: "'PT Serif', Charter, Georgia, serif", headingFont: "'PT Serif', Charter, Georgia, serif",
        bodyFace: .family("PT Serif"), headingFace: .family("PT Serif"))

    public static let academic = ReadingTheme(
        id: "academic", name: String(localized: "Academic", bundle: .greeceKit, comment: "Reading theme name: like a scientific paper"),
        summary: String(localized: "LaTeX paper with numbered sections", bundle: .greeceKit, comment: "Summary of the Academic reading theme, in Settings"),
        light: Palette(page: "#FFFFFF", text: "#141414", secondary: "#474747", tertiary: "#9C9C9C", heading: "#000000", accent: "#1B4E91"),
        dark: Palette(page: "#1A1B1D", text: "#E5E5E2", secondary: "#ABABA7", tertiary: "#62625F", heading: "#F5F5F2", accent: "#93BBF4"),
        bodyFont: "'Latin Modern Roman', 'CMU Serif', 'STIX Two Text', 'Times New Roman', serif",
        headingFont: "'Latin Modern Roman', 'CMU Serif', 'STIX Two Text', 'Times New Roman', serif",
        bodyFace: .family("STIX Two Text"), headingFace: .family("STIX Two Text"))

    public static let paper = ReadingTheme(
        id: "paper", name: String(localized: "Paper", bundle: .greeceKit, comment: "Reading theme name: like a printed page"),
        summary: String(localized: "Warm sepia, like a well-read book", bundle: .greeceKit, comment: "Summary of the Paper reading theme, in Settings"),
        light: Palette(page: "#F5EDDA", text: "#3A2E1F", secondary: "#665640", tertiary: "#AE9D80", heading: "#2A2016", accent: "#8A4A12"),
        dark: Palette(page: "#1E1913", text: "#DDCEB3", secondary: "#AA9A7F", tertiary: "#62574A", heading: "#F0E4CD", accent: "#E5A766"),
        bodyFont: "'Iowan Old Style', Palatino, 'Book Antiqua', Georgia, serif",
        headingFont: "'Iowan Old Style', Palatino, 'Book Antiqua', Georgia, serif",
        bodyFace: .family("Palatino"), headingFace: .family("Palatino"))

    public static let story = ReadingTheme(
        id: "story", name: String(localized: "Story", bundle: .greeceKit, comment: "Reading theme name: for long articles"),
        summary: String(localized: "Long reads in Charter", bundle: .greeceKit, comment: "Summary of the Story reading theme, in Settings. Charter is a typeface"),
        light: Palette(page: "#FFFFFF", text: "#242424", secondary: "#6B6B6B", tertiary: "#B3B3B3", heading: "#242424", accent: "#167A14"),
        dark: Palette(page: "#121212", text: "#E6E6E6", secondary: "#A8A8A8", tertiary: "#575757", heading: "#F2F2F2", accent: "#62C660"),
        bodyFont: "Charter, 'Bitstream Charter', Georgia, serif",
        headingFont: "-apple-system, 'Helvetica Neue', sans-serif",
        bodyFace: .family("Charter"), headingFace: .system)

    public static let writer = ReadingTheme(
        id: "writer", name: String(localized: "Writer", bundle: .greeceKit, comment: "Reading theme name, after the iA Writer app"),
        summary: String(localized: "Focused monospace, like iA Writer", bundle: .greeceKit, comment: "Summary of the Writer reading theme, in Settings. iA Writer is an app"),
        light: Palette(page: "#FBFBFA", text: "#1E1E1E", secondary: "#5C5C5C", tertiary: "#B9B9B9", heading: "#111111", accent: "#1474B3"),
        dark: Palette(page: "#161616", text: "#D6D6D6", secondary: "#9C9C9C", tertiary: "#525252", heading: "#EDEDED", accent: "#45ABEF"),
        bodyFont: "'iA Writer Quattro S', 'iA Writer Quattro V', \(monoStack)",
        headingFont: "'iA Writer Quattro S', 'iA Writer Quattro V', \(monoStack)",
        bodyFace: .mono, headingFace: .mono)

    public static let graphite = ReadingTheme(
        id: "graphite", name: String(localized: "Graphite", bundle: .greeceKit, comment: "Reading theme name, after Bear’s Graphite theme"),
        summary: String(localized: "Warm Avenir with red accents, like Bear", bundle: .greeceKit,
                        comment: "Summary of the Graphite reading theme, in Settings. Avenir is a typeface, Bear an app"),
        light: Palette(page: "#FFFEFC", text: "#3F3F3F", secondary: "#6C6C6C", tertiary: "#B9B7B3", heading: "#262626", accent: "#C4363B"),
        dark: Palette(page: "#27292C", text: "#DCDCDC", secondary: "#A3A3A3", tertiary: "#5D6065", heading: "#F0F0F0", accent: "#F27377"),
        bodyFont: "'Avenir Next', Avenir, -apple-system, sans-serif", headingFont: "'Avenir Next', Avenir, -apple-system, sans-serif",
        bodyFace: .family("Avenir Next"), headingFace: .family("Avenir Next"))

    public static let whitey = ReadingTheme(
        id: "whitey", name: "Whitey",
        summary: String(localized: "Typora’s Whitey by day, Night after dark", bundle: .greeceKit,
                        comment: "Summary of the Whitey reading theme, in Settings. Typora is an app; Whitey and Night are its themes"),
        light: Palette(page: "#FFFFFF", text: "#333333", secondary: "#666666", tertiary: "#B0B0B0", heading: "#222222", accent: "#3470AE"),
        dark: Palette(page: "#363B40", text: "#C3C9CF", secondary: "#A4ABB2", tertiary: "#6C747C", heading: "#E8E8E8", accent: "#9CC8F5"),
        bodyFont: "Vollkorn, 'Hoefler Text', Palatino, Georgia, serif", headingFont: "Vollkorn, 'Hoefler Text', Palatino, Georgia, serif",
        bodyFace: .family("Hoefler Text"), headingFace: .family("Hoefler Text"))

    public static let gothic = ReadingTheme(
        id: "gothic", name: String(localized: "Gothic", bundle: .greeceKit, comment: "Reading theme name: geometric sans-serif type, as in Century Gothic"),
        summary: String(localized: "Geometric sans throughout", bundle: .greeceKit, comment: "Summary of the Gothic reading theme, in Settings: sans-serif type everywhere"),
        light: Palette(page: "#FFFFFF", text: "#303030", secondary: "#5E5E5E", tertiary: "#ABABAB", heading: "#151515", accent: "#2A69B0"),
        dark: Palette(page: "#212121", text: "#D8D8D8", secondary: "#A4A4A4", tertiary: "#5A5A5A", heading: "#F4F4F4", accent: "#80B5F0"),
        bodyFont: "'TeXGyreAdventor', 'Century Gothic', Futura, 'Avenir Next', sans-serif",
        headingFont: "'TeXGyreAdventor', 'Century Gothic', Futura, 'Avenir Next', sans-serif",
        bodyFace: .family("Futura"), headingFace: .family("Futura"))

    public static let pixyll = ReadingTheme(
        id: "pixyll", name: "Pixyll",
        summary: String(localized: "Sturdy serif text, airy sans headings", bundle: .greeceKit, comment: "Summary of the Pixyll reading theme, in Settings"),
        light: Palette(page: "#FFFFFF", text: "#333333", secondary: "#5D656F", tertiary: "#A9B0B8", heading: "#222222", accent: "#0070D6"),
        dark: Palette(page: "#1C1E22", text: "#D3D5D9", secondary: "#9FA4AB", tertiary: "#585D64", heading: "#F1F2F4", accent: "#5EABFF"),
        bodyFont: "Merriweather, Georgia, Cambria, serif", headingFont: "Lato, 'Avenir Next', 'Helvetica Neue', sans-serif",
        bodyFace: .family("Georgia"), headingFace: .family("Avenir Next"))

    public static let solarized = ReadingTheme(
        id: "solarized", name: "Solarized",
        summary: String(localized: "Ethan Schoonover’s precision colours", bundle: .greeceKit, comment: "Summary of the Solarized reading theme, in Settings. Ethan Schoonover made it"),
        light: Palette(page: "#FDF6E3", text: "#586E75", secondary: "#5B7077", tertiary: "#93A1A1", heading: "#073642", accent: "#1F6FA8"),
        dark: Palette(page: "#002B36", text: "#93A1A1", secondary: "#8A9A9C", tertiary: "#586E75", heading: "#EEE8D5", accent: "#45A2E4"),
        bodyFont: systemStack, headingFont: systemStack, bodyFace: .system, headingFace: .system)

    public static let nord = ReadingTheme(
        id: "nord", name: "Nord",
        summary: String(localized: "Arctic, north-bluish calm", bundle: .greeceKit, comment: "Summary of the Nord reading theme, in Settings"),
        light: Palette(page: "#ECEFF4", text: "#2E3440", secondary: "#4C566A", tertiary: "#A3ACBC", heading: "#2E3440", accent: "#486793"),
        dark: Palette(page: "#2E3440", text: "#D8DEE9", secondary: "#AAB3C3", tertiary: "#616E88", heading: "#ECEFF4", accent: "#88C0D0"),
        bodyFont: systemStack, headingFont: systemStack, bodyFace: .system, headingFace: .system)

    public static let dracula = ReadingTheme(
        id: "dracula", name: "Dracula",
        summary: String(localized: "Dracula after dark, Alucard by day", bundle: .greeceKit,
                        comment: "Summary of the Dracula reading theme, in Settings. Dracula and Alucard are its dark and light versions"),
        light: Palette(page: "#FFFBEB", text: "#1F1F1F", secondary: "#5A5543", tertiary: "#A59D7C", heading: "#644AC9", accent: "#036A96"),
        dark: Palette(page: "#282A36", text: "#F8F8F2", secondary: "#BDC1D6", tertiary: "#6272A4", heading: "#BD93F9", accent: "#8BE9FD"),
        bodyFont: systemStack, headingFont: systemStack, bodyFace: .system, headingFace: .system)

    public static let terminal = ReadingTheme(
        id: "terminal", name: String(localized: "Terminal", bundle: .greeceKit, comment: "Reading theme name: like a terminal window, all monospaced"),
        summary: String(localized: "Everything in SF Mono", bundle: .greeceKit, comment: "Summary of the Terminal reading theme, in Settings. SF Mono is a typeface"),
        light: Palette(page: "#F7F7F2", text: "#1B1B1B", secondary: "#555555", tertiary: "#A3A3A0", heading: "#0B0B0B", accent: "#0B6B4D"),
        dark: Palette(page: "#0D100E", text: "#C9D4C5", secondary: "#909C8C", tertiary: "#4D594C", heading: "#E8F5E4", accent: "#5FD787"),
        bodyFont: monoStack, headingFont: monoStack, bodyFace: .mono, headingFace: .mono)
}
