import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Manages light/dark theme detection and provides theme names for renderers.
final class ThemeManager {

    static let shared = ThemeManager()

    // MARK: - Markdown Themes

    struct MarkdownTheme: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    static let markdownThemes: [MarkdownTheme] = [
        MarkdownTheme(id: "github-light", displayName: "GitHub Light"),
        MarkdownTheme(id: "github-dark", displayName: "GitHub Dark"),
        MarkdownTheme(id: "solarized-light", displayName: "Solarized Light"),
        MarkdownTheme(id: "solarized-dark", displayName: "Solarized Dark"),
        MarkdownTheme(id: "nord", displayName: "Nord"),
        MarkdownTheme(id: "dracula", displayName: "Dracula"),
        MarkdownTheme(id: "one-light", displayName: "One Light"),
        MarkdownTheme(id: "one-dark", displayName: "One Dark"),
        MarkdownTheme(id: "monokai", displayName: "Monokai"),
        MarkdownTheme(id: "gruvbox-light", displayName: "Gruvbox Light"),
        MarkdownTheme(id: "gruvbox-dark", displayName: "Gruvbox Dark"),
    ]

    // MARK: - Code Themes (highlight.js theme names)

    struct CodeTheme: Identifiable, Hashable {
        let id: String
        let displayName: String
        let isDark: Bool
    }

    static let codeThemes: [CodeTheme] = [
        // Light themes
        CodeTheme(id: "xcode", displayName: "Xcode", isDark: false),
        CodeTheme(id: "github", displayName: "GitHub", isDark: false),
        CodeTheme(id: "vs", displayName: "Visual Studio", isDark: false),
        CodeTheme(id: "atom-one-light", displayName: "Atom One Light", isDark: false),
        CodeTheme(id: "solarized-light", displayName: "Solarized Light", isDark: false),
        CodeTheme(id: "intellij-light", displayName: "IntelliJ Light", isDark: false),
        CodeTheme(id: "googlecode", displayName: "Google Code", isDark: false),
        CodeTheme(id: "stackoverflow-light", displayName: "Stack Overflow Light", isDark: false),
        CodeTheme(id: "gruvbox-light", displayName: "Gruvbox Light", isDark: false),
        // Dark themes
        CodeTheme(id: "atom-one-dark", displayName: "Atom One Dark", isDark: true),
        CodeTheme(id: "monokai", displayName: "Monokai", isDark: true),
        CodeTheme(id: "dracula", displayName: "Dracula", isDark: true),
        CodeTheme(id: "nord", displayName: "Nord", isDark: true),
        CodeTheme(id: "solarized-dark", displayName: "Solarized Dark", isDark: true),
        CodeTheme(id: "vs2015", displayName: "VS 2015 Dark", isDark: true),
        CodeTheme(id: "github-dark", displayName: "GitHub Dark", isDark: true),
        CodeTheme(id: "stackoverflow-dark", displayName: "Stack Overflow Dark", isDark: true),
        CodeTheme(id: "gruvbox-dark", displayName: "Gruvbox Dark", isDark: true),
        CodeTheme(id: "tokyo-night-dark", displayName: "Tokyo Night", isDark: true),
        CodeTheme(id: "catppuccin-mocha", displayName: "Catppuccin Mocha", isDark: true),
    ]

    // MARK: - System Appearance Detection

    var isDarkMode: Bool {
        #if canImport(AppKit)
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.current
        return appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        return false
        #endif
    }

    // MARK: - Active Theme Resolution

    var currentMarkdownTheme: String {
        let settings = GreeceSettings.shared
        return isDarkMode ? settings.markdownDarkTheme : settings.markdownLightTheme
    }

    var currentCodeTheme: String {
        let settings = GreeceSettings.shared
        return isDarkMode ? settings.codeDarkTheme : settings.codeLightTheme
    }

    // MARK: - CSS Variables for current theme

    func markdownCSSVariables() -> String {
        let settings = GreeceSettings.shared
        let theme = currentMarkdownTheme
        return """
        :root {
            --font-family: \(settings.markdownFontFamily), -apple-system, BlinkMacSystemFont, sans-serif;
            --font-size: \(settings.markdownFontSize)px;
            --line-height: \(settings.markdownLineHeight);
            --theme: \(theme);
        }
        """
    }

    func codeCSSVariables() -> String {
        let settings = GreeceSettings.shared
        let weight = cssWeight(from: settings.codeFontWeight)
        return """
        :root {
            --code-font-family: '\(settings.codeFontFamily)', 'SF Mono', 'Menlo', 'Monaco', monospace;
            --code-font-size: \(settings.codeFontSize)px;
            --code-font-weight: \(weight);
            --tab-width: \(settings.codeTabWidth);
            --word-wrap: \(settings.codeWordWrap ? "pre-wrap" : "pre");
        }
        """
    }

    private func cssWeight(from name: String) -> String {
        switch name.lowercased() {
        case "ultralight": return "100"
        case "thin":       return "200"
        case "light":      return "300"
        case "regular":    return "400"
        case "medium":     return "500"
        case "semibold":   return "600"
        case "bold":       return "700"
        case "heavy":      return "800"
        case "black":      return "900"
        default:           return "400"
        }
    }

    // MARK: - Available System Monospace Fonts

    static let monospaceFonts: [String] = [
        "SF Mono",
        "Menlo",
        "Monaco",
        "Courier New",
        "Fira Code",
        "JetBrains Mono",
        "Source Code Pro",
        "Cascadia Code",
        "IBM Plex Mono",
        "Inconsolata",
        "Hack",
        "Anonymous Pro",
    ]

    static let proportionalFonts: [String] = [
        "-apple-system",
        "Helvetica Neue",
        "Georgia",
        "Charter",
        "Palatino",
        "New York",
        "Avenir Next",
        "San Francisco",
        "Inter",
        "Source Sans Pro",
        "Lato",
    ]

    static let fontWeights: [String] = [
        "ultralight", "thin", "light", "regular",
        "medium", "semibold", "bold", "heavy", "black"
    ]
}
