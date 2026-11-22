import XCTest

/// The app's String Catalog (Greece/Localizable.xcstrings): every string is translated into every
/// language Greece ships, and every translation takes the same arguments as the English, so no
/// language can show a raw key, drop a value or crash formatting one. `KitLocalizationTests` runs the
/// same checks on GreeceKit's catalog.
class LocalizationTests: XCTestCase {
    static let languages = ["de", "fr", "es", "it", "pt-BR", "nl", "sv", "pl", "tr", "el", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant"]

    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The catalog under test, relative to the repository.
    class var catalogPath: String { "Greece/Localizable.xcstrings" }

    struct Entry {
        let key: String
        let json: [String: Any]
        var localizations: [String: Any] { json["localizations"] as? [String: Any] ?? [:] }
    }

    func entries() throws -> [Entry] {
        let data = try Data(contentsOf: Self.repository.appendingPathComponent(Self.catalogPath))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        return strings.sorted { $0.key < $1.key }
            .filter { $0.value["shouldTranslate"] as? Bool != false && $0.value["extractionState"] as? String != "stale" }
            .map { Entry(key: $0.key, json: $0.value) }
    }

    func testCatalogHasStrings() throws {
        XCTAssertGreaterThan(try entries().count, 200, "The catalog should hold the app's strings")
    }

    func testEveryStringIsTranslatedIntoEveryLanguage() throws {
        for entry in try entries() {
            for language in Self.languages {
                guard let localization = entry.localizations[language] as? [String: Any] else {
                    XCTFail("\(language): no translation for “\(entry.key)”")
                    continue
                }
                let units = Self.units(in: localization)
                XCTAssertFalse(units.isEmpty, "\(language): “\(entry.key)” has no text")
                for (path, unit) in units {
                    XCTAssertEqual(unit["state"] as? String, "translated", "\(language): “\(entry.key)” \(path) isn’t marked translated")
                    let value = unit["value"] as? String ?? ""
                    XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language): “\(entry.key)” \(path) is empty")
                }
            }
        }
    }

    func testTranslationsTakeTheSameArguments() throws {
        for entry in try entries() {
            let source = (entry.localizations["en"] as? [String: Any]).map { Self.signatures(of: $0) }
                ?? [Variant(path: "", isOneForm: false, arguments: Self.arguments(in: entry.key, substitutions: [:]))]
            // Every English variant takes the same arguments (a "one" form may spell its number out).
            guard let expected = source.first(where: { !$0.isOneForm })?.arguments ?? source.first?.arguments else { continue }
            XCTAssertEqual(expected, Self.arguments(in: entry.key, substitutions: [:]), "en: “\(entry.key)” takes different arguments than its key")
            for language in ["en"] + Self.languages {
                guard let localization = entry.localizations[language] as? [String: Any] else { continue }
                for variant in Self.signatures(of: localization) {
                    if variant.isOneForm {
                        // "One thing needs attention": the singular may leave its count out, but nothing else.
                        XCTAssertTrue(variant.arguments.allSatisfy { expected[$0.key] == $0.value } && expected.count - variant.arguments.count <= 1,
                                      "\(language): “\(entry.key)” \(variant.path) takes \(variant.arguments), expected \(expected)")
                    } else {
                        XCTAssertEqual(variant.arguments, expected, "\(language): “\(entry.key)” \(variant.path) takes different arguments")
                    }
                }
            }
        }
    }

    // MARK: - Reading the catalog

    /// Every string unit of a localization: the plain one, plural variations, substitution variations.
    static func units(in localization: [String: Any], path: String = "") -> [(String, [String: Any])] {
        var result: [(String, [String: Any])] = []
        if let unit = localization["stringUnit"] as? [String: Any] { result.append((path.isEmpty ? "value" : path, unit)) }
        if let variations = localization["variations"] as? [String: [String: Any]] {
            for (kind, cases) in variations {
                for (name, value) in cases {
                    if let nested = value as? [String: Any] { result += units(in: nested, path: path + "\(kind).\(name) ") }
                }
            }
        }
        if let substitutions = localization["substitutions"] as? [String: [String: Any]] {
            for (name, substitution) in substitutions {
                result += units(in: substitution, path: path + "%#@\(name)@ ")
            }
        }
        return result
    }

