import Foundation

// The code theme catalog, with each author's official colours.
// Token roles (highlight.js scopes → palette):
//   comment      comments, doc comments, quotes
//   keyword      keywords, literals (true/false/nil), CSS selector tags
//   string       strings, characters, template strings
//   number       numbers, symbols, list bullets
//   function     function and method names, Markdown sections
//   type         class, struct and type names
//   tag          HTML/XML tag names, CSS ids and classes
//   attribute    HTML attributes, object keys, CSS properties
//   variable     variables, template variables, `self`/`this`
//   builtIn      built-in functions and types (print, String, console)
//   regexp       regular expressions, links
//   meta         preprocessor lines, decorators, shebangs
//   added/removed  diff lines
//   selection    selection background
//
// Where an official colour falls below Greece's readability floor (text 4.5:1, tokens 3:1, comments 2.2:1
// against the background), only its lightness is nudged, just enough; each change is noted above its theme.

extension CodeTheme {

    /// Every theme, in gallery order within each group (pairs, light, dark).
    public static let all: [CodeTheme] = [
        // Pairs
        xcode, xcodePresentation, vscode, github, one, catppuccin, catppuccinMacchiato, catppuccinFrappe,
        tokyoNight, tokyoNightStorm, solarized, gruvbox, rosePine, rosePineMoon, material, nightOwl, ayu, ayuMirage,
        monokaiPro, intelliJ, atom, everforest, kanagawa, vitesse, tomorrow, horizon, noctis, minTheme, flexoki,
        modus,
        // Light
        quietLight, xcodeSunset, xcodeLowKey, xcodeBasic,
        // Dark
        dracula, monokai, nord, githubDimmed, palenight, tomorrowEighties, synthwave84, cobalt2, poimandres, panda,
        mariana, zenburn, xcodeMidnight, xcodeDusk, xcodeCivic,
    ]

    // Names of themes and their variants are the authors' own: proper names stay as they are
    // (Dracula, Latte, Mocha, One Dark); plain words that only say which version it is are localized.
    private static var lightVariant: String { PreviewSettings.Appearance.lightTitle }
    private static var darkVariant: String { PreviewSettings.Appearance.darkTitle }
    private static var dayName: String {
        String(localized: "Day", bundle: .greeceKit, comment: "Code theme variant name: Tokyo Night’s light version")
    }

    // MARK: - Pairs

    // Readability, lightness only: light: added #34C759 → #2CA94B
    public static let xcode = CodeTheme(
        id: "xcode", name: "Xcode",
        light: Palette(background: "#FFFFFF", foreground: "#262626", comment: "#5D6C79", keyword: "#9B2393",
                       string: "#C41A16", number: "#1C00CF", function: "#0F68A0", type: "#3900A0",
                       tag: "#9B2393", attribute: "#815F03", variable: "#326D74", builtIn: "#6C36A9",
                       regexp: "#C41A16", meta: "#643820", added: "#2CA94B", removed: "#FF3B30", selection: "#A4CDFF"),
        dark: Palette(background: "#1F1F24", foreground: "#DDDDDE", comment: "#6C7986", keyword: "#FC5FA3",
                      string: "#FC6A5D", number: "#D0BF69", function: "#41A1C0", type: "#D0A8FF",
                      tag: "#FC5FA3", attribute: "#BF8555", variable: "#67B7A4", builtIn: "#A167E6",
                      regexp: "#FC6A5D", meta: "#FD8F3F", added: "#30D158", removed: "#FF453A", selection: "#515B70"),
        boldKeywords: true,
        lightName: String(localized: "Default Light", bundle: .greeceKit, comment: "Code theme variant name: Xcode’s default light theme"),
        darkName: String(localized: "Default Dark", bundle: .greeceKit, comment: "Code theme variant name: Xcode’s default dark theme"),
        keywords: "apple default")

    // Readability, lightness only: light: added #34C759 → #2CA94B
    public static let xcodePresentation = CodeTheme(
        id: "xcode-presentation",
        name: String(localized: "Xcode Presentation", bundle: .greeceKit, comment: "Code theme name: Xcode’s large, high-contrast theme for presenting"),
        light: Palette(background: "#FFFFFF", foreground: "#000000", comment: "#56606B", keyword: "#C33381",
                       string: "#BA0011", number: "#000BFF", function: "#0F68A0", type: "#2E0D6E",
                       tag: "#C33381", attribute: "#836C28", variable: "#3B7F89", builtIn: "#5C2699",
                       regexp: "#BA0011", meta: "#6E200D", added: "#2CA94B", removed: "#FF3B30", selection: "#C7DBFF"),
        dark: Palette(background: "#18181C", foreground: "#FFFFFF", comment: "#6C7987", keyword: "#F2248C",
                      string: "#FC4651", number: "#FFE76D", function: "#35B0D8", type: "#D0A8FF",
                      tag: "#F2248C", attribute: "#E09D65", variable: "#56D0B3", builtIn: "#AB64FF",
                      regexp: "#FC4651", meta: "#FD8F3F", added: "#30D158", removed: "#FF453A", selection: "#515B70"),
        boldKeywords: true,
        lightName: String(localized: "Presentation Light", bundle: .greeceKit, comment: "Code theme variant name: the light version of Xcode’s Presentation theme"),
        darkName: String(localized: "Presentation Dark", bundle: .greeceKit, comment: "Code theme variant name: the dark version of Xcode’s Presentation theme"),
        keywords: "apple presentation large")

    public static let vscode = CodeTheme(
        id: "vscode", name: "Visual Studio Code",
        light: Palette(background: "#FFFFFF", foreground: "#000000", comment: "#008000", keyword: "#0000FF",
                       string: "#A31515", number: "#098658", function: "#795E26", type: "#267F99",
                       tag: "#800000", attribute: "#E50000", variable: "#001080", builtIn: "#795E26",
                       regexp: "#811F3F", meta: "#0000FF", added: "#098658", removed: "#A31515", selection: "#ADD6FF"),
        dark: Palette(background: "#1E1E1E", foreground: "#D4D4D4", comment: "#6A9955", keyword: "#569CD6",
                      string: "#CE9178", number: "#B5CEA8", function: "#DCDCAA", type: "#4EC9B0",
                      tag: "#569CD6", attribute: "#9CDCFE", variable: "#9CDCFE", builtIn: "#DCDCAA",
                      regexp: "#D16969", meta: "#569CD6", added: "#B5CEA8", removed: "#CE9178", selection: "#264F78"),
        lightName: "Light+", darkName: "Dark+", keywords: "vs code vscode microsoft visual studio default plus modern")

