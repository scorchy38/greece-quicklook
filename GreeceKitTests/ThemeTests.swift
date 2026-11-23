import XCTest
import AppKit
@testable import GreeceKit

/// Code, reading and diagram themes: complete palettes, readable contrast, and settings that
/// reach the page.
final class ThemeTests: XCTestCase {

    /// WCAG AA for body text; WCAG's 3:1 for large text and UI for coloured tokens; comments are
    /// meant to recede, so they only need to stay legible.
    private let bodyText = 4.5
    private let token = 3.0
    private let comment = 2.2

    private func isHex(_ value: String) -> Bool {
        value.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil
    }

    // MARK: - Code themes

    func testCatalogIsLargeAndUnique() {
        XCTAssertGreaterThanOrEqual(CodeTheme.all.count, 40)
        XCTAssertEqual(Set(CodeTheme.all.map(\.id)).count, CodeTheme.all.count, "duplicate theme ids")
        XCTAssertEqual(Set(CodeTheme.all.map(\.name)).count, CodeTheme.all.count, "duplicate theme names")
        XCTAssertEqual(CodeTheme.default.id, "xcode")
        XCTAssertEqual(CodeTheme.all.first?.id, "xcode")
        // Ids people may already have saved.
        for id in ["xcode", "github", "one", "catppuccin", "tokyo-night", "rose-pine", "solarized", "gruvbox"] {
            XCTAssertNotNil(CodeTheme.named(id), id)
        }
        for variants in CodeTheme.Variants.allCases {
            XCTAssertFalse(CodeTheme.group(variants).isEmpty, "no \(variants) themes")
        }
    }

