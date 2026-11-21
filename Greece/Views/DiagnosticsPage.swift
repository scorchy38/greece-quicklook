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
                    Button(copied ? "Copied" : "Copy Report") {
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

            Section("Greece") {
                ForEach(diagnostics.findings) { finding in
                    FindingRow(finding: finding) { fix in
                        Task { await diagnostics.perform(fix, status: status) }
                    }
                }
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
                            Text(item.enabled ? "On" : "Off").foregroundStyle(.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.app)
                                Text("\(item.isThumbnail ? "Finder thumbnails" : "Previews") · \(item.types.count) file types")
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
        if diagnostics.findings.isEmpty { return "Checking…" }
        switch attention {
        case 0: return "Everything looks right"
        case 1: return "One thing needs attention"
        default: return "\(attention) things need attention"
        }
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
            Group {
                if route.checking {
                    ProgressView().controlSize(.small).frame(width: 52)
                } else {
                    Button("Check", action: check).controlSize(.small).frame(width: 52)
                }
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder private var verdict: some View {
        if let observed = route.observed {
            switch observed {
            case .greece: badge("Greece", "checkmark.seal.fill", .green, help: "Confirmed in Quick Look just now.")
            case .otherExtension: badge("Another app", "puzzlepiece.extension.fill", .orange, help: "Quick Look picked another app’s extension.")
            case .macOS(let viewer): badge("macOS", "apple.logo", .secondary, help: "Quick Look used \(viewer).")
            case .noAnswer: badge("No answer", "questionmark.circle", .secondary, help: "Quick Look didn’t report a viewer in time. Try again.")
            }
        } else {
            switch route.verdict {
            case .greece: badge("Greece", "checkmark.circle.fill", .green, help: "Greece claims this type.")
            case .greeceShared(let others): badge("Greece, also \(others.joined(separator: ", "))", "exclamationmark.triangle.fill", .orange,
                                                  help: "More than one extension claims this type; Quick Look shows only one.")
            case .otherApp(let app): badge(app, "puzzlepiece.extension", .secondary, help: "\(app) claims this type.")
            case .macOSKeeps(let reason): badge("macOS keeps", "lock.fill", .secondary, help: reason)
            case .macOS: badge("macOS", "apple.logo", .secondary, help: "Shown by Apple’s built-in viewer.")
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