    public static let github = CodeTheme(
        id: "github", name: "GitHub",
        light: Palette(background: "#FFFFFF", foreground: "#1F2328", comment: "#6E7781", keyword: "#CF222E",
                       string: "#0A3069", number: "#0550AE", function: "#8250DF", type: "#953800",
                       tag: "#116329", attribute: "#0550AE", variable: "#953800", builtIn: "#0550AE",
                       regexp: "#0A3069", meta: "#8250DF", added: "#116329", removed: "#82071E", selection: "#ADD6FF"),
        dark: Palette(background: "#0D1117", foreground: "#E6EDF3", comment: "#8B949E", keyword: "#FF7B72",
                      string: "#A5D6FF", number: "#79C0FF", function: "#D2A8FF", type: "#FFA657",
                      tag: "#7EE787", attribute: "#79C0FF", variable: "#FFA657", builtIn: "#79C0FF",
                      regexp: "#A5D6FF", meta: "#D2A8FF", added: "#7EE787", removed: "#FFA198", selection: "#264F78"),
        lightName: "GitHub Light", darkName: "GitHub Dark", keywords: "primer github light default dark default")

    public static let one = CodeTheme(
        id: "one", name: "One",
        light: Palette(background: "#FAFAFA", foreground: "#383A42", comment: "#A0A1A7", keyword: "#A626A4",
                       string: "#50A14F", number: "#B76B01", function: "#4078F2", type: "#CB7701",
                       tag: "#E45649", attribute: "#B76B01", variable: "#E45649", builtIn: "#0184BC",
                       regexp: "#0184BC", meta: "#4078F2", added: "#50A14F", removed: "#E45649", selection: "#E5E5E6"),
        dark: Palette(background: "#282C34", foreground: "#ABB2BF", comment: "#5C6370", keyword: "#C678DD",
                      string: "#98C379", number: "#D19A66", function: "#61AFEF", type: "#E5C07B",
                      tag: "#E06C75", attribute: "#D19A66", variable: "#E06C75", builtIn: "#56B6C2",
                      regexp: "#56B6C2", meta: "#61AFEF", added: "#98C379", removed: "#E06C75", selection: "#3E4451"),
        italicComments: true, lightName: "One Light", darkName: "One Dark", keywords: "atom one dark one light")

    // Readability, lightness only: light: string #40A02B → #3F9D2A, number #FE640B → #F05801, type #DF8E1D → #C17B19, attribute #DF8E1D → #C17B19, regexp #EA76CB → #E44EBC, meta #DF8E1D → #C17B19, added #40A02B → #3F9D2A
    public static let catppuccin = CodeTheme(
        id: "catppuccin", name: "Catppuccin",
        light: Palette(background: "#EFF1F5", foreground: "#4C4F69", comment: "#7C7F93", keyword: "#8839EF",
                       string: "#3F9D2A", number: "#F05801", function: "#1E66F5", type: "#C17B19",
                       tag: "#1E66F5", attribute: "#C17B19", variable: "#E64553", builtIn: "#D20F39",
                       regexp: "#E44EBC", meta: "#C17B19", added: "#3F9D2A", removed: "#D20F39", selection: "#CCCFD7"),
        dark: Palette(background: "#1E1E2E", foreground: "#CDD6F4", comment: "#9399B2", keyword: "#CBA6F7",
                      string: "#A6E3A1", number: "#FAB387", function: "#89B4FA", type: "#F9E2AF",
                      tag: "#89B4FA", attribute: "#F9E2AF", variable: "#EBA0AC", builtIn: "#F38BA8",
                      regexp: "#F5C2E7", meta: "#F9E2AF", added: "#A6E3A1", removed: "#F38BA8", selection: "#3B3D4F"),
        italicComments: true, lightName: "Latte", darkName: "Mocha", keywords: "catppuccin latte mocha pastel")

    // Readability, lightness only: light: string #40A02B → #3F9D2A, number #FE640B → #F05801, type #DF8E1D → #C17B19, attribute #DF8E1D → #C17B19, regexp #EA76CB → #E44EBC, meta #DF8E1D → #C17B19, added #40A02B → #3F9D2A
    public static let catppuccinMacchiato = CodeTheme(
        id: "catppuccin-macchiato", name: "Catppuccin Macchiato",
        light: Palette(background: "#EFF1F5", foreground: "#4C4F69", comment: "#7C7F93", keyword: "#8839EF",
                       string: "#3F9D2A", number: "#F05801", function: "#1E66F5", type: "#C17B19",
                       tag: "#1E66F5", attribute: "#C17B19", variable: "#E64553", builtIn: "#D20F39",
                       regexp: "#E44EBC", meta: "#C17B19", added: "#3F9D2A", removed: "#D20F39", selection: "#CCCFD7"),
        dark: Palette(background: "#24273A", foreground: "#CAD3F5", comment: "#939AB7", keyword: "#C6A0F6",
                      string: "#A6DA95", number: "#F5A97F", function: "#8AADF4", type: "#EED49F",
                      tag: "#8AADF4", attribute: "#EED49F", variable: "#EE99A0", builtIn: "#ED8796",
                      regexp: "#F5BDE6", meta: "#EED49F", added: "#A6DA95", removed: "#ED8796", selection: "#404459"),
        italicComments: true, lightName: "Latte", darkName: "Macchiato", keywords: "catppuccin latte macchiato pastel")

    // Readability, lightness only: light: string #40A02B → #3F9D2A, number #FE640B → #F05801, type #DF8E1D → #C17B19, attribute #DF8E1D → #C17B19, regexp #EA76CB → #E44EBC, meta #DF8E1D → #C17B19, added #40A02B → #3F9D2A
    public static let catppuccinFrappe = CodeTheme(
        id: "catppuccin-frappe", name: "Catppuccin Frappé",
        light: Palette(background: "#EFF1F5", foreground: "#4C4F69", comment: "#7C7F93", keyword: "#8839EF",
                       string: "#3F9D2A", number: "#F05801", function: "#1E66F5", type: "#C17B19",
                       tag: "#1E66F5", attribute: "#C17B19", variable: "#E64553", builtIn: "#D20F39",
                       regexp: "#E44EBC", meta: "#C17B19", added: "#3F9D2A", removed: "#D20F39", selection: "#CCCFD7"),
        dark: Palette(background: "#303446", foreground: "#C6D0F5", comment: "#949CBB", keyword: "#CA9EE6",
                      string: "#A6D189", number: "#EF9F76", function: "#8CAAEE", type: "#E5C890",
                      tag: "#8CAAEE", attribute: "#E5C890", variable: "#EA999C", builtIn: "#E78284",
                      regexp: "#F4B8E4", meta: "#E5C890", added: "#A6D189", removed: "#E78284", selection: "#494E63"),
        italicComments: true, lightName: "Latte", darkName: "Frappé", keywords: "catppuccin latte frappe frappé pastel")

    // Readability, lightness only: light: added #4197A4 → #3C8B97, removed #C47981 → #BC6770; dark: removed #914C54 → #9C525A
    public static let tokyoNight = CodeTheme(
        id: "tokyo-night", name: "Tokyo Night",
        light: Palette(background: "#E1E2E7", foreground: "#3760BF", comment: "#848CB5", keyword: "#9854F1",
                       string: "#587539", number: "#B15C00", function: "#2E7DE9", type: "#07879D",
                       tag: "#F52A65", attribute: "#9854F1", variable: "#F52A65", builtIn: "#188092",
                       regexp: "#2E5857", meta: "#387068", added: "#3C8B97", removed: "#BC6770", selection: "#B7C1E3"),
        dark: Palette(background: "#1A1B26", foreground: "#C0CAF5", comment: "#565F89", keyword: "#BB9AF7",
                      string: "#9ECE6A", number: "#FF9E64", function: "#7AA2F7", type: "#0DB9D7",
                      tag: "#F7768E", attribute: "#BB9AF7", variable: "#F7768E", builtIn: "#2AC3DE",
                      regexp: "#B4F9F8", meta: "#73DACA", added: "#449DAB", removed: "#9C525A", selection: "#283457"),
        italicComments: true, lightName: dayName,
        darkName: String(localized: "Night", bundle: .greeceKit, comment: "Code theme variant name: Tokyo Night’s dark version"),
        keywords: "folke tokyonight tokyo night day")

