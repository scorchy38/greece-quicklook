import SwiftUI
import GreeceKit

/// Every setting, so the sidebar's search can find it by name or by what it's about.
/// Titles match in the app's language; the English title and keywords match as well.
struct SettingsEntry: Identifiable, Hashable {
    let title: String
    let page: Page
    let keywords: String
    var id: String { page.rawValue + keywords }

    init(title: LocalizedStringResource, page: Page, keywords: String) {
        self.title = String(localized: title)
        self.page = page
        self.keywords = title.key + " " + keywords
    }

    /// Every word must appear in the title, the page or the keywords, ignoring case and accents.
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            title.localizedStandardContains(word) || page.title.localizedStandardContains(word)
                || keywords.localizedStandardContains(word)
        }
    }

    static let all: [SettingsEntry] = [
        .init(title: "Reading theme", page: .markdown,
              keywords: "style look appearance typography colours colors sepia paper serif " + ReadingTheme.all.map(\.name).joined(separator: " ")),
        .init(title: "Reading font", page: .markdown, keywords: "typeface serif new york rounded typography theme default"),
        .init(title: "Reading size", page: .markdown, keywords: "text size zoom typography"),
        .init(title: "Line width", page: .markdown, keywords: "measure column wide narrow"),
        .init(title: "Outline beside long documents", page: .markdown, keywords: "table of contents toc headings sidebar"),
        .init(title: "Front matter as properties", page: .markdown, keywords: "yaml metadata frontmatter"),
        .init(title: "Math", page: .markdown, keywords: "katex latex equations formulas"),
        .init(title: "Mermaid diagrams", page: .markdown, keywords: "charts flowchart sequence graphs"),
        .init(title: "Diagram theme", page: .markdown,
              keywords: "mermaid charts flowchart colours colors palette match code " + DiagramTheme.all.map(\.name).joined(separator: " ")),
        .init(title: "Load remote images", page: .markdown, keywords: "internet network web privacy"),
        .init(title: "Code theme", page: .code,
              keywords: "colors colours syntax highlighting dark light palette " + CodeTheme.all.map { "\($0.name) \($0.keywords)" }.joined(separator: " ")),
        .init(title: "Theme variant", page: .code, keywords: "light dark automatic pin appearance always"),
        .init(title: "Code font", page: .code, keywords: "monospace typeface sf mono jetbrains fira ligatures"),
        .init(title: "Code font weight", page: .code, keywords: "light regular medium semibold bold thin heavy"),
        .init(title: "Code size", page: .code, keywords: "text size zoom"),
        .init(title: "Tab width", page: .code, keywords: "indentation spaces tabs"),
        .init(title: "Line numbers", page: .code, keywords: "gutter"),
        .init(title: "Wrap long lines", page: .code, keywords: "word wrap soft wrap"),
        .init(title: "Format minified JSON", page: .code, keywords: "pretty print beautify json xml"),
        .init(title: "Row numbers", page: .data, keywords: "tables csv tsv sqlite"),
        .init(title: "Rows to show", page: .data, keywords: "limit large tables csv tsv sqlite"),
        .init(title: "Show hidden files", page: .files, keywords: "dotfiles archives folders zip"),
        .init(title: "Keep folders on top", page: .files, keywords: "sort order archives folders"),
        .init(title: "Appearance", page: .general, keywords: "dark mode light mode theme"),
        .init(title: "Info bar", page: .general, keywords: "status bar footer details size"),
        .init(title: "Update previews when files change", page: .general, keywords: "live reload refresh save auto"),
        .init(title: "Remember scroll position", page: .general, keywords: "resume reading position where I left off"),
        .init(title: "Remember window size", page: .general, keywords: "panel size quick look window"),
        .init(title: "Forget positions and sizes", page: .general, keywords: "reset clear memory privacy"),
        .init(title: "Preview kinds", page: .general, keywords: "turn off formats extensions code documents data archives apps 3d models maps fonts media hand back apple"),
        .init(title: "Menu bar", page: .general, keywords: "status item recent files agents claude codex"),
        .init(title: "Recently previewed files", page: .general, keywords: "history recents privacy"),
        .init(title: "Open at login", page: .general, keywords: "startup launch login items"),
        .init(title: "Terminal command", page: .general, keywords: "cli command line shell greece install pipe"),
        .init(title: "Turn on Greece", page: .general, keywords: "enable extension quick look status"),
        .init(title: "Restart Quick Look", page: .general, keywords: "reset cache refresh qlmanage"),
        .init(title: "Restore default settings", page: .general, keywords: "reset defaults"),
        .init(title: "Diagnostics", page: .diagnostics, keywords: "troubleshoot not working conflicts extensions repair csv typescript plain text"),
        .init(title: "Other Quick Look extensions", page: .diagnostics, keywords: "conflict peek looq syntax highlight qlmarkdown"),
        .init(title: "Copy report", page: .diagnostics, keywords: "support bug feedback"),
    ]
}

/// The sidebar while searching: matching settings, each opening its page.
struct SettingsSearchResults: View {
    let query: String
    var body: some View {
        let results = SettingsEntry.all.filter { $0.matches(query) }
        Section("Settings") {
            if results.isEmpty {
                Text("No settings match “\(query)”", comment: "Settings search; the argument is what was typed")
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                    Text(entry.page.title).font(.caption).foregroundStyle(.secondary)
                }
                .tag(entry.page)
            }
        }
    }
}
