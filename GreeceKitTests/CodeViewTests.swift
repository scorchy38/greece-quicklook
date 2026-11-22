import XCTest
import JavaScriptCore
@testable import GreeceKit

/// Formatting of minified source, and the page-side analysis behind folding, sticky scroll,
/// symbols, bracket matching and the JSON tree.
final class CodeFormatterTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/code")

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    private func lines(_ text: String) -> Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }

    // MARK: Detection

    func testMinificationDetectionIsConservative() throws {
        XCTAssertTrue(Minified.looksMinified(try fixture("berths.min.js"), separators: .braces))
        XCTAssertTrue(Minified.looksMinified(try fixture("harbour.min.css"), separators: .braces))
        XCTAssertTrue(Minified.looksMinified(try fixture("feed.min.xml"), separators: .tags))
        XCTAssertTrue(Minified.looksMinified(try fixture("arrivals.min.sql"), separators: .clauses))
        XCTAssertTrue(Minified.looksMinified(try fixture("schema.min.graphql"), separators: .braces))

        XCTAssertFalse(Minified.looksMinified(try fixture("Harbour.swift"), separators: .braces))
        XCTAssertFalse(Minified.looksMinified("a{color:red}", separators: .braces), "short one-liners read fine")
        // Readable CSS with one enormous data URI is not minified.
        var css = (0..<40).map { ".rule\($0) {\n  color: red;\n  margin: 0 auto;\n}\n" }.joined()
        css += ".logo { background: url(data:image/png;base64,\(String(repeating: "iVBORw0KGgo", count: 2000))); }\n"
        XCTAssertFalse(Minified.looksMinified(css, separators: .braces))
        // A long string literal in readable JavaScript isn't either.
        let js = "const a = 1;\nconst blob = \"\(String(repeating: "x", count: 5000))\";\nexport default a;\n"
        XCTAssertFalse(Minified.looksMinified(js, separators: .braces))
    }

    func testStylesFollowLanguage() {
        let js = LanguageCatalog.language(forExtension: "js")!
        XCTAssertEqual(CodeFormatter.style(for: js, fileExtension: "js"), .javascript(jsx: false))
        XCTAssertEqual(CodeFormatter.style(for: LanguageCatalog.language(forExtension: "html")!, fileExtension: "html"), .html)
        XCTAssertNil(CodeFormatter.style(for: LanguageCatalog.language(forExtension: "vue")!, fileExtension: "vue"), "templates are left alone")
        XCTAssertEqual(CodeFormatter.style(for: LanguageCatalog.language(forExtension: "xml")!, fileExtension: "xml"), .xml)
        XCTAssertNil(CodeFormatter.style(for: LanguageCatalog.language(forExtension: "sol")!, fileExtension: "sol"), "Solidity isn't JavaScript")
        XCTAssertNil(CodeFormatter.style(for: LanguageCatalog.language(forExtension: "swift")!, fileExtension: "swift"))
    }

    // MARK: Formatting keeps every token

    func testJavaScriptFormatting() throws {
        let source = try fixture("berths.min.js")
        let formatted = try XCTUnwrap(CodeFormatter.format(source, style: .javascript(jsx: false)))
        XCTAssertGreaterThan(lines(formatted), 60)
        XCTAssertTrue(CodeFormatter.sameNonWhitespace(source, formatted))
        XCTAssertTrue(formatted.contains("class n extends Error {"))
        XCTAssertTrue(formatted.contains("`${e} is longer than ${t} m`"), "template literals are untouched")
        XCTAssertTrue(formatted.contains("/^[A-Z]{2}-\\d{4}$/"), "regular expressions are untouched")
    }

    func testCSSFormatting() throws {
        let source = try fixture("harbour.min.css")
        let formatted = try XCTUnwrap(CodeFormatter.format(source, style: .css))
        XCTAssertGreaterThan(lines(formatted), 50)
        XCTAssertTrue(formatted.contains("@media (prefers-color-scheme:dark) {") || formatted.contains("@media (prefers-color-scheme: dark) {"))
        XCTAssertTrue(formatted.contains("content: \" · \" attr(data-flag)"), "strings keep their spaces")
    }

    func testHTMLFormatting() throws {
        let source = try fixture("notices.min.html")
        let formatted = try XCTUnwrap(CodeFormatter.format(source, style: .html))
        XCTAssertGreaterThan(lines(formatted), 25)
        XCTAssertTrue(CodeFormatter.sameNonWhitespace(source, formatted))
    }

    func testSQLFormatting() throws {
        let source = try fixture("arrivals.min.sql")
        let formatted = try XCTUnwrap(CodeFormatter.format(source, style: .sql(dialect: "postgresql")))
        XCTAssertGreaterThan(lines(formatted), 15)
        XCTAssertTrue(formatted.contains("'GR'"))
        XCTAssertTrue(formatted.hasPrefix("select"), "keyword case is preserved")
        // Not SQL at all: either refused (shown as it is) or laid out without losing a token.
        if let odd = CodeFormatter.format("select ( from ((( where", style: .sql(dialect: "sql")) {
            XCTAssertTrue(CodeFormatter.sameNonWhitespace("select ( from ((( where", odd))
        }
    }

    func testGraphQLFormatting() throws {
        let formatted = try XCTUnwrap(GraphQLFormatter.prettyPrinted("query Q($id:ID!){user(id:$id){name friends(first:2){...F}}}fragment F on User{name @include(if:true) age}"))
        XCTAssertEqual(formatted, """
        query Q($id: ID!) {
          user(id: $id) {
            name
            friends(first: 2) {
              ...F
            }
          }
        }

        fragment F on User {
          name @include(if: true)
          age
        }

        """)
        let fixture = try fixture("schema.min.graphql")
        let schema = try XCTUnwrap(CodeFormatter.format(fixture, style: .graphql))
        XCTAssertTrue(schema.contains("...VesselFields\n"))
        XCTAssertTrue(schema.contains("fragment VesselFields on Vessel {"))
        XCTAssertNil(GraphQLFormatter.prettyPrinted("query { a "), "unbalanced braces are refused")
        XCTAssertNil(GraphQLFormatter.prettyPrinted("query { a(b: \"unterminated) }"))
    }

    func testXMLFormatting() throws {
        let formatted = try XCTUnwrap(XMLFormatter.prettyPrinted(#"<?xml version="1.0"?><a x="1>2"><b>text &amp; more</b><c/><!-- note --><d><![CDATA[<raw>]]></d><p>Mixed <i>content</i> stays</p></a>"#))
        XCTAssertEqual(formatted, """
        <?xml version="1.0"?>
        <a x="1>2">
          <b>text &amp; more</b>
          <c/>
          <!-- note -->
          <d><![CDATA[<raw>]]></d>
          <p>Mixed <i>content</i> stays</p>
        </a>

        """)
        let feed = try XCTUnwrap(CodeFormatter.format(try fixture("feed.min.xml"), style: .xml))
        XCTAssertTrue(feed.contains("    <item>\n      <title>Meltemi warning"))
        XCTAssertNil(XMLFormatter.prettyPrinted("<a><b></a>"), "mismatched tags are refused")
        XCTAssertNil(XMLFormatter.prettyPrinted("<a><b>"), "unclosed tags are refused")
        XCTAssertNil(XMLFormatter.prettyPrinted("<a attr=\"x<y\">"), "a broken tag is refused")
        XCTAssertNil(XMLFormatter.prettyPrinted("<a><!-- never closed </a>"))
    }

    func testFormattersRefuseHostileInputQuickly() {
        let start = Date()
        XCTAssertNil(XMLFormatter.prettyPrinted(String(repeating: "<a>", count: 200_000)), "nesting bomb")
        XCTAssertNil(GraphQLFormatter.prettyPrinted(String(repeating: "{", count: 200_000)))
        XCTAssertNil(CodeFormatter.format(String(repeating: "a;", count: 600_000), style: .javascript(jsx: false)), "too large to format quickly")
        XCTAssertNil(CodeFormatter.format(String(repeating: "select 1,", count: 3_000), style: .sql(dialect: "sql")), "too large for sql-formatter")
        XCTAssertNil(XMLFormatter.prettyPrinted(String(repeating: "<", count: 1_000_000)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    // MARK: Through the preview pipeline

    private func prepared(_ name: String, settings: PreviewSettings = PreviewSettings()) throws -> (WebDocument, FileSummary) {
        guard case .web(let document, let summary, _) = try PreviewFactory.prepare(Self.fixtures.appendingPathComponent(name), settings: settings) else {
            throw XCTSkip("not a web preview")
        }
        return (document, summary)
    }

    func testMinifiedFilesAreFormattedAndSaySo() throws {
        for name in ["berths.min.js", "harbour.min.css", "notices.min.html", "feed.min.xml", "arrivals.min.sql", "schema.min.graphql", "berths.min.json"] {
            let (document, summary) = try prepared(name)
            XCTAssertTrue(summary.details.contains("Formatted"), name)
            XCTAssertGreaterThan(lines(document.text), 10, name)
            XCTAssertEqual(summary.details.first, "\(TextFile(text: document.text).lineCount.formatted()) lines", "\(name) counts formatted lines")
        }
        for name in ["Harbour.swift", "timetable.py", "compose.yaml", "berths.json"] {
            let (document, summary) = try prepared(name)
            XCTAssertFalse(summary.details.contains("Formatted"), name)
            XCTAssertEqual(document.text, try fixture(name), name)
        }
        var off = PreviewSettings()
        off.prettyPrint = false
        let (document, summary) = try prepared("berths.min.js", settings: off)
        XCTAssertFalse(summary.details.contains("Formatted"))
        XCTAssertEqual(document.text, try fixture("berths.min.js"))
    }

    func testPropertyListsCarryATree() throws {
        let (document, summary) = try prepared("Settings.plist")
        XCTAssertEqual(summary.details.first, "Binary")
        let data = try XCTUnwrap(document.data)
        let tree = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
        XCTAssertEqual(tree["CFBundleIdentifier"] as? String, "com.example.harbour")
        XCTAssertEqual((tree["Berths"] as? [[String: Any]])?.first?["Open"] as? Bool, true)
        XCTAssertEqual(tree["LastInspection"] as? String, "2026-11-20T09:15:00Z")
        XCTAssertEqual(tree["Seal"] as? String, "<deadbeef cafebabe 00010203 04050607…>  (24 bytes)")
        XCTAssertEqual(tree["Tugs"] as? Int, 2)
    }

    func testTruncatedJSONIsFormattedAndServesTheWholeFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceCode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("big.json")
        let item = #"{"id":1,"name":"Berth","tags":["a","b"],"depth":11.5},"#
        let body = String(repeating: item, count: (TextFile.defaultLimit / item.utf8.count) + 2000)
        try ("[" + body + "{}]").write(to: url, atomically: true, encoding: .utf8)
        guard case .web(let document, let summary, _) = try PreviewFactory.prepare(url, settings: PreviewSettings()) else { return XCTFail() }
        XCTAssertTrue(document.truncated)
        XCTAssertTrue(summary.details.contains("Formatted"))
        XCTAssertTrue(document.text.hasPrefix("[\n  {\n    \"id\": 1,"))
        let served = try XCTUnwrap(document.resources?("source"))
        XCTAssertEqual(served.data.count, try Data(contentsOf: url).count)
        XCTAssertNil(document.resources?("../etc/passwd"))
    }
}
