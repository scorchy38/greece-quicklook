import XCTest
import JavaScriptCore
import WebKit
@testable import GreeceKit

/// The preview pages' strings (GreeceKit/Resources/Web/l10n). Every key a page script passes to
/// `kit.t`, `kit.plural` or `kit.ordinal` is in en.json; every language translates every key, with
/// the same placeholders and every plural form the language needs; and a page comes up in its language.
final class PageLocalizationTests: XCTestCase {
    static let languages = LocalizationTests.languages

    // MARK: - The scripts' keys

    enum Call: String { case t, plural, ordinal }

    struct Use {
        let call: Call
        let key: String
        let place: String
    }

    /// Every page script Greece wrote: greece.js, enhancers and modules (vendored libraries aside).
    static func scripts() throws -> [URL] {
        let root = WebAssets.root
        var files = [root.appendingPathComponent("greece.js")]
        for folder in ["enhancers", "modules"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)
            files += names.filter { $0.hasSuffix(".js") }.sorted().map { root.appendingPathComponent(folder).appendingPathComponent($0) }
        }
        return files
    }

    private static var cachedUses: (uses: [Use], errors: [String])?

    static func uses() throws -> (uses: [Use], errors: [String]) {
        if let cachedUses { return cachedUses }
        var uses: [Use] = []
        var errors: [String] = []
        for url in try scripts() {
            let found = Self.uses(in: try String(contentsOf: url, encoding: .utf8), file: url.lastPathComponent)
            uses += found.uses
            errors += found.errors
        }
        cachedUses = (uses, errors)
        return (uses, errors)
    }

    /// The calls in one script. A key must be a string literal, so it can be checked here.
    static func uses(in source: String, file: String) -> (uses: [Use], errors: [String]) {
        let text = Array(source.unicodeScalars)
        var uses: [Use] = []
        var errors: [String] = []
        var line = 1
        var counted = 0
        var i = 0
        let identifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        while i < text.count {
            guard text[i] == "k", i == 0 || !identifier.contains(text[i - 1]) else { i += 1; continue }
            var matched: Call?
            for call in [Call.t, .plural, .ordinal] where matches(text, at: i, "kit.\(call.rawValue)(") {
                matched = call
            }
            guard let call = matched else { i += 1; continue }
            line += text[counted..<i].lazy.filter { $0 == "\n" }.count
            counted = i
            var j = i + "kit.\(call.rawValue)(".unicodeScalars.count
            let place = "\(file):\(line)"
            if call != .t {
                guard let comma = endOfArgument(text, from: j) else {
                    errors.append("\(place): kit.\(call.rawValue) has no key")
                    i = j
                    continue
                }
                j = comma + 1
            }
            if let (key, _) = literal(text, from: j) {
                uses.append(Use(call: call, key: key, place: place))
            } else {
                errors.append("\(place): kit.\(call.rawValue)’s key isn’t a string literal")
            }
            i = j
        }
        return (uses, errors)
    }

    private static func matches(_ text: [Unicode.Scalar], at index: Int, _ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard index + scalars.count <= text.count else { return false }
        return Array(text[index..<index + scalars.count]) == scalars
    }

    /// A JavaScript string literal at `from` (after whitespace): its value and where it ends.
    static func literal(_ text: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        var i = start
        while i < text.count, CharacterSet.whitespacesAndNewlines.contains(text[i]) { i += 1 }
        guard i < text.count, ["'", "\"", "`"].contains(text[i]) else { return nil }
        let quote = text[i]
        var value = String.UnicodeScalarView()
        i += 1
        while i < text.count {
            let c = text[i]
            if c == quote { return (String(value), i + 1) }
            if quote == "`", c == "$", i + 1 < text.count, text[i + 1] == "{" { return nil }
            if c == "\\", i + 1 < text.count {
                let next = text[i + 1]
                switch next {
                case "n": value.append("\n"); i += 2
                case "t": value.append("\t"); i += 2
                case "u", "x":
                    var digits = ""
                    var k = i + 2
                    if next == "u", k < text.count, text[k] == "{" {
                        k += 1
                        while k < text.count, text[k] != "}" { digits.unicodeScalars.append(text[k]); k += 1 }
                        k += 1
                    } else {
                        let count = next == "u" ? 4 : 2
                        while k < text.count, digits.count < count { digits.unicodeScalars.append(text[k]); k += 1 }
                    }
                    guard let code = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
                    value.append(scalar)
                    i = k
                default: value.append(next); i += 2
                }
                continue
            }
            value.append(c)
            i += 1
        }
        return nil
    }

    /// The comma that ends the argument starting at `from`, skipping nested brackets and strings.
    private static func endOfArgument(_ text: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0
        var i = start
        while i < text.count {
            let c = text[i]
            if c == "'" || c == "\"" || c == "`" {
                if let (_, end) = literal(text, from: i) { i = end; continue }
                // A template with ${…}: skip to its closing backtick.
                var k = i + 1
                while k < text.count, text[k] != c { k += text[k] == "\\" ? 2 : 1 }
                i = k + 1
                continue
            }
            switch c {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": if depth == 0 { return nil }; depth -= 1
            case ",": if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return nil
    }

    // MARK: - The tables

    /// An entry as a test sees it: its text, or its forms by CLDR category.
    enum Entry: Equatable {
        case text(String)
        case forms([String: String])

        var texts: [String] {
            switch self {
            case .text(let text): return [text]
            case .forms(let forms): return Array(forms.values)
            }
        }
    }

    static let folder = WebAssets.root.appendingPathComponent("l10n")

    static func table(_ language: String) throws -> (entries: [String: Entry], same: Set<String>) {
        let data = try Data(contentsOf: folder.appendingPathComponent("\(language).json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "\(language).json isn’t an object")
        var entries: [String: Entry] = [:]
        for (key, value) in json where !key.hasPrefix("@") {
            if let text = value as? String {
                entries[key] = .text(text)
            } else if let object = value as? [String: Any] {
                if let text = object["value"] as? String {
                    entries[key] = .text(text)
                } else {
                    let forms = object.filter { WebStrings.pluralCategories.contains($0.key) }.compactMapValues { $0 as? String }
                    XCTAssertFalse(forms.isEmpty, "\(language): “\(key)” has neither a value nor plural forms")
                    XCTAssertTrue(Set(object.keys).subtracting(WebStrings.pluralCategories).subtracting(["comment"]).isEmpty,
                                  "\(language): “\(key)” has unknown fields \(object.keys.sorted())")
                    entries[key] = .forms(forms)
                }
            } else {
                XCTFail("\(language): “\(key)” is neither text nor an object")
            }
        }
        return (entries, Set(json["@same"] as? [String] ?? []))
    }

    private static let placeholder = try! NSRegularExpression(pattern: #"\{\d+\}"#)

    /// A key without its context: "Line [shape]" is the English "Line", told apart from "Line" in a text.
    static func english(_ key: String) -> String {
        key.replacingOccurrences(of: #" \[[^\]]+\]$"#, with: "", options: .regularExpression)
    }

    static func placeholders(_ text: String) -> [String] {
        placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }.sorted()
    }

    /// The categories a language's plural (or ordinal) rules use, from WebKit's own JavaScript engine.
    static func categories(_ language: String, ordinal: Bool) -> Set<String> {
        let context = JSContext()!
        let type = ordinal ? "ordinal" : "cardinal"
        let value = context.evaluateScript("new Intl.PluralRules('\(language)', { type: '\(type)' }).resolvedOptions().pluralCategories.join(' ')")
        return Set((value?.toString() ?? "other").split(separator: " ").map(String.init))
    }

    // MARK: - English

    func testScriptsUseLiteralKeys() throws {
        let (uses, errors) = try Self.uses()
        XCTAssertGreaterThan(uses.count, 300, "the page scripts should be localized")
        for error in errors { XCTFail(error) }
    }

    func testEveryKeyIsInEnglish() throws {
        let (uses, _) = try Self.uses()
        let english = try Self.table("en").entries
        var calls: [String: Call] = [:]
        for use in uses {
            let plural = use.call != .t
            if let earlier = calls[use.key], (earlier == .t) != !plural || (plural && earlier != use.call) {
                XCTFail("\(use.place): “\(use.key)” is used as kit.\(use.call.rawValue) and kit.\(earlier.rawValue)")
            }
            calls[use.key] = use.call
            switch english[use.key] {
            case nil: XCTFail("\(use.place): “\(use.key)” isn’t in en.json")
            case .text?: if plural { XCTFail("\(use.place): “\(use.key)” is used with kit.\(use.call.rawValue) but en.json has no plural forms") }
            case .forms?: if !plural { XCTFail("\(use.place): “\(use.key)” has plural forms in en.json but is used with kit.t") }
            }
        }
        for key in Set(english.keys).subtracting(calls.keys).sorted() {
            XCTFail("en.json: “\(key)” isn’t used by any page script")
        }
    }

    func testEnglishIsComplete() throws {
        let english = try Self.table("en").entries
        let calls = Dictionary(try Self.uses().uses.map { ($0.key, $0.call) }, uniquingKeysWith: { a, _ in a })
        for (key, entry) in english {
            let expected = Self.placeholders(key)
            if case .text(let text) = entry {
                XCTAssertEqual(text, Self.english(key), "en: “\(key)” should read as its key")
            }
            for text in entry.texts {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "en: “\(key)” is empty")
                XCTAssertEqual(Self.placeholders(text), expected, "en: “\(key)” → “\(text)” takes different placeholders than its key")
            }
            if case .forms(let forms) = entry {
                let needed = Self.categories("en", ordinal: calls[key] == .ordinal)
                XCTAssertEqual(Set(forms.keys), needed, "en: “\(key)” needs exactly the forms \(needed.sorted())")
                XCTAssertEqual(forms["other"], Self.english(key), "en: a plural’s key is its “other” form")
            }
        }
    }

    // MARK: - Every language

    func testEveryLanguageHasATable() {
        XCTAssertEqual(Set(WebStrings.available), Set(["en"] + Self.languages))
        XCTAssertEqual(WebStrings.available.first, "en")
    }

    func testEveryStringIsTranslated() throws {
        let english = try Self.table("en").entries
        for language in Self.languages {
            let (entries, same) = try Self.table(language)
            for (key, source) in english.sorted(by: { $0.key < $1.key }) {
                guard let entry = entries[key] else { XCTFail("\(language): no translation for “\(key)”"); continue }
                for text in entry.texts {
                    XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language): “\(key)” is empty")
                }
                switch (source, entry) {
                case (.text, .forms): XCTFail("\(language): “\(key)” must be text, as in en.json")
                case (.forms, .text): XCTFail("\(language): “\(key)” must have plural forms, as in en.json")
                default: break
                }
                if Set(entry.texts) == Set(source.texts) || entry.texts == [Self.english(key)] {
                    XCTAssertTrue(same.contains(key), "\(language): “\(key)” is still English (list it under \"@same\" if that’s right)")
                }
            }
            for key in Set(entries.keys).subtracting(english.keys).sorted() {
                XCTFail("\(language): “\(key)” isn’t in en.json any more")
            }
            for key in same.sorted() {
                XCTAssertNotNil(english[key], "\(language): \"@same\" lists “\(key)”, which isn’t in en.json")
                if let entry = entries[key], let source = english[key] {
                    XCTAssertEqual(Set(entry.texts), Set(source.texts), "\(language): \"@same\" lists “\(key)”, but it’s translated")
                }
            }
        }
    }

    func testTranslationsTakeTheSamePlaceholders() throws {
        let english = try Self.table("en").entries
        for language in Self.languages {
            let entries = try Self.table(language).entries
            for (key, entry) in entries.sorted(by: { $0.key < $1.key }) where english[key] != nil {
                let expected = Self.placeholders(key)
                for text in entry.texts {
                    XCTAssertEqual(Self.placeholders(text), expected, "\(language): “\(key)” → “\(text)” takes different placeholders")
                }
            }
        }
    }

    func testPluralsHaveEveryFormTheLanguageNeeds() throws {
        let calls = Dictionary(try Self.uses().uses.map { ($0.key, $0.call) }, uniquingKeysWith: { a, _ in a })
        for language in Self.languages {
            let entries = try Self.table(language).entries
            let cardinal = Self.categories(language, ordinal: false)
            let ordinal = Self.categories(language, ordinal: true)
            for (key, entry) in entries.sorted(by: { $0.key < $1.key }) {
                guard case .forms(let forms) = entry else { continue }
                let needed = calls[key] == .ordinal ? ordinal : cardinal
                let have = Set(forms.keys)
                for missing in needed.subtracting(have).sorted() {
                    XCTFail("\(language): “\(key)” has no “\(missing)” form (\(language) uses \(needed.sorted().joined(separator: ", ")))")
                }
                for extra in have.subtracting(needed).sorted() {
                    XCTFail("\(language): “\(key)” has a “\(extra)” form \(language) never uses")
                }
            }
        }
    }

    // MARK: - The checker itself

    func testKeysAreReadLikeJavaScript() {
        let source = #"""
        kit.t('Find {0}', kit.quoted(x)); kit.plural(Math.max(a, b), "{0} files");
        Smart.kit.t(`Show All`); kit.ordinal(n, 'On the {0}th'); kit.t('It’s \'here\'');
        kit.t(label); kit.t(`Line ${n}`); notkit.t('no'); kit.plural(f(x, [1, 2]), '{0} rows', y);
        """#
        let (uses, errors) = Self.uses(in: source, file: "x.js")
        XCTAssertEqual(uses.map(\.key), ["Find {0}", "{0} files", "Show All", "On the {0}th", "It’s 'here'", "{0} rows"])
        XCTAssertEqual(uses.map(\.call), [.t, .plural, .t, .ordinal, .t, .plural])
        XCTAssertEqual(errors.count, 2, errors.joined(separator: "\n"))
    }
}

// MARK: - Pages

/// A page in another language: its `lang`, its strings, plurals and numbers.
@MainActor
final class LocalizedPageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizedPage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        WebStrings.languageOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func page(_ name: String, _ contents: String, language: String) async throws -> (PreviewView, WKWebView) {
        WebStrings.languageOverride = language
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await PreviewFactory.makePreview(for: url, settings: PreviewSettings())
        await preview.waitUntilReady()
        return (preview, try XCTUnwrap(preview.webView as? WKWebView))
    }

    private func translation(_ key: String, _ language: String) throws -> String {
        guard case .text(let text)? = try PageLocalizationTests.table(language).entries[key] else {
            throw XCTSkip("no “\(key)” in \(language).json")
        }
        return text
    }

    func testAGermanMarkdownPage() async throws {
        let (preview, web) = try await page("Notes.md", "# Hafen\n\nDas **ägäische** Licht.\n", language: "de")
        defer { withExtendedLifetime(preview) {} }
        let state = try await web.callAsyncJavaScript("""
            greeceFind.open('Licht');
            const bar = document.querySelector('.doc-findbar');
            return { lang: document.documentElement.lang, placeholder: bar.querySelector('input').placeholder,
                     done: bar.querySelector('.find-done').textContent.trim(), typing: greece.kit.typing };
            """, contentWorld: .page) as? [String: Any] ?? [:]
        XCTAssertEqual(state["lang"] as? String, "de")
        let key = state["typing"] as? Bool == false ? "Select text to find it" : "Find"
        let german = try translation(key, "de")
        XCTAssertNotEqual(german, key)
        XCTAssertEqual(state["placeholder"] as? String, german)
        XCTAssertEqual(state["done"] as? String, try translation("Done", "de"))
    }

    func testAGermanCodePage() async throws {
        let (preview, web) = try await page("hafen.swift", "let harbour = \"Piraeus\"\nprint(harbour)\n", language: "de")
        defer { withExtendedLifetime(preview) {} }
        let lang = try await web.callAsyncJavaScript("return document.documentElement.lang", contentWorld: .page) as? String
        XCTAssertEqual(lang, "de")
        let copy = try await web.callAsyncJavaScript("return document.querySelector('#copy-all').textContent", contentWorld: .page) as? String
        XCTAssertEqual(copy, try translation("Copy", "de"))
    }

    func testRussianPluralsAndNumbers() async throws {
        let (preview, web) = try await page("notes.md", "# Заметки\n", language: "ru")
        defer { withExtendedLifetime(preview) {} }
        let result = try await web.callAsyncJavaScript("""
            const kit = greece.kit;
            return { forms: [1, 2, 5, 21, 1.5].map((n) => kit.plural(n, '{0} commits')),
                     number: kit.number(1234.5), lang: kit.lang, missing: kit.t('No such string {0}', 3) };
            """, contentWorld: .page) as? [String: Any] ?? [:]
        let forms = try XCTUnwrap(result["forms"] as? [String])
        XCTAssertEqual(result["lang"] as? String, "ru")
        // one (1, 21), few (2), many (5) and other (1.5) are four different words in Russian.
        XCTAssertEqual(Set([forms[0], forms[1], forms[2], forms[4]]).count, 4, forms.joined(separator: " | "))
        XCTAssertEqual(forms[0].dropFirst(2), forms[3].dropFirst(3), "21 takes the same form as 1")
        XCTAssertEqual((result["number"] as? String)?.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{A0}", with: " "), "1 234,5")
        XCTAssertEqual(result["missing"] as? String, "No such string 3", "an unknown key shows as itself")
    }

    func testTheStringsAreInert() throws {
        WebStrings.languageOverride = "ja"
        var document = WebDocument(kind: .markdown, text: "# Title\n")
        document.fileName = "a.md"
        let html = document.html(settings: PreviewSettings())
        XCTAssertTrue(html.contains("<html lang=\"ja\""))
        XCTAssertTrue(html.contains("<script id=\"strings\" type=\"application/json\">"))
        XCTAssertTrue(html.contains("script-src greece://asset;"), "the page's CSP is unchanged")
        for language in WebStrings.available {
            XCTAssertFalse(WebStrings.json(for: language).contains("<"), language)
        }
    }

    func testLanguageMatching() {
        for (forced, expected) in [("de-CH", "de"), ("zh-TW", "zh-Hant"), ("zh-CN", "zh-Hans"), ("pt-PT", "pt-BR"), ("fr", "fr"), ("ar", "en")] {
            WebStrings.languageOverride = forced
            XCTAssertEqual(WebStrings.language, expected, forced)
        }
        XCTAssertEqual(WebStrings.formattingLocale(for: "en", region: "IN"), "en-IN")
        XCTAssertEqual(WebStrings.formattingLocale(for: "pt-BR", region: "PT"), "pt-PT")
        XCTAssertEqual(WebStrings.formattingLocale(for: "zh-Hant", region: "HK"), "zh-Hant-HK")
        XCTAssertEqual(WebStrings.formattingLocale(for: "de", region: nil), "de")
    }
}
