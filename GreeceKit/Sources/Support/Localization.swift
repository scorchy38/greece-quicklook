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

extension Locale {
    /// For formatters whose output sits inside Greece's sentences ("Modified 3 hours ago"): the
    /// language Greece's strings actually use, with the Mac's region. Usually the same as `current`;
    /// they differ when the Mac's language is one Greece doesn't speak, where `current` would put
    /// "fa 4 hores" into an English sentence.
    static var greeceKitText: Locale {
        let language = Bundle.greeceKit.preferredLocalizations.first ?? "en"
        guard Locale.current.language.languageCode?.identifier != Locale(identifier: language).language.languageCode?.identifier else { return .current }
        var components = Locale.Components(identifier: language)
        components.region = Locale.current.region
        return Locale(components: components)
    }
}
