import Foundation
import Combine

/// Every user preference that shapes a preview. Stored as one JSON document in the
/// shared App Group so the app and the Quick Look extension always agree.
public struct PreviewSettings: Codable, Equatable, Sendable {

    public enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .system: return String(localized: "Match System", bundle: .greeceKit, comment: "Appearance option: follow the Mac’s light or dark appearance")
            case .light: return Self.lightTitle
            case .dark: return Self.darkTitle
            }
        }

        /// Light or dark appearance: also a code theme's variant and group.
        static var lightTitle: String {
            String(localized: "Light", bundle: .greeceKit, comment: "Appearance, or a theme’s variant: light, as opposed to dark")
        }
        static var darkTitle: String {
            String(localized: "Dark", bundle: .greeceKit, comment: "Appearance, or a theme’s variant: dark, as opposed to light")
        }
    }

    public enum ReadingFont: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The reading theme's own typefaces.
        case theme
        case system, serif, rounded, mono
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .theme: return String(localized: "Theme Default", bundle: .greeceKit, comment: "Reading font option: the reading theme’s own typefaces")
            // Typeface names.
            case .system: return "San Francisco"
            case .serif: return "New York"
            case .rounded: return "SF Rounded"
            case .mono: return "SF Mono"
            }
        }
        var cssStack: String {
            switch self {
            case .theme, .system: return "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif"
            case .serif: return "ui-serif, 'New York', Georgia, serif"
            case .rounded: return "ui-rounded, 'SF Pro Rounded', -apple-system, sans-serif"
            case .mono: return "ui-monospace, 'SF Mono', Menlo, monospace"
            }
        }
    }

    public enum ReadingWidth: String, Codable, CaseIterable, Identifiable, Sendable {
        case narrow, comfortable, wide, full
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .narrow: return String(localized: "Narrow", bundle: .greeceKit, comment: "Line width option for reading Markdown")
            case .comfortable: return String(localized: "Comfortable", bundle: .greeceKit, comment: "Line width option for reading Markdown")
            case .wide: return String(localized: "Wide", bundle: .greeceKit, comment: "Line width option for reading Markdown")
            case .full: return String(localized: "Full Width", bundle: .greeceKit, comment: "Line width option for reading Markdown: as wide as the window")
            }
        }
        var css: String {
            switch self {
            case .narrow: return "620px"
            case .comfortable: return "760px"
            case .wide: return "960px"
            case .full: return "none"
            }
        }
    }

    /// Which palette of a light-and-dark code theme to use.
    public enum ThemeVariant: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic, light, dark
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .automatic: return String(localized: "Automatic", bundle: .greeceKit, comment: "Code theme variant: follow the Mac’s appearance")
            case .light: return Appearance.lightTitle
            case .dark: return Appearance.darkTitle
            }
        }
    }

    public enum CodeFontWeight: String, Codable, CaseIterable, Identifiable, Sendable {
        case light, regular, medium, semibold
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .light: return String(localized: "Light [font weight]", defaultValue: "Light", bundle: .greeceKit, comment: "Code font weight: thinner than regular")
            case .regular: return String(localized: "Regular", bundle: .greeceKit, comment: "Code font weight")
            case .medium: return String(localized: "Medium", bundle: .greeceKit, comment: "Code font weight: a little bolder than regular")
            case .semibold: return String(localized: "Semibold", bundle: .greeceKit, comment: "Code font weight")
            }
        }
        /// The CSS `font-weight`.
        public var value: Int {
            switch self {
            case .light: return 300
            case .regular: return 400
            case .medium: return 500
            case .semibold: return 600
            }
        }
    }

    /// How long Greece remembers where you were in a file.
    public enum Memory: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, session, always
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .off: return Self.offTitle
            case .session: return String(localized: "Until Restart", bundle: .greeceKit, comment: "Option for remembering scroll positions: until the Mac restarts")
            case .always: return String(localized: "Always", bundle: .greeceKit, comment: "Option for remembering scroll positions")
            }
        }

        static var offTitle: String {
            String(localized: "Off", bundle: .greeceKit, comment: "A setting or feature that is turned off")
        }
    }

    /// Whether the Quick Look window opens at the size you last left it.
    public enum WindowMemory: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, allFiles, perKind
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .off: return Memory.offTitle
            case .allFiles: return String(localized: "For All Files", bundle: .greeceKit, comment: "Option for remembering the window size: one size for every file")
            case .perKind: return String(localized: "For Each Kind of File", bundle: .greeceKit, comment: "Option for remembering the window size: a size per kind of file")
            }
        }
    }

    // General
    public var appearance: Appearance = .system
    public var showInfoBar = true
    public var liveUpdates = true
    public var rememberScroll: Memory = .session
    public var rememberWindowSize: WindowMemory = .allFiles
    /// Raised by the app's "Forget Positions and Sizes"; the extension then clears its memory.
    public var memoryGeneration = 0
    /// Keep a list of recently previewed files for the menu bar.
    public var recordRecents = true
    public var showInMenuBar = true

    // Code
    public var theme = CodeTheme.default.id
    /// Pins one palette of a light-and-dark theme; automatic follows the appearance.
    public var themeVariant: ThemeVariant = .automatic
    public var codeFont = "SF Mono"
    public var codeFontSize: Double = 12
    public var codeFontWeight: CodeFontWeight = .regular
    public var lineNumbers = true
    public var wrapLines = false
    public var tabWidth = 4
    public var prettyPrint = true

    // Markdown
    public var readingTheme = ReadingTheme.default.id
    public var diagramTheme = DiagramTheme.default.id
    /// `.theme` uses the reading theme's own typefaces.
    public var readingFont: ReadingFont = .theme
    public var readingSize: Double = 15
    public var readingWidth: ReadingWidth = .comfortable
    public var showOutline = true
    public var renderMath = true
    public var renderDiagrams = true
    public var loadRemoteImages = true
    public var showFrontMatter = true

    // Data
    public var rowNumbers = true
    public var maxRows = 100_000

    // Archives & folders
    public var showHiddenFiles = false
    public var foldersFirst = true

    public init() {}

    public static let `default` = PreviewSettings()

    // Tolerant decoding: unknown keys are ignored, missing keys keep their defaults,
    // so older and newer builds can share one settings document safely.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? c.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        read(.appearance, &appearance)
        read(.showInfoBar, &showInfoBar)
        read(.liveUpdates, &liveUpdates)
        read(.rememberScroll, &rememberScroll)
        read(.rememberWindowSize, &rememberWindowSize)
        read(.memoryGeneration, &memoryGeneration)
        read(.recordRecents, &recordRecents)
        read(.showInMenuBar, &showInMenuBar)
        read(.theme, &theme)
        read(.themeVariant, &themeVariant)
        read(.codeFontWeight, &codeFontWeight)
        read(.readingTheme, &readingTheme)
        read(.diagramTheme, &diagramTheme)
        read(.codeFont, &codeFont)
        read(.codeFontSize, &codeFontSize)
        read(.lineNumbers, &lineNumbers)
        read(.wrapLines, &wrapLines)
        read(.tabWidth, &tabWidth)
        read(.prettyPrint, &prettyPrint)
        read(.readingFont, &readingFont)
        read(.readingSize, &readingSize)
        read(.readingWidth, &readingWidth)
        read(.showOutline, &showOutline)
        read(.renderMath, &renderMath)
        read(.renderDiagrams, &renderDiagrams)
        read(.loadRemoteImages, &loadRemoteImages)
        read(.showFrontMatter, &showFrontMatter)
        read(.rowNumbers, &rowNumbers)
        read(.maxRows, &maxRows)
        read(.showHiddenFiles, &showHiddenFiles)
        read(.foldersFirst, &foldersFirst)
        sanitize()
    }

    mutating func sanitize() {
        codeFontSize = min(max(codeFontSize, 9), 24)
        readingSize = min(max(readingSize, 11), 26)
        tabWidth = min(max(tabWidth, 1), 8)
        maxRows = min(max(maxRows, 100), 1_000_000)
        if CodeTheme.named(theme) == nil { theme = CodeTheme.default.id }
        if ReadingTheme.named(readingTheme) == nil { readingTheme = ReadingTheme.default.id }
        if DiagramTheme.named(diagramTheme) == nil { diagramTheme = DiagramTheme.default.id }
    }

    /// The code theme as previews draw it, with any pinned variant applied.
    public var codeTheme: CodeTheme { (CodeTheme.named(theme) ?? .default).pinned(themeVariant) }

    /// The Markdown reading theme.
    public var markdownTheme: ReadingTheme { ReadingTheme.named(readingTheme) ?? .default }

    /// The Mermaid diagram theme.
    public var mermaidTheme: DiagramTheme { DiagramTheme.named(diagramTheme) ?? .default }

    /// The body typeface for reading, from the font setting or the reading theme.
    var readingFontStack: String {
        readingFont == .theme ? markdownTheme.bodyFont : readingFont.cssStack
    }

    /// The heading typeface for reading: the theme's own, or New York with the serif setting.
    var headingFontStack: String {
        switch readingFont {
        case .theme: return markdownTheme.headingFont
        case .serif: return ReadingFont.serif.cssStack
        default: return readingFont.cssStack
        }
    }
}

/// Reads and writes `PreviewSettings` in the shared App Group container.
public final class SettingsStore: ObservableObject {

    public static let appGroup = "ZHCT595PYJ.com.scorchy.greece"
    static let key = "preview-settings.v1"

    public static let shared = SettingsStore()

    @Published public var settings: PreviewSettings {
        didSet { if settings != oldValue { save() } }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: SettingsStore.appGroup) ?? .standard
        self.defaults = store
        self.settings = SettingsStore.read(from: store)
    }

    /// The freshest settings, read straight from disk. The extension calls this for every preview.
    public static func current() -> PreviewSettings {
        read(from: UserDefaults(suiteName: appGroup) ?? .standard)
    }

    public func reset() { settings = PreviewSettings() }

    private static func read(from defaults: UserDefaults) -> PreviewSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(PreviewSettings.self, from: data) else {
            return PreviewSettings()
        }
        return decoded
    }

    private func save() {
        var clean = settings
        clean.sanitize()
        if let data = try? JSONEncoder().encode(clean) { defaults.set(data, forKey: Self.key) }
    }
}