    // Readability, lightness only: light: added #4197A4 → #3C8B97, removed #C47981 → #BC6770; dark: removed #914C54 → #AA5C65
    public static let tokyoNightStorm = CodeTheme(
        id: "tokyo-night-storm", name: "Tokyo Night Storm",
        light: Palette(background: "#E1E2E7", foreground: "#3760BF", comment: "#848CB5", keyword: "#9854F1",
                       string: "#587539", number: "#B15C00", function: "#2E7DE9", type: "#07879D",
                       tag: "#F52A65", attribute: "#9854F1", variable: "#F52A65", builtIn: "#188092",
                       regexp: "#2E5857", meta: "#387068", added: "#3C8B97", removed: "#BC6770", selection: "#B7C1E3"),
        dark: Palette(background: "#24283B", foreground: "#C0CAF5", comment: "#565F89", keyword: "#BB9AF7",
                      string: "#9ECE6A", number: "#FF9E64", function: "#7AA2F7", type: "#0DB9D7",
                      tag: "#F7768E", attribute: "#BB9AF7", variable: "#F7768E", builtIn: "#2AC3DE",
                      regexp: "#B4F9F8", meta: "#73DACA", added: "#449DAB", removed: "#AA5C65", selection: "#2E3C64"),
        italicComments: true, lightName: dayName, darkName: "Storm", keywords: "folke tokyonight tokyo night day storm")

    // Readability, lightness only: light: foreground #657B83 → #5F747C, keyword #859900 → #839600, string #2AA198 → #299E95, attribute #93A1A1 → #819191, meta #B58900 → #B28700, added #859900 → #839600
    public static let solarized = CodeTheme(
        id: "solarized", name: "Solarized",
        light: Palette(background: "#FDF6E3", foreground: "#5F747C", comment: "#93A1A1", keyword: "#839600",
                       string: "#299E95", number: "#D33682", function: "#268BD2", type: "#CB4B16",
                       tag: "#268BD2", attribute: "#819191", variable: "#268BD2", builtIn: "#268BD2",
                       regexp: "#DC322F", meta: "#B28700", added: "#839600", removed: "#DC322F", selection: "#EEE8D5"),
        dark: Palette(background: "#002B36", foreground: "#839496", comment: "#586E75", keyword: "#859900",
                      string: "#2AA198", number: "#D33682", function: "#268BD2", type: "#CB4B16",
                      tag: "#268BD2", attribute: "#93A1A1", variable: "#268BD2", builtIn: "#268BD2",
                      regexp: "#DC322F", meta: "#B58900", added: "#859900", removed: "#DC322F", selection: "#274642"),
        italicComments: true, lightName: lightVariant, darkName: darkVariant, keywords: "ethan schoonover solarized")

    public static let gruvbox = CodeTheme(
        id: "gruvbox", name: "Gruvbox",
        light: Palette(background: "#FBF1C7", foreground: "#3C3836", comment: "#928374", keyword: "#9D0006",
                       string: "#79740E", number: "#8F3F71", function: "#79740E", type: "#B57614",
                       tag: "#427B58", attribute: "#427B58", variable: "#076678", builtIn: "#AF3A03",
                       regexp: "#AF3A03", meta: "#427B58", added: "#79740E", removed: "#9D0006", selection: "#BDAE93"),
        dark: Palette(background: "#282828", foreground: "#EBDBB2", comment: "#928374", keyword: "#FB4934",
                      string: "#B8BB26", number: "#D3869B", function: "#B8BB26", type: "#FABD2F",
                      tag: "#8EC07C", attribute: "#8EC07C", variable: "#83A598", builtIn: "#FE8019",
                      regexp: "#FE8019", meta: "#8EC07C", added: "#B8BB26", removed: "#FB4934", selection: "#665C54"),
        italicComments: true, lightName: lightVariant, darkName: darkVariant, keywords: "morhetz gruvbox retro medium")

    // Readability, lightness only: light: string #EA9D34 → #C77C15, number #D7827E → #D2716C, function #D7827E → #D2716C, variable #D7827E → #D2716C, regexp #EA9D34 → #C77C15, meta #D7827E → #D2716C
    public static let rosePine = CodeTheme(
        id: "rose-pine", name: "Rosé Pine",
        light: Palette(background: "#FAF4ED", foreground: "#575279", comment: "#9893A5", keyword: "#286983",
                       string: "#C77C15", number: "#D2716C", function: "#D2716C", type: "#56949F",
                       tag: "#56949F", attribute: "#907AA9", variable: "#D2716C", builtIn: "#B4637A",
                       regexp: "#C77C15", meta: "#D2716C", added: "#56949F", removed: "#B4637A", selection: "#EFE9E5"),
        dark: Palette(background: "#191724", foreground: "#E0DEF4", comment: "#6E6A86", keyword: "#31748F",
                      string: "#F6C177", number: "#EBBCBA", function: "#EBBCBA", type: "#9CCFD8",
                      tag: "#9CCFD8", attribute: "#C4A7E7", variable: "#EBBCBA", builtIn: "#EB6F92",
                      regexp: "#F6C177", meta: "#EBBCBA", added: "#9CCFD8", removed: "#EB6F92", selection: "#2A2838"),
        italicComments: true, lightName: "Dawn",
        darkName: String(localized: "Main", bundle: .greeceKit, comment: "Code theme variant name: Rosé Pine’s main version, as opposed to Dawn and Moon"),
        keywords: "rose pine rosepine dawn main")

    // Readability, lightness only: light: string #EA9D34 → #C77C15, number #D7827E → #D2716C, function #D7827E → #D2716C, variable #D7827E → #D2716C, regexp #EA9D34 → #C77C15, meta #D7827E → #D2716C
    public static let rosePineMoon = CodeTheme(
        id: "rose-pine-moon", name: "Rosé Pine Moon",
        light: Palette(background: "#FAF4ED", foreground: "#575279", comment: "#9893A5", keyword: "#286983",
                       string: "#C77C15", number: "#D2716C", function: "#D2716C", type: "#56949F",
                       tag: "#56949F", attribute: "#907AA9", variable: "#D2716C", builtIn: "#B4637A",
                       regexp: "#C77C15", meta: "#D2716C", added: "#56949F", removed: "#B4637A", selection: "#EFE9E5"),
        dark: Palette(background: "#232136", foreground: "#E0DEF4", comment: "#6E6A86", keyword: "#3E8FB0",
                      string: "#F6C177", number: "#EA9A97", function: "#EA9A97", type: "#9CCFD8",
                      tag: "#9CCFD8", attribute: "#C4A7E7", variable: "#EA9A97", builtIn: "#EB6F92",
                      regexp: "#F6C177", meta: "#EA9A97", added: "#9CCFD8", removed: "#EB6F92", selection: "#312F45"),
        italicComments: true, lightName: "Dawn", darkName: "Moon", keywords: "rose pine rosepine dawn moon")

