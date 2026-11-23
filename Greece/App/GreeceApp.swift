import SwiftUI
import Quartz
import GreeceKit

struct GreeceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SettingsStore.shared
    @StateObject private var status = ExtensionStatus()
    @StateObject private var recents = RecentFiles()

    /// SwiftUI writes this binding while it updates scenes; only real changes may reach the store,
    /// or every write publishes a settings change mid-update.
    private var menuBarInserted: Binding<Bool> {
        Binding(get: { store.settings.showInMenuBar },
                set: { value in if store.settings.showInMenuBar != value { store.settings.showInMenuBar = value } })
    }

    /// The app's name, the same in every language.
    private let name = "Greece"

    var body: some Scene {
        Window(name, id: "main") {
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

        // After the main window: the first scene is the one that opens at launch.
        MenuBarExtra(name, systemImage: "doc.text.magnifyingglass", isInserted: menuBarInserted) {
            MenuBarView(recents: recents)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: Any?

    /// With the menu bar item on, closing the window leaves Greece in the menu bar (no Dock icon).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !SettingsStore.shared.settings.showInMenuBar
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true,
                  SettingsStore.shared.settings.showInMenuBar else { return }
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }

    // The app delegate is part of the responder chain, so it can own the Quick Look panel.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookPresenter.shared.attach(to: panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookPresenter.shared.detach(from: panel) }
}
