import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case markdown = "Markdown"
        case code = "Source Code"
        case data = "Data Files"
        case archives = "Archives"
        case folders = "Folders"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .markdown: return "text.document"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .data: return "tablecells"
            case .archives: return "archivebox"
            case .folders: return "folder"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsView()
                    case .markdown:
                        MarkdownSettingsView()
                    case .code:
                        CodeSettingsView()
                    case .data:
                        DataSettingsView()
                    case .archives:
                        ArchiveSettingsView()
                    case .folders:
                        FolderSettingsView()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage(GreeceConstants.Keys.showMetadataBar, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var showMetadataBar = true

    @AppStorage(GreeceConstants.Keys.metadataShowSize, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var metadataShowSize = true

    @AppStorage(GreeceConstants.Keys.metadataShowDates, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var metadataShowDates = true

    @AppStorage(GreeceConstants.Keys.metadataShowType, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var metadataShowType = true

    @AppStorage(GreeceConstants.Keys.rememberScrollPosition, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var rememberScrollPosition = true

    @AppStorage(GreeceConstants.Keys.cacheRemoteImages, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var cacheRemoteImages = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Metadata Bar") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show metadata bar", isOn: $showMetadataBar)

                    if showMetadataBar {
                        Group {
                            Toggle("Show file size", isOn: $metadataShowSize)
                            Toggle("Show modification date", isOn: $metadataShowDates)
                            Toggle("Show file type", isOn: $metadataShowType)
                        }
                        .padding(.leading, 20)
                    }
                }
                .padding(8)
            }

            GroupBox("Behavior") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Remember scroll position across previews", isOn: $rememberScrollPosition)
                    Toggle("Cache remote images in Markdown files", isOn: $cacheRemoteImages)

                    if cacheRemoteImages {
                        Button("Clear Image Cache") {
                            GreeceSettings.shared.clearImageCache()
                        }
                        .padding(.leading, 20)
                    }
                }
                .padding(8)
            }

            GroupBox("About") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Greece")
                            .font(.headline)
                        Text("v1.0.0")
                            .foregroundColor(.secondary)
                    }
                    Text("A better look at your files.")
                        .foregroundColor(.secondary)
                    Text("Built natively for macOS. No new app to manage, just a better Quick Look experience right in Finder.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .padding(.top, 2)

                    Divider()
                        .padding(.vertical, 4)

                    Text("Quick Look Extension Status")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("To enable Greece, go to System Settings → Privacy & Security → Extensions → Quick Look and ensure Greece is enabled.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Markdown Settings

struct MarkdownSettingsView: View {
    @AppStorage(GreeceConstants.Keys.markdownLightTheme, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var lightTheme = "github-light"

    @AppStorage(GreeceConstants.Keys.markdownDarkTheme, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var darkTheme = "github-dark"

    @AppStorage(GreeceConstants.Keys.markdownFontFamily, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var fontFamily = "-apple-system"

    @AppStorage(GreeceConstants.Keys.markdownFontSize, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var fontSize = 15

    @AppStorage(GreeceConstants.Keys.markdownLineHeight, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var lineHeight = 1.6

    @AppStorage(GreeceConstants.Keys.markdownShowTOC, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var showTOC = true

    @AppStorage(GreeceConstants.Keys.markdownRenderMath, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var renderMath = true

    @AppStorage(GreeceConstants.Keys.markdownRenderMermaid, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var renderMermaid = true

    @AppStorage(GreeceConstants.Keys.markdownRenderEmoji, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var renderEmoji = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Markdown")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Themes") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Light theme:")
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $lightTheme) {
                            ForEach(ThemeManager.markdownThemes, id: \.id) { theme in
                                Text(theme.displayName).tag(theme.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                    HStack {
                        Text("Dark theme:")
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $darkTheme) {
                            ForEach(ThemeManager.markdownThemes, id: \.id) { theme in
                                Text(theme.displayName).tag(theme.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                }
                .padding(8)
            }

            GroupBox("Typography") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Font:")
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $fontFamily) {
                            ForEach(ThemeManager.proportionalFonts, id: \.self) { font in
                                Text(font).tag(font)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                    HStack {
                        Text("Font size:")
                            .frame(width: 100, alignment: .trailing)
                        Stepper("\(fontSize) px", value: $fontSize, in: 10...24)
                    }
                    HStack {
                        Text("Line height:")
                            .frame(width: 100, alignment: .trailing)
                        Slider(value: $lineHeight, in: 1.2...2.0, step: 0.1)
                            .frame(maxWidth: 150)
                        Text(String(format: "%.1f", lineHeight))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(8)
            }

            GroupBox("Features") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show table of contents sidebar", isOn: $showTOC)
                    Toggle("Render KaTeX math formulas", isOn: $renderMath)
                    Toggle("Render Mermaid diagrams", isOn: $renderMermaid)
                    Toggle("Replace emoji shortcodes", isOn: $renderEmoji)
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Code Settings

struct CodeSettingsView: View {
    @AppStorage(GreeceConstants.Keys.codeLightTheme, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var lightTheme = "xcode"

    @AppStorage(GreeceConstants.Keys.codeDarkTheme, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var darkTheme = "atom-one-dark"

    @AppStorage(GreeceConstants.Keys.codeFontFamily, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var fontFamily = "SF Mono"

    @AppStorage(GreeceConstants.Keys.codeFontSize, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var fontSize = 13

    @AppStorage(GreeceConstants.Keys.codeFontWeight, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var fontWeight = "regular"

    @AppStorage(GreeceConstants.Keys.codeShowLineNumbers, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var showLineNumbers = true

    @AppStorage(GreeceConstants.Keys.codeWordWrap, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var wordWrap = false

    @AppStorage(GreeceConstants.Keys.codeTabWidth, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var tabWidth = 4

    @AppStorage(GreeceConstants.Keys.codeAutoFormat, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var autoFormat = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Source Code")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Themes") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Light theme:")
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $lightTheme) {
                            ForEach(ThemeManager.codeThemes.filter { !$0.isDark }, id: \.id) { theme in
                                Text(theme.displayName).tag(theme.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                    HStack {
                        Text("Dark theme:")
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $darkTheme) {
                            ForEach(ThemeManager.codeThemes.filter { $0.isDark }, id: \.id) { theme in
                                Text(theme.displayName).tag(theme.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                }
                .padding(8)
            }

            GroupBox("Typography") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Font:")
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $fontFamily) {
                            ForEach(ThemeManager.monospaceFonts, id: \.self) { font in
                                Text(font).tag(font)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                    HStack {
                        Text("Font size:")
                            .frame(width: 100, alignment: .trailing)
                        Stepper("\(fontSize) px", value: $fontSize, in: 9...24)
                    }
                    HStack {
                        Text("Weight:")
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $fontWeight) {
                            ForEach(ThemeManager.fontWeights, id: \.self) { weight in
                                Text(weight.capitalized).tag(weight)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                }
                .padding(8)
            }

            GroupBox("Display") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show line numbers", isOn: $showLineNumbers)
                    Toggle("Word wrap", isOn: $wordWrap)
                    Toggle("Auto-format JSON, CSS, XML, SVG, plist", isOn: $autoFormat)
                    HStack {
                        Text("Tab width:")
                            .frame(width: 100, alignment: .trailing)
                        Stepper("\(tabWidth) spaces", value: $tabWidth, in: 1...8)
                    }
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Data Settings

struct DataSettingsView: View {
    @AppStorage(GreeceConstants.Keys.csvAlternatingRows, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var alternatingRows = true

    @AppStorage(GreeceConstants.Keys.csvMaxRows, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var maxRows = 10000

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Data Files")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("CSV / TSV") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Alternating row colors", isOn: $alternatingRows)
                    HStack {
                        Text("Max rows:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("", value: $maxRows, format: .number)
                            .frame(width: 100)
                        Text("rows")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
            }

            GroupBox("SQLite") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SQLite databases are displayed with a tab bar for switching between tables.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("Column headers show type and constraint tooltips on hover.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(8)
            }

            GroupBox("Diff / Patch") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Diff and patch files are rendered with color-coded additions (green) and removals (red).")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("Supports unified diff format with hunk headers and file headers.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Archive Settings

struct ArchiveSettingsView: View {
    @AppStorage(GreeceConstants.Keys.archiveShowHidden, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var showHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Archives")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Display") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show hidden files (dot-prefixed)", isOn: $showHidden)

                    Text("Supported formats: ZIP, TAR, GZ, BZ2, TAR.GZ, TAR.BZ2")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("Archives are parsed using pure Swift binary parsing — no shell commands or external tools.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(8)
            }

            GroupBox("Columns") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The archive browser shows: Name, Size, Compressed Size, Date Modified, and Kind.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("Columns are sortable by clicking the header. Directories are listed first.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Folder Settings

struct FolderSettingsView: View {
    @AppStorage(GreeceConstants.Keys.folderShowHidden, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var showHidden = false

    @AppStorage(GreeceConstants.Keys.folderShowSize, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var showSize = true

    @AppStorage(GreeceConstants.Keys.folderShowDate, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var showDate = true

    @AppStorage(GreeceConstants.Keys.folderShowKind, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var showKind = true

    @AppStorage(GreeceConstants.Keys.folderShowTags, store: UserDefaults(suiteName: GreeceConstants.appGroupIdentifier))
    var showTags = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Folders")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Display") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show hidden files", isOn: $showHidden)
                }
                .padding(8)
            }

            GroupBox("Columns") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("File size", isOn: $showSize)
                    Toggle("Date modified", isOn: $showDate)
                    Toggle("Kind", isOn: $showKind)
                    Toggle("Finder tags", isOn: $showTags)
                }
                .padding(8)
            }

            GroupBox("Spotlight Metadata") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Folder previews use Spotlight metadata to show file kinds and Finder tag colors.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("File icons are sourced from NSWorkspace for accurate representation.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(8)
            }
        }
    }
}