    private struct Variant {
        let path: String
        let isOneForm: Bool
        let arguments: [Int: String]
    }

    /// The arguments each spelling of a localization consumes: argument number → kind.
    private static func signatures(of localization: [String: Any]) -> [Variant] {
        let substitutions = localization["substitutions"] as? [String: [String: Any]] ?? [:]
        var variants: [Variant] = []
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            variants.append(Variant(path: "value", isOneForm: false, arguments: arguments(in: value, substitutions: substitutions)))
            // Each substitution's forms must print its own argument (%arg), the singular excepted.
            for (name, substitution) in substitutions {
                for (path, unit) in units(in: substitution, path: "%#@\(name)@ ") {
                    let text = unit["value"] as? String ?? ""
                    let one = path.hasSuffix("plural.one ") || path.hasSuffix("plural.zero ") || path.hasSuffix("plural.two ")
                    if !text.contains("%arg") && !one {
                        variants.append(Variant(path: path, isOneForm: false, arguments: [:]))
                    }
                }
            }
        }
        if let variations = localization["variations"] as? [String: [String: Any]] {
            for (kind, cases) in variations {
                for (name, value) in cases {
                    guard let nested = value as? [String: Any] else { continue }
                    for variant in signatures(of: nested) {
                        variants.append(Variant(path: "\(kind).\(name)", isOneForm: kind == "plural" && ["one", "zero", "two"].contains(name),
                                                arguments: variant.arguments))
                    }
                }
            }
        }
        return variants
    }

    private static let specifier = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?(#@([A-Za-z0-9_]+)@|[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])|%)"#)

    /// Argument number → kind ("int", "double", "object", "char"), following printf's numbering.
    static func arguments(in format: String, substitutions: [String: [String: Any]]) -> [Int: String] {
        var result: [Int: String] = [:]
        var next = 1
        let text = format as NSString
        for match in specifier.matches(in: format, range: NSRange(location: 0, length: text.length)) {
            let whole = text.substring(with: match.range)
            if whole == "%%" { continue }
            var position = next
            if match.range(at: 1).location != NSNotFound { position = Int(text.substring(with: match.range(at: 1))) ?? next }
            if match.range(at: 3).location != NSNotFound {
                let name = text.substring(with: match.range(at: 3))
                let substitution = substitutions[name] ?? [:]
                if let argument = substitution["argNum"] as? Int { position = argument }
                result[position] = kind(of: substitution["formatSpecifier"] as? String ?? "@")
            } else {
                result[position] = kind(of: text.substring(with: match.range(at: 4)))
            }
            next = position + 1
        }
        return result
    }

    private static func kind(of specifier: String) -> String {
        switch specifier.last {
        case "@": return "object"
        case "f", "F", "e", "E", "g", "G", "a", "A": return "double"
        case "c", "C", "s", "S": return "char"
        case "p": return "pointer"
        default: return "int"
        }
    }

    // MARK: - The checker itself

    func testArgumentsAreReadLikePrintf() {
        XCTAssertEqual(Self.arguments(in: "%@ also previews %lld of %@", substitutions: [:]), [1: "object", 2: "int", 3: "object"])
        XCTAssertEqual(Self.arguments(in: "%2$lld von %1$@ (100 %%)", substitutions: [:]), [1: "object", 2: "int"])
        XCTAssertEqual(Self.arguments(in: "%1$@ zeigt %#@types@", substitutions: ["types": ["argNum": 2, "formatSpecifier": "lld"]]),
                       [1: "object", 2: "int"])
        XCTAssertNotEqual(Self.arguments(in: "%@ rows", substitutions: [:]), Self.arguments(in: "%lld rows", substitutions: [:]))
    }
}
