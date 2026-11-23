import Foundation

/// How the reader last chose to see folders and archives: list or icons, sorted and grouped.
///
/// Kept in the Quick Look extension's own defaults, as `PreviewMemory` keeps scroll positions:
/// preview extensions can read the shared App Group but not write to it. These are preferences,
/// not places, so the app's "Forget Positions and Sizes" leaves them alone.
enum BrowserMemory {
    enum Scope: String {
        /// Folders on disk (and an app bundle's files), which can be shown as icons.
        case folders
        /// Archives and disk images: a list only, with compressed sizes to sort by.
        case archives
    }

    static let key = "browser-view.v1"

    /// Where choices are kept: the extension's own defaults. Tests point it elsewhere.
    nonisolated(unsafe) static var store: UserDefaults = .standard

    static func state(for scope: Scope, defaults: UserDefaults = store) -> BrowserViewState {
        guard let stored = (defaults.dictionary(forKey: key) ?? [:])[scope.rawValue] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: stored),
              var state = try? JSONDecoder().decode(BrowserViewState.self, from: data) else {
            return BrowserViewState()
        }
        if scope == .archives { state.layout = .list }
        return state
    }

    static func remember(_ state: BrowserViewState, for scope: Scope, defaults: UserDefaults = store) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[scope.rawValue] = [
            "layout": state.layout.rawValue,
            "sort": state.sort.rawValue,
            "ascending": state.ascending,
            "group": state.group.rawValue,
        ] as [String: Any]
        defaults.set(all, forKey: key)
    }
}
