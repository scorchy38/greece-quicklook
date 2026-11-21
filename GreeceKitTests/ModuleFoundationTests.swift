import XCTest
@testable import GreeceKit

final class ModuleFoundationTests: XCTestCase {
    private struct Sample: Encodable { var title: String }

    func testModuleDataCannotCloseItsScriptTag() {
        let document = WebDocument(module: .init("sample"), data: Sample(title: "</script><script>alert(1)</script>"), scripts: [])
        let html = document.html(settings: PreviewSettings())
        XCTAssertFalse(html.contains("</script><script>alert"))
        XCTAssertTrue(html.contains("<script id=\"data\" type=\"application/json\">"))
    }

    func testOnlyBundledModuleScriptsLoad() {
        let document = WebDocument(module: .init("sample"), data: Sample(title: "x"),
                                   scripts: ["../../../../etc/passwd", "modules/does-not-exist.js", "greece.js"])
        let html = document.html(settings: PreviewSettings())
        XCTAssertFalse(html.contains("passwd"))
        XCTAssertFalse(html.contains("does-not-exist"))
    }

    func testPlainDocumentsGetNoExtraAccess() {
        let html = WebDocument(kind: .markdown, text: "# Hi").html(settings: PreviewSettings())
        XCTAssertTrue(html.contains("connect-src greece://asset;"))
        XCTAssertFalse(html.contains("greece://module"))
        XCTAssertFalse(html.contains("<script id=\"data\""))
    }

    func testModuleDocumentsAskForWhatTheyUse() {
        var document = WebDocument(module: .init("sample"), data: Sample(title: "x"), scripts: [])
        document.readableDirectory = URL(fileURLWithPath: "/tmp")
        document.resources = { _ in nil }
        let html = document.html(settings: PreviewSettings())
        XCTAssertTrue(html.contains("connect-src greece://asset greece://file greece://module;"))
    }
}
