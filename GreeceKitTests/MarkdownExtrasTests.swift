import XCTest
import JavaScriptCore
import WebKit
@testable import GreeceKit

/// Markdown beyond GFM: the syntax plugins (run in JavaScriptCore with the bundled markdown-it),
/// MDX, hostile input, and the reading tools on a real page.
final class MarkdownExtrasTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/markdown")
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceMarkdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - JavaScriptCore

    private static var contexts: [String: JSContext] = [:]

    /// markdown-it, its footnote plugin and markdown-syntax.js, with the page's `greece` stand-in.
    private func markdown(fileName: String = "README.md") throws -> JSContext {
        if let context = Self.contexts[fileName] { return context }
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail("JS exception: \(exception?.toString() ?? "?")") }
        context.evaluateScript("var window = globalThis;")
        for path in ["vendor/markdown-it/markdown-it.min.js", "vendor/markdown-it/markdown-it-footnote.min.js"] {
            context.evaluateScript(try String(contentsOf: try XCTUnwrap(WebAssets.url(path)), encoding: .utf8))
        }
        context.setObject(fileName, forKeyedSubscript: "fileName" as NSString)
        context.evaluateScript("""
            const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
            window.greece = { markdownPlugins: [], kit: { esc: (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]), fileName } };
            """)
        let syntax = try XCTUnwrap(WebAssets.url("enhancers/markdown-syntax.js"))
        context.evaluateScript(try String(contentsOf: syntax, encoding: .utf8))
        context.evaluateScript("""
            var md = window.markdownit({ html: true, linkify: true, typographer: true });
            md.use(window.markdownitFootnote);
            for (const plugin of window.greece.markdownPlugins) md.use(plugin);
            """)
        Self.contexts[fileName] = context
        return context
    }

    private func render(_ source: String, fileName: String = "README.md") throws -> String {
        let context = try markdown(fileName: fileName)
        context.setObject(source, forKeyedSubscript: "source" as NSString)
        return context.evaluateScript("md.render(source)")?.toString() ?? ""
    }

    // MARK: - Syntax

    func testMaterialTabs() throws {
        let html = try render("=== \"macOS\"\n\n    Use **Homebrew**.\n\n===+ \"Linux\"\n\n    ```sh\n    apt install x\n    ```\n\nAfter.\n")
        XCTAssertTrue(html.contains(#"<div class="md-tabs">"#))
        XCTAssertTrue(html.contains(#"<section class="md-tab" data-label="macOS">"#))
        XCTAssertTrue(html.contains(#"<section class="md-tab" data-label="Linux" data-selected="">"#))
        XCTAssertTrue(html.contains("<strong>Homebrew</strong>"))
        XCTAssertTrue(html.contains(#"<code class="language-sh">apt install x"#), "indented content is Markdown, not a code block")
        XCTAssertTrue(html.hasSuffix("<p>After.</p>\n"))
    }

    func testContainerTabsAndAdmonitions() throws {
        let tabs = try render(":::tabs\n== npm\nnpm i x\n@tab pnpm\npnpm add x\n:::\n")
        XCTAssertEqual(tabs.components(separatedBy: "class=\"md-tab\"").count - 1, 2)
        XCTAssertTrue(tabs.contains(#"data-label="pnpm""#))

        let tip = try render(":::tip[Pro tip]\nBody\n:::\n\n::: details\nHidden\n:::\n\n!!! warning \"Careful\"\n    Hot\n\n???+ example\n    Open\n\n??? bug\n    Closed\n")
        XCTAssertTrue(tip.contains(#"<blockquote class="alert callout tip">"#))
        XCTAssertTrue(tip.contains("<span>Pro tip</span>"))
        XCTAssertTrue(tip.contains(#"<details class="alert callout note">"#) && tip.contains("<span>Details</span>"))
        XCTAssertTrue(tip.contains(#"<blockquote class="alert callout warning">"#) && tip.contains("<span>Careful</span>"))
        XCTAssertTrue(tip.contains(#"<details class="alert callout example" open>"#))
        XCTAssertTrue(tip.contains(#"<details class="alert callout bug">"#))
        XCTAssertFalse(try render(":::unknown\nx\n:::\n").contains("callout"), "unknown containers stay text")
    }

    func testObsidianAndGitHubCallouts() throws {
        let html = try render("> [!NOTE]\n> GitHub.\n\n> [!tip]- Folded *title*\n> Body\n\n> [!faq]+\n> Open\n\n> [!custom-thing] Mine\n> x\n\n> Plain quote\n")
        XCTAssertTrue(html.contains(#"<blockquote class="alert callout note">"#))
        XCTAssertTrue(html.contains(#"<details class="alert callout tip">"#))
        XCTAssertTrue(html.contains("<summary class=\"alert-title\">") && html.contains("<span>Folded <em>title</em></span>"))
        XCTAssertTrue(html.contains(#"<details class="alert callout question" open>"#) && html.contains("<span>FAQ</span>"))
        XCTAssertTrue(html.contains("<span>Mine</span>"))
        XCTAssertTrue(html.contains("<blockquote>\n<p>Plain quote</p>"))
        XCTAssertFalse(html.contains("[!"), "markers never leak into the text")
    }

    func testWikiLinks() throws {
        let html = try render("[[My Page]] [[Docs/Setup#First Run|setup]] [[#Local Heading]] ![[shot.png|300]] ![[Other Note]] [[file.pdf]]")
        XCTAssertTrue(html.contains(#"<a href="My%20Page.md" class="wikilink">My Page</a>"#))
        XCTAssertTrue(html.contains(#"<a href="Docs/Setup.md#first-run" class="wikilink">setup</a>"#))
        XCTAssertTrue(html.contains(##"<a href="#local-heading" class="wikilink">Local Heading</a>"##))
        XCTAssertTrue(html.contains(#"<img class="wiki-embed" src="shot.png" alt="shot.png" width="300">"#))
        XCTAssertTrue(html.contains(#"<a href="Other%20Note.md" class="wikilink embed">Other Note</a>"#))
        XCTAssertTrue(html.contains(#"href="file.pdf""#))
    }

    func testWikiLinksCannotBecomeScripts() throws {
        let html = try render(#"[[javascript:alert(1)]] [[a|<img src=x onerror=alert(2)>]] ![[x.png|"onload="y]] [[data:text/html,x]]"#)
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertFalse(html.contains("href=\"data:"))
        XCTAssertFalse(html.contains("<img src=x"))
        XCTAssertFalse(html.contains("onload=\"y"))
        XCTAssertTrue(html.contains("javascript%3Aalert(1).md"))
    }

    func testDefinitionListsAbbreviationsAndInlineMarks() throws {
        let html = try render("Term\n: One\n: Two\n\nOther\n: Three\n\n*[HTML]: HyperText Markup Language\nAn HTML page, not HTMLX. ==Marked **bold**==, H~2~O, x^2^, ~~gone~~, a == b == c, [HTML](https://x.test).\n")
        XCTAssertTrue(html.contains("<dl>\n<dt>Term</dt>\n<dd>One</dd>\n<dd>Two</dd>\n<dt>Other</dt>\n<dd>Three</dd>\n</dl>"))
        XCTAssertTrue(html.contains(#"An <abbr title="HyperText Markup Language">HTML</abbr> page, not HTMLX."#))
        XCTAssertTrue(html.contains("<mark>Marked <strong>bold</strong></mark>"))
        XCTAssertTrue(html.contains("H<sub>2</sub>O") && html.contains("x<sup>2</sup>") && html.contains("<s>gone</s>"))
        XCTAssertTrue(html.contains("a == b == c"))
        XCTAssertTrue(html.contains(#"<a href="https://x.test">HTML</a>"#), "abbreviations never rewrite link text")
    }

    func testMDX() throws {
        let source = """
        import { Callout } from 'nextra/components'
        import {
          Steps,
        } from '@/components'
        export const meta = {
          title: 'x',
        }

        # Title

        Version {props.version} here{/* hidden */}.

        <Callout type="warning" title="Careful">
          Indented **child**.
        </Callout>

        <Tabs items={['npm', 'yarn']}>
          <Tabs.Tab>npm i</Tabs.Tab>
          <Tabs.Tab>yarn add</Tabs.Tab>
        </Tabs>

        <Chart data={[1, 2]} title="<script>alert(1)</script>" />

        ```jsx
        import Foo from 'bar'
        <Callout>kept as code</Callout>
        ```
        """
        let html = try render(source, fileName: "page.mdx")
        XCTAssertFalse(html.contains("nextra/components"))
        XCTAssertFalse(html.contains("export const"))
        XCTAssertFalse(html.contains("hidden"))
        XCTAssertTrue(html.contains(#"<code class="mdx-expr">props.version</code>"#))
        XCTAssertTrue(html.contains(#"<blockquote class="alert callout warning">"#) && html.contains("<span>Careful</span>") && html.contains("<strong>child</strong>"))
        XCTAssertTrue(html.contains(#"data-label="npm""#) && html.contains(#"data-label="yarn""#))
        XCTAssertTrue(html.contains(#"<div class="mdx mdx-leaf" data-mdx="Chart">"#))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("import Foo from 'bar'\n&lt;Callout&gt;kept as code&lt;/Callout&gt;"), "code fences are untouched")
        // Plain Markdown files keep JSX-looking text and braces as they are.
        XCTAssertTrue(try render("Use {braces} freely.", fileName: "notes.md").contains("{braces}"))
    }

    func testHostileMarkdownStaysFast() throws {
        let cases = [
            String(repeating: "==a ", count: 25_000), String(repeating: "[[ ", count: 30_000), String(repeating: "~a ^b ", count: 20_000),
            String(repeating: ":::note\n", count: 10_000), String(repeating: "!!! note\n", count: 3_000),
            String(repeating: "> [!note]\n", count: 10_000), String(repeating: ">", count: 5_000) + " [!tip] x",
            String(repeating: "Term\n: def\n", count: 5_000), (0..<300).map { "*[A\($0)]: x" }.joined(separator: "\n") + "\n" + String(repeating: "A1 A2 ", count: 10_000),
            (0..<200).map { String(repeating: " ", count: $0 * 4) + "=== \"T\($0)\"" }.joined(separator: "\n"),
        ]
        for (index, source) in cases.enumerated() {
            let started = Date()
            _ = try render(source)
            try XCTAssertWithinBudget(Date().timeIntervalSince(started), 3, "case \(index)")
        }
        for source in [String(repeating: "<Foo>\n", count: 3_000), String(repeating: "{", count: 30_000), String(repeating: "import {\n", count: 3_000)] {
            let started = Date()
            _ = try render(source, fileName: "x.mdx")
            try XCTAssertWithinBudget(Date().timeIntervalSince(started), 3)
        }
    }

    // MARK: - On a real page

    @MainActor
    private func page(_ url: URL) async throws -> WKWebView {
        let preview = try await PreviewFactory.makePreview(for: url, settings: PreviewSettings())
        await preview.waitUntilReady()
        return try XCTUnwrap(preview.webView as? WKWebView)
    }

    @MainActor
    func testFrontMatterBlockScalars() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FrontMatter-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "---\nname: harbour-forms\ndescription: >\n  Fills in permit forms.\n  Use for berths.\nnotes: |\n  One\n  Two\n---\n\n# Title\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let web = try await page(url)
        let values = try await web.callAsyncJavaScript("return Array.from(document.querySelectorAll('.front-matter dd')).map((d) => d.textContent)",
                                                       contentWorld: .page) as? [String]
        XCTAssertEqual(values, ["harbour-forms", "Fills in permit forms. Use for berths.", "One\nTwo"])
    }

    @MainActor
    func testReadingToolsOnTheExtrasFixture() async throws {
        let web = try await page(fixtures.appendingPathComponent("extras.md"))
        let state = try await web.callAsyncJavaScript("""
            const q = (s) => document.querySelectorAll(s).length;
            const bar = document.querySelector('.md-tabbar');
            const before = Array.from(bar.children).map((b) => b.getAttribute('aria-selected')).join();
            bar.children[1].click();
            const after = Array.from(bar.children).map((b) => b.getAttribute('aria-selected')).join();
            const panels = Array.from(document.querySelectorAll('.md-tabs')[0].querySelectorAll(':scope > .md-tab')).map((p) => p.hidden).join();
            document.querySelector('.outline-hide') && document.querySelector('.outline-hide').click();
            return {
              tabbars: q('.md-tabbar'), before, after, panels,
              callouts: q('.callout'), folded: q('details.callout:not([open])'),
              anchors: q('.heading-anchor'), tasks: (document.querySelector('.outline-tasks') || {}).textContent,
              outlineHidden: document.querySelector('.doc').classList.contains('outline-collapsed') || window.innerWidth <= 1080,
              wiki: q('a.wikilink'), dl: q('dl:not(.front-matter) dt'), abbr: q('abbr[title]'), marks: q('article mark'),
              mermaid: q('.mermaid-expand'), progress: q('.read-progress'), lightbox: document.querySelector('article').classList.contains('has-lightbox'),
              footnotes: q('.footnote-ref a'), images: q('article img'),
            };
            """, contentWorld: .page) as? [String: Any] ?? [:]
        XCTAssertEqual(state["tabbars"] as? Int, 2)
        XCTAssertEqual(state["before"] as? String, "true,false,false")
        XCTAssertEqual(state["after"] as? String, "false,true,false")
        XCTAssertEqual(state["panels"] as? String, "true,false,true")
        XCTAssertEqual(state["callouts"] as? Int, 7)
        XCTAssertEqual(state["folded"] as? Int, 1)
        XCTAssertGreaterThanOrEqual(state["anchors"] as? Int ?? 0, 7)
        XCTAssertEqual(state["tasks"] as? String, "5 of 7 done")
        XCTAssertEqual(state["outlineHidden"] as? Bool, true)
        XCTAssertEqual(state["wiki"] as? Int, 3)
        XCTAssertEqual(state["dl"] as? Int, 2)
        XCTAssertGreaterThanOrEqual(state["abbr"] as? Int ?? 0, 2)
        XCTAssertEqual(state["marks"] as? Int, 1)
        XCTAssertEqual(state["mermaid"] as? Int, 1)
        XCTAssertEqual(state["progress"] as? Int, 1)
        XCTAssertEqual(state["lightbox"] as? Bool, true)
        XCTAssertEqual(state["footnotes"] as? Int, 2)
        XCTAssertEqual(state["images"] as? Int, 2)
    }

    @MainActor
    func testOutlineResizesHidesAndProgressFollowsScrolling() async throws {
        let preview = try await PreviewFactory.makePreview(for: fixtures.appendingPathComponent("extras.md"), settings: PreviewSettings())
        await preview.waitUntilReady()
        // Wide enough for the outline to be a sidebar.
        preview.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        preview.layoutSubtreeIfNeeded()
        let web = try XCTUnwrap(preview.webView as? WKWebView)
        for _ in 0..<40 {
            let wide = try await web.callAsyncJavaScript("return window.innerWidth > 1300 && !matchMedia('(max-width: 1080px)').matches",
                                                         contentWorld: .page) as? Bool ?? false
            if wide { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await web.callAsyncJavaScript("""
            const nav = document.querySelector('nav.outline');
            const handle = document.querySelector('.outline-resizer');
            const before = nav.getBoundingClientRect().width;
            const r = handle.getBoundingClientRect();
            const x = r.left + r.width / 2;
            const y = r.top + 20;
            const pointer = (type, cx) => handle.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: 1, button: 0, clientX: cx, clientY: y }));
            pointer('pointerdown', x);
            for (let i = 1; i <= 10; i++) pointer('pointermove', x - i * 10);
            pointer('pointerup', x - 100);
            const after = nav.getBoundingClientRect().width;
            document.querySelector('.outline-hide').click();
            const hidden = getComputedStyle(nav).display === 'none';
            const show = document.querySelector('.outline-show');
            const showVisible = getComputedStyle(show).display !== 'none';
            show.click();
            const back = getComputedStyle(nav).display !== 'none';
            window.scrollTo(0, 500);
            window.dispatchEvent(new Event('scroll'));
            const bar = document.querySelector('.read-progress');
            return { width: window.innerWidth, before, after, hidden, showVisible, back, progress: bar.classList.contains('on'), transform: bar.style.transform };
            """, contentWorld: .page) as? [String: Any] ?? [:]
        XCTAssertGreaterThan(result["width"] as? Double ?? Double(result["width"] as? Int ?? 0), 1300)
        let before = result["before"] as? Double ?? 0
        let after = result["after"] as? Double ?? 0
        XCTAssertGreaterThan(after, before + 60, "dragging the edge 100 px left widens the outline")
        XCTAssertEqual(result["hidden"] as? Bool, true)
        XCTAssertEqual(result["showVisible"] as? Bool, true)
        XCTAssertEqual(result["back"] as? Bool, true)
        XCTAssertEqual(result["progress"] as? Bool, true)
        XCTAssertTrue((result["transform"] as? String ?? "").hasPrefix("scaleX(0."), result["transform"] as? String ?? "")
    }

    @MainActor
    func testDiagramOpensInAZoomViewAndCloses() async throws {
        let web = try await page(fixtures.appendingPathComponent("extras.md"))
        let result = try await web.callAsyncJavaScript("""
            const block = document.querySelector('.mermaid-block');
            if (!block.querySelector('svg')) return { rendered: false };
            block.querySelector('.mermaid-expand').click();
            const view = document.querySelector('.diagram-view');
            const inView = !!(view && view.querySelector('svg'));
            const level = view.querySelector('.zoom-level').textContent;
            view.querySelector('[data-act="in"]').click();
            const zoomed = view.querySelector('.zoom-level').textContent;
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            return { rendered: true, inView, level, zoomed, closed: !document.querySelector('.diagram-view'), back: !!block.querySelector('svg') };
            """, contentWorld: .page) as? [String: Any] ?? [:]
        guard result["rendered"] as? Bool == true else { throw XCTSkip("Mermaid hadn't finished drawing") }
        XCTAssertEqual(result["inView"] as? Bool, true)
        XCTAssertNotEqual(result["level"] as? String, result["zoomed"] as? String)
        XCTAssertEqual(result["closed"] as? Bool, true)
        XCTAssertEqual(result["back"] as? Bool, true, "the diagram returns to the page")
    }

    @MainActor
    func testLightboxSteppingAndFootnotePopover() async throws {
        let web = try await page(fixtures.appendingPathComponent("extras.md"))
        let result = try await web.callAsyncJavaScript("""
            const images = document.querySelectorAll('article img');
            images[0].click();
            const box = document.querySelector('.lightbox');
            const first = box && box.querySelector('.lightbox-count').textContent + '|' + box.querySelector('.lightbox-caption').textContent;
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
            const second = box.querySelector('.lightbox-count').textContent;
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            const closed = !document.querySelector('.lightbox');
            const ref = document.querySelector('.footnote-ref a');
            ref.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
            const pop = document.querySelector('.footnote-pop');
            return { first, second, closed, popover: pop && !pop.hidden ? pop.textContent.trim() : null };
            """, contentWorld: .page) as? [String: Any] ?? [:]
        XCTAssertEqual(result["first"] as? String, "1 of 2|Sunrise")
        XCTAssertEqual(result["second"] as? String, "2 of 2")
        XCTAssertEqual(result["closed"] as? Bool, true)
        XCTAssertEqual(result["popover"] as? String, "Previews paint in under a few hundred milliseconds, even for long documents.")
    }

    @MainActor
    func testMDXPageAndHostileMarkdownPage() async throws {
        let web = try await page(fixtures.appendingPathComponent("components.mdx"))
        let mdx = try await web.callAsyncJavaScript("""
            return { components: document.querySelectorAll('.mdx').length, tabs: document.querySelectorAll('.md-tabbar button').length,
                     text: document.querySelector('article').textContent };
            """, contentWorld: .page) as? [String: Any] ?? [:]
        XCTAssertEqual(mdx["components"] as? Int, 3)
        XCTAssertEqual(mdx["tabs"] as? Int, 2)
        XCTAssertFalse((mdx["text"] as? String ?? "").contains("import"))

        let hostile = directory.appendingPathComponent("hostile.md")
        try """
        === "<img src=x onerror=alert(1)>"

            body

        > [!note]- <script>alert(2)</script>
        > x

        [[javascript:alert(3)|click]] ![[x.png|" onload="alert(4)]]

        :::tip[<svg onload=alert(5)>]
        y
        :::
        """.write(to: hostile, atomically: true, encoding: .utf8)
        let web2 = try await page(hostile)
        let active = try await web2.callAsyncJavaScript("""
            const nodes = Array.from(document.querySelectorAll('article *'));
            return { scripts: document.querySelectorAll('article script').length,
                     handlers: nodes.filter((n) => Array.from(n.attributes).some((a) => a.name.startsWith('on'))).length,
                     javascript: nodes.filter((n) => /^\\s*javascript:/i.test(n.getAttribute('href') || '')).length,
                     tab: (document.querySelector('.md-tabbar button') || {}).textContent };
            """, contentWorld: .page) as? [String: Any] ?? [:]
        XCTAssertEqual(active["scripts"] as? Int, 0)
        XCTAssertEqual(active["handlers"] as? Int, 0)
        XCTAssertEqual(active["javascript"] as? Int, 0)
        XCTAssertEqual(active["tab"] as? String, "<img src=x onerror=alert(1)>")
    }
}
