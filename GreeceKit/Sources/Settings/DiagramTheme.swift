import Foundation

/// A Mermaid diagram theme: one of Mermaid's built-in themes, or a palette for its `base` theme,
/// each with a light and a dark variant. Pages read the result from CSS custom properties
/// (`--mm-*`), so appearance changes and live settings changes need no extra plumbing.
public struct DiagramTheme: Identifiable, Hashable, Sendable {

    /// The colours Mermaid's `base` theme derives everything else from.
    public struct Palette: Hashable, Sendable {
        public var background: String
        public var node: String
        public var nodeText: String
        public var border: String
        public var secondary: String
        public var tertiary: String
        public var line: String
        public var text: String
        public var note: String
        public var noteText: String

        public init(background: String, node: String, nodeText: String, border: String, secondary: String,
                    tertiary: String, line: String, text: String, note: String, noteText: String) {
            self.background = background
            self.node = node
            self.nodeText = nodeText
            self.border = border
            self.secondary = secondary
            self.tertiary = tertiary
            self.line = line
            self.text = text
            self.note = note
            self.noteText = noteText
        }

        var isDark: Bool { ThemeColor.luminance(background) < 0.18 }

        /// `themeVariables` for Mermaid, in a stable order.
        var variables: [(String, String)] {
            [
                ("background", background),
                ("primaryColor", node), ("primaryTextColor", nodeText), ("primaryBorderColor", border),
                ("secondaryColor", secondary), ("secondaryTextColor", nodeText),
                ("secondaryBorderColor", ThemeColor.mix(secondary, line, 0.45)),
                ("tertiaryColor", tertiary), ("tertiaryTextColor", nodeText),
                ("tertiaryBorderColor", ThemeColor.mix(tertiary, line, 0.35)),
                ("lineColor", line), ("textColor", text), ("titleColor", text),
                ("noteBkgColor", note), ("noteTextColor", noteText), ("noteBorderColor", ThemeColor.mix(note, line, 0.4)),
                ("edgeLabelBackground", background),
                ("clusterBkg", tertiary), ("clusterBorder", ThemeColor.mix(tertiary, line, 0.35)),
            ]
        }
    }

    public enum Style: Hashable, Sendable {
        /// Mermaid's own themes by name ("default", "neutral", "forest", "dark", "base").
        case builtIn(light: String, dark: String)
        /// A palette for the `base` theme. `card` paints the diagram's box in the palette's background.
        case palette(light: Palette, dark: Palette, card: Bool)
        /// Derived from the code theme.
        case matchCode
        /// Derived from the Markdown reading theme.
        case matchReading
    }

    public let id: String
    public let name: String
    public let style: Style

    public static let `default` = greece

    public static func named(_ id: String) -> DiagramTheme? { all.first { $0.id == id } }

    /// Palettes as drawn for each appearance (light, dark); built-ins approximate Mermaid's own.
    public func palettes(code: CodeTheme, reading: ReadingTheme) -> (light: Palette, dark: Palette) {
        switch style {
        case .palette(let light, let dark, _): return (light, dark)
        case .matchCode: return (DiagramTheme.derived(from: code.light), DiagramTheme.derived(from: code.dark))
        case .matchReading: return (DiagramTheme.derived(from: reading.light), DiagramTheme.derived(from: reading.dark))
        case .builtIn(let light, let dark): return (DiagramTheme.approximation(light), DiagramTheme.approximation(dark))
        }
    }

    // MARK: - CSS

    public func css(code: CodeTheme, reading: ReadingTheme) -> String {
        func block(_ palette: Palette, card: Bool) -> String {
            var out = "--mm-theme:base;--mm-dark:\(palette.isDark ? 1 : 0);"
            out += "--mm-keys:\(palette.variables.map(\.0).joined(separator: " "));"
            for (key, value) in palette.variables { out += "--mm-\(key):\(value);" }
            out += "--mm-block:\(card ? palette.background : "var(--fill)");"
            return out
        }
        func builtIn(_ name: String, appearanceIsDark: Bool) -> String {
            // A dark theme on a light page (or the reverse) gets a card in its own tone.
            let themeIsDark = name == "dark"
            let card = themeIsDark == appearanceIsDark ? "var(--fill)" : (themeIsDark ? "#1F2020" : "#FFFFFF")
            return "--mm-theme:\(name);--mm-dark:\(themeIsDark ? 1 : 0);--mm-keys:none;--mm-block:\(card);"
        }
        let light: String
        let dark: String
        switch style {
        case .builtIn(let l, let d):
            light = builtIn(l, appearanceIsDark: false)
            dark = builtIn(d, appearanceIsDark: true)
        case .palette(let l, let d, let card):
            light = block(l, card: card)
            dark = block(d, card: card)
        case .matchCode, .matchReading:
            let pair = palettes(code: code, reading: reading)
            light = block(pair.light, card: true)
            dark = block(pair.dark, card: true)
        }
        return ":root{\(light)}\n@media (prefers-color-scheme: dark){:root{\(dark)}}"
    }

