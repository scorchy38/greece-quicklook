import XCTest

/// Checks on the repository itself: generated files that must stay in step with their sources.
final class RepositoryTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func listed(_ kind: String) throws -> [String] {
        let folder = repo.appendingPathComponent("Types/\(kind)")
        var seen = Set<String>(), result: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).filter({ $0.hasSuffix(".txt") }).sorted() {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let type = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
                if !type.isEmpty, seen.insert(type).inserted { result.append(type) }
            }
        }
        return result
    }

    private func supportedTypes(_ plist: String) throws -> [String] {
        let data = try Data(contentsOf: repo.appendingPathComponent(plist))
        let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let attributes = (root?["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
        return attributes?["QLSupportedContentTypes"] as? [String] ?? []
    }

    func testContentTypesAreSynced() throws {
        // Each preview family's Info.plist holds exactly its lists, in order (Types/families.json).
        let data = try Data(contentsOf: repo.appendingPathComponent("Types/families.json"))
        let families = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["families"] as? [[String: Any]] ?? []
        XCTAssertFalse(families.isEmpty)
        var everyPreviewType: [String] = []
        for family in families {
            let target = family["target"] as? String ?? ""
            let plist = target == "GreeceQuickLook" ? "GreeceQuickLook/Info.plist" : "GreeceQuickLook/Families/\(target)/Info.plist"
            var expected: [String] = []
            for list in family["lists"] as? [String] ?? [] {
                for type in try types(in: "Types/preview/\(list).txt") where !expected.contains(type) { expected.append(type) }
            }
            XCTAssertEqual(try supportedTypes(plist), expected, "\(target): run scripts/sync-types.py")
            everyPreviewType += expected
        }
        XCTAssertEqual(Set(everyPreviewType), Set(try listed("preview")), "every preview list belongs to a family")
        XCTAssertEqual(everyPreviewType.count, Set(everyPreviewType).count, "no type is claimed by two families")
        XCTAssertEqual(try supportedTypes("GreeceThumbnails/Info.plist"), try listed("thumbnails"), "Run scripts/sync-types.py")
    }

    // MARK: - Localization

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repo.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
    }

    private func catalogStrings(_ path: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: repo.appendingPathComponent(path))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], path)
        return try XCTUnwrap(catalog["strings"] as? [String: [String: Any]], path)
    }

    private func families() throws -> [[String: Any]] {
        let data = try Data(contentsOf: repo.appendingPathComponent("Types/families.json"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["families"] as? [[String: Any]] ?? []
    }

    /// Each Quick Look extension's Info.plist, and the catalog that translates its display name.
    private func extensions() throws -> [(plist: String, catalog: String)] {
        try families().map { family in
            let target = family["target"] as? String ?? ""
            return (target == "GreeceQuickLook" ? "GreeceQuickLook/Info.plist" : "GreeceQuickLook/Families/\(target)/Info.plist",
                    "GreeceQuickLook/Families/\(target)/InfoPlist.xcstrings")
        } + [("GreeceThumbnails/Info.plist", "GreeceThumbnails/InfoPlist.xcstrings")]
    }

    /// The translation of `key` into `language`, when it's done.
    private func translation(_ entry: [String: Any]?, _ language: String) -> String? {
        let unit = ((entry?["localizations"] as? [String: Any])?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        guard unit?["state"] as? String == "translated", let value = unit?["value"] as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    func testExtensionsSpeakGreecesLanguages() throws {
        // GreeceKit.framework speaks its host's language unless the host allows mixed localizations, and
        // an extension has no strings of its own: without these, every preview would stay in English.
        for (path, _) in try extensions() {
            let root = try plist(path)
            XCTAssertEqual(root["CFBundleLocalizations"] as? [String], ["en"] + LocalizationTests.languages, "\(path): run scripts/sync-types.py")
            XCTAssertEqual(root["CFBundleAllowMixedLocalizations"] as? Bool, true, "\(path): run scripts/sync-types.py")
        }
    }

    func testExtensionNamesAreTranslated() throws {
        // Their names show in System Settings › Extensions and on the app's Preview Kinds list.
        for (path, catalog) in try extensions() {
            let name = try XCTUnwrap(try plist(path)["CFBundleDisplayName"] as? String)
            let entry = try catalogStrings(catalog)["CFBundleDisplayName"]
            XCTAssertEqual(translation(entry, "en"), name, "\(catalog): run scripts/sync-types.py")
            for language in LocalizationTests.languages {
                XCTAssertNotNil(translation(entry, language), "\(catalog): “\(name)” isn’t translated into \(language)")
            }
        }
    }

    func testTypeDescriptionsAreTranslated() throws {
        // Finder's Kind for each type Greece declares: Launch Services looks the English description up
        // in the app's InfoPlist.strings, so the catalog is keyed by it.
        let declarations = try XCTUnwrap(try plist("Greece/App/Info.plist")["UTImportedTypeDeclarations"] as? [[String: Any]])
        let descriptions = Set(declarations.compactMap { $0["UTTypeDescription"] as? String })
        XCTAssertGreaterThan(descriptions.count, 50)
        let strings = try catalogStrings("Greece/App/InfoPlist.xcstrings")
        let keys = Set(strings.keys.filter { $0.range(of: #"^(CF|NS|LS|UI|UT|QL)[A-Za-z]+$"#, options: .regularExpression) == nil })
        XCTAssertEqual(keys, descriptions, "Greece/App/InfoPlist.xcstrings: run scripts/sync-types.py")
        for description in descriptions.sorted() {
            for language in LocalizationTests.languages {
                XCTAssertNotNil(translation(strings[description], language), "“\(description)” isn’t translated into \(language)")
            }
        }
    }

    private func types(in path: String) throws -> [String] {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8).split(separator: "\n").compactMap {
            let type = $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            return type.isEmpty ? nil : type
        }
    }
}
