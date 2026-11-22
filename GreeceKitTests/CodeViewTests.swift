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

    func testJSONWithCommentsIsNotReformatted() {
        let jsonc = "// settings\n{\"a\":1,\"b\":[1,2,3],\"c\":\"x\"}"
        XCTAssertNil(JSONFormatter.prettyPrinted(jsonc), "removing the line break would swallow the object into the comment")
        XCTAssertNotNil(JSONFormatter.prettyPrinted(#"{"url":"https://example.com/a//b"}"#), "slashes inside strings are fine")
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

/// The code view's structure analysis (enhancers/code-analysis.js), run in JavaScriptCore exactly
/// as the page and its workers run it.
final class CodeAnalysisTests: XCTestCase {
    private static let context: JSContext = {
        let context = JSContext()!
        let url = WebAssets.url("enhancers/code-analysis.js")!
        context.evaluateScript(try! String(contentsOf: url, encoding: .utf8))
        context.evaluateScript("""
        function summary(text, lang) {
          const r = GreeceCodeAnalysis.analyze(text, lang, 4);
          const g = r.regions;
          return JSON.stringify({
            family: r.family,
            regions: Array.from(g.start).map((s, k) => [s + 1, g.end[k] + 1, g.hide[k] + 1, g.tail[k]]),
            symbols: r.symbols.map((s) => [s.kind, s.name, String(s.line + 1), String(s.depth)]),
            brackets: Array.from(r.brackets.pos).map((p, k) => [text[p], r.brackets.match[k] >= 0 ? text[r.brackets.match[k]] : null]),
          });
        }
        """)
        return context
    }()

    private struct Summary: Decodable {
        var family: String
        var regions: [[Int]]
        var symbols: [[String]]
        var brackets: [[String?]]
        var symbolNames: [String] { symbols.map { $0[1] } }
        func symbol(_ name: String) -> (kind: String, line: Int, depth: Int)? {
            guard let s = symbols.first(where: { $0[1] == name }) else { return nil }
            return (s[0], Int(s[2]) ?? -1, Int(s[3]) ?? -1)
        }
    }

    private func analyze(_ text: String, _ lang: String) throws -> Summary {
        let fn = Self.context.objectForKeyedSubscript("summary")!
        let json = try XCTUnwrap(fn.call(withArguments: [text, lang])?.toString())
        return try JSONDecoder().decode(Summary.self, from: Data(json.utf8))
    }

    private func evaluate(_ script: String) -> String {
        Self.context.evaluateScript(script)?.toString() ?? ""
    }

    private func fixture(_ name: String) throws -> String {
        var text = try String(contentsOf: CodeFormatterTests.fixtures.appendingPathComponent(name), encoding: .utf8)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    // MARK: Regions

    func testBraceRegionsFoldClosingLinesIntoTheHeader() throws {
        let code = """
        struct A {
            func b() {
                if x {
                    y()
                } else {
                    z()
                }
            }
        }
        """
        let s = try analyze(code, "swift")
        XCTAssertEqual(s.family, "brace")
        // [header, scope end, last hidden line, closing line shown after the pill]
        XCTAssertEqual(s.regions, [[1, 9, 9, 1], [2, 8, 8, 1], [3, 5, 4, 0], [5, 7, 7, 1]],
                       "`} else {` stays visible; lines of only closing brackets fold away")
    }

    func testAllmanBlocksAreNamedByTheLineAbove() throws {
        let s = try analyze("int main(void)\n{\n    return 0;\n}", "c")
        XCTAssertEqual(s.regions.first, [1, 4, 4, 1])
        XCTAssertEqual(s.symbol("main")?.kind, "func")
    }

    func testIndentationRegionsIgnoreDocstrings() throws {
        let code = """
        class A:
            def f(self):
                \"\"\"Docs
        that are not indented
                \"\"\"
                return 1

        def g():
            pass
        """
        let s = try analyze(code, "python")
        XCTAssertEqual(s.family, "indent")
        XCTAssertEqual(s.regions.map { Array($0.prefix(2)) }, [[1, 6], [2, 6], [8, 9]])
        XCTAssertEqual(s.symbol("f")?.kind, "method")
        XCTAssertEqual(s.symbol("f")?.depth, 1)
        XCTAssertEqual(s.symbol("g")?.kind, "func")
    }

    func testIndentedBlocksTakeTheirClosingLine() throws {
        XCTAssertEqual(try analyze("def a\n  b\nend", "ruby").regions, [[1, 3, 3, 1]])
        XCTAssertEqual(try analyze("<a>\n  <b/>\n</a>", "xml").regions, [[1, 3, 3, 1]])
    }

    // MARK: Lexing

    func testBracketsSkipStringsCommentsAndRegularExpressions() throws {
        let code = "const a = \"{\"; // }\nconst r = /[}(]/g, t = `x ${ {k: 1}.k } y`;\nf(1, [2]);"
        let s = try analyze(code, "javascript")
        XCTAssertEqual(s.brackets.map { $0[0] ?? "" }, ["{", "}", "(", "[", "]", ")"])
        XCTAssertTrue(s.brackets.allSatisfy { $0[1] != nil }, "every bracket found its partner")
    }

    func testRustLifetimesAreNotCharacters() throws {
        let s = try analyze("fn f<'a>(x: &'a str) -> &'a str {\n    x\n}", "rust")
        XCTAssertEqual(s.regions, [[1, 3, 3, 1]])
        XCTAssertEqual(s.symbol("f")?.kind, "func")
    }

    func testSwiftInterpolationDoesNotEndStrings() throws {
        let s = try analyze("let a = \"\\(b(\"}\"))\"\nfunc c() {\n}", "swift")
        // Only `func c() {}` counts: nothing inside the interpolation, including the "}" literal.
        XCTAssertEqual(s.brackets.map { $0[0] ?? "" }, ["(", ")", "{", "}"])
        XCTAssertTrue(s.brackets.allSatisfy { $0[1] != nil })
    }

    // MARK: Symbols

    func testSymbolsAcrossLanguages() throws {
        let swift = try analyze(try fixture("Harbour.swift"), "swift")
        XCTAssertEqual(swift.symbol("HarbourMaster")?.kind, "class")
        XCTAssertEqual(swift.symbol("assign")?.kind, "method")
        XCTAssertEqual(swift.symbol("assign")?.depth, 1)
        XCTAssertEqual(swift.symbol("Model")?.kind, "mark")
        XCTAssertEqual(swift.symbol("maximumLength")?.kind, "property")

        let python = try analyze(try fixture("timetable.py"), "python")
        XCTAssertEqual(python.symbol("Timetable")?.kind, "class")
        XCTAssertEqual(python.symbol("connections")?.kind, "method")
        XCTAssertEqual(python.symbol("main")?.kind, "func")

        let js = try analyze("export class A {\n  run(x) {\n    if (x) {\n      return 1;\n    }\n  }\n}\nconst f = async (a) => {\n  return a;\n};\nfunction g() {\n}", "javascript")
        XCTAssertEqual(js.symbolNames, ["A", "run", "f", "g"], "`if` is not a method")

        let go = try analyze("type Port struct {\n\tName string\n}\n\nfunc (p *Port) Open() error {\n\treturn nil\n}", "go")
        XCTAssertEqual(go.symbol("Port")?.kind, "struct")
        XCTAssertEqual(go.symbol("Open")?.kind, "func")

        let sql = try analyze("CREATE TABLE IF NOT EXISTS berths (\n  id integer\n);\ncreate view free as select 1;", "sql")
        XCTAssertEqual(sql.symbolNames, ["berths", "free"])

        let css = try analyze("@media (max-width: 600px) {\n  .a {\n    color: red;\n  }\n}\n@keyframes k {\n  0% {\n    top: 0;\n  }\n}", "css")
        XCTAssertEqual(css.symbolNames, ["@media (max-width: 600px)", ".a", "@keyframes k"], "keyframe steps are not listed")

        let yaml = try analyze(try fixture("compose.yaml"), "yaml")
        XCTAssertEqual(Array(yaml.symbolNames.prefix(4)), ["services", "api", "db", "tiles"])
    }

    // MARK: Indentation

    func testIndentStepAndGuides() {
        let result = evaluate("""
        (function () {
          const A = GreeceCodeAnalysis;
          const two = 'a:\\n  b:\\n    c: 1\\n\\n  d: 2';
          const m = A.measureIndent(two, A.lineStarts(two), 4);
          const g = A.guideCounts(m.indent, m.unit);
          const tabs = 'f() {\\n\\tif (x) {\\n\\t\\ty();\\n\\t}\\n}';
          const t = A.measureIndent(tabs, A.lineStarts(tabs), 4);
          return JSON.stringify({ unit: m.unit, guides: Array.from(g), tabs: t.tabs, tabUnit: t.unit });
        })()
        """)
        XCTAssertEqual(result, #"{"unit":2,"guides":[0,1,2,1,1],"tabs":true,"tabUnit":4}"#,
                       "the blank line between `c` and `d` carries the shallower depth")
    }

    // MARK: JSON index

    func testJSONIndexPathsAndTolerance() {
        let result = evaluate("""
        (function () {
          const A = GreeceCodeAnalysis;
          const text = '// settings\\n{a: 1, "b c": [true, null, {"d": "x\\\\"y"}], \\'e\\': -1.5e3,}';
          const at = A.indexJSON(text);
          const root = A.childrenOf(0, at)[0];
          const kids = A.childrenOf(root, at);
          const arr = A.childrenOf(kids[1], at);
          const d = A.childrenOf(arr[2], at)[0];
          const lines = '{"a":1}\\n{"a":2}';
          const nd = A.indexJSON(lines);
          return JSON.stringify({
            error: at.error, keys: kids.map((k) => A.keyText(text, at, k)),
            path: A.pathOf(text, at, d), value: A.stringValue(text, at.start[d], at.end[d]),
            types: arr.map((n) => at.type[n]),
            lines: A.childrenOf(0, nd).length, linePath: A.pathOf(lines, nd, A.childrenOf(A.childrenOf(0, nd)[1], nd)[0]),
          });
        })()
        """)
        XCTAssertEqual(result, #"{"error":null,"keys":["a","b c","e"],"path":"$[\"b c\"][2].d","value":"x\"y","types":[5,7,1],"lines":2,"linePath":"$[1].a"}"#)
    }

    func testBrokenJSONSaysWhere() {
        let result = evaluate(#"JSON.stringify(GreeceCodeAnalysis.indexJSON('{"a": [1, 2}').error)"#)
        XCTAssertTrue(result.contains("offset"), result)
    }

    // MARK: Hostile input

    func testHostileInputFinishesQuickly() {
        let start = Date()
        let result = evaluate("""
        (function () {
          const A = GreeceCodeAnalysis;
          const out = [];
          out.push(A.analyze('('.repeat(200000), 'javascript', 4).regions.start.length);
          out.push(A.analyze('"'.repeat(500000), 'python', 4).lineCount);
          out.push(A.analyze('{\\n'.repeat(100000) + '}\\n'.repeat(100000), 'json', 4).regions.start.length);
          out.push(A.analyze('a'.repeat(4000000), 'swift', 4).lineCount);
          out.push(A.analyze('/* never closed\\n'.repeat(50000), 'c', 4).lineCount);
          out.push(A.indexJSON('['.repeat(1000000)).count);
          out.push(A.indexJSON('"' + 'x'.repeat(1000000)).count);
          out.push(A.indexJSON('[1,'.repeat(300000) + ']', { maxNodes: 1000 }).truncated);
          return JSON.stringify(out);
        })()
        """)
        XCTAssertEqual(result, "[0,1,100000,1,50001,1000001,2,true]")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: Scripts

    func testEveryCodeEnhancerCompiles() throws {
        let folder = WebAssets.root.appendingPathComponent("enhancers")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("code-") && $0.hasSuffix(".js") }
        XCTAssertGreaterThanOrEqual(files.count, 10)
        for file in files {
            let context = JSContext()!
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            context.setObject(source, forKeyedSubscript: "source" as NSString)
            let ok = context.evaluateScript("(function () { try { new Function(source); return 'ok'; } catch (e) { return String(e); } })()")?.toString()
            XCTAssertEqual(ok, "ok", file)
        }
    }
}
