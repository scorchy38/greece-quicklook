import XCTest
import UniformTypeIdentifiers
@testable import GreeceKit

/// Every language Greece highlights must actually reach Greece in Quick Look: its extension has to
/// resolve to a content type the extension claims. Undeclared extensions get throwaway "dyn." types
/// that Quick Look hands to its plain-text viewer instead.
final class CoverageTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Extensions macOS keeps for its own viewers, whatever Greece declares.
    private let keptByMacOS: [String: String] = [
        "txt": "plain text stays with Apple's text viewer",
        "text": "plain text stays with Apple's text viewer",
        "csv": "Quick Look always uses its Office previewer",
        "ts": "typed as MPEG video before macOS 27",
        "mts": "typed as AVCHD video",
        "m2ts": "typed as video",
        "html": "Apple renders the page itself",
        "htm": "Apple renders the page itself",
        "xhtml": "Apple renders the page itself",
        "svg": "Apple renders the image",
        "rtf": "Apple renders rich text",
        "shtml": "Apple renders the page itself",
        // Other apps' types on this Mac, and not text: DTS audio, Logic sampler, C3 archives.
        "dts": "DTS audio", "exs": "Logic sampler instrument", "pp": "an archive format", "edn": "an Adobe document", "exp": "a symbol export list",
        // Usually binary despite the extension.
        "out": "usually an executable", "nc": "usually NetCDF data", "sig": "usually a binary signature",
        // Claimed by modules in progress (documents, maps); remove once they land.
        "tex": "pending", "sty": "pending", "cls": "pending", "ltx": "pending", "dtx": "pending", "ins": "pending",
        "bbx": "pending", "cbx": "pending", "bib": "pending",
    ]

    private func claimed() throws -> Set<String> {
        let folder = repo.appendingPathComponent("Types/preview")
        var result = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".txt") {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let type = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
                if !type.isEmpty { result.insert(type) }
            }
        }
        return result
    }

    /// Extension → content type, from Greece's own declarations.
    private func declared() throws -> [String: String] {
        let folder = repo.appendingPathComponent("Types/declarations")
        var map: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".plist") {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            let declarations = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] ?? []
            for declaration in declarations {
                guard let identifier = declaration["UTTypeIdentifier"] as? String,
                      let tags = declaration["UTTypeTagSpecification"] as? [String: Any] else { continue }
                let extensions = (tags["public.filename-extension"] as? [String]) ?? [(tags["public.filename-extension"] as? String)].compactMap { $0 }
                for ext in extensions { map[ext.lowercased()] = identifier }
            }
        }
        return map
    }

    func testEveryHighlightedExtensionReachesGreece() throws {
        let claims = try claimed()
        let declarations = try declared()
        var unreachable: [String] = []
        for ext in LanguageCatalog.byExtension.keys.sorted() where keptByMacOS[ext] == nil && !ext.contains(".") {
            if let identifier = declarations[ext] {
                if !claims.contains(identifier) { unreachable.append("\(ext) (declared as \(identifier) but not claimed)") }
                continue
            }
            guard let type = UTType(filenameExtension: ext), !type.isDynamic else {
                unreachable.append("\(ext) (no content type: declare it)")
                continue
            }
            if !claims.contains(type.identifier) { unreachable.append("\(ext) (\(type.identifier) not claimed)") }
        }
        XCTAssert(unreachable.isEmpty, "Greece highlights these but Quick Look won't hand them over:\n" + unreachable.joined(separator: "\n"))
    }
}
