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
    /// A framework speaks its host's language unless the host allows mixed localizations. Quick Look
    /// extensions have no strings of their own, so each declares Greece's languages and allows mixed
    /// localizations (`CFBundleLocalizations`, `CFBundleAllowMixedLocalizations`, written by
    /// scripts/sync-types.py). The framework then resolves to the user's language there too, and
    /// falls back to English for any other.
    static let greeceKit = Bundle(for: GreeceKitBundleMarker.self)
}

private final class GreeceKitBundleMarker {}