    // Readability, lightness only: light: foreground #90A4AE → #5F7682, string #91B859 → #789C43, number #F76D47 → #F65F36, type #E2931D → #C7811A, variable #39ADB5 → #349EA5, regexp #91B859 → #789C43, added #91B859 → #789C43
    public static let material = CodeTheme(
        id: "material", name: "Material",
        light: Palette(background: "#FAFAFA", foreground: "#5F7682", comment: "#90A4AE", keyword: "#9C3EDA",
                       string: "#789C43", number: "#F65F36", function: "#6182B8", type: "#C7811A",
                       tag: "#E53935", attribute: "#9C3EDA", variable: "#349EA5", builtIn: "#6182B8",
                       regexp: "#789C43", meta: "#6182B8", added: "#789C43", removed: "#E53935", selection: "#DBEEEC"),
        dark: Palette(background: "#263238", foreground: "#EEFFFF", comment: "#546E7A", keyword: "#C792EA",
                      string: "#C3E88D", number: "#F78C6C", function: "#82AAFF", type: "#FFCB6B",
                      tag: "#F07178", attribute: "#C792EA", variable: "#89DDFF", builtIn: "#82AAFF",
                      regexp: "#C3E88D", meta: "#82AAFF", added: "#C3E88D", removed: "#F07178", selection: "#31454A"),
        italicComments: true,
        lightName: String(localized: "Lighter", bundle: .greeceKit, comment: "Code theme variant name: Material Theme’s light version, “Material Lighter”"),
        darkName: String(localized: "Default", bundle: .greeceKit, comment: "Code theme variant name: Material Theme’s default (dark) version"),
        keywords: "material theme mattia astorino equinusocio lighter")

    // Readability, lightness only: light: regexp #5CA7E4 → #3E97DF, added #49D0C5 → #29A197, removed #F76E6E → #F65E5E
    public static let nightOwl = CodeTheme(
        id: "night-owl", name: "Night Owl",
        light: Palette(background: "#FBFBFB", foreground: "#403F53", comment: "#989FB1", keyword: "#994CC3",
                       string: "#C96765", number: "#AA0982", function: "#4876D6", type: "#111111",
                       tag: "#994CC3", attribute: "#4876D6", variable: "#4876D6", builtIn: "#4876D6",
                       regexp: "#3E97DF", meta: "#4876D6", added: "#29A197", removed: "#F65E5E", selection: "#E0E0E0"),
        dark: Palette(background: "#011627", foreground: "#D6DEEB", comment: "#637777", keyword: "#C792EA",
                      string: "#ECC48D", number: "#F78C6C", function: "#82AAFF", type: "#FFCB8B",
                      tag: "#CAECE6", attribute: "#C5E478", variable: "#C5E478", builtIn: "#C5E478",
                      regexp: "#5CA7E4", meta: "#82AAFF", added: "#9CCC65", removed: "#EF5350", selection: "#1D3B53"),
        italicComments: true, lightName: "Light Owl", darkName: "Night Owl",
        keywords: "sarah drasner sdras night owl light owl")

    // Readability, lightness only: light: comment #ADAEB1 → #AAABAF, keyword #FA8532 → #F16706, string #86B300 → #779F00, function #EBA400 → #C18700, type #22A4E6 → #199ADC, tag #55B4D4 → #319DC1, attribute #EBA400 → #C18700, variable #55B4D4 → #319DC1, builtIn #F07171 → #EF6565, regexp #4CBF99 → #3AA380, meta #E59645 → #D67B1E, added #6CBF43 → #5BA337, removed #FF7383 → #FF5468
    public static let ayu = CodeTheme(
        id: "ayu", name: "Ayu",
        light: Palette(background: "#FCFCFC", foreground: "#5C6166", comment: "#AAABAF", keyword: "#F16706",
                       string: "#779F00", number: "#A37ACC", function: "#C18700", type: "#199ADC",
                       tag: "#319DC1", attribute: "#C18700", variable: "#319DC1", builtIn: "#EF6565",
                       regexp: "#3AA380", meta: "#D67B1E", added: "#5BA337", removed: "#FF5468", selection: "#D7E4F6"),
        dark: Palette(background: "#10141C", foreground: "#BFBDB6", comment: "#5A6673", keyword: "#FF8F40",
                      string: "#AAD94C", number: "#D2A6FF", function: "#FFB454", type: "#59C2FF",
                      tag: "#39BAE6", attribute: "#FFB454", variable: "#39BAE6", builtIn: "#F07178",
                      regexp: "#95E6CB", meta: "#E6C08A", added: "#70BF56", removed: "#F26D78", selection: "#193155"),
        italicComments: true, lightName: lightVariant, darkName: darkVariant, keywords: "ayu")

    // Readability, lightness only: light: comment #ADAEB1 → #AAABAF, keyword #FA8532 → #F16706, string #86B300 → #779F00, function #EBA400 → #C18700, type #22A4E6 → #199ADC, tag #55B4D4 → #319DC1, attribute #EBA400 → #C18700, variable #55B4D4 → #319DC1, builtIn #F07171 → #EF6565, regexp #4CBF99 → #3AA380, meta #E59645 → #D67B1E, added #6CBF43 → #5BA337, removed #FF7383 → #FF5468
    public static let ayuMirage = CodeTheme(
        id: "ayu-mirage", name: "Ayu Mirage",
        light: Palette(background: "#FCFCFC", foreground: "#5C6166", comment: "#AAABAF", keyword: "#F16706",
                       string: "#779F00", number: "#A37ACC", function: "#C18700", type: "#199ADC",
                       tag: "#319DC1", attribute: "#C18700", variable: "#319DC1", builtIn: "#EF6565",
                       regexp: "#3AA380", meta: "#D67B1E", added: "#5BA337", removed: "#FF5468", selection: "#D7E4F6"),
        dark: Palette(background: "#242936", foreground: "#CCCAC2", comment: "#6E7C8F", keyword: "#FFA659",
                      string: "#D5FF80", number: "#DFBFFF", function: "#FFCD66", type: "#73D0FF",
                      tag: "#5CCFE6", attribute: "#FFCD66", variable: "#5CCFE6", builtIn: "#F28779",
                      regexp: "#95E6CB", meta: "#D9BE98", added: "#87D96C", removed: "#F27983", selection: "#2B4768"),
        italicComments: true, lightName: lightVariant, darkName: "Mirage", keywords: "ayu mirage")

