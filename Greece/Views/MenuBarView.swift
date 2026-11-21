import SwiftUI
import AppKit

/// The menu bar window: recent previews and agent edits, one click from Quick Look.
struct MenuBarView: View {
    @ObservedObject var recents: RecentFiles
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private func items(_ source: RecentFiles.Source) -> [RecentFiles.Item] {
        let all = recents.items[source] ?? []
        guard !query.isEmpty else { return Array(all.prefix(8)) }
        return all.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) || $0.context.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a file", text: $query)
                    .textFieldStyle(.plain)
                if recents.loading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let sources = RecentFiles.Source.allCases.filter { !items($0).isEmpty }
                    if sources.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 26)).foregroundStyle(.tertiary)
                            Text(query.isEmpty ? "Files you preview, and files Claude Code or Codex edit, appear here." : "No matching files.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                    ForEach(sources, id: \.self) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(source.rawValue, systemImage: source.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 2)
                            let list = items(source)
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                FileRow(item: item) {
                                    dismiss()
                                    NSApp.activate(ignoringOtherApps: true)
                                    QuickLookPresenter.shared.show(list.map(\.url), at: index)
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Button("Open Greece") {
                    dismiss()
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .onAppear { recents.refresh() }
    }
}

private struct FileRow: View {
    let item: RecentFiles.Item
    let preview: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: preview) {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.url.lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                    Text([item.context, item.date.formatted(.relative(presentation: .named))].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.url.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }
}
