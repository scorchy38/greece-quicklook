import Foundation

/// Thread-safe wrapper around UserDefaults (App Group) for shared settings.
final class GreeceSettings {

    static let shared = GreeceSettings()

    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: GreeceConstants.appGroupIdentifier) ?? .standard
        registerDefaults()
    }

    // MARK: - Register Defaults

    private func registerDefaults() {
        defaults.register(defaults: [
            // General
            GreeceConstants.Keys.showMetadataBar: true,
            GreeceConstants.Keys.metadataShowSize: true,
            GreeceConstants.Keys.metadataShowDates: true,
            GreeceConstants.Keys.metadataShowType: true,
            GreeceConstants.Keys.rememberScrollPosition: true,
            GreeceConstants.Keys.cacheRemoteImages: true,

            // Markdown
            GreeceConstants.Keys.markdownLightTheme: "github-light",
            GreeceConstants.Keys.markdownDarkTheme: "github-dark",
            GreeceConstants.Keys.markdownFontFamily: "-apple-system",
            GreeceConstants.Keys.markdownFontSize: 15,
            GreeceConstants.Keys.markdownLineHeight: 1.6,
            GreeceConstants.Keys.markdownShowTOC: true,
            GreeceConstants.Keys.markdownRenderMath: true,
            GreeceConstants.Keys.markdownRenderMermaid: true,
            GreeceConstants.Keys.markdownRenderEmoji: true,

            // Source Code
            GreeceConstants.Keys.codeLightTheme: "xcode",
            GreeceConstants.Keys.codeDarkTheme: "atom-one-dark",
            GreeceConstants.Keys.codeFontFamily: "SF Mono",
            GreeceConstants.Keys.codeFontSize: 13,
            GreeceConstants.Keys.codeFontWeight: "regular",
            GreeceConstants.Keys.codeShowLineNumbers: true,
            GreeceConstants.Keys.codeWordWrap: false,
            GreeceConstants.Keys.codeTabWidth: 4,
            GreeceConstants.Keys.codeAutoFormat: true,

            // Data
            GreeceConstants.Keys.csvAlternatingRows: true,
            GreeceConstants.Keys.csvMaxRows: GreeceConstants.maxCSVRows,
            GreeceConstants.Keys.sqliteDefaultTable: "",

            // Archives
            GreeceConstants.Keys.archiveSortColumn: "name",
            GreeceConstants.Keys.archiveSortAscending: true,
            GreeceConstants.Keys.archiveShowHidden: false,

            // Folders
            GreeceConstants.Keys.folderShowHidden: false,
            GreeceConstants.Keys.folderShowSize: true,
            GreeceConstants.Keys.folderShowDate: true,
            GreeceConstants.Keys.folderShowKind: true,
            GreeceConstants.Keys.folderShowTags: true,
        ])
    }

    // MARK: - Generic Accessors

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func integer(forKey key: String) -> Int {
        defaults.integer(forKey: key)
    }

    func double(forKey key: String) -> Double {
        defaults.double(forKey: key)
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: - Convenience Properties

    // General
    var showMetadataBar: Bool {
        get { bool(forKey: GreeceConstants.Keys.showMetadataBar) }
        set { set(newValue, forKey: GreeceConstants.Keys.showMetadataBar) }
    }

    var rememberScrollPosition: Bool {
        get { bool(forKey: GreeceConstants.Keys.rememberScrollPosition) }
        set { set(newValue, forKey: GreeceConstants.Keys.rememberScrollPosition) }
    }

    var cacheRemoteImages: Bool {
        get { bool(forKey: GreeceConstants.Keys.cacheRemoteImages) }
        set { set(newValue, forKey: GreeceConstants.Keys.cacheRemoteImages) }
    }

    // Markdown
    var markdownLightTheme: String {
        get { string(forKey: GreeceConstants.Keys.markdownLightTheme) ?? "github-light" }
        set { set(newValue, forKey: GreeceConstants.Keys.markdownLightTheme) }
    }

    var markdownDarkTheme: String {
        get { string(forKey: GreeceConstants.Keys.markdownDarkTheme) ?? "github-dark" }
        set { set(newValue, forKey: GreeceConstants.Keys.markdownDarkTheme) }
    }

    var markdownFontFamily: String {
        get { string(forKey: GreeceConstants.Keys.markdownFontFamily) ?? "-apple-system" }
        set { set(newValue, forKey: GreeceConstants.Keys.markdownFontFamily) }
    }

    var markdownFontSize: Int {
        get { integer(forKey: GreeceConstants.Keys.markdownFontSize) }
        set { set(newValue, forKey: GreeceConstants.Keys.markdownFontSize) }
    }

    var markdownLineHeight: Double {
        get { double(forKey: GreeceConstants.Keys.markdownLineHeight) }
        set { set(newValue, forKey: GreeceConstants.Keys.markdownLineHeight) }
    }

    var markdownShowTOC: Bool {
        get { bool(forKey: GreeceConstants.Keys.markdownShowTOC) }
        set { set(newValue, forKey: GreeceConstants.Keys.markdownShowTOC) }
    }

    var markdownRenderMath: Bool {
        get { bool(forKey: GreeceConstants.Keys.markdownRenderMath) }
        set { set(newValue, forKey: GreeceConstants.Keys.markdownRenderMath) }
    }

    var markdownRenderMermaid: Bool {
        get { bool(forKey: GreeceConstants.Keys.markdownRenderMermaid) }
        set { set(newValue, forKey: GreeceConstants.Keys.markdownRenderMermaid) }
    }

    var markdownRenderEmoji: Bool {
        get { bool(forKey: GreeceConstants.Keys.markdownRenderEmoji) }
        set { set(newValue, forKey: GreeceConstants.Keys.markdownRenderEmoji) }
    }

    // Source Code
    var codeLightTheme: String {
        get { string(forKey: GreeceConstants.Keys.codeLightTheme) ?? "xcode" }
        set { set(newValue, forKey: GreeceConstants.Keys.codeLightTheme) }
    }

    var codeDarkTheme: String {
        get { string(forKey: GreeceConstants.Keys.codeDarkTheme) ?? "atom-one-dark" }
        set { set(newValue, forKey: GreeceConstants.Keys.codeDarkTheme) }
    }

    var codeFontFamily: String {
        get { string(forKey: GreeceConstants.Keys.codeFontFamily) ?? "SF Mono" }
        set { set(newValue, forKey: GreeceConstants.Keys.codeFontFamily) }
    }

    var codeFontSize: Int {
        get { integer(forKey: GreeceConstants.Keys.codeFontSize) }
        set { set(newValue, forKey: GreeceConstants.Keys.codeFontSize) }
    }

    var codeFontWeight: String {
        get { string(forKey: GreeceConstants.Keys.codeFontWeight) ?? "regular" }
        set { set(newValue, forKey: GreeceConstants.Keys.codeFontWeight) }
    }

    var codeShowLineNumbers: Bool {
        get { bool(forKey: GreeceConstants.Keys.codeShowLineNumbers) }
        set { set(newValue, forKey: GreeceConstants.Keys.codeShowLineNumbers) }
    }

    var codeWordWrap: Bool {
        get { bool(forKey: GreeceConstants.Keys.codeWordWrap) }
        set { set(newValue, forKey: GreeceConstants.Keys.codeWordWrap) }
    }

    var codeTabWidth: Int {
        get { integer(forKey: GreeceConstants.Keys.codeTabWidth) }
        set { set(newValue, forKey: GreeceConstants.Keys.codeTabWidth) }
    }

    var codeAutoFormat: Bool {
        get { bool(forKey: GreeceConstants.Keys.codeAutoFormat) }
        set { set(newValue, forKey: GreeceConstants.Keys.codeAutoFormat) }
    }

    // Data
    var csvAlternatingRows: Bool {
        get { bool(forKey: GreeceConstants.Keys.csvAlternatingRows) }
        set { set(newValue, forKey: GreeceConstants.Keys.csvAlternatingRows) }
    }

    var csvMaxRows: Int {
        get { integer(forKey: GreeceConstants.Keys.csvMaxRows) }
        set { set(newValue, forKey: GreeceConstants.Keys.csvMaxRows) }
    }

    // Archives
    var archiveShowHidden: Bool {
        get { bool(forKey: GreeceConstants.Keys.archiveShowHidden) }
        set { set(newValue, forKey: GreeceConstants.Keys.archiveShowHidden) }
    }

    // Folders
    var folderShowHidden: Bool {
        get { bool(forKey: GreeceConstants.Keys.folderShowHidden) }
        set { set(newValue, forKey: GreeceConstants.Keys.folderShowHidden) }
    }

    var folderShowTags: Bool {
        get { bool(forKey: GreeceConstants.Keys.folderShowTags) }
        set { set(newValue, forKey: GreeceConstants.Keys.folderShowTags) }
    }

    // MARK: - Scroll Position Memory

    func scrollPosition(for filePath: String) -> Double? {
        let positions = defaults.dictionary(forKey: GreeceConstants.Keys.scrollPositions) as? [String: Double]
        return positions?[filePath]
    }

    func setScrollPosition(_ position: Double, for filePath: String) {
        var positions = (defaults.dictionary(forKey: GreeceConstants.Keys.scrollPositions) as? [String: Double]) ?? [:]
        positions[filePath] = position
        // Keep only the last 500 entries
        if positions.count > 500 {
            let sorted = positions.sorted { $0.value < $1.value }
            positions = Dictionary(uniqueKeysWithValues: Array(sorted.suffix(400)))
        }
        set(positions, forKey: GreeceConstants.Keys.scrollPositions)
    }

    // MARK: - Image Cache Management

    var imageCacheURL: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(GreeceConstants.imageCacheDirectory)
    }

    func clearImageCache() {
        guard let cacheURL = imageCacheURL else { return }
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