    public static let monokaiPro = CodeTheme(
        id: "monokai-pro", name: "Monokai Pro",
        light: Palette(background: "#FAF4F2", foreground: "#29242A", comment: "#A59FA0", keyword: "#E14775",
                       string: "#CC7A0A", number: "#7058BE", function: "#269D69", type: "#1C8CA8",
                       tag: "#E14775", attribute: "#1C8CA8", variable: "#E16032", builtIn: "#269D69",
                       regexp: "#CC7A0A", meta: "#7058BE", added: "#269D69", removed: "#E14775", selection: "#E5E0DE"),
        dark: Palette(background: "#2D2A2E", foreground: "#FCFCFA", comment: "#727072", keyword: "#FF6188",
                      string: "#FFD866", number: "#AB9DF2", function: "#A9DC76", type: "#78DCE8",
                      tag: "#FF6188", attribute: "#78DCE8", variable: "#FC9867", builtIn: "#A9DC76",
                      regexp: "#FFD866", meta: "#AB9DF2", added: "#A9DC76", removed: "#FF6188", selection: "#434044"),
        italicComments: true, lightName: lightVariant, darkName: "Pro", keywords: "monokai pro light filter wimer hazenberg")

    // Readability, lightness only: dark: removed #6C6C6C → #757575
    public static let intelliJ = CodeTheme(
        id: "intellij", name: "IntelliJ",
        light: Palette(background: "#FFFFFF", foreground: "#080808", comment: "#8C8C8C", keyword: "#0033B3",
                       string: "#067D17", number: "#1750EB", function: "#00627A", type: "#000000",
                       tag: "#0033B3", attribute: "#174AD4", variable: "#871094", builtIn: "#000000",
                       regexp: "#264EFF", meta: "#9E880D", added: "#0A7700", removed: "#616161", selection: "#A6D2FF"),
        dark: Palette(background: "#2B2B2B", foreground: "#A9B7C6", comment: "#808080", keyword: "#CC7832",
                      string: "#6A8759", number: "#6897BB", function: "#FFC66D", type: "#A9B7C6",
                      tag: "#E8BF6A", attribute: "#BABABA", variable: "#9876AA", builtIn: "#A9B7C6",
                      regexp: "#6A8759", meta: "#BBB529", added: "#629755", removed: "#757575", selection: "#214283"),
        lightName: "IntelliJ Light", darkName: "Darcula", keywords: "jetbrains intellij idea darcula light")

    public static let atom = CodeTheme(
        id: "atom", name: "Atom",
        light: Palette(background: "#FFFFFF", foreground: "#555555", comment: "#999988", keyword: "#222222",
                       string: "#DD1144", number: "#DD1144", function: "#990000", type: "#606AA1",
                       tag: "#008080", attribute: "#445588", variable: "#008080", builtIn: "#445588",
                       regexp: "#DD1144", meta: "#990000", added: "#718C00", removed: "#DD1144", selection: "#AFC4DA"),
        dark: Palette(background: "#1D1F21", foreground: "#C5C8C6", comment: "#8A8A8A", keyword: "#96CBFE",
                      string: "#A8FF60", number: "#FF73FD", function: "#FFD2A7", type: "#FFFFB6",
                      tag: "#96CBFE", attribute: "#FF73FD", variable: "#C6C5FE", builtIn: "#DAD085",
                      regexp: "#E9C062", meta: "#8996A8", added: "#A8FF60", removed: "#CC6666", selection: "#444444"),
        lightName: "Atom Light", darkName: "Atom Dark", keywords: "atom github syntax light dark")

    // Readability, lightness only: light: string #DFA000 → #B98500, number #DF69BA → #DD60B6, function #8DA101 → #849701, tag #F57D26 → #E8670B, attribute #DFA000 → #B98500, variable #DF69BA → #DD60B6, builtIn #8DA101 → #849701, regexp #DFA000 → #B98500, meta #8DA101 → #849701, added #8DA101 → #849701
    public static let everforest = CodeTheme(
        id: "everforest", name: "Everforest",
        light: Palette(background: "#FDF6E3", foreground: "#5C6A72", comment: "#939F91", keyword: "#F85552",
                       string: "#B98500", number: "#DD60B6", function: "#849701", type: "#3A94C5",
                       tag: "#E8670B", attribute: "#B98500", variable: "#DD60B6", builtIn: "#849701",
                       regexp: "#B98500", meta: "#849701", added: "#849701", removed: "#F85552", selection: "#EFE9D5"),
        dark: Palette(background: "#2D353B", foreground: "#D3C6AA", comment: "#859289", keyword: "#E67E80",
                      string: "#DBBC7F", number: "#D699B6", function: "#A7C080", type: "#7FBBB3",
                      tag: "#E69875", attribute: "#DBBC7F", variable: "#D699B6", builtIn: "#A7C080",
                      regexp: "#DBBC7F", meta: "#A7C080", added: "#A7C080", removed: "#E67E80", selection: "#414B51"),
        italicComments: true, lightName: lightVariant, darkName: darkVariant, keywords: "sainnhe everforest green forest medium")

    // Readability, lightness only: light: tag #6693BF → #598ABA, builtIn #6693BF → #598ABA, added #6E915F → #6D8F5E
    public static let kanagawa = CodeTheme(
        id: "kanagawa", name: "Kanagawa",
        light: Palette(background: "#F2ECBC", foreground: "#545464", comment: "#8A8980", keyword: "#624C83",
                       string: "#6F894E", number: "#B35B79", function: "#4D699B", type: "#597B75",
                       tag: "#598ABA", attribute: "#77713F", variable: "#C84053", builtIn: "#598ABA",
                       regexp: "#836F4A", meta: "#C84053", added: "#6D8F5E", removed: "#D7474B", selection: "#C9CBD1"),
        dark: Palette(background: "#1F1F28", foreground: "#DCD7BA", comment: "#727169", keyword: "#957FB8",
                      string: "#98BB6C", number: "#D27E99", function: "#7E9CD8", type: "#7AA89F",
                      tag: "#7FB4CA", attribute: "#E6C384", variable: "#E46876", builtIn: "#7FB4CA",
                      regexp: "#C0A36E", meta: "#E46876", added: "#76946A", removed: "#C34043", selection: "#223249"),
        italicComments: true, lightName: "Lotus", darkName: "Wave", keywords: "rebelot kanagawa lotus wave hokusai")

    public static let vitesse = CodeTheme(
        id: "vitesse", name: "Vitesse",
        light: Palette(background: "#FFFFFF", foreground: "#393A34", comment: "#A0ADA0", keyword: "#1E754F",
                       string: "#B56959", number: "#2F798A", function: "#59873A", type: "#2E8F82",
                       tag: "#1E754F", attribute: "#B07D48", variable: "#B07D48", builtIn: "#998418",
                       regexp: "#AB5E3F", meta: "#59873A", added: "#22863A", removed: "#B31D28", selection: "#EAEAEA"),
        dark: Palette(background: "#121212", foreground: "#CECABE", comment: "#687668", keyword: "#4D9375",
                      string: "#C98A7D", number: "#4C9A91", function: "#80A665", type: "#5DA994",
                      tag: "#4D9375", attribute: "#BD976A", variable: "#BD976A", builtIn: "#B8A965",
                      regexp: "#C4704F", meta: "#80A665", added: "#85E89D", removed: "#FDAEB7", selection: "#272727"),
        lightName: lightVariant, darkName: darkVariant, keywords: "antfu anthony fu vitesse")

