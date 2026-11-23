import XCTest
import WebKit
@testable import GreeceKit

/// Quick Look never passes typed keys to a preview, so the code view works by pointer there:
/// right-click a word to find it, select text to change the query, and no field pretends to take
/// typing. The context menu also drops WebKit's items that make no sense in a preview.
@MainActor
final class PointerOnlyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PointerOnly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        PreviewHost.acceptsTyping = true
        try? FileManager.default.removeItem(at: directory)
    }

    private let source = """
    struct Lamp {
        var beam: Int
        func shine() -> Int { beam * 2 }
    }

    let lamp = Lamp(beam: 3)
    print(lamp.beam)
    """

    /// The preview owns the page's message handling, so tests keep it alive alongside its web view.
    private func page() async throws -> (PreviewView, PreviewWebView) {
        let url = directory.appendingPathComponent("Lamp.swift")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await PreviewFactory.makePreview(for: url, settings: PreviewSettings())
        await preview.waitUntilReady()
        return (preview, try XCTUnwrap(preview.webView as? PreviewWebView))
    }

    private func evaluate(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, contentWorld: .page)
    }

    /// Selects `word` on 1-based `line`, as a right-click would, and returns its client point.
    private let selectWord = """
        const el = document.querySelector('.code-view .ln[data-n="' + line + '"]');
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode()) && !node.nodeValue.includes(word)) {}
        const range = document.createRange();
        const at = node.nodeValue.indexOf(word);
        range.setStart(node, at);
        range.setEnd(node, at + word.length);
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        const box = range.getBoundingClientRect();
        return [box.left + 2, box.top + 2];
        """

    private func rightClick(_ web: WKWebView, word: String, line: Int) async throws {
        _ = try await web.callAsyncJavaScript("""
            const point = (() => { \(selectWord) })();
            const target = document.elementFromPoint(point[0], point[1]);
            target.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: point[0], clientY: point[1] }));
            """, arguments: ["word": word, "line": line], contentWorld: .page)
    }

    /// The page's menu items arrive as a message, just before WebKit would ask for the menu.
    private func menuItems(_ web: PreviewWebView) async throws -> [PreviewWebView.PageMenuItem] {
        for _ in 0..<50 where web.pageMenuItems.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        return web.pageMenuItems
    }

    func testRightClickingAWordOffersToFindIt() async throws {
        let (preview, web) = try await page()
        defer { withExtendedLifetime(preview) {} }
        try await rightClick(web, word: "beam", line: 7)
        let items = try await menuItems(web)
        let find = try XCTUnwrap(items.first)
        XCTAssertEqual(find.title, "Find “beam”")

        // Choosing it searches from that occurrence: the last of four.
        _ = try await evaluate(web, "greece.chooseMenuItem(\(find.id))")
        var state: [String: Any] = [:]
        for _ in 0..<50 {
            state = try await evaluate(web, """
                const bar = document.querySelector('.code-findbar');
                return { hidden: bar.hidden, query: bar.querySelector('input').value, count: bar.querySelector('.find-count').textContent };
                """) as? [String: Any] ?? [:]
            if state["count"] as? String == "4 of 4" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(state["hidden"] as? Bool, false)
        XCTAssertEqual(state["query"] as? String, "beam")
        XCTAssertEqual(state["count"] as? String, "4 of 4")
    }

    func testRightClickingEmptySpaceOffersLineAndViewCommands() async throws {
        let (preview, web) = try await page()
        defer { withExtendedLifetime(preview) {} }
        _ = try await evaluate(web, """
            getSelection().removeAllRanges();
            const el = document.querySelector('.code-view .ln[data-n="2"]');
            const box = el.getBoundingClientRect();
            el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: box.right - 4, clientY: box.top + 4 }));
            """)
        let titles = try await menuItems(web).map(\.title)
        XCTAssertEqual(titles.first, "Copy Line 2")
        XCTAssertTrue(titles.contains("Wrap Lines"))
        XCTAssertTrue(titles.contains("Copy All"))
    }

    func testWithoutTypingNothingLooksTypeable() async throws {
        PreviewHost.acceptsTyping = false
        let (preview, web) = try await page()
        defer { withExtendedLifetime(preview) {} }
        let state = try await evaluate(web, """
            const input = document.querySelector('.code-findbar input');
            const symbols = document.querySelector('.code-symbols .symbols-filter');
            return { noTyping: document.documentElement.classList.contains('no-typing'), readOnly: input.readOnly,
                     symbolsFilterHidden: !symbols || symbols.hidden, findTitle: document.querySelector('.floating-tools [aria-label="Find"]').title };
            """) as? [String: Any] ?? [:]
        XCTAssertEqual(state["noTyping"] as? Bool, true)
        XCTAssertEqual(state["readOnly"] as? Bool, true)
        XCTAssertEqual(state["symbolsFilterHidden"] as? Bool, true)
        XCTAssertEqual(state["findTitle"] as? String, "Find", "no shortcut in the tooltip where keys can't reach")
    }

    func testWithoutTypingTheFindButtonSearchesForTheSelection() async throws {
        PreviewHost.acceptsTyping = false
        let (preview, web) = try await page()
        defer { withExtendedLifetime(preview) {} }
        _ = try await web.callAsyncJavaScript("(() => { \(selectWord) })(); document.querySelector('.floating-tools [aria-label=\"Find\"]').click();",
                                              arguments: ["word": "lamp", "line": 7], contentWorld: .page)
        var query = "", count = ""
        for _ in 0..<50 {
            let state = try await evaluate(web, "const bar = document.querySelector('.code-findbar'); return [bar.querySelector('input').value, bar.querySelector('.find-count').textContent]") as? [String] ?? []
            (query, count) = (state.first ?? "", state.last ?? "")
            if count.hasSuffix("of 4") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(query, "lamp")
        // Case-insensitive by default: Lamp, lamp, Lamp( and lamp; the selected one is the fourth.
        XCTAssertEqual(count, "4 of 4")
    }

    func testTheInfoBarKnowsTheFile() async throws {
        let (preview, _) = try await page()
        let bar = try XCTUnwrap(preview.subviews.compactMap { $0 as? InfoBarView }.first)
        XCTAssertEqual(bar.toolTip, (directory.appendingPathComponent("Lamp.swift").path as NSString).abbreviatingWithTildeInPath)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let titles = bar.menu(for: event)?.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(titles, ["Copy Path", "Copy Name", "—", "Show in Finder"])
    }

    func testMenuKeepsUsefulWebKitItemsAndDropsTheRest() throws {
        let web = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        for name in ["Reload", "Copy", "OpenLinkInNewWindow", "DownloadLinkedFile", "CopyLink", "LookUp", "ShareMenu"] {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + name)
            menu.addItem(item)
            if name == "Reload" { menu.addItem(.separator()) }
        }
        web.pageMenuItems = [PreviewWebView.PageMenuItem(["id": 0, "title": "Find “beam”"])!]
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        web.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }, ["Find “beam”", "—", "Copy", "CopyLink", "LookUp", "ShareMenu"])
        XCTAssertTrue(web.pageMenuItems.isEmpty, "items are used once")
    }
}
