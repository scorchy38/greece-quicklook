import SwiftUI
import GreeceKit

enum Page: String, CaseIterable, Identifiable, Hashable {
    case welcome, markdown, code, data, files, general, diagnostics, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return String(localized: "Welcome", comment: "Sidebar page")
        case .markdown: return "Markdown"
        case .code: return String(localized: "Code", comment: "Sidebar page: settings for source code previews")
        case .data: return String(localized: "Data", comment: "Sidebar page: settings for tables and databases")
        case .files: return String(localized: "Archives & Folders", comment: "Sidebar page")
        case .general: return String(localized: "General", comment: "Sidebar page")
        case .diagnostics: return String(localized: "Diagnostics", comment: "Sidebar page")
        case .about: return String(localized: "About", comment: "Sidebar page: about Greece")
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "sparkles"
        case .markdown: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .data: return "tablecells"
        case .files: return "archivebox"
        case .general: return "gearshape"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var status: ExtensionStatus
    @SceneStorage("page") private var storedPage: Page = .welcome
    @State private var query = ""
    /// Fixed page for snapshots; nil in normal use.
    var pinnedPage: Page?

    private var page: Page {
        get { pinnedPage ?? storedPage }
        nonmutating set { storedPage = newValue }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { if let value = $0 { page = value; query = "" } })) {
                if !query.isEmpty {
                    SettingsSearchResults(query: query)
                } else {
                Label(Page.welcome.title, systemImage: Page.welcome.symbol).tag(Page.welcome)
                Section("Previews") {
                    ForEach([Page.markdown, .code, .data, .files]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section {
                    ForEach([Page.general, .diagnostics, .about]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                } header: {
                    Text(verbatim: "Greece")
                }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search Settings")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                StatusFooter { page = .welcome }
            }
        } detail: {
            detail
                .navigationTitle(page.title)
        }
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .welcome: WelcomeView(open: { page = $0 })
        case .markdown: MarkdownPage()
        case .code: CodePage()
        case .data: DataPage()
        case .files: FilesPage()
        case .general: GeneralPage()
        case .diagnostics: DiagnosticsPage()
        case .about: AboutPage()
        }
    }
}

/// A quiet reminder in the sidebar when Quick Look isn't using Greece yet.
private struct StatusFooter: View {
    @EnvironmentObject private var status: ExtensionStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Quick Look status")
        .accessibilityLabel(text)
    }

    private var color: Color {
        switch status.state {
        case .active: return .green
        case .checking: return .secondary
        default: return .orange
        }
    }

    private var text: String {
        switch status.state {
        case .active: return String(localized: "Quick Look is on", comment: "Sidebar status footer")
        case .checking: return String(localized: "Checking Quick Look…", comment: "Sidebar status footer")
        default: return String(localized: "Turn on Quick Look", comment: "Sidebar status footer; opens the Welcome page")
        }
    }
}