    // Readability, lightness only: light: number #F5871F → #E6750A, type #C99E00 → #B68F00
    public static let tomorrow = CodeTheme(
        id: "tomorrow", name: "Tomorrow",
        light: Palette(background: "#FFFFFF", foreground: "#4D4D4C", comment: "#8E908C", keyword: "#8959A8",
                       string: "#718C00", number: "#E6750A", function: "#4271AE", type: "#B68F00",
                       tag: "#C82829", attribute: "#C82829", variable: "#C82829", builtIn: "#4271AE",
                       regexp: "#C82829", meta: "#4271AE", added: "#718C00", removed: "#C82829", selection: "#D6D6D6"),
        dark: Palette(background: "#1D1F21", foreground: "#C5C8C6", comment: "#969896", keyword: "#B294BB",
                      string: "#B5BD68", number: "#DE935F", function: "#81A2BE", type: "#F0C674",
                      tag: "#CC6666", attribute: "#CC6666", variable: "#CC6666", builtIn: "#81A2BE",
                      regexp: "#CC6666", meta: "#81A2BE", added: "#B5BD68", removed: "#CC6666", selection: "#373B41"),
        lightName: "Tomorrow", darkName: "Tomorrow Night", keywords: "chris kempson tomorrow night")

    // Readability, lightness only: light: string #F6661E → #F3580A, type #F77D26 → #E56408, added #60C9A0 → #359C74; dark: comment #4C4D53 → #54555C
    public static let horizon = CodeTheme(
        id: "horizon", name: "Horizon",
        light: Palette(background: "#FDF0ED", foreground: "#333333", comment: "#989190", keyword: "#8A31B9",
                       string: "#F3580A", number: "#DC3318", function: "#1D8991", type: "#E56408",
                       tag: "#DA103F", attribute: "#DC3318", variable: "#DA103F", builtIn: "#1D8991",
                       regexp: "#DC3318", meta: "#1D8991", added: "#359C74", removed: "#F43E5C", selection: "#FBDDD5"),
        dark: Palette(background: "#1C1E26", foreground: "#BBBBBB", comment: "#54555C", keyword: "#A96EC9",
                      string: "#E4A88A", number: "#DB887A", function: "#24A2AD", type: "#E4B28F",
                      tag: "#D55170", attribute: "#DB887A", variable: "#D55170", builtIn: "#24A2AD",
                      regexp: "#DB887A", meta: "#24A2AD", added: "#24A075", removed: "#F43E5C", selection: "#292B37"),
        italicComments: true,
        lightName: String(localized: "Bright", bundle: .greeceKit, comment: "Code theme variant name: Horizon’s light version"),
        darkName: darkVariant, keywords: "jolaleye horizon bright")

    // Readability, lightness only: light: keyword #FF5792 → #FF4888, string #00B368 → #00A560, attribute #00BDD6 → #009DB2, variable #FA8900 → #D87600, builtIn #00BDD6 → #009DB2, regexp #00B368 → #00A560, added #00B368 → #00A560
    public static let noctis = CodeTheme(
        id: "noctis", name: "Noctis",
        light: Palette(background: "#FEF8EC", foreground: "#005661", comment: "#8CA6A6", keyword: "#FF4888",
                       string: "#00A560", number: "#5842FF", function: "#0095A8", type: "#0094F0",
                       tag: "#E64100", attribute: "#009DB2", variable: "#D87600", builtIn: "#009DB2",
                       regexp: "#00A560", meta: "#0095A8", added: "#00A560", removed: "#E64100", selection: "#D8EEEC"),
        dark: Palette(background: "#052529", foreground: "#B2CACD", comment: "#5B858B", keyword: "#DF769B",
                      string: "#49E9A6", number: "#7060EB", function: "#16A3B6", type: "#49ACE9",
                      tag: "#E66533", attribute: "#49D6E9", variable: "#E4B781", builtIn: "#49D6E9",
                      regexp: "#49E9A6", meta: "#16A3B6", added: "#49E9A6", removed: "#E66533", selection: "#0A464D"),
        italicComments: true, lightName: "Lux", darkName: "Noctis", keywords: "liviu schera noctis lux")

    // Readability, lightness only: light: comment #C2C3C5 → #ACADB0
    public static let minTheme = CodeTheme(
        id: "min", name: "Min",
        light: Palette(background: "#FFFFFF", foreground: "#24292E", comment: "#ACADB0", keyword: "#D32F2F",
                       string: "#22863A", number: "#1976D2", function: "#6F42C1", type: "#6F42C1",
                       tag: "#22863A", attribute: "#6F42C1", variable: "#1976D2", builtIn: "#6F42C1",
                       regexp: "#22863A", meta: "#6F42C1", added: "#587C0C", removed: "#AD0707", selection: "#ADD6FF"),
        dark: Palette(background: "#1F1F1F", foreground: "#B392F0", comment: "#6B737C", keyword: "#F97583",
                      string: "#FFAB70", number: "#F8F8F8", function: "#B392F0", type: "#79B8FF",
                      tag: "#FFAB70", attribute: "#79B8FF", variable: "#79B8FF", builtIn: "#79B8FF",
                      regexp: "#FFAB70", meta: "#F97583", added: "#81B88B", removed: "#C74E39", selection: "#264F78"),
        lightName: "Min Light", darkName: "Min Dark", keywords: "miguel solorio minimal")

    // Readability, lightness only: light: comment #B7B5AC → #AEABA1
    public static let flexoki = CodeTheme(
        id: "flexoki", name: "Flexoki",
        light: Palette(background: "#FFFCF0", foreground: "#100F0F", comment: "#AEABA1", keyword: "#66800B",
                       string: "#24837B", number: "#5E409D", function: "#BC5215", type: "#BC5215",
                       tag: "#205EA6", attribute: "#BC5215", variable: "#205EA6", builtIn: "#66800B",
                       regexp: "#24837B", meta: "#AD8301", added: "#66800B", removed: "#AF3029", selection: "#F2F0E5"),
        dark: Palette(background: "#100F0F", foreground: "#CECDC3", comment: "#575653", keyword: "#879A39",
                      string: "#3AA99F", number: "#8B7EC8", function: "#DA702C", type: "#DA702C",
                      tag: "#4385BE", attribute: "#DA702C", variable: "#4385BE", builtIn: "#879A39",
                      regexp: "#3AA99F", meta: "#D0A215", added: "#879A39", removed: "#D14D41", selection: "#1C1B1A"),
        lightName: lightVariant, darkName: darkVariant, keywords: "steph ango kepano flexoki paper ink")

