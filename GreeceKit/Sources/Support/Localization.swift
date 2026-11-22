import Foundation

extension Bundle {
    /// GreeceKit's own bundle, which holds its string catalog (`GreeceKit/Resources/Localizable.xcstrings`).
    ///
    /// Every user-visible string in GreeceKit is looked up here, never in the host's main bundle, so the
    /// app and each Quick Look extension show the same translations:
    ///
    ///     String(localized: "Sandboxed", bundle: .greeceKit)
    ///     String(localized: "\(count) files", bundle: .greeceKit)   // plural variations in the catalog
    ///
    /// The host decides the rest of the language: `Locale.current` (dates, relative times, numbers and
    /// sizes in the same sentences), Launch Services' kinds and the system's own strings follow the
    /// host's main bundle. A Quick Look extension has no strings of its own, so each declares Greece's
    /// languages and allows mixed localizations (`CFBundleLocalizations`,
    /// `CFBundleAllowMixedLocalizations`, written by scripts/sync-types.py); without them a German
    /// preview would read "Geändert 1 hour ago". Languages Greece doesn't speak fall back to English.
    static let greeceKit = Bundle(for: GreeceKitBundleMarker.self)
}

private final class GreeceKitBundleMarker {}
