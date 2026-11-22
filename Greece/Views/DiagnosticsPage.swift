import SwiftUI
import AppKit

/// Why a file does or doesn't reach Greece, and one-click fixes.
struct DiagnosticsPage: View {
    @EnvironmentObject private var status: ExtensionStatus
    @StateObject private var diagnostics = Diagnostics()
    @State private var copied = false

    private var attention: Int { diagnostics.findings.filter { $0.severity >= .warning }.count }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: attention == 0 ? "checkmark.seal.fill" : "stethoscope")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(attention == 0 ? Color.green : Color.orange)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline).font(.headline)
                        Text("Greece checks its registration, other Quick Look extensions and how macOS routes each kind of file.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if diagnostics.running { ProgressView().controlSize(.small) }
                }
                .padding(.vertical, 6)
                HStack {
                    Button("Check Again") { Task { await diagnostics.run() } }.disabled(diagnostics.running)
                    Button(copied ? String(localized: "Copied", comment: "Shown briefly after copying the report")
                                  : String(localized: "Copy Report", comment: "Copies a plain-text diagnostics report")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.report, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    Spacer()
                    if let message = diagnostics.message {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }

            Section {
                ForEach(diagnostics.findings) { finding in
                    FindingRow(finding: finding) { fix in
                        Task { await diagnostics.perform(fix, status: status) }
                    }
                }
            } header: {
                Text(verbatim: "Greece")
            }

            Section {
                ForEach(diagnostics.routes) { route in
                    RouteRow(route: route) { Task { await diagnostics.check(route.id) } }
                }
            } header: {
                Text("Who Shows Each Kind of File")
            } footer: {
                Text("Check opens a sample in the real Quick Look panel and reports which viewer macOS picked.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Other Quick Look Extensions") {
                let others = diagnostics.extensions.filter { !$0.isApple && !$0.isGreece }
                if others.isEmpty {
                    Text("None installed. Only Greece and Apple’s own viewers are in play.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(others) { item in
                        LabeledContent {
                            Text(item.enabled ? String(localized: "On", comment: "Extension state") : String(localized: "Off", comment: "Extension state"))
                                .foregroundStyle(.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.app)
                                Text(item.isThumbnail
                                     ? String(localized: "Finder thumbnails · \(item.types.count) file types", comment: "Another app’s thumbnail extension")
                                     : String(localized: "Previews · \(item.types.count) file types", comment: "Another app’s preview extension"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await diagnostics.run() }
    }

    private var headline: String {
        if diagnostics.findings.isEmpty { return String(localized: "Checking…") }
        if attention == 0 { return String(localized: "Everything looks right", comment: "Diagnostics found no problems") }
        return String(localized: "\(attention) things need attention", comment: "Diagnostics headline")
    }
}

private struct FindingRow: View {
    let finding: Diagnostics.Finding
    let perform: (Diagnostics.Fix) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: finding.severity.symbol)
                .foregroundStyle(Color(nsColor: finding.severity.color))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                if finding.severity != .ok || !finding.detail.isEmpty {
                    Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let fix = finding.fix {
                Button(fix.title) { perform(fix) }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RouteRow: View {
    let route: Diagnostics.Route
    let check: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.title)
                Text(route.sampleName).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            verdict
            // The button keeps its room while checking, so rows don't shift and every language fits.
            Button("Check", action: check)
                .controlSize(.small)
                .opacity(route.checking ? 0 : 1)
                .disabled(route.checking)
                .overlay {
                    if route.checking { ProgressView().controlSize(.small) }
                }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder private var verdict: some View {
        if let observed = route.observed {
            switch observed {
            case .greece:
                badge("Greece", "checkmark.seal.fill", .green, help: String(localized: "Confirmed in Quick Look just now."))
            case .otherExtension:
                badge(String(localized: "Another app", comment: "Diagnostics: another app’s extension showed the file"), "puzzlepiece.extension.fill", .orange,
                      help: String(localized: "Quick Look picked another app’s extension."))
            case .macOS(let viewer):
                badge("macOS", "apple.logo", .secondary,
                      help: String(localized: "Quick Look used \(viewer).", comment: "The argument is a viewer, such as Apple’s text viewer"))
            case .noAnswer:
                badge(String(localized: "No answer", comment: "Diagnostics: Quick Look didn’t say which viewer it used"), "questionmark.circle", .secondary,
                      help: String(localized: "Quick Look didn’t report a viewer in time. Try again."))
            }
        } else {
            switch route.verdict {
            case .greece:
                badge("Greece", "checkmark.circle.fill", .green, help: String(localized: "Greece claims this type."))
            case .greeceShared(let others):
                badge(String(localized: "Greece, also \(others.formatted(.list(type: .and)))", comment: "The argument lists other apps that claim the same file type"),
                      "exclamationmark.triangle.fill", .orange,
                      help: String(localized: "More than one extension claims this type; Quick Look shows only one."))
            case .otherApp(let app):
                badge(app, "puzzlepiece.extension", .secondary, help: String(localized: "\(app) claims this type.", comment: "The argument is an app’s name"))
            case .macOSKeeps(let reason):
                badge(String(localized: "macOS keeps", comment: "Diagnostics: macOS always shows this file type itself"), "lock.fill", .secondary, help: reason)
            case .macOS:
                badge("macOS", "apple.logo", .secondary, help: String(localized: "Shown by Apple’s built-in viewer."))
            }
        }
    }

    private func badge(_ text: String, _ symbol: String, _ color: Color, help: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .foregroundStyle(color)
            .lineLimit(1)
            .help(help)
    }
}