    public static let modus = CodeTheme(
        id: "modus", name: "Modus",
        light: Palette(background: "#FFFFFF", foreground: "#000000", comment: "#595959", keyword: "#531AB6",
                       string: "#3548CF", number: "#0000B0", function: "#721045", type: "#005F5F",
                       tag: "#721045", attribute: "#005E8B", variable: "#005E8B", builtIn: "#8F0075",
                       regexp: "#00663F", meta: "#A0132F", added: "#005000", removed: "#8F1313", selection: "#BDBDBD"),
        dark: Palette(background: "#000000", foreground: "#FFFFFF", comment: "#989898", keyword: "#B6A0FF",
                      string: "#79A8FF", number: "#00BCFF", function: "#FEACD0", type: "#6AE4B9",
                      tag: "#FEACD0", attribute: "#00D3D0", variable: "#00D3D0", builtIn: "#F78FE7",
                      regexp: "#00C06F", meta: "#FF7F86", added: "#A0E0A0", removed: "#FFBFBF", selection: "#5A5A5A"),
        lightName: "Operandi", darkName: "Vivendi", keywords: "protesilaos modus operandi vivendi emacs accessible")

    // MARK: - Light only

    // Readability, lightness only: only: comment #AAAAAA → #A6A6A6, attribute #8190A0 → #808F9F
    public static let quietLight = CodeTheme(
        id: "quiet-light", name: String(localized: "Quiet Light", bundle: .greeceKit, comment: "Code theme name: Visual Studio Code’s soft light theme"),
        only: Palette(background: "#F5F5F5", foreground: "#333333", comment: "#A6A6A6", keyword: "#4B69C6",
                      string: "#448C27", number: "#9C5D27", function: "#AA3731", type: "#7A3E9D",
                      tag: "#4B69C6", attribute: "#808F9F", variable: "#7A3E9D", builtIn: "#AA3731",
                      regexp: "#4B69C6", meta: "#AA3731", added: "#448C27", removed: "#C73D20", selection: "#C9D0D9"),
        italicComments: true, keywords: "vs code vscode microsoft quiet light")

    // Readability, lightness only: only: added #34C759 → #2BA64A
    public static let xcodeSunset = CodeTheme(
        id: "xcode-sunset", name: String(localized: "Sunset", bundle: .greeceKit, comment: "Code theme name: one of Xcode’s built-in themes"),
        only: Palette(background: "#FFFCE5", foreground: "#000000", comment: "#C3741C", keyword: "#294277",
                      string: "#DF0700", number: "#294277", function: "#0F68A0", type: "#B44500",
                      tag: "#294277", attribute: "#2C329D", variable: "#476A97", builtIn: "#476A97",
                      regexp: "#DF0700", meta: "#646485", added: "#2BA64A", removed: "#FF3B30", selection: "#F9DF9C"),
        keywords: "apple xcode sunset")

    // Readability, lightness only: only: added #34C759 → #2CA94B
    public static let xcodeLowKey = CodeTheme(
        id: "xcode-low-key", name: String(localized: "Low Key", bundle: .greeceKit, comment: "Code theme name: one of Xcode’s built-in themes, in muted colours"),
        only: Palette(background: "#FFFFFF", foreground: "#000000", comment: "#435138", keyword: "#262C6A",
                      string: "#702C51", number: "#262C6A", function: "#0F68A0", type: "#476A97",
                      tag: "#262C6A", attribute: "#1E4D1A", variable: "#476A97", builtIn: "#476A97",
                      regexp: "#702C51", meta: "#000000", added: "#2CA94B", removed: "#FF3B30", selection: "#CFD5D1"),
        keywords: "apple xcode low key lowkey")

    // Readability, lightness only: only: added #34C759 → #2CA94B
    public static let xcodeBasic = CodeTheme(
        id: "xcode-basic", name: String(localized: "Basic", bundle: .greeceKit, comment: "Code theme name: one of Xcode’s built-in themes, plain black on white"),
        only: Palette(background: "#FFFFFF", foreground: "#000000", comment: "#008000", keyword: "#0000FF",
                      string: "#A31515", number: "#000000", function: "#0F68A0", type: "#2B839F",
                      tag: "#0000FF", attribute: "#000000", variable: "#2B839F", builtIn: "#2B839F",
                      regexp: "#A31515", meta: "#0000FF", added: "#2CA94B", removed: "#FF3B30", selection: "#A4CDFF"),
        keywords: "apple xcode basic")

    // MARK: - Dark only

    public static let dracula = CodeTheme(
        id: "dracula", name: "Dracula",
        only: Palette(background: "#282A36", foreground: "#F8F8F2", comment: "#6272A4", keyword: "#FF79C6",
                      string: "#F1FA8C", number: "#BD93F9", function: "#50FA7B", type: "#8BE9FD",
                      tag: "#FF79C6", attribute: "#50FA7B", variable: "#BD93F9", builtIn: "#8BE9FD",
                      regexp: "#F1FA8C", meta: "#50FA7B", added: "#50FA7B", removed: "#FF5555", selection: "#44475A"),
        keywords: "dracula zeno rocha")

    public static let monokai = CodeTheme(
        id: "monokai", name: "Monokai",
        only: Palette(background: "#272822", foreground: "#F8F8F2", comment: "#75715E", keyword: "#F92672",
                      string: "#E6DB74", number: "#AE81FF", function: "#A6E22E", type: "#A6E22E",
                      tag: "#F92672", attribute: "#A6E22E", variable: "#FD971F", builtIn: "#66D9EF",
                      regexp: "#E6DB74", meta: "#A6E22E", added: "#A6E22E", removed: "#F92672", selection: "#49483E"),
        keywords: "monokai sublime classic wimer hazenberg")

    public static let nord = CodeTheme(
        id: "nord", name: "Nord",
        only: Palette(background: "#2E3440", foreground: "#D8DEE9", comment: "#616E88", keyword: "#81A1C1",
                      string: "#A3BE8C", number: "#B48EAD", function: "#88C0D0", type: "#8FBCBB",
                      tag: "#81A1C1", attribute: "#8FBCBB", variable: "#81A1C1", builtIn: "#88C0D0",
                      regexp: "#EBCB8B", meta: "#5E81AC", added: "#A3BE8C", removed: "#BF616A", selection: "#3F4758"),
        keywords: "nord arctic ice studio nordtheme")

    public static let githubDimmed = CodeTheme(
        id: "github-dimmed", name: "GitHub Dimmed",
        only: Palette(background: "#22272E", foreground: "#ADBAC7", comment: "#768390", keyword: "#F47067",
                      string: "#96D0FF", number: "#6CB6FF", function: "#DCBDFB", type: "#F69D50",
                      tag: "#8DDB8C", attribute: "#6CB6FF", variable: "#F69D50", builtIn: "#6CB6FF",
                      regexp: "#96D0FF", meta: "#DCBDFB", added: "#8DDB8C", removed: "#FF938A", selection: "#264F78"),
        keywords: "primer github dark dimmed")

    public static let palenight = CodeTheme(
        id: "palenight", name: "Palenight",
        only: Palette(background: "#292D3E", foreground: "#BABED8", comment: "#676E95", keyword: "#C792EA",
                      string: "#C3E88D", number: "#F78C6C", function: "#82AAFF", type: "#FFCB6B",
                      tag: "#F07178", attribute: "#C792EA", variable: "#89DDFF", builtIn: "#82AAFF",
                      regexp: "#C3E88D", meta: "#82AAFF", added: "#C3E88D", removed: "#F07178", selection: "#404663"),
        italicComments: true, keywords: "material theme palenight")

