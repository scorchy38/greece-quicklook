import Foundation

/// A syntax theme with a light and a dark palette. Previews switch automatically
/// with the system appearance, so one choice looks right day and night.
public struct CodeTheme: Identifiable, Hashable, Sendable {

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
    }

    public let id: String
    public let name: String
    public let light: Palette
    public let dark: Palette
    /// Bold keywords, as Xcode does.
    public var boldKeywords = false

    public static func named(_ id: String) -> CodeTheme? { all.first { $0.id == id } }

    public static let `default` = xcode

    public static let all: [CodeTheme] = [xcode, github, one, catppuccin, tokyoNight, rosePine, solarized, gruvbox]

    // MARK: - Catalog

    public static let xcode = CodeTheme(
        id: "xcode", name: "Xcode",
        light: Palette(background: "#FFFFFF", foreground: "#262626", comment: "#5D6C79", keyword: "#9B2393",
                       string: "#C41A16", number: "#1C00CF", function: "#326D74", type: "#0B4F79",
                       tag: "#9B2393", attribute: "#815F03", variable: "#0F68A0", builtIn: "#6C36A9",
                       regexp: "#C41A16", meta: "#643820", added: "#1A7F37", removed: "#CF222E", selection: "#B4D8FD"),
        dark: Palette(background: "#1F1F24", foreground: "#DFDFE0", comment: "#7F8C98", keyword: "#FC5FA3",
                      string: "#FC6A5D", number: "#D0BF69", function: "#67B7A4", type: "#5DD8FF",
                      tag: "#FC5FA3", attribute: "#BF8555", variable: "#41A1C0", builtIn: "#D0A8FF",
                      regexp: "#FC6A5D", meta: "#FD8F3F", added: "#3FB950", removed: "#F85149", selection: "#515B70"),
        boldKeywords: true)

    public static let github = CodeTheme(
        id: "github", name: "GitHub",
        light: Palette(background: "#FFFFFF", foreground: "#1F2328", comment: "#59636E", keyword: "#CF222E",
                       string: "#0A3069", number: "#0550AE", function: "#6639BA", type: "#953800",
                       tag: "#116329", attribute: "#0550AE", variable: "#953800", builtIn: "#0550AE",
                       regexp: "#116329", meta: "#0550AE", added: "#1A7F37", removed: "#CF222E", selection: "#B6E3FF"),
        dark: Palette(background: "#0D1117", foreground: "#E6EDF3", comment: "#8B949E", keyword: "#FF7B72",
                      string: "#A5D6FF", number: "#79C0FF", function: "#D2A8FF", type: "#FFA657",
                      tag: "#7EE787", attribute: "#79C0FF", variable: "#FFA657", builtIn: "#79C0FF",
                      regexp: "#7EE787", meta: "#79C0FF", added: "#3FB950", removed: "#F85149", selection: "#264F78"))

    public static let one = CodeTheme(
        id: "one", name: "One",
        light: Palette(background: "#FAFAFA", foreground: "#383A42", comment: "#A0A1A7", keyword: "#A626A4",
                       string: "#50A14F", number: "#986801", function: "#4078F2", type: "#C18401",
                       tag: "#E45649", attribute: "#986801", variable: "#E45649", builtIn: "#C18401",
                       regexp: "#0184BC", meta: "#4078F2", added: "#50A14F", removed: "#E45649", selection: "#E5E5E6"),
        dark: Palette(background: "#282C34", foreground: "#ABB2BF", comment: "#7F848E", keyword: "#C678DD",
                      string: "#98C379", number: "#D19A66", function: "#61AFEF", type: "#E5C07B",
                      tag: "#E06C75", attribute: "#D19A66", variable: "#E06C75", builtIn: "#E5C07B",
                      regexp: "#56B6C2", meta: "#61AFEF", added: "#98C379", removed: "#E06C75", selection: "#3E4451"))

    public static let catppuccin = CodeTheme(
        id: "catppuccin", name: "Catppuccin",
        light: Palette(background: "#EFF1F5", foreground: "#4C4F69", comment: "#8C8FA1", keyword: "#8839EF",
                       string: "#40A02B", number: "#FE640B", function: "#1E66F5", type: "#DF8E1D",
                       tag: "#D20F39", attribute: "#DF8E1D", variable: "#E64553", builtIn: "#D20F39",
                       regexp: "#EA76CB", meta: "#179299", added: "#40A02B", removed: "#D20F39", selection: "#CCD0DA"),
        dark: Palette(background: "#1E1E2E", foreground: "#CDD6F4", comment: "#7F849C", keyword: "#CBA6F7",
                      string: "#A6E3A1", number: "#FAB387", function: "#89B4FA", type: "#F9E2AF",
                      tag: "#F38BA8", attribute: "#F9E2AF", variable: "#EBA0AC", builtIn: "#F38BA8",
                      regexp: "#F5C2E7", meta: "#94E2D5", added: "#A6E3A1", removed: "#F38BA8", selection: "#45475A"))

    public static let tokyoNight = CodeTheme(
        id: "tokyo-night", name: "Tokyo Night",
        light: Palette(background: "#E1E2E7", foreground: "#3760BF", comment: "#848CB5", keyword: "#9854F1",
                       string: "#587539", number: "#B15C00", function: "#2E7DE9", type: "#188092",
                       tag: "#F52A65", attribute: "#9854F1", variable: "#3760BF", builtIn: "#8C6C3E",
                       regexp: "#2E5857", meta: "#007197", added: "#587539", removed: "#F52A65", selection: "#B7C1E3"),
        dark: Palette(background: "#1A1B26", foreground: "#C0CAF5", comment: "#565F89", keyword: "#BB9AF7",
                      string: "#9ECE6A", number: "#FF9E64", function: "#7AA2F7", type: "#2AC3DE",
                      tag: "#F7768E", attribute: "#BB9AF7", variable: "#C0CAF5", builtIn: "#E0AF68",
                      regexp: "#B4F9F8", meta: "#7DCFFF", added: "#9ECE6A", removed: "#F7768E", selection: "#283457"))

    public static let rosePine = CodeTheme(
        id: "rose-pine", name: "Rosé Pine",
        light: Palette(background: "#FAF4ED", foreground: "#575279", comment: "#9893A5", keyword: "#286983",
                       string: "#EA9D34", number: "#D7827E", function: "#D7827E", type: "#56949F",
                       tag: "#56949F", attribute: "#907AA9", variable: "#575279", builtIn: "#B4637A",
                       regexp: "#B4637A", meta: "#797593", added: "#56949F", removed: "#B4637A", selection: "#DFDAD9"),
        dark: Palette(background: "#191724", foreground: "#E0DEF4", comment: "#6E6A86", keyword: "#31748F",
                      string: "#F6C177", number: "#EBBCBA", function: "#EBBCBA", type: "#9CCFD8",
                      tag: "#9CCFD8", attribute: "#C4A7E7", variable: "#E0DEF4", builtIn: "#EB6F92",
                      regexp: "#EB6F92", meta: "#908CAA", added: "#9CCFD8", removed: "#EB6F92", selection: "#403D52"))

    public static let solarized = CodeTheme(
        id: "solarized", name: "Solarized",
        light: Palette(background: "#FDF6E3", foreground: "#586E75", comment: "#93A1A1", keyword: "#859900",
                       string: "#2AA198", number: "#D33682", function: "#268BD2", type: "#B58900",
                       tag: "#268BD2", attribute: "#B58900", variable: "#CB4B16", builtIn: "#CB4B16",
                       regexp: "#DC322F", meta: "#CB4B16", added: "#859900", removed: "#DC322F", selection: "#EEE8D5"),
        dark: Palette(background: "#002B36", foreground: "#93A1A1", comment: "#586E75", keyword: "#859900",
                      string: "#2AA198", number: "#D33682", function: "#268BD2", type: "#B58900",
                      tag: "#268BD2", attribute: "#B58900", variable: "#CB4B16", builtIn: "#CB4B16",
                      regexp: "#DC322F", meta: "#CB4B16", added: "#859900", removed: "#DC322F", selection: "#073642"))

    public static let gruvbox = CodeTheme(
        id: "gruvbox", name: "Gruvbox",
        light: Palette(background: "#FBF1C7", foreground: "#3C3836", comment: "#928374", keyword: "#9D0006",
                       string: "#79740E", number: "#8F3F71", function: "#427B58", type: "#B57614",
                       tag: "#076678", attribute: "#B57614", variable: "#076678", builtIn: "#AF3A03",
                       regexp: "#AF3A03", meta: "#AF3A03", added: "#79740E", removed: "#9D0006", selection: "#EBDBB2"),
        dark: Palette(background: "#282828", foreground: "#EBDBB2", comment: "#928374", keyword: "#FB4934",
                      string: "#B8BB26", number: "#D3869B", function: "#8EC07C", type: "#FABD2F",
                      tag: "#83A598", attribute: "#FABD2F", variable: "#83A598", builtIn: "#FE8019",
                      regexp: "#FE8019", meta: "#FE8019", added: "#B8BB26", removed: "#FB4934", selection: "#504945"))

    // MARK: - CSS

    /// CSS custom properties for both appearances. The page decides via `prefers-color-scheme`,
    /// which WebKit resolves from the hosting view's effective appearance.
    public var css: String {
        func block(_ p: Palette) -> String {
            """
            --bg:\(p.background);--fg:\(p.foreground);--t-comment:\(p.comment);--t-keyword:\(p.keyword);\
            --t-string:\(p.string);--t-number:\(p.number);--t-function:\(p.function);--t-type:\(p.type);\
            --t-tag:\(p.tag);--t-attr:\(p.attribute);--t-variable:\(p.variable);--t-builtin:\(p.builtIn);\
            --t-regexp:\(p.regexp);--t-meta:\(p.meta);--t-added:\(p.added);--t-removed:\(p.removed);\
            --t-selection:\(p.selection);--t-keyword-weight:\(boldKeywords ? 600 : 400);
            """
        }
        return ":root{\(block(light))}\n@media (prefers-color-scheme: dark){:root{\(block(dark))}}"
    }
}
