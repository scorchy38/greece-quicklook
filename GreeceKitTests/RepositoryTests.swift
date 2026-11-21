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
        XCTAssertEqual(try supportedTypes("GreeceQuickLook/Info.plist"), try listed("preview"), "Run scripts/sync-types.py")
        XCTAssertEqual(try supportedTypes("GreeceThumbnails/Info.plist"), try listed("thumbnails"), "Run scripts/sync-types.py")
    }
}