    // MARK: - Derived palettes

    static func derived(from p: CodeTheme.Palette) -> Palette {
        Palette(background: p.background, node: ThemeColor.mix(p.background, p.function, 0.16), nodeText: p.foreground,
                border: p.function, secondary: ThemeColor.mix(p.background, p.string, 0.16),
                tertiary: ThemeColor.mix(p.background, p.foreground, 0.04), line: ThemeColor.mix(p.foreground, p.background, 0.35),
                text: p.foreground, note: ThemeColor.mix(p.background, p.type, 0.18), noteText: p.foreground)
    }

    static func derived(from p: ReadingTheme.Palette) -> Palette {
        Palette(background: p.page, node: ThemeColor.mix(p.page, p.accent, 0.12), nodeText: p.text,
                border: p.accent, secondary: ThemeColor.mix(p.page, p.heading, 0.08),
                tertiary: ThemeColor.mix(p.page, p.text, 0.03), line: p.secondary,
                text: p.text, note: ThemeColor.mix(p.page, p.accent, 0.06), noteText: p.text)
    }

    /// Close enough to Mermaid's built-in themes for Settings' swatches.
    static func approximation(_ name: String) -> Palette {
        switch name {
        case "dark":
            return Palette(background: "#1F2020", node: "#1F2020", nodeText: "#CCCCCC", border: "#CCCCCC", secondary: "#3A3A3A",
                           tertiary: "#2B2B2B", line: "#D3D3D3", text: "#CCCCCC", note: "#585858", noteText: "#CCCCCC")
        case "forest":
            return Palette(background: "#FFFFFF", node: "#CDE498", nodeText: "#1A1A1A", border: "#13540C", secondary: "#CDFFB2",
                           tertiary: "#F4F4F4", line: "#008000", text: "#1A1A1A", note: "#FFF5AD", noteText: "#1A1A1A")
        case "neutral":
            return Palette(background: "#FFFFFF", node: "#EEEEEE", nodeText: "#1A1A1A", border: "#999999", secondary: "#F4F4F4",
                           tertiary: "#FAFAFA", line: "#666666", text: "#1A1A1A", note: "#FFF5AD", noteText: "#1A1A1A")
        case "base":
            return Palette(background: "#FFFFFF", node: "#FFF4DD", nodeText: "#333333", border: "#C2A86B", secondary: "#FFFFDE",
                           tertiary: "#F4F4F4", line: "#333333", text: "#333333", note: "#FFF5AD", noteText: "#333333")
        default:
            return Palette(background: "#FFFFFF", node: "#ECECFF", nodeText: "#333333", border: "#9370DB", secondary: "#FFFFDE",
                           tertiary: "#F4F4F4", line: "#333333", text: "#333333", note: "#FFF5AD", noteText: "#333333")
        }
    }

    // MARK: - Catalog

    public static let all: [DiagramTheme] = [
        greece, matchCode, matchReading,
        mermaid, neutral, forest, dark, base,
        github, nord, solarized, dracula, catppuccin, tokyoNight, rosePine, gruvbox, one,
        blueprint, monochrome, pastel, sepia,
    ]

    /// Built-in themes and the ones derived from other settings, shown first in Settings.
    public var isAutomatic: Bool {
        switch style {
        case .matchCode, .matchReading: return true
        default: return id == "greece"
        }
    }

    public var isBuiltIn: Bool { if case .builtIn = style { return true } else { return false } }

    private static func p(_ background: String, _ node: String, _ nodeText: String, _ border: String, _ secondary: String,
                          _ tertiary: String, _ line: String, _ text: String, _ note: String, _ noteText: String) -> Palette {
        Palette(background: background, node: node, nodeText: nodeText, border: border, secondary: secondary,
                tertiary: tertiary, line: line, text: text, note: note, noteText: noteText)
    }

