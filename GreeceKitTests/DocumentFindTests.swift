import XCTest
import WebKit
@testable import GreeceKit

/// Find in documents: it searches what you read (across bold and links, never across paragraphs),
/// opens folded sections to show a match, and works by pointer where keys can't reach the page.
@MainActor
final class DocumentFindTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentFind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        PreviewHost.acceptsTyping = true
        try? FileManager.default.removeItem(at: directory)
    }

    private let markdown = """
    # Harbour notes

    The **Aegean** light falls on the harbour at dawn.

    Aegean
    light is a phrase split across lines, which is still one paragraph.

    Another paragraph ends with Aegean

    light starts this one, so the two never match together.

    <details><summary>Ferries</summary>

    The late ferry to the harbour leaves at nine.

    </details>
    """

    private func page() async throws -> (PreviewView, PreviewWebView) {
        let url = directory.appendingPathComponent("Notes.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await PreviewFactory.makePreview(for: url, settings: PreviewSettings())
        await preview.waitUntilReady()
        return (preview, try XCTUnwrap(preview.webView as? PreviewWebView))
    }

    private func evaluate(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, contentWorld: .page)
    }

    private func find(_ web: WKWebView, _ query: String) async throws -> [String: Any] {
        try await web.callAsyncJavaScript("""
            greeceFind.open(query);
            const bar = document.querySelector('.doc-findbar');
            return { count: greeceFind.count, label: bar.querySelector('.find-count').textContent, hidden: bar.hidden };
            """, arguments: ["query": query], contentWorld: .page) as? [String: Any] ?? [:]
    }

    func testFindsAcrossStylingButNotAcrossParagraphs() async throws {
        let (preview, web) = try await page()
        defer { withExtendedLifetime(preview) {} }
        // "The **Aegean** light" and the soft line break inside one paragraph both match; the two
        // paragraphs that end and start with the words don't.
        let state = try await find(web, "aegean light")
        XCTAssertEqual(state["hidden"] as? Bool, false)
        XCTAssertEqual(state["count"] as? Int, 2)
        XCTAssertEqual(state["label"] as? String, "1 of 2")
    }

    func testAMatchInsideAClosedDetailsOpensIt() async throws {
        let (preview, web) = try await page()
        defer { withExtendedLifetime(preview) {} }
        let before = try await evaluate(web, "return document.querySelector('details').open") as? Bool
        XCTAssertEqual(before, false)
        let state = try await find(web, "late ferry")
        XCTAssertEqual(state["count"] as? Int, 1)
        let after = try await evaluate(web, "return document.querySelector('details').open") as? Bool
        XCTAssertEqual(after, true)
    }

    func testStepsWrapAroundAndDoneClears() async throws {
        let (preview, web) = try await page()
        defer { withExtendedLifetime(preview) {} }
        _ = try await find(web, "harbour")
        let labels = try await evaluate(web, """
            const label = () => document.querySelector('.doc-findbar .find-count').textContent;
            const seen = [label()];
            for (let i = 0; i < 3; i++) { greeceFind.next(); seen.push(label()); }
            document.querySelector('.doc-findbar .find-done').click();
            seen.push(String(CSS.highlights.get('greece-find').size));
            return seen;
            """) as? [String]
        XCTAssertEqual(labels, ["1 of 3", "2 of 3", "3 of 3", "1 of 3", "0"])
    }

    func testRightClickingAWordOffersFind() async throws {
        let (preview, web) = try await page()
        defer { withExtendedLifetime(preview) {} }
        _ = try await evaluate(web, """
            const strong = document.querySelector('strong');
            const range = document.createRange();
            range.selectNodeContents(strong);
            getSelection().removeAllRanges();
            getSelection().addRange(range);
            const box = range.getBoundingClientRect();
            strong.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: box.left + 2, clientY: box.top + 2 }));
            """)
        for _ in 0..<50 where web.pageMenuItems.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(web.pageMenuItems.map(\.title), ["Find “Aegean”"])
    }

    func testWithoutTypingTheSelectionIsTheQuery() async throws {
        PreviewHost.acceptsTyping = false
        let (preview, web) = try await page()
        defer { withExtendedLifetime(preview) {} }
        let state = try await evaluate(web, """
            const strong = document.querySelector('strong');
            const range = document.createRange();
            range.selectNodeContents(strong);
            getSelection().removeAllRanges();
            getSelection().addRange(range);
            greeceFind.open();
            const input = document.querySelector('.doc-findbar input');
            return { query: input.value, readOnly: input.readOnly, label: document.querySelector('.doc-findbar .find-count').textContent };
            """) as? [String: Any] ?? [:]
        XCTAssertEqual(state["query"] as? String, "Aegean")
        XCTAssertEqual(state["readOnly"] as? Bool, true)
        // Aegean appears three times; the bold one in the first paragraph is the first.
        XCTAssertEqual(state["label"] as? String, "1 of 3")
    }

    func testTheOutlineTogglesFromTheContextMenu() async throws {
        let url = directory.appendingPathComponent("Guide.md")
        try (1...6).map { "## Section \($0)\n\nSome text about part \($0).\n" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let preview = try await PreviewFactory.makePreview(for: url, settings: PreviewSettings())
        await preview.waitUntilReady()
        let web = try XCTUnwrap(preview.webView as? PreviewWebView)
        let state = "const d = document.querySelector('.doc'); return d.classList.contains('outline-collapsed') || d.classList.contains('outline-floating')"
        let before = try await evaluate(web, state) as? Bool
        _ = try await evaluate(web, """
            getSelection().removeAllRanges();
            const p = document.querySelector('article p');
            p.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 5, clientY: 5 }));
            """)
        for _ in 0..<50 where web.pageMenuItems.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let item = try XCTUnwrap(web.pageMenuItems.first { $0.title == "Outline" })
        _ = try await evaluate(web, "greece.chooseMenuItem(\(item.id))")
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = try await evaluate(web, state) as? Bool
        XCTAssertNotEqual(before, after, "choosing Outline flips the outline")
    }

    func testCodePagesKeepTheirOwnFind() async throws {
        let url = directory.appendingPathComponent("lamp.swift")
        try "let lamp = 1\n".write(to: url, atomically: true, encoding: .utf8)
        let preview = try await PreviewFactory.makePreview(for: url, settings: PreviewSettings())
        await preview.waitUntilReady()
        let web = try XCTUnwrap(preview.webView as? WKWebView)
        let bars = try await evaluate(web, "return [document.querySelectorAll('.doc-findbar').length, document.querySelectorAll('.code-findbar').length]") as? [Int]
        XCTAssertEqual(bars, [0, 1])
    }
}
