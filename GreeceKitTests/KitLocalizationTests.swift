import XCTest
@testable import GreeceKit

/// GreeceKit's String Catalog (GreeceKit/Resources/Localizable.xcstrings), where every word of every
/// preview comes from, in the app and in each Quick Look extension. Besides the app catalog's checks
/// (inherited: every string in every language, the same arguments), every count has its language's
/// plural forms, the catalog holds exactly what the code looks up, and lookups resolve through the
/// framework's own bundle.
final class KitLocalizationTests: LocalizationTests {
    override class var catalogPath: String { "GreeceKit/Resources/Localizable.xcstrings" }

    /// CLDR's cardinal plural categories for each language, as Xcode's String Catalog editor offers them.
    static let pluralCategories: [String: Set<String>] = [
        "en": ["one", "other"], "de": ["one", "other"], "nl": ["one", "other"], "sv": ["one", "other"],
        "tr": ["one", "other"], "el": ["one", "other"],
        "fr": ["one", "many", "other"], "es": ["one", "many", "other"], "it": ["one", "many", "other"], "pt-BR": ["one", "many", "other"],
        "pl": ["one", "few", "many", "other"], "ru": ["one", "few", "many", "other"], "uk": ["one", "few", "many", "other"],
        "ja": ["other"], "ko": ["other"], "zh-Hans": ["other"], "zh-Hant": ["other"],
    ]

    func testEveryCountHasItsLanguagesPluralForms() throws {
        var counts = 0
        for entry in try entries() where Self.arguments(in: entry.key, substitutions: [:]).values.contains("int") {
            counts += 1
            for language in ["en"] + Self.languages {
                guard let localization = entry.localizations[language] as? [String: Any] else {
                    XCTFail("\(language): “\(entry.key)” counts something but has no plural forms")
                    continue
                }
                let forms = Self.pluralForms(in: localization)
                XCTAssertFalse(forms.isEmpty, "\(language): “\(entry.key)” counts something but has no plural forms")
                for categories in forms {
                    XCTAssertEqual(categories, Self.pluralCategories[language],
                                   "\(language): “\(entry.key)” needs exactly the plural forms \(Self.pluralCategories[language]!.sorted())")
                }
            }
        }
        XCTAssertGreaterThan(counts, 50, "GreeceKit counts lines, files, rows…: those strings should have plural forms")
    }

    /// The plural categories of each plural variation in a localization (the whole string's, or a substitution's).
    static func pluralForms(in localization: [String: Any]) -> [Set<String>] {
        var result: [Set<String>] = []
        if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] { result.append(Set(plural.keys)) }
        for substitution in (localization["substitutions"] as? [String: [String: Any]] ?? [:]).values {
            if let plural = (substitution["variations"] as? [String: Any])?["plural"] as? [String: Any] { result.append(Set(plural.keys)) }
        }
        return result
    }

    // MARK: - The catalog and the code agree

    /// Every key the compiler extracted from GreeceKit's sources in this build (SWIFT_EMIT_LOC_STRINGS
    /// writes one .stringsdata per source file), with the file it came from.
    private func extractedKeys() throws -> [String: String] {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()   // …/Build/Products/Debug
        let objects = products.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex/Greece.build/\(products.lastPathComponent)/GreeceKit.build/Objects-normal")
        var keys: [String: String] = [:]
        for case let url as URL in FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil)?.allObjects ?? []
        where url.pathExtension == "stringsdata" {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let tables = json?["tables"] as? [String: [[String: Any]]] ?? [:]
            XCTAssertEqual(Set(tables.keys).subtracting(["Localizable"]), [], "\(url.lastPathComponent): GreeceKit keeps all its strings in one table")
            for entry in tables["Localizable"] ?? [] {
                if let key = entry["key"] as? String { keys[key] = url.deletingPathExtension().lastPathComponent }
            }
        }
        if keys.isEmpty { throw XCTSkip("No extracted strings next to this build (\(objects.path))") }
        return keys
    }

    func testCatalogHoldsExactlyWhatTheCodeLooksUp() throws {
        let extracted = try extractedKeys()
        let catalog = Set(try entries().map(\.key))
        for (key, file) in extracted.sorted(by: { $0.key < $1.key }) where !catalog.contains(key) {
            XCTFail("“\(key)” (\(file).swift) isn’t in GreeceKit’s catalog: add it to GreeceKit/Resources/Localizable.xcstrings")
        }
        for key in catalog.subtracting(extracted.keys).sorted() {
            XCTFail("“\(key)” is in GreeceKit’s catalog but no code looks it up any more")
        }
    }

    // MARK: - Lookups at run time

    /// The framework's compiled strings for one language, as a bundle would load them for a German user.
    private func lproj(_ language: String) throws -> Bundle {
        XCTAssertTrue(Bundle.greeceKit.localizations.contains(language), "GreeceKit.framework ships no \(language) strings")
        return try XCTUnwrap(Bundle.greeceKit.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
    }

    func testEveryStringResolvesToItsGermanTranslation() throws {
        let german = try lproj("de")
        var checked = 0
        for entry in try entries() {
            guard let localization = entry.localizations["de"] as? [String: Any],
                  localization["variations"] == nil, localization["substitutions"] == nil,
                  let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String else { continue }
            XCTAssertEqual(german.localizedString(forKey: entry.key, value: "∅", table: nil), value, "“\(entry.key)”")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 200)
    }

    func testCountsTakeEachLanguagesPluralForm() throws {
        // The way the code asks for a count, resolved through GreeceKit's bundle in another language.
        func files(_ count: Int, _ language: String) -> String {
            String(localized: LocalizedStringResource("\(count) files", locale: Locale(identifier: language),
                                                      bundle: .atURL(Bundle.greeceKit.bundleURL)))
        }
        XCTAssertEqual(files(1, "en"), "1 file")
        XCTAssertEqual(files(3, "en"), "3 files")
        XCTAssertEqual(files(1, "de"), "1 Datei")
        XCTAssertEqual(files(3, "de"), "3 Dateien")
        // Russian: 1 and 21 are "one", 3 is "few", 5 is "many".
        let russian = [1, 21, 3, 5].map { files($0, "ru") }
        XCTAssertEqual(Set(russian.map { $0.split(separator: " ").last! }).count, 3, "\(russian)")
        XCTAssertEqual(russian[0].split(separator: " ").last, russian[1].split(separator: " ").last)
    }
}
