import Foundation
import os

/// The preview pages' own words (the find bar, menus, cards, toolbars), in the language the
/// reader's Mac prefers. Tables live in `Web/l10n/<language>.json`, keyed by the English text;
/// `en.json` is the source and lists every key. A value is the text, `{ "value": …, "comment": … }`,
/// or plural forms by CLDR category (`{ "one": …, "other": … }`). A language file may list keys that
/// are deliberately the same as English under `"@same"`.
///
/// A page embeds one table, inert, as `<script id="strings" type="application/json">`, and reads it
/// with `kit.t`, `kit.plural`, `kit.number` and `kit.date` (greece.js).
public enum WebStrings {
    /// Forces a language for every page: tests and renders. Nil follows `GREECE_LANGUAGE`, then the Mac.
    public static var languageOverride: String? {
        get { lock.withLock { override } }
        set { lock.withLock { override = newValue } }
    }

    /// Languages with a table in the bundle, English first.
    public static let available: [String] = {
        let folder = WebAssets.root.appendingPathComponent("l10n")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        return ["en"] + names.filter { $0 != "en" }.sorted()
    }()

    /// The language pages are shown in: forced, or the first of the reader's preferred languages
    /// Greece has, matched the way macOS matches an app's localizations ("de-CH" → "de", "zh-TW" → "zh-Hant").
    public static var language: String {
        let forced = languageOverride ?? ProcessInfo.processInfo.environment["GREECE_LANGUAGE"]
        if let forced, let match = Bundle.preferredLocalizations(from: available, forPreferences: [forced]).first,
           available.contains(match) { return match }
        return Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages).first ?? "en"
    }

    /// Numbers and dates: the page's language with the Mac's region, as macOS formats them in an app
    /// shown in that language ("en" in India → "en-IN", "de" in Switzerland → "de-CH").
    static func formattingLocale(for language: String, region: String? = Locale.current.region?.identifier) -> String {
        let parts = language.split(separator: "-").map(String.init)
        guard let region, !region.isEmpty, let code = parts.first else { return language }
        // Keep the language and its script ("zh-Hans"); the region is the Mac's.
        let script = parts.dropFirst().first { $0.count == 4 }
        return ([code] + (script.map { [$0] } ?? []) + [region]).joined(separator: "-")
    }

    /// The `<script id="strings">` element for a page in `language`.
    static func element(for language: String) -> String {
        "<script id=\"strings\" type=\"application/json\">\(json(for: language))</script>"
    }

    /// `{"lang":…,"locale":…,"strings":{…}}` with every key: the language's text, English where it
    /// has none. Made inert for a `<script>` element: no "<" can close it or open a comment.
    static func json(for language: String) -> String {
        let cached = lock.withLock { cache[language] }
        let strings = cached ?? {
            let built = buildTable(language)
            lock.withLock { cache[language] = built }
            return built
        }()
        var page: [String: Any] = ["lang": language, "locale": formattingLocale(for: language)]
        #if DEBUG
        page["debug"] = true
        #endif
        let head = (try? JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // `head` is a small object; splice the cached table in rather than re-encoding it per page.
        return String(head.dropLast()) + ",\"strings\":" + strings + "}"
    }

    // MARK: - Tables

    private static let lock = NSLock()
    private static var override: String?
    /// Encoded tables by language, built once per process.
    private static var cache: [String: String] = [:]
    private static let log = Logger(subsystem: "com.scorchy.greece", category: "l10n")

    /// A table file's entries, each reduced to what the page needs: a string, or plural forms.
    static func entries(_ language: String) -> [String: Any] {
        guard let url = WebAssets.url("l10n/\(language).json"), let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: Any] = [:]
        for (key, value) in object where !key.hasPrefix("@") {
            if let text = value as? String {
                result[key] = text
            } else if let entry = value as? [String: Any] {
                if let text = entry["value"] as? String {
                    result[key] = text
                } else {
                    let forms = entry.filter { pluralCategories.contains($0.key) }.compactMapValues { $0 as? String }
                    if !forms.isEmpty { result[key] = forms }
                }
            }
        }
        return result
    }

    static let pluralCategories: Set<String> = ["zero", "one", "two", "few", "many", "other"]

    private static func buildTable(_ language: String) -> String {
        var table = entries("en")
        if language != "en" {
            let translated = entries(language)
            #if DEBUG
            let missing = table.keys.filter { translated[$0] == nil }.sorted()
            if !missing.isEmpty {
                log.error("\(language, privacy: .public) has no text for \(missing.count) strings, shown in English: \(missing.prefix(20).joined(separator: " · "), privacy: .public)")
            }
            #endif
            table.merge(translated.filter { table[$0.key] != nil }) { _, new in new }
        }
        let data = (try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }
}
