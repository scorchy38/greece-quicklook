import SwiftUI
import GreeceKit

// MARK: - Shared layout

/// A live preview of a sample file above the settings that shape it.
private struct PreviewPage<Content: View>: View {
    @EnvironmentObject private var store: SettingsStore
    let samples: [(String, URL)]
    @Binding var selection: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            LivePreview(url: samples[min(selection, samples.count - 1)].1, settings: store.settings)
                .frame(minHeight: 240, idealHeight: 340, maxHeight: 380)
                .accessibilityLabel("Live preview")
            Divider()
            Form { content() }
                .formStyle(.grouped)
                .frame(minHeight: 200)
        }
        .toolbar {
            if samples.count > 1 {
                ToolbarItem(placement: .principal) {
                    Picker("Sample", selection: $selection) {
                        ForEach(samples.indices, id: \.self) { index in Text(samples[index].0).tag(index) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Choose a sample file")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    QuickLookPresenter.shared.show(samples[min(selection, samples.count - 1)].1)
                } label: {
                    Label("Open in Quick Look", systemImage: "eye")
                }
                .help("Open this sample in the real Quick Look panel")
            }
        }
    }
}

private struct ValueStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "pt"

    var body: some View {
        Stepper(value: $value, in: range, step: 1) {
            LabeledContent(title) {
                Text("\(Int(value)) \(unit)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Markdown

struct MarkdownPage: View {
    @EnvironmentObject private var store: SettingsStore
    @SceneStorage("markdown.sample") private var sample = 0

    var body: some View {
        PreviewPage(samples: [("Document", Samples.markdown), ("Notebook", Samples.notebook)], selection: $sample) {
            Section("Typography") {
                Picker("Font", selection: $store.settings.readingFont) {
                    ForEach(PreviewSettings.ReadingFont.allCases) { font in Text(font.title).tag(font) }
                }
                ValueStepper(title: "Size", value: $store.settings.readingSize, range: 11...26)
                Picker("Line width", selection: $store.settings.readingWidth) {
                    ForEach(PreviewSettings.ReadingWidth.allCases) { width in Text(width.title).tag(width) }
                }
            }
            Section {
                Toggle("Show an outline beside long documents", isOn: $store.settings.showOutline)
                Toggle("Show front matter as properties", isOn: $store.settings.showFrontMatter)
            } header: {
                Text("Document")
            } footer: {
                Text("The outline appears when the preview is wide enough and the document has three or more sections.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Math", isOn: $store.settings.renderMath)
                Toggle("Mermaid diagrams", isOn: $store.settings.renderDiagrams)
                Toggle("Load remote images", isOn: $store.settings.loadRemoteImages)
            } header: {
                Text("Rich content")
            } footer: {
                Text("Math and diagrams render on your Mac with bundled libraries. Remote images are the only content that ever touches the network; turn them off to keep previews fully offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Code

struct CodePage: View {
    @EnvironmentObject private var store: SettingsStore
    @SceneStorage("code.sample") private var sample = 0

    private var fonts: [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let candidates = ["Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Cascadia Code", "Source Code Pro",
                          "IBM Plex Mono", "Iosevka", "Hack", "Berkeley Mono", "Monaspace Neon", "Courier New"]
        return ["SF Mono"] + candidates.filter(installed.contains)
    }

    var body: some View {
        PreviewPage(samples: [("Swift", Samples.swift), ("Python", Samples.python), ("JSON", Samples.json), ("Patch", Samples.patch)], selection: $sample) {
            Section {
                ThemePicker(selection: $store.settings.theme)
                    .padding(.vertical, 6)
            } header: {
                Text("Theme")
            } footer: {
                Text("Every theme has a light and a dark variant and follows your Mac’s appearance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Text") {
                Picker("Font", selection: $store.settings.codeFont) {
                    ForEach(fonts, id: \.self) { name in Text(name).tag(name) }
                }
                ValueStepper(title: "Size", value: $store.settings.codeFontSize, range: 9...24)
                Picker("Tab width", selection: $store.settings.tabWidth) {
                    ForEach([2, 3, 4, 8], id: \.self) { width in Text("\(width) spaces").tag(width) }
                }
            }
            Section {
                Toggle("Line numbers", isOn: $store.settings.lineNumbers)
                Toggle("Wrap long lines", isOn: $store.settings.wrapLines)
                Toggle("Format minified JSON", isOn: $store.settings.prettyPrint)
            } header: {
                Text("Layout")
            } footer: {
                Text("Greece highlights more than 190 languages, decodes binary property lists, and keeps JSON keys in their original order when formatting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Theme thumbnails in the style of System Settings' appearance picker.
private struct ThemePicker: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 14)], spacing: 14) {
            ForEach(CodeTheme.all) { theme in
                Button { selection = theme.id } label: {
                    VStack(spacing: 7) {
                        ThemeThumbnail(palette: scheme == .dark ? theme.dark : theme.light, selected: selection == theme.id)
                        Text(theme.name)
                            .font(.caption)
                            .foregroundStyle(selection == theme.id ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(theme.name) theme")
                .accessibilityAddTraits(selection == theme.id ? .isSelected : [])
            }
        }
    }
}

private struct ThemeThumbnail: View {
    let palette: CodeTheme.Palette
    let selected: Bool

    var body: some View {
        let lines: [[(String, CGFloat)]] = [
            [(palette.keyword, 16), (palette.type, 26), (palette.foreground, 8)],
            [(palette.comment, 44)],
            [(palette.keyword, 12), (palette.function, 22), (palette.string, 18)],
            [(palette.foreground, 10), (palette.number, 8), (palette.attribute, 20)],
        ]
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines.indices, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(lines[row].indices, id: \.self) { index in
                        Capsule()
                            .fill(Color(hex: lines[row][index].0))
                            .frame(width: lines[row][index].1, height: 4)
                    }
                }
                .padding(.leading, row == 2 || row == 3 ? 8 : 0)
            }
        }
        .padding(10)
        .frame(width: 96, height: 62, alignment: .topLeading)
        .background(Color(hex: palette.background), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .padding(3)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
        }
    }
}

// MARK: - Data

struct DataPage: View {
    @EnvironmentObject private var store: SettingsStore
    @SceneStorage("data.sample") private var sample = 0

    var body: some View {
        PreviewPage(samples: [("SQLite", Samples.sqlite), ("CSV", Samples.csv)], selection: $sample) {
            Section("Tables") {
                Toggle("Row numbers", isOn: $store.settings.rowNumbers)
                Picker("Show up to", selection: $store.settings.maxRows) {
                    Text("1,000 rows").tag(1_000)
                    Text("10,000 rows").tag(10_000)
                    Text("100,000 rows").tag(100_000)
                    Text("1,000,000 rows").tag(1_000_000)
                }
            }
            Section {
                Label("Click a column header to sort. Select rows and press ⌘C to copy them as tab-separated text.", systemImage: "hand.tap")
                Label("SQLite files open read-only and unchanged. Large tables page in as you scroll.", systemImage: "lock")
                Label("Tab- and pipe-separated files open in Greece. For .csv files, macOS keeps its own built-in table preview.", systemImage: "info.circle")
            } header: {
                Text("Good to know")
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Archives & folders

struct FilesPage: View {
    @EnvironmentObject private var store: SettingsStore
    @SceneStorage("files.sample") private var sample = 0

    var body: some View {
        PreviewPage(samples: [("ZIP Archive", Samples.zip), ("Folder", Samples.folder)], selection: $sample) {
            Section {
                Toggle("Show hidden files", isOn: $store.settings.showHiddenFiles)
                Toggle("Keep folders on top", isOn: $store.settings.foldersFirst)
            } header: {
                Text("Listing")
            } footer: {
                Text("Greece reads ZIP, JAR, tar, gzip, bzip2 and xz without extracting anything. A compressed text file, such as a .log.gz, opens straight to its contents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var status: ExtensionStatus
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $store.settings.appearance) {
                    ForEach(PreviewSettings.Appearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
                }
                .pickerStyle(.segmented)
                Toggle("Show the info bar", isOn: $store.settings.showInfoBar)
            } header: {
                Text("Previews")
            } footer: {
                Text("The info bar shows what a file is at a glance: its language, size, line or row count, and when it last changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Update previews when files change", isOn: $store.settings.liveUpdates)
                Picker("Remember scroll position", selection: $store.settings.rememberScroll) {
                    ForEach(PreviewSettings.Memory.allCases) { memory in Text(memory.title).tag(memory) }
                }
                Picker("Remember window size", selection: $store.settings.rememberWindowSize) {
                    ForEach(PreviewSettings.WindowMemory.allCases) { memory in Text(memory.title).tag(memory) }
                }
                Button("Forget Positions and Sizes") { store.settings.memoryGeneration += 1 }
            } header: {
                Text("While You Read")
            } footer: {
                Text("Save a file while its preview is open and the preview updates in place, at the same spot. Greece can also reopen files where you left off, and the window at the size you last chose.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Quick Look") {
                LabeledContent("Status") {
                    switch status.state {
                    case .active: Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .checking: Text("Checking…").foregroundStyle(.secondary)
                    default: Label("Off", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                HStack {
                    if status.state != .active {
                        Button("Turn On Greece") { status.enable() }.disabled(status.working)
                    }
                    Button("Restart Quick Look") { status.resetQuickLook() }.disabled(status.working)
                    Button("Extension Settings…") { status.openExtensionSettings() }
                }
                if let message = status.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Restore Default Settings…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore all preview settings to their defaults?", isPresented: $confirmReset) {
            Button("Restore Defaults", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - About

struct AboutPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Greece").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Privacy") {
                Label("Previews are rendered on your Mac. Greece has no accounts, analytics or tracking.", systemImage: "lock.shield")
                Label("Files are opened read-only. Databases are never modified, and archives are never extracted.", systemImage: "doc.badge.clock")
                Label("The only network access is loading remote images in Markdown, which you can turn off.", systemImage: "network")
            }
            Section("Acknowledgements") {
                ForEach(Samples.licenses, id: \.name) { license in
                    DisclosureGroup(license.name) {
                        Text(license.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Helpers

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }
}
