import SwiftUI
import GreeceKit

enum Page: String, CaseIterable, Identifiable, Hashable {
    case welcome, markdown, code, data, files, general, diagnostics, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .markdown: return "Markdown"
        case .code: return "Code"
        case .data: return "Data"
        case .files: return "Archives & Folders"
        case .general: return "General"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
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
    /// Fixed page for snapshots; nil in normal use.
    var pinnedPage: Page?

    private var page: Page {
        get { pinnedPage ?? storedPage }
        nonmutating set { storedPage = newValue }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { if let value = $0 { page = value } })) {
                Label(Page.welcome.title, systemImage: Page.welcome.symbol).tag(Page.welcome)
                Section("Previews") {
                    ForEach([Page.markdown, .code, .data, .files]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Greece") {
                    ForEach([Page.general, .diagnostics, .about]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
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
        case .active: return "Quick Look is on"
        case .checking: return "Checking Quick Look…"
        default: return "Turn on Quick Look"
        }
    }
}