    public static let greece = DiagramTheme(id: "greece", name: "Greece", style: .palette(
        light: p("#FFFFFF", "#FFFFFF", "#1D1D1F", "#B9B9BF", "#E8F1FD", "#F7F7F8", "#8A8A8F", "#3A3A3C", "#FFF6D9", "#3D3315"),
        dark: p("#1E1E1E", "#2C2C2E", "#F5F5F7", "#5A5A5F", "#1E3350", "#262628", "#8E8E93", "#D1D1D6", "#3A3321", "#F5ECD0"),
        card: false))

    public static let matchCode = DiagramTheme(id: "match-code", name: "Match Code Theme", style: .matchCode)
    public static let matchReading = DiagramTheme(id: "match-reading", name: "Match Reading Theme", style: .matchReading)

    public static let mermaid = DiagramTheme(id: "mermaid", name: "Mermaid", style: .builtIn(light: "default", dark: "dark"))
    public static let neutral = DiagramTheme(id: "neutral", name: "Neutral", style: .builtIn(light: "neutral", dark: "dark"))
    public static let forest = DiagramTheme(id: "forest", name: "Forest", style: .builtIn(light: "forest", dark: "forest"))
    public static let dark = DiagramTheme(id: "dark", name: "Dark", style: .builtIn(light: "dark", dark: "dark"))
    public static let base = DiagramTheme(id: "base", name: "Base", style: .builtIn(light: "base", dark: "base"))

    public static let github = DiagramTheme(id: "github", name: "GitHub", style: .palette(
        light: p("#FFFFFF", "#DDF4FF", "#1F2328", "#54AEFF", "#FFF8C5", "#F6F8FA", "#59636E", "#1F2328", "#FFF8C5", "#1F2328"),
        dark: p("#0D1117", "#121D2F", "#F0F6FC", "#1F6FEB", "#272115", "#151B23", "#9198A1", "#F0F6FC", "#272115", "#F0F6FC"),
        card: true))

    public static let nord = DiagramTheme(id: "nord", name: "Nord", style: .palette(
        light: p("#ECEFF4", "#E5E9F0", "#2E3440", "#5E81AC", "#D8DEE9", "#F3F5F8", "#4C566A", "#2E3440", "#F2E5C6", "#2E3440"),
        dark: p("#2E3440", "#3B4252", "#ECEFF4", "#88C0D0", "#434C5E", "#353C4A", "#D8DEE9", "#ECEFF4", "#4C566A", "#EBCB8B"),
        card: true))

    public static let solarized = DiagramTheme(id: "solarized", name: "Solarized", style: .palette(
        light: p("#FDF6E3", "#EEE8D5", "#073642", "#268BD2", "#F5E9C9", "#FBF3DE", "#657B83", "#586E75", "#F5E4B8", "#073642"),
        dark: p("#002B36", "#073642", "#EEE8D5", "#268BD2", "#0B4352", "#03303C", "#93A1A1", "#93A1A1", "#3B3A1C", "#EEE8D5"),
        card: true))

    public static let dracula = DiagramTheme(id: "dracula", name: "Dracula", style: .palette(
        light: p("#FFFBEB", "#EDE8FF", "#1F1F1F", "#644AC9", "#E3F1F6", "#F7F2DC", "#6C664B", "#1F1F1F", "#FBF0C2", "#1F1F1F"),
        dark: p("#282A36", "#44475A", "#F8F8F2", "#BD93F9", "#383A59", "#30323F", "#BFC3D9", "#F8F8F2", "#3E3F4F", "#F1FA8C"),
        card: true))

    public static let catppuccin = DiagramTheme(id: "catppuccin", name: "Catppuccin", style: .palette(
        light: p("#EFF1F5", "#E6E9EF", "#4C4F69", "#8839EF", "#DCE0E8", "#F5F6F9", "#7C7F93", "#4C4F69", "#F4E5CB", "#4C4F69"),
        dark: p("#1E1E2E", "#313244", "#CDD6F4", "#CBA6F7", "#45475A", "#181825", "#9399B2", "#CDD6F4", "#3A3846", "#F9E2AF"),
        card: true))

