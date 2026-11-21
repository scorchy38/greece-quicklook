import SwiftUI
import GreeceKit

struct WelcomeView: View {
    @EnvironmentObject private var status: ExtensionStatus
    let open: (Page) -> Void

    private let samples: [(url: URL, title: String, symbol: String)] = [
        (Samples.markdown, "Markdown", "doc.richtext"),
        (Samples.swift, "Swift", "swift"),
        (Samples.json, "JSON", "curlybraces.square"),
        (Samples.patch, "Patch", "plus.forwardslash.minus"),
        (Samples.notebook, "Notebook", "book.pages"),
        (Samples.sqlite, "SQLite", "cylinder.split.1x2"),
        (Samples.zip, "ZIP Archive", "archivebox"),
        (Samples.folder, "Folder", "folder"),
    ]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 76, height: 76)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Greece")
                            .font(.largeTitle.weight(.semibold))
                        Text("A better look at your files. Press Space on Markdown, code, data, archives and folders to see them beautifully, instantly, and entirely on your Mac.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 10)
            }

            Section {
                statusRow
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                    ForEach(samples, id: \.url) { sample in
                        SampleTile(url: sample.url, title: sample.title, symbol: sample.symbol)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Try it")
            } footer: {
                Text("Each opens in the real Quick Look panel, exactly as Finder shows it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Make it yours") {
                ForEach([Page.markdown, .code, .data, .files]) { page in
                    Button {
                        open(page)
                    } label: {
                        HStack {
                            Label(page.title, systemImage: page.symbol)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(blurb(for: page))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusRow: some View {
        switch status.state {
        case .active:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quick Look previews are on").font(.headline)
                    Text("Select any file in Finder and press Space. Settings apply to the next preview you open.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            if let message = status.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking Quick Look…").foregroundStyle(.secondary)
            }
        case .disabled, .notRegistered, .otherCopy:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quick Look isn’t using Greece yet").font(.headline)
                    Text(explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            HStack {
                Button(status.working ? "Turning On…" : "Turn On Greece") { status.enable() }
                    .buttonStyle(.borderedProminent)
                    .disabled(status.working)
                Button("Open Extension Settings") { status.openExtensionSettings() }
                Spacer()
            }
        }
    }

    private var explanation: String {
        switch status.state {
        case .otherCopy(let path):
            let name = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: "/Contents/PlugIns", with: "")
            return "Quick Look is using another copy of Greece at \(name). Turn on this copy to use its previews and settings."
        case .disabled:
            return "Greece’s Quick Look extension is switched off in System Settings. Turn it on to preview files with Greece."
        default:
            return "macOS hasn’t registered Greece’s Quick Look extension yet. Turn it on to start previewing files."
        }
    }

    private func blurb(for page: Page) -> String {
        switch page {
        case .markdown: return "Fonts, width, math, diagrams"
        case .code: return "Themes, fonts, line numbers"
        case .data: return "Tables and databases"
        case .files: return "Hidden files, sorting"
        default: return ""
        }
    }
}

private struct SampleTile: View {
    let url: URL
    let title: String
    let symbol: String
    @State private var hovering = false

    var body: some View {
        Button {
            QuickLookPresenter.shared.show(url)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 40)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Preview \(url.lastPathComponent) in Quick Look")
        .accessibilityLabel("Preview \(title) sample")
    }
}
