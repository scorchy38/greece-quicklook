import Foundation

/// Where a preview is being shown, and what that place allows.
public enum PreviewHost {
    /// True inside one of Greece's extensions, whose sandbox can't reach some system services
    /// (Quick Look's thumbnail generator among them).
    public static let isAppExtension = Bundle.main.bundleURL.pathExtension == "appex"

    /// False inside Quick Look. The panel never becomes key for an extension's view, so typed keys
    /// go to the host instead: in Finder they move the selection and swap the previewed file. There,
    /// previews work by pointer alone (selections, buttons, context menus) and show no field that
    /// looks typeable. Set `GREECE_NO_TYPING=1` to render the Quick Look layout elsewhere.
    nonisolated(unsafe) public static var acceptsTyping: Bool = {
        if ProcessInfo.processInfo.environment["GREECE_NO_TYPING"] == "1" { return false }
        return !isAppExtension
    }()
}
