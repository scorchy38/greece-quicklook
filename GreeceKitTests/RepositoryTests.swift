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

    private func types(in path: String) throws -> [String] {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8).split(separator: "\n").compactMap {
            let type = $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            return type.isEmpty ? nil : type
        }
    }
}