    public static let tomorrowEighties = CodeTheme(
        id: "tomorrow-eighties", name: "Tomorrow Night Eighties",
        only: Palette(background: "#2D2D2D", foreground: "#CCCCCC", comment: "#999999", keyword: "#CC99CC",
                      string: "#99CC99", number: "#F99157", function: "#6699CC", type: "#FFCC66",
                      tag: "#F2777A", attribute: "#F2777A", variable: "#F2777A", builtIn: "#6699CC",
                      regexp: "#99CC99", meta: "#6699CC", added: "#99CC99", removed: "#F2777A", selection: "#515151"),
        keywords: "chris kempson tomorrow night eighties")

    public static let synthwave84 = CodeTheme(
        id: "synthwave-84", name: "SynthWave ’84",
        only: Palette(background: "#262335", foreground: "#BBBBBB", comment: "#848BBD", keyword: "#FEDE5D",
                      string: "#FF8B39", number: "#F97E72", function: "#36F9F6", type: "#FE4450",
                      tag: "#72F1B8", attribute: "#FEDE5D", variable: "#FF7EDB", builtIn: "#36F9F6",
                      regexp: "#F97E72", meta: "#36F9F6", added: "#63C89E", removed: "#FE4450", selection: "#413F4E"),
        italicComments: true, keywords: "synthwave 84 '84 retro neon robb owen")

    public static let cobalt2 = CodeTheme(
        id: "cobalt2", name: "Cobalt2",
        only: Palette(background: "#193549", foreground: "#FFFFFF", comment: "#0088FF", keyword: "#FF9D00",
                      string: "#A5FF90", number: "#FF628C", function: "#FFC600", type: "#FFC600",
                      tag: "#9EFFFF", attribute: "#FFC600", variable: "#FB94FF", builtIn: "#80FFBB",
                      regexp: "#A5FF90", meta: "#9EFFFF", added: "#A5FF90", removed: "#FF628C", selection: "#0050A4"),
        italicComments: true, keywords: "wes bos cobalt cobalt2")

    public static let poimandres = CodeTheme(
        id: "poimandres", name: "Poimandres",
        only: Palette(background: "#1B1E28", foreground: "#A6ACCD", comment: "#5A5F79", keyword: "#91B4D5",
                      string: "#5DE4C7", number: "#5DE4C7", function: "#ADD7FF", type: "#8489A4",
                      tag: "#5DE4C7", attribute: "#91B4D5", variable: "#E4F0FB", builtIn: "#8489A4",
                      regexp: "#5FB3A1", meta: "#ADD7FF", added: "#5FB3A1", removed: "#D0679D", selection: "#272C3C"),
        italicComments: true, keywords: "poimandres drcmda")

    public static let panda = CodeTheme(
        id: "panda", name: "Panda",
        only: Palette(background: "#292A2B", foreground: "#E6E6E6", comment: "#676B79", keyword: "#FF75B5",
                      string: "#19F9D8", number: "#FFB86C", function: "#6FC1FF", type: "#19F9D8",
                      tag: "#FF2C6D", attribute: "#FFB86C", variable: "#FF9AC1", builtIn: "#B084EB",
                      regexp: "#6FC1FF", meta: "#6FC1FF", added: "#19F9D8", removed: "#FF2C6D", selection: "#5F4E3B"),
        italicComments: true, keywords: "panda syntax tinkertrain")

    public static let mariana = CodeTheme(
        id: "mariana", name: "Mariana",
        only: Palette(background: "#303841", foreground: "#D8DEE9", comment: "#A6ACB9", keyword: "#C695C6",
                      string: "#99C794", number: "#F9AE58", function: "#5FB4B4", type: "#F9AE58",
                      tag: "#EC5F66", attribute: "#C695C6", variable: "#EC5F66", builtIn: "#6699CC",
                      regexp: "#99C794", meta: "#5FB4B4", added: "#99C794", removed: "#EC5F66", selection: "#4D5864"),
        keywords: "sublime text mariana")

    public static let zenburn = CodeTheme(
        id: "zenburn", name: "Zenburn",
        only: Palette(background: "#3F3F3F", foreground: "#DCDCCC", comment: "#7F9F7F", keyword: "#F0DFAF",
                      string: "#CC9393", number: "#8CD0D3", function: "#EFEF8F", type: "#DFDFBF",
                      tag: "#E89393", attribute: "#DFDFBF", variable: "#EFDCBC", builtIn: "#EFEF8F",
                      regexp: "#CC9393", meta: "#FFCFAF", added: "#709080", removed: "#ECBCBC", selection: "#2F2F2F"),
        keywords: "zenburn jani nurminen vim")

    // Readability, lightness only: only: attribute #2D449B → #3651B9
    public static let xcodeMidnight = CodeTheme(
        id: "xcode-midnight", name: String(localized: "Midnight", bundle: .greeceKit, comment: "Code theme name: one of Xcode’s built-in themes, on black"),
        only: Palette(background: "#000000", foreground: "#FFFFFF", comment: "#41CC45", keyword: "#D31895",
                      string: "#FF2C38", number: "#786DFF", function: "#41A1C0", type: "#00A0FF",
                      tag: "#D31895", attribute: "#3651B9", variable: "#23FF83", builtIn: "#00A0FF",
                      regexp: "#FF2C38", meta: "#E47C48", added: "#30D158", removed: "#FF453A", selection: "#4B4740"),
        keywords: "apple xcode midnight")

    // Readability, lightness only: only: keyword #B21889 → #C41A97, tag #B21889 → #C41A97
    public static let xcodeDusk = CodeTheme(
        id: "xcode-dusk", name: String(localized: "Dusk", bundle: .greeceKit, comment: "Code theme name: one of Xcode’s built-in themes, on dark grey"),
        only: Palette(background: "#1E2028", foreground: "#FFFFFF", comment: "#41B645", keyword: "#C41A97",
                      string: "#DB2C38", number: "#786DC4", function: "#41A1C0", type: "#00A0BE",
                      tag: "#C41A97", attribute: "#55747C", variable: "#83C057", builtIn: "#00A0BE",
                      regexp: "#DB2C38", meta: "#C67C48", added: "#30D158", removed: "#FF453A", selection: "#54554A"),
        keywords: "apple xcode dusk")

    public static let xcodeCivic = CodeTheme(
        id: "xcode-civic", name: String(localized: "Civic", bundle: .greeceKit, comment: "Code theme name: one of Xcode’s built-in themes"),
        only: Palette(background: "#1F2029", foreground: "#E1E2E7", comment: "#45BB3E", keyword: "#D7008F",
                      string: "#D3232E", number: "#149C92", function: "#41A1C0", type: "#25908D",
                      tag: "#D7008F", attribute: "#55747C", variable: "#1DA9A2", builtIn: "#25908D",
                      regexp: "#D3232E", meta: "#C77A4B", added: "#30D158", removed: "#FF453A", selection: "#35404E"),
        keywords: "apple xcode civic")
}