    public static let tokyoNight = DiagramTheme(id: "tokyo-night", name: "Tokyo Night", style: .palette(
        light: p("#E1E2E7", "#D7DBE8", "#2D4F9E", "#2E7DE9", "#D2D6E4", "#E9E9ED", "#6172B0", "#2D4F9E", "#ECE4D2", "#2D4F9E"),
        dark: p("#1A1B26", "#24283B", "#C0CAF5", "#7AA2F7", "#292E42", "#16161E", "#A9B1D6", "#C0CAF5", "#2F2B2A", "#E0AF68"),
        card: true))

    public static let rosePine = DiagramTheme(id: "rose-pine", name: "Rosé Pine", style: .palette(
        light: p("#FAF4ED", "#F2E9E1", "#575279", "#907AA9", "#FFFAF3", "#F4EDE8", "#797593", "#575279", "#F7E6D0", "#575279"),
        dark: p("#191724", "#26233A", "#E0DEF4", "#C4A7E7", "#1F1D2E", "#21202E", "#908CAA", "#E0DEF4", "#2C2836", "#F6C177"),
        card: true))

    public static let gruvbox = DiagramTheme(id: "gruvbox", name: "Gruvbox", style: .palette(
        light: p("#FBF1C7", "#EBDBB2", "#3C3836", "#458588", "#F2E5BC", "#F9F5D7", "#665C54", "#3C3836", "#F6DD95", "#3C3836"),
        dark: p("#282828", "#3C3836", "#EBDBB2", "#83A598", "#32302F", "#1D2021", "#A89984", "#EBDBB2", "#504945", "#FABD2F"),
        card: true))

    public static let one = DiagramTheme(id: "one", name: "One", style: .palette(
        light: p("#FAFAFA", "#E9ECF5", "#383A42", "#4078F2", "#F0F0F1", "#FFFFFF", "#696C77", "#383A42", "#F6EBCB", "#383A42"),
        dark: p("#282C34", "#323A49", "#ABB2BF", "#61AFEF", "#2C313A", "#21252B", "#9DA5B4", "#ABB2BF", "#3E4451", "#E5C07B"),
        card: true))

    public static let blueprint = DiagramTheme(id: "blueprint", name: "Blueprint", style: .palette(
        light: p("#EAF2FB", "#FFFFFF", "#0B3A6F", "#1F5FA8", "#DCE9F8", "#F4F8FD", "#1F5FA8", "#0B3A6F", "#FFFFFF", "#0B3A6F"),
        dark: p("#0E2A4A", "#133A66", "#E8F1FC", "#9CC3F0", "#10345C", "#0B2440", "#9CC3F0", "#E8F1FC", "#133A66", "#E8F1FC"),
        card: true))

    public static let monochrome = DiagramTheme(id: "monochrome", name: "Monochrome", style: .palette(
        light: p("#FFFFFF", "#FFFFFF", "#111111", "#111111", "#F2F2F2", "#FAFAFA", "#333333", "#111111", "#F2F2F2", "#111111"),
        dark: p("#161616", "#161616", "#EDEDED", "#EDEDED", "#262626", "#1E1E1E", "#CFCFCF", "#EDEDED", "#262626", "#EDEDED"),
        card: false))

    public static let pastel = DiagramTheme(id: "pastel", name: "Pastel", style: .palette(
        light: p("#FFFFFF", "#E3F0FF", "#2E3440", "#8DB4E8", "#FFE9E3", "#EAF7EA", "#7A869A", "#2E3440", "#FFF6D6", "#4A4030"),
        dark: p("#1E1F24", "#2A3550", "#E6E8EE", "#7FA6DE", "#4A3330", "#2B3D2E", "#A3ACBD", "#E6E8EE", "#3E3826", "#F2E6C2"),
        card: false))

    public static let sepia = DiagramTheme(id: "sepia", name: "Sepia", style: .palette(
        light: p("#F5EDDA", "#EFE3C8", "#3A2E1F", "#8A6A3C", "#E8D9B8", "#F9F3E6", "#6B5840", "#3A2E1F", "#EAD7AE", "#3A2E1F"),
        dark: p("#1E1913", "#2B241B", "#DDCEB3", "#B08A55", "#332A1F", "#241E17", "#AA9A7F", "#DDCEB3", "#3A3022", "#EBD9B4"),
        card: true))
}