    func testEveryPaletteIsCompleteAndReadable() {
        var problems: [String] = []
        for theme in CodeTheme.all {
            let palettes = theme.variants == .pair ? [("light", theme.light), ("dark", theme.dark)] : [("only", theme.light)]
            for (label, p) in palettes {
                let name = "\(theme.id) \(label)"
                let all = [p.background, p.foreground, p.comment, p.selection] + p.tokens.map(\.color)
                for value in all where !isHex(value) { problems.append("\(name): \(value) is not #RRGGBB") }
                let fg = ThemeColor.contrast(p.foreground, p.background)
                if fg < bodyText { problems.append(String(format: "%@: foreground %.2f:1", name, fg)) }
                let c = ThemeColor.contrast(p.comment, p.background)
                if c < comment { problems.append(String(format: "%@: comment %.2f:1", name, c)) }
                for (role, color) in p.tokens {
                    let ratio = ThemeColor.contrast(color, p.background)
                    if ratio < token { problems.append(String(format: "%@: %@ %@ %.2f:1", name, role, color, ratio)) }
                }
                if p.selection == p.background { problems.append("\(name): selection is invisible") }
                // Diff colours must be told apart.
                if p.added == p.removed { problems.append("\(name): added and removed are the same colour") }
            }
        }
        XCTAssert(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func testVariantsMatchTheirPalettes() {
        for theme in CodeTheme.all {
            switch theme.variants {
            case .pair:
                XCTAssertFalse(theme.light.isDark, "\(theme.id) light variant is dark")
                XCTAssertTrue(theme.dark.isDark, "\(theme.id) dark variant is light")
            case .light:
                XCTAssertFalse(theme.light.isDark, theme.id)
                XCTAssertEqual(theme.light, theme.dark)
            case .dark:
                XCTAssertTrue(theme.dark.isDark, theme.id)
                XCTAssertEqual(theme.light, theme.dark)
            }
        }
    }

    func testPinnedVariantUsesOnePalette() {
        var settings = PreviewSettings()
        settings.theme = "github"
        XCTAssertNotEqual(settings.codeTheme.light, settings.codeTheme.dark)
        XCTAssertTrue(settings.codeTheme.css.contains("prefers-color-scheme: dark"))

        settings.themeVariant = .dark
        XCTAssertEqual(settings.codeTheme.light, CodeTheme.github.dark)
        XCTAssertEqual(settings.codeTheme.dark, CodeTheme.github.dark)
        XCTAssertFalse(settings.codeTheme.css.contains("prefers-color-scheme"))

        settings.themeVariant = .light
        XCTAssertEqual(settings.codeTheme.dark, CodeTheme.github.light)

        // Pinning a single-palette theme changes nothing.
        let single = CodeTheme.all.first { $0.variants == .dark }!
        settings.theme = single.id
        settings.themeVariant = .light
        XCTAssertEqual(settings.codeTheme.light, single.dark)
    }

    func testThemeCSSSetsEveryToken() {
        for theme in CodeTheme.all {
            let css = theme.css
            for name in ["--bg", "--fg", "--t-comment", "--t-keyword", "--t-string", "--t-number", "--t-function", "--t-type",
                         "--t-tag", "--t-attr", "--t-variable", "--t-builtin", "--t-regexp", "--t-meta", "--t-added",
                         "--t-removed", "--t-selection", "--t-keyword-weight"] {
                XCTAssertTrue(css.contains(name + ":"), "\(theme.id) misses \(name)")
            }
            XCTAssertEqual(css.contains("prefers-color-scheme: dark"), theme.variants == .pair, theme.id)
        }
        XCTAssertTrue(CodeTheme.xcode.css.contains("calc(var(--code-weight, 400) + 200)"), "bold keywords follow the code weight")
    }

    func testSearchFindsThemesByVariantName() {
        XCTAssertTrue(CodeTheme.all.contains { $0.matches("mocha") })
        XCTAssertTrue(CodeTheme.all.contains { $0.matches("dracula") })
        XCTAssertFalse(CodeTheme.all.contains { $0.matches("zzzz-no-theme") })
    }

    // MARK: - Reading themes

    func testReadingThemesAreReadable() {
        XCTAssertGreaterThanOrEqual(ReadingTheme.all.count, 15)
        XCTAssertEqual(Set(ReadingTheme.all.map(\.id)).count, ReadingTheme.all.count)
        XCTAssertEqual(ReadingTheme.default.id, "greece")
        var problems: [String] = []
        for theme in ReadingTheme.all {
            for (label, p) in [("light", theme.light), ("dark", theme.dark)] {
                let name = "\(theme.id) \(label)"
                for value in [p.page, p.text, p.secondary, p.tertiary, p.heading, p.accent] where !isHex(value) {
                    problems.append("\(name): \(value) is not #RRGGBB")
                }
                for (role, color, minimum) in [("text", p.text, bodyText), ("heading", p.heading, bodyText),
                                               ("secondary", p.secondary, bodyText), ("link", p.accent, bodyText),
                                               ("tertiary", p.tertiary, 1.8)] {
                    let ratio = ThemeColor.contrast(color, p.page)
                    if ratio < minimum { problems.append(String(format: "%@: %@ %.2f:1", name, role, ratio)) }
                }
            }
            XCTAssertGreaterThan(ThemeColor.luminance(theme.light.page), 0.18, "\(theme.id) light page is dark")
            XCTAssertLessThan(ThemeColor.luminance(theme.dark.page), 0.18, "\(theme.id) dark page is light")
        }
        XCTAssert(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func testEveryReadingThemeHasItsStyles() throws {
        let url = try XCTUnwrap(WebAssets.url("themes/reading.css"))
        let css = try String(contentsOf: url, encoding: .utf8)
        for theme in ReadingTheme.all where !theme.isNative {
            XCTAssertTrue(css.contains("html.reading.rt-\(theme.id) {"), "reading.css has no section for \(theme.id)")
            XCTAssertTrue(theme.css.hasPrefix("html.reading{"), "\(theme.id) colours must stay on reading pages")
        }
        XCTAssertEqual(ReadingTheme.greece.css, "", "the native theme keeps the system's colours")
    }

    // MARK: - Diagram themes

    func testDiagramThemes() {
        XCTAssertGreaterThanOrEqual(DiagramTheme.all.count, 17)
        XCTAssertEqual(Set(DiagramTheme.all.map(\.id)).count, DiagramTheme.all.count)
        let builtIns: Set = ["default", "neutral", "forest", "dark", "base"]
        var problems: [String] = []
        for theme in DiagramTheme.all {
            if case .builtIn(let light, let dark) = theme.style {
                XCTAssertTrue(builtIns.contains(light) && builtIns.contains(dark), theme.id)
                continue
            }
            for code in [CodeTheme.xcode, CodeTheme.github] {
                let pair = theme.palettes(code: code, reading: .github)
                for (label, p) in [("light", pair.light), ("dark", pair.dark)] {
                    let name = "\(theme.id) \(label)"
                    for (role, a, b, minimum) in [("node text", p.nodeText, p.node, bodyText), ("label", p.text, p.background, bodyText),
                                                  ("note", p.noteText, p.note, bodyText), ("line", p.line, p.background, token)] {
                        let ratio = ThemeColor.contrast(a, b)
                        if ratio < minimum { problems.append(String(format: "%@: %@ %.2f:1", name, role, ratio)) }
                    }
                }
            }
        }
        XCTAssert(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func testDiagramCSSFollowsAppearanceAndCodeTheme() {
        let css = DiagramTheme.matchCode.css(code: CodeTheme.github, reading: .greece)
        XCTAssertTrue(css.contains("--mm-theme:base"))
        XCTAssertTrue(css.contains("--mm-background:\(CodeTheme.github.light.background)"))
        XCTAssertTrue(css.contains("@media (prefers-color-scheme: dark){:root{"))
        XCTAssertTrue(css.contains("--mm-background:\(CodeTheme.github.dark.background)"))
        let builtIn = DiagramTheme.neutral.css(code: .xcode, reading: .greece)
        XCTAssertTrue(builtIn.contains("--mm-theme:neutral"))
        XCTAssertTrue(builtIn.contains("--mm-theme:dark"))
        XCTAssertTrue(builtIn.contains("--mm-keys:none"))
    }

    // MARK: - Thumbnails

    /// The colour of a thumbnail's top-left corner, drawn as Finder would draw it.
    private func cornerColour(_ name: String, _ text: String, settings: PreviewSettings) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("greece-theme-\(UUID().uuidString)-\(name)")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let page = try XCTUnwrap(Thumbnailer.page(for: url, maximumSize: CGSize(width: 128, height: 128), settings: settings))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(page.size.width), pixelsHigh: Int(page.size.height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        page.draw()
        NSGraphicsContext.restoreGraphicsState()
        let colour = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        return String(format: "#%02X%02X%02X", Int((colour.redComponent * 255).rounded()), Int((colour.greenComponent * 255).rounded()),
                      Int((colour.blueComponent * 255).rounded()))
    }

    func testThumbnailsUseTheChosenThemes() throws {
        var settings = PreviewSettings()
        settings.theme = "dracula"
        settings.codeFontWeight = .semibold
        XCTAssertEqual(try cornerColour("a.swift", "let x = 1\n", settings: settings), CodeTheme.named("dracula")?.light.background)

        // A pinned dark variant reaches Finder too.
        settings.theme = "github"
        settings.themeVariant = .dark
        XCTAssertEqual(try cornerColour("b.swift", "let x = 1\n", settings: settings), CodeTheme.github.dark.background)

        settings.readingTheme = "paper"
        XCTAssertEqual(try cornerColour("c.md", "# Hi\n\nText\n", settings: settings), ReadingTheme.paper.light.page)
    }

    // MARK: - Settings reach the page

    func testNewSettingsDecodeTolerantly() throws {
        let old = try JSONDecoder().decode(PreviewSettings.self, from: Data(#"{"theme":"one","readingFont":"serif"}"#.utf8))
        XCTAssertEqual(old.themeVariant, .automatic)
        XCTAssertEqual(old.codeFontWeight, .regular)
        XCTAssertEqual(old.readingTheme, "greece")
        XCTAssertEqual(old.diagramTheme, "greece")
        XCTAssertEqual(old.readingFont, .serif)

        let odd = try JSONDecoder().decode(PreviewSettings.self, from: Data(#"""
        {"theme":"no-such-theme","themeVariant":"sideways","codeFontWeight":"black","readingTheme":"nope",
         "diagramTheme":42,"readingFont":"theme"}
        """#.utf8))
        XCTAssertEqual(odd.theme, CodeTheme.default.id)
        XCTAssertEqual(odd.themeVariant, .automatic)
        XCTAssertEqual(odd.codeFontWeight, .regular)
        XCTAssertEqual(odd.readingTheme, ReadingTheme.default.id)
        XCTAssertEqual(odd.diagramTheme, DiagramTheme.default.id)
        XCTAssertEqual(odd.readingFont, .theme)

        var settings = PreviewSettings()
        settings.theme = "dracula"
        settings.themeVariant = .light
        settings.codeFontWeight = .semibold
        settings.readingTheme = "newsprint"
        settings.diagramTheme = "match-code"
        let round = try JSONDecoder().decode(PreviewSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(round, settings)
    }

    func testReadingSettingsReachThePage() {
        var settings = PreviewSettings()
        settings.readingTheme = "academic"
        settings.codeFontWeight = .medium
        settings.diagramTheme = "nord"
        let html = WebDocument(kind: .markdown, text: "# Hi\n").html(settings: settings)
        XCTAssertTrue(html.contains("greece://asset/themes/reading.css"))
        XCTAssertTrue(html.contains("rt-academic"))
        XCTAssertTrue(html.contains(" reading\""), "reading pages are marked for reading styles")
        XCTAssertTrue(html.contains("--code-weight:500"))
        XCTAssertTrue(html.contains("STIX Two Text"), "the theme's typeface")
        XCTAssertTrue(html.contains("--mm-primaryColor:"))

        // Code pages don't load reading styles.
        let code = WebDocument(kind: .code, text: "let x = 1", grammar: "swift").html(settings: settings)
        XCTAssertFalse(code.contains("themes/reading.css"))

        // The person's own font wins over the theme's.
        settings.readingFont = .mono
        XCTAssertTrue(WebDocument.variablesCSS(settings).contains("--read-font:ui-monospace"))

        // Live changes switch the previous theme's class off.
        let classes = WebDocument.classes(settings: settings, kind: .markdown)
        XCTAssertEqual(classes["rt-academic"], true)
        XCTAssertEqual(classes["rt-github"], false)
        XCTAssertTrue(WebDocument.liveUpdateScript(settings: settings, kind: .markdown).contains("rt-greece"))
    }
}
