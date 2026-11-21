import SwiftUI
import Quartz
import GreeceKit

struct GreeceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SettingsStore.shared
    @StateObject private var status = ExtensionStatus()

    var body: some Scene {
        Window("Greece", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(status)
                .frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Restart Quick Look") { status.resetQuickLook() }
            }
            CommandGroup(replacing: .help) {
                Link("Greece on GitHub", destination: URL(string: "https://github.com/scorchy38/greece-quicklook")!)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // The app delegate is part of the responder chain, so it can own the Quick Look panel.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookPresenter.shared.attach(to: panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookPresenter.shared.detach(from: panel) }
}
