import XCTest
import JavaScriptCore
import WebKit
@testable import GreeceKit

/// Smart files: which files get which card, the parsers behind the cards (run in JavaScriptCore,
/// the same code the page runs), .env secrets kept out of the page and out of thumbnails, and
/// hostile or huge input.
final class SmartFilesTests: XCTestCase {
    private var directory: URL!
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/smart")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceSmart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - JavaScriptCore

    private static var shared: JSContext?

    /// js-yaml plus every code-smart enhancer, loaded the way the page loads them (no DOM).
    private func smart() throws -> JSContext {
        if let context = Self.shared { return context }
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail("JS exception: \(exception?.toString() ?? "?")") }
        let yaml = try XCTUnwrap(WebAssets.url("vendor/js-yaml/js-yaml.min.js"))
        context.evaluateScript(try String(contentsOf: yaml, encoding: .utf8))
        let enhancers = WebAssets.enhancers(for: "code", ext: "js").filter { $0.hasPrefix("enhancers/code-smart") }
        XCTAssertGreaterThanOrEqual(enhancers.count, 6)
        for path in enhancers {
            context.evaluateScript(try String(contentsOf: try XCTUnwrap(WebAssets.url(path)), encoding: .utf8), withSourceURL: URL(string: path))
        }
        Self.shared = context
        return context
    }

    /// Runs `body` with `input` (and `name`, `language`) bound, returning the result.
    @discardableResult
    private func js(_ body: String, input: String = "", name: String = "", language: String = "") throws -> JSValue {
        let context = try smart()
        context.setObject(input, forKeyedSubscript: "input" as NSString)
        context.setObject(name, forKeyedSubscript: "fileName" as NSString)
        context.setObject(language, forKeyedSubscript: "language" as NSString)
        return try XCTUnwrap(context.evaluateScript("(function () { \(body) })()"))
    }

    /// The card a file gets, routed exactly as Quick Look routes it: FileKind first, then the page.
    private func card(_ name: String, _ contents: String) throws -> String? {
        let url = try file(name, contents)
        let grammar: String
        switch FileKind.detect(url) {
        case .code(let language): grammar = language.grammar
        case .json: grammar = "json"
        default: return "not a code page"
        }
        let id = try js("const k = GreeceSmart.detect(GreeceSmart.file(fileName, input, language)); return k ? k.id : null;",
                        input: contents, name: name, language: grammar)
        return id.isNull ? nil : id.toString()
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - Detection

    func testEveryFixtureGetsItsCard() throws {
        let expected: [String: String] = [
            ".env": "env", "package.json": "manifest", "Cargo.toml": "manifest", "pyproject.toml": "manifest",
            "go.mod": "manifest", "Gemfile": "manifest", "Podfile": "manifest", "Package.swift": "manifest",
            "composer.json": "manifest", "pubspec.yaml": "manifest", "mix.exs": "manifest", "build.gradle.kts": "manifest",
            "server.log": "log", "events.jsonl": "log", "Dockerfile": "docker", "docker-compose.yml": "compose",
            "ci.yml": "workflow", "deployment.yaml": "kubernetes", "openapi.yaml": "openapi", "swagger.json": "openapi",
            "crontab": "cron", "Makefile": "make", "config": "ssh",
        ]
        for (name, id) in expected {
            XCTAssertEqual(try card(name, try fixture(name)), id, name)
        }
    }

    func testNameVariantsAndSniffing() throws {
        XCTAssertEqual(try card(".env.production", "A=1\n"), "env")
        XCTAssertEqual(try card("staging.env", "A=1\n"), "env")
        XCTAssertEqual(try card(".envrc", "export A=1\nexport B=2\n"), "env")
        XCTAssertNil(try card(".envrc", "use flake\nlayout python\n"))
        XCTAssertEqual(try card("compose.yaml", "services:\n  web:\n    image: nginx\n"), "compose")
        XCTAssertEqual(try card("docker-compose.override.yml", "services:\n  web:\n    ports: ['80:80']\n"), "compose")
        XCTAssertEqual(try card("Containerfile", "FROM alpine\n"), "docker")
        XCTAssertEqual(try card("Dockerfile.dev", "FROM alpine\n"), "docker")
        XCTAssertEqual(try card("GNUmakefile", "all:\n\techo\n"), "make")
        XCTAssertEqual(try card("justfile", "# Build it\nbuild:\n    cargo build\n"), "make")
        XCTAssertEqual(try card("build.gradle", "dependencies {\n  implementation 'a:b:1'\n}\n"), "manifest")
        XCTAssertEqual(try card("Package@swift-5.9.swift", "let package = Package(name: \"X\")\n"), "manifest")
        XCTAssertEqual(try card("app.log.1", "2024-01-01 10:00:00 INFO hi\n"), "log")
        XCTAssertEqual(try card("release.yml", "on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo\n"), "workflow")
        XCTAssertEqual(try card("api.json", "{\n  \"openapi\": \"3.0.0\",\n  \"info\": {},\n  \"paths\": {}\n}\n"), "openapi")
        // Text that reads like a log, whatever its name.
        let log = (0..<20).map { "2024-03-0\($0 % 9 + 1)T10:00:\(10 + $0)Z \($0 % 4 == 0 ? "ERROR" : "INFO") step \($0)" }.joined(separator: "\n")
        XCTAssertEqual(try card("output", log), "log")
    }

    func testOrdinaryFilesGetNoCard() throws {
        XCTAssertNil(try card("notes.txt", "Shopping list\n\nMilk, eggs and bread.\nCall the bank about the error on the statement.\n"))
        XCTAssertNil(try card("LICENSE", "MIT License\n\nCopyright (c) 2024\n"))
        XCTAssertNil(try card("settings.yml", "theme: dark\nfont: 13\nservices:\n  - search\n"))
        XCTAssertNil(try card("data.json", "{\"a\": 1, \"paths\": []}"))
        XCTAssertNil(try card("config", "[core]\n\trepositoryformatversion = 0\n\tbare = false\n"))
        XCTAssertNil(try card("main.swift", "print(\"hello\")\n"))
        XCTAssertNil(try card("values.yaml", "replicaCount: 1\nimage:\n  repository: nginx\n"))
    }

    // MARK: - .env

    private let secretEnv = """
    # Database
    export DATABASE_URL="postgres://user:hunter2pass@db/prod"
    API_KEY=sk_live_abcdef123456 # rotated
    EMPTY=
    QUOTED=''
    # OLD_KEY=old-secret-value
    MULTI="-----BEGIN KEY-----
    c2VjcmV0LWxpbmUtdHdv
    -----END KEY-----"
    API_KEY=second-secret-value
    stray-token-without-key
    ESCAPED="ends with \\" still-open
    closing-line-secret"
    PORT = 8080
    """
    private let secrets = ["hunter2pass", "sk_live_abcdef123456", "old-secret-value", "c2VjcmV0LWxpbmUtdHdv", "second-secret-value",
                           "stray-token-without-key", "still-open", "closing-line-secret", "8080", "BEGIN KEY"]

    func testEnvParsingFlagsDuplicatesAndEmpties() throws {
        let result = try js("""
            const p = GreeceSmart.kind('env').parse(input);
            return { keys: p.keyCount, duplicates: p.duplicates.map((e) => e.key + ':' + e.line + '<' + e.duplicateOf),
                     empties: p.empties.map((e) => e.key), types: p.lines.map((l) => l.type).join(',') };
            """, input: secretEnv).toDictionary() ?? [:]
        XCTAssertEqual(result["keys"] as? Int, 7)
        XCTAssertEqual(result["duplicates"] as? [String], ["API_KEY:10<3"])
        XCTAssertEqual(result["empties"] as? [String], ["EMPTY", "QUOTED"])
        XCTAssertEqual(result["types"] as? String,
                       "comment,entry,entry,entry,entry,commented,entry,continuation,continuation,entry,other,entry,continuation,entry")
    }

    func testEnvMaskingHidesEverySecretAndMatchesThumbnails() throws {
        let page = try js("return GreeceSmart.kind('env').masked(input);", input: secretEnv).toString() ?? ""
        let thumbnail = EnvMask.masked(secretEnv)
        XCTAssertEqual(page, thumbnail, "page and thumbnail must hide the same things")
        for secret in secrets { XCTAssertFalse(thumbnail.contains(secret), secret) }
        XCTAssertTrue(thumbnail.contains("# Database"))
        XCTAssertTrue(thumbnail.contains("export DATABASE_URL=••••••••"))
        XCTAssertTrue(thumbnail.contains("API_KEY=•••••••• # rotated"))
        XCTAssertTrue(thumbnail.contains("# OLD_KEY=••••••••"))
        XCTAssertTrue(thumbnail.contains("EMPTY="))

        // Odd inputs: CRLF, tabs, unicode, lone quotes, a file that's only junk.
        for text in ["A=1\r\nB=\"x\r\ny\"\r\n", "\tA = 'v' # c", "KEY=pässwörd🙂", "A=\"", "A='open\n\nstill", "just junk\nmore junk", ""] {
            let fromPage = try js("return GreeceSmart.kind('env').masked(input);", input: text).toString() ?? ""
            XCTAssertEqual(fromPage, EnvMask.masked(text), text.debugDescription)
        }
    }

    func testEnvNamesMatchBetweenPageAndThumbnails() throws {
        for name in [".env", ".env.local", ".env.production", "prod.env", ".flaskenv", ".dev.vars", "env.example"] {
            XCTAssertTrue(EnvMask.applies(to: name), name)
            XCTAssertTrue(try js("return GreeceSmart.kind('env').detect(GreeceSmart.file(fileName, '', ''));", name: name).toBool(), name)
        }
        for name in ["environment.ts", "env.ts", "envelope.txt", "README.env.md", ".envrc"] {
            XCTAssertFalse(EnvMask.applies(to: name), name)
        }
    }

    /// The thumbnail of a .env file is pixel for pixel the thumbnail of its masked text.
    func testThumbnailDrawsOnlyMaskedValues() throws {
        let settings = PreviewSettings()
        let size = CGSize(width: 256, height: 256)
        let env = try XCTUnwrap(Thumbnailer.page(for: try file(".env", secretEnv), maximumSize: size, settings: settings))
        XCTAssertEqual(env.badge, "ENV")
        let maskedDir = directory.appendingPathComponent("masked")
        try FileManager.default.createDirectory(at: maskedDir, withIntermediateDirectories: true)
        let maskedURL = maskedDir.appendingPathComponent(".env")
        try EnvMask.masked(secretEnv).write(to: maskedURL, atomically: true, encoding: .utf8)
        let masked = try XCTUnwrap(Thumbnailer.page(for: maskedURL, maximumSize: size, settings: settings))
        let plain = try XCTUnwrap(Thumbnailer.page(for: try file("secrets.sh", secretEnv), maximumSize: size, settings: settings))
        XCTAssertEqual(pixels(env), pixels(masked))
        XCTAssertNotEqual(pixels(env), pixels(plain))
    }

    private func pixels(_ page: ThumbnailPage) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(page.size.width), pixelsHigh: Int(page.size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        page.draw()
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    // MARK: - The page itself

    @MainActor
    private func page(_ url: URL) async throws -> WKWebView {
        let preview = try await PreviewFactory.makePreview(for: url, settings: PreviewSettings())
        await preview.waitUntilReady()
        return try XCTUnwrap(preview.webView as? WKWebView)
    }

    @MainActor
    private func evaluate(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, contentWorld: .page)
    }

    @MainActor
    func testEnvSecretsStayOutOfThePageUntilRevealed() async throws {
        let web = try await page(try file(".env", secretEnv))
        let everything = "return document.documentElement.outerHTML + JSON.stringify(window.greece.kit.payload)"
        let before = try await evaluate(web, everything) as? String ?? ""
        XCTAssertTrue(before.contains("env-secret"), "the page should have rendered masked values")
        for secret in secrets { XCTAssertFalse(before.contains(secret), "\(secret) is in the page before reveal") }

        let one = try await evaluate(web, "document.querySelector('.env-secret').click(); return document.querySelector('.env-secret').textContent") as? String
        XCTAssertEqual(one, "\"postgres://user:hunter2pass@db/prod\"")
        _ = try await evaluate(web, "document.querySelector('.env-toggle').click(); return 0")
        let after = try await evaluate(web, "return document.querySelector('.code-view').textContent") as? String ?? ""
        for secret in ["sk_live_abcdef123456", "c2VjcmV0LWxpbmUtdHdv", "second-secret-value", "stray-token-without-key"] {
            XCTAssertTrue(after.contains(secret), "\(secret) should show after Reveal All")
        }
        _ = try await evaluate(web, "document.querySelector('.env-toggle').click(); return 0")
        let hidden = try await evaluate(web, "return document.querySelector('.code-view').textContent") as? String ?? ""
        XCTAssertFalse(hidden.contains("hunter2pass"))
    }

    @MainActor
    func testHostileManifestIsShownAsText() async throws {
        let hostile = """
        {"name": "<img src=x onerror=alert(1)>", "version": "\\"><script>alert(2)</script>",
         "description": "<b>bold</b>", "homepage": "javascript:alert(3)",
         "scripts": {"<svg onload=alert(4)>": "rm -rf / <script>"},
         "dependencies": {"__proto__": "1", "constructor": "2", "<i>x</i>": "^1"}}
        """
        let web = try await page(try file("package.json", hostile))
        let result = try await evaluate(web, """
            const card = document.querySelector('.smart-card');
            return { card: !!card, active: card.querySelectorAll('img, script, svg[onload], b, i, a[href^="javascript"]').length,
                     handlers: Array.from(card.querySelectorAll('*')).some((n) => Array.from(n.attributes).some((a) => a.name.startsWith('on'))),
                     text: card.textContent }
            """) as? [String: Any] ?? [:]
        XCTAssertEqual(result["card"] as? Bool, true)
        XCTAssertEqual(result["active"] as? Int, 0)
        XCTAssertEqual(result["handlers"] as? Bool, false)
        XCTAssertTrue((result["text"] as? String ?? "").contains("<img src=x onerror=alert(1)>"))
    }

    @MainActor
    func testLogPageFiltersAndSteps() async throws {
        let web = try await page(fixtures.appendingPathComponent("server.log"))
        let result = try await evaluate(web, """
            const chips = Array.from(document.querySelectorAll('.log-chip')).map((c) => c.textContent);
            const rows = document.querySelectorAll('.log-view .ln').length;
            const repeat = document.querySelector('.lg-rep') && document.querySelector('.lg-rep').textContent;
            document.querySelector('.log-chip[data-level="3"]').click();
            const hiddenInfo = getComputedStyle(document.querySelector('.log-view .lg-i')).display;
            document.querySelector('.log-step.next').click();
            const focused = document.querySelector('.lg-focus');
            return { chips, rows, repeat, hiddenInfo, focused: focused && focused.dataset.n, payload: document.getElementById('payload') !== null };
            """) as? [String: Any] ?? [:]
        XCTAssertEqual(result["chips"] as? [String], ["Errors8", "Warnings3", "Info16", "Debug2", "Trace1"])
        XCTAssertEqual(result["rows"] as? Int, 23, "eight heartbeats fold into one row")
        XCTAssertEqual(result["repeat"] as? String, "×8")
        XCTAssertEqual(result["hiddenInfo"] as? String, "none")
        XCTAssertEqual(result["focused"] as? String, "8")
    }

    @MainActor
    func testEveryCardRendersWithoutErrors() async throws {
        for name in ["package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Gemfile", "Podfile", "Package.swift", "composer.json",
                     "pubspec.yaml", "mix.exs", "build.gradle.kts", "Dockerfile", "docker-compose.yml", "ci.yml", "deployment.yaml",
                     "openapi.yaml", "swagger.json", "crontab", "Makefile", "config", "events.jsonl"] {
            let web = try await page(fixtures.appendingPathComponent(name))
            let count = try await evaluate(web, "return document.querySelectorAll('.smart-card').length") as? Int
            XCTAssertEqual(count, 1, name)
        }
    }

    // MARK: - Parsers

    func testTOMLReadsTheCommonSubset() throws {
        let toml = """
        title = "TOML \\"x\\" \\u00e9"
        [owner]
        name = 'Tom'
        dob = 1979-05-27T07:32:00-08:00
        [database]
        ports = [ 8000, 8001,
          8002, ] # trailing comma
        data = [ ["gamma", "delta"], [1, 2] ]
        enabled = true
        temp = { cpu = 79.5, case = 72.0 }
        "quoted key".dotted.inner = 0x1F
        big = 1_000
        multi = \"\"\"
        one
        two\"\"\"
        literal = '''raw \\n'''
        [[products]]
        name = "Hammer"
        [[products]]
        name = "Nail"
        broken line here
        after = "still read"
        """
        let result = try js("const r = GreeceSmart.toml(input); return JSON.stringify(r);", input: toml).toString() ?? ""
        let parsed = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] ?? [:]
        let data = parsed["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(data["title"] as? String, "TOML \"x\" é")
        let db = data["database"] as? [String: Any] ?? [:]
        XCTAssertEqual(db["ports"] as? [Int], [8000, 8001, 8002])
        XCTAssertEqual(db["big"] as? Int, 1000)
        XCTAssertEqual(db["multi"] as? String, "one\ntwo")
        XCTAssertEqual(db["literal"] as? String, "raw \\n")
        XCTAssertEqual(((db["quoted key"] as? [String: Any])?["dotted"] as? [String: Any])?["inner"] as? Int, 31)
        XCTAssertEqual((data["owner"] as? [String: Any])?["dob"] as? String, "1979-05-27T07:32:00-08:00")
        XCTAssertEqual((data["products"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(data["after"] as? String, nil, "keys after [[products]] belong to the last product")
        XCTAssertEqual(((data["products"] as? [[String: Any]])?.last)?["after"] as? String, "still read")
        XCTAssertEqual((parsed["errors"] as? [Any])?.count, 1, "the broken line is skipped, not fatal")
    }

    func testTOMLRefusesPrototypeKeysAndDeepNesting() throws {
        let result = try js("""
            const a = GreeceSmart.toml('__proto__ = 1\\n[constructor]\\nx = 1\\n[a.__proto__]\\ny = 2\\n');
            const deep = GreeceSmart.toml('v = ' + '['.repeat(50000) + ']'.repeat(50000));
            const inline = GreeceSmart.toml('v = ' + '{a = '.repeat(5000) + '1' + '}'.repeat(5000));
            return [Object.prototype.y === undefined && ({}).x === undefined, a.errors.length, deep.errors.length, inline.errors.length];
            """).toArray() as? [Any] ?? []
        XCTAssertEqual(result.first as? Bool, true)
        XCTAssertEqual(result[1] as? Int, 3)
        XCTAssertEqual(result[2] as? Int, 1)
        XCTAssertEqual(result[3] as? Int, 1)
    }

    func testManifestsReadNamesVersionsScriptsAndDependencies() throws {
        let summary = """
            const m = GreeceSmart.kind('manifest').parse(fileName, input);
            const facts = {}; m.facts.forEach((f) => { if (f.value) facts[f.label] = f.value; });
            return { title: m.title, version: m.version, label: m.label, facts, scripts: m.scripts.map((s) => s.name),
                     deps: m.deps.map((d) => d.name + '@' + d.version + (d.type ? ':' + d.type : '')) };
            """
        func manifest(_ name: String) throws -> [String: Any] {
            try js(summary, input: try fixture(name), name: name).toDictionary() as? [String: Any] ?? [:]
        }
        let npm = try manifest("package.json")
        XCTAssertEqual(npm["title"] as? String, "@greece/web")
        XCTAssertEqual(npm["version"] as? String, "2.4.1")
        XCTAssertEqual((npm["facts"] as? [String: Any])?["Node"] as? String, ">=20.11")
        XCTAssertEqual((npm["scripts"] as? [String])?.count, 9)
        let deps = npm["deps"] as? [String] ?? []
        XCTAssertTrue(deps.contains("react@^19.0.0"))
        XCTAssertTrue(deps.contains("typescript@^5.6.3:dev"))
        XCTAssertTrue(deps.contains("react@>=18:peer"))
        XCTAssertTrue(deps.contains("sharp@^0.33.5:optional"))

        let cargo = try manifest("Cargo.toml")
        XCTAssertEqual(cargo["title"] as? String, "greece-index")
        XCTAssertTrue((cargo["deps"] as? [String] ?? []).contains("tracing@0.1:optional"))
        XCTAssertTrue((cargo["deps"] as? [String] ?? []).contains("cc@1.1:build"))
        XCTAssertTrue((cargo["deps"] as? [String] ?? []).contains("greece-core@path"))

        let python = try manifest("pyproject.toml")
        XCTAssertEqual((python["facts"] as? [String: Any])?["Python"] as? String, ">=3.10")
        XCTAssertTrue((python["deps"] as? [String] ?? []).contains("pillow@>=10.4,<12"))
        XCTAssertTrue((python["deps"] as? [String] ?? []).contains("pytest@>=8.3:dev"))

        let go = try manifest("go.mod")
        XCTAssertEqual(go["title"] as? String, "greece-sync")
        XCTAssertEqual((go["deps"] as? [String])?.filter { $0.hasSuffix(":indirect") }.count, 5)

        let gems = try manifest("Gemfile")
        XCTAssertTrue((gems["deps"] as? [String] ?? []).contains("rspec-rails@~> 7.0:dev"))
        XCTAssertEqual((gems["facts"] as? [String: Any])?["Ruby"] as? String, "3.3.5")

        let pods = try manifest("Podfile")
        XCTAssertEqual((pods["facts"] as? [String: Any])?["Platform"] as? String, "iOS 16.0")
        XCTAssertTrue((pods["deps"] as? [String] ?? []).contains("Quick@~> 7.6:test"))

        let swift = try manifest("Package.swift")
        XCTAssertEqual(swift["title"] as? String, "GreeceKit")
        XCTAssertEqual((swift["facts"] as? [String: Any])?["Platforms"] as? String, "macOS 14, iOS 17, visionOS 1")
        XCTAssertTrue((swift["deps"] as? [String] ?? []).contains("swift-argument-parser@from 1.5.0"))

        let composer = try manifest("composer.json")
        XCTAssertEqual((composer["facts"] as? [String: Any])?["PHP"] as? String, "^8.3")

        let pubspec = try manifest("pubspec.yaml")
        XCTAssertEqual(pubspec["label"] as? String, "Flutter package")
        XCTAssertTrue((pubspec["deps"] as? [String] ?? []).contains("flutter_lints@^5.0.0:dev"))

        let mix = try manifest("mix.exs")
        XCTAssertEqual(mix["title"] as? String, "greece_relay")
        XCTAssertTrue((mix["deps"] as? [String] ?? []).contains("credo@~> 1.7:dev"))
        XCTAssertEqual(mix["scripts"] as? [String], ["setup", "assets.setup", "test"])

        let gradle = try manifest("build.gradle.kts")
        XCTAssertEqual(gradle["title"] as? String, "com.example.greece")
        XCTAssertEqual((gradle["facts"] as? [String: Any])?["Android"] as? String, "API 26 – 35")
        XCTAssertTrue((gradle["deps"] as? [String] ?? []).contains("junit:junit@4.13.2:test"))
    }

    func testBrokenManifestsDontThrow() throws {
        for (name, text) in [("package.json", "{ not json"), ("package.json", "[1,2]"), ("Cargo.toml", "[[[[\n= = =\n"),
                             ("pyproject.toml", "[project\nname = "), ("pubspec.yaml", "a: [\n"), ("go.mod", "require (\n"),
                             ("Package.swift", ".package(url: \"x\""), ("mix.exs", "defp deps do [ {:a, "), ("build.gradle", "dependencies {")] {
            let value = try js("const m = GreeceSmart.kind('manifest').parse(fileName, input); return m === null ? 'null' : typeof m;", input: text, name: name)
            XCTAssertTrue(["null", "object"].contains(value.toString()), name)
        }
    }

    func testCronInPlainEnglish() throws {
        let cases: [String: String] = [
            "*/15 * * * *": "Every 15 minutes", "0 * * * *": "Every hour", "5 * * * *": "Every hour at :05",
            "30 6 * * 1-5": "Every weekday at 06:30", "0 0 * * *": "Every day at 00:00", "0 9 * * 1,3,5": "Every Monday, Wednesday and Friday at 09:00",
            "0 0 1 * *": "On the 1st of every month at 00:00", "0 0 1 1 *": "Every year on 1 January at 00:00",
            "0 */2 * * *": "Every 2 hours", "0 9-17 * * 1-5": "Every hour from 09:00 to 17:00 on weekdays",
            "0 0 * * 6,0": "Every Saturday and Sunday at 00:00", "0 0 * * 1-7": "Every day at 00:00", "0 4 * * SUN": "Every Sunday at 04:00",
            "@reboot": "At startup", "@weekly": "Every Sunday at 00:00", "0 12 15 * 5": "On the 15th of every month and every Friday at 12:00",
        ]
        for (expression, english) in cases {
            XCTAssertEqual(try js("return GreeceSmart.cron.describe(input);", input: expression).toString(), english, expression)
        }
        for bad in ["61 * * * *", "* * *", "a b c d e", "*/0 * * * *", "5-1 * * * *", String(repeating: "1,", count: 200) + "1 * * * *"] {
            XCTAssertTrue(try js("return GreeceSmart.cron.describe(input);", input: bad).isNull, bad)
        }
        // Next run, from Saturday 21 Nov 2026 10:00 local time.
        let next = try js("const d = GreeceSmart.cron.nextRun(input, new Date(2026, 10, 21, 10, 0)); return d.toString();", input: "30 6 * * 1-5").toString() ?? ""
        XCTAssertTrue(next.hasPrefix("Mon Nov 23 2026 06:30"), next)
    }

    func testCrontabFilesAndUserColumns() throws {
        let user = try js("const t = GreeceSmart.kind('cron').parse(input); return t.jobs.map((j) => j.user + '|' + j.command).join('\\n');",
                          input: "SHELL=/bin/sh\n17 * * * * root cd / && run-parts --report /etc/cron.hourly\n25 6 * * * root test -x /usr/sbin/anacron\n").toString()
        XCTAssertEqual(user, "root|cd / && run-parts --report /etc/cron.hourly\nroot|test -x /usr/sbin/anacron")
        let personal = try js("const t = GreeceSmart.kind('cron').parse(input); return t.jobs.map((j) => j.user + '|' + j.command).join('\\n');",
                              input: "0 3 * * * python3 backup.py\n").toString()
        XCTAssertEqual(personal, "|python3 backup.py")
    }

    func testMakefileTargetsAndDescriptions() throws {
        let result = try js("const m = GreeceSmart.kind('make').parse(input); return m.defaultGoal + ' ' + m.targets.map((t) => t.name + '=' + t.description).join(';');",
                            input: try fixture("Makefile")).toString() ?? ""
        XCTAssertTrue(result.hasPrefix("build "), result)
        XCTAssertTrue(result.contains("render=Render every fixture to PNG, light and dark"))
        XCTAssertTrue(result.contains("clean=Remove build products"))
        XCTAssertFalse(result.contains("%.png"), "pattern rules aren't targets you run")
        XCTAssertFalse(result.contains(".PHONY"))
    }

    func testSSHHostsAndIncludes() throws {
        let result = try js("const s = GreeceSmart.kind('ssh').parse(input); return s.hosts.map((h) => h.patterns.join(' ') + '>' + (h.options.hostname || '')).join(';') + '|' + s.includes.length;",
                            input: try fixture("config")).toString()
        XCTAssertEqual(result, "github.com>;build-mac>10.0.4.21;prod-web prod-web-*>web.greece.example.com;bastion>bastion.example.com;*>|1")
    }

    func testInfrastructureCards() throws {
        let docker = try js("const d = GreeceSmart.kind('docker').parse(input); const f = d.stages[d.stages.length - 1]; return [d.stages.length, f.image, f.expose.join(','), f.entrypoint, f.cmd, f.copiesFrom.join(',')].join('|');",
                            input: try fixture("Dockerfile")).toString()
        XCTAssertEqual(docker, "3|gcr.io/distroless/nodejs22-debian12|3000,9464/tcp|node|server.js --port 3000|build")
        let compose = try js("const c = GreeceSmart.kind('compose').parse(input); return c.services.map((s) => s.name + ':' + s.depends.join('+') + ':' + s.ports.join('+')).join(';');",
                             input: try fixture("docker-compose.yml")).toString()
        XCTAssertEqual(compose, "web:db+cache:3000:3000;worker:db+cache:;db::5433:5432;cache::;proxy:web:80:80+443:443")
        let flow = try js("const w = GreeceSmart.kind('workflow').parse(input); return w.triggers.map((t) => t.name + '=' + t.detail).join(';') + '|' + w.jobs.map((j) => j.id + '<' + j.needs.join('+')).join(';');",
                          input: try fixture("ci.yml")).toString()
        XCTAssertEqual(flow, "Push=to main, release/**;Pull request=into main;Schedule=Every weekday at 06:30;Manual=1 input|lint<;test<;build<lint+test;release<build")
        let k8s = try js("return GreeceSmart.kind('kubernetes').parse(input).map((r) => r.kind + ':' + r.name + ':' + r.images.length).join(';');",
                         input: try fixture("deployment.yaml")).toString()
        XCTAssertEqual(k8s, "Namespace:greece:0;Deployment:greece-web:1;Service:greece-web:0;Ingress:greece:0;CronJob:cleanup:1;Secret:greece-secrets:0")
    }

    func testKubernetesSecretsNeverReachTheCard() throws {
        let card = try js("return JSON.stringify(GreeceSmart.kind('kubernetes').parse(input));", input: try fixture("deployment.yaml")).toString() ?? ""
        XCTAssertFalse(card.contains("never-shown"))
        XCTAssertFalse(card.contains("sk_live"))
    }

    func testOpenAPIGroupsResolvesAndCaps() throws {
        let api = try js("const a = GreeceSmart.kind('openapi').parse(jsyaml.load(input)); return a.groups.map((g) => g.name + ':' + g.endpoints.map((e) => e.method + ' ' + e.path + '(' + e.params.map((p) => p.name).join(',') + ')').join(',')).join(';');",
                         input: try fixture("openapi.yaml")).toString() ?? ""
        XCTAssertTrue(api.hasPrefix("Files:GET /files(cursor,kind),POST /files(),GET /files/{id}(id),DELETE /files/{id}(id);Previews:"), api)
        let swagger = try js("const a = GreeceSmart.kind('openapi').parse(JSON.parse(input)); return a.spec + '|' + a.servers[0] + '|' + a.count;",
                             input: try fixture("swagger.json")).toString()
        XCTAssertEqual(swagger, "Swagger 2.0|https://licensing.example.com/v1|4")
        // Reference loops and a flood of paths stay bounded.
        let hostile = try js("""
            const doc = { openapi: '3.0.0', paths: {}, components: { parameters: { A: { $ref: '#/components/parameters/B' }, B: { $ref: '#/components/parameters/A' } } } };
            for (let i = 0; i < 10000; i++) doc.paths['/p' + i] = { get: { parameters: [{ $ref: '#/components/parameters/A' }] }, post: {} };
            const t0 = Date.now(); const a = GreeceSmart.kind('openapi').parse(doc); return [a.count, Date.now() - t0];
            """).toArray() as? [Int] ?? []
        XCTAssertEqual(hostile.first, 5000)
        XCTAssertLessThan(hostile.last ?? 99999, 2000)
    }

    func testYAMLBombsAndCyclesStayBounded() throws {
        let bomb = """
        a: &a ["x","x","x","x","x","x","x","x","x"]
        b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
        c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
        d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]
        e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]
        f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e]
        services:
          web: { image: x, ports: *f, volumes: *f, depends_on: *f }
        """
        let result = try js("""
            const t0 = Date.now();
            const c = GreeceSmart.kind('compose').parse(input);
            const k = GreeceSmart.kind('kubernetes').parse('apiVersion: v1\\nkind: List\\nitems: &x [ {apiVersion: v1, kind: List, items: *x} ]\\n');
            return [c.services[0].ports.length, c.services[0].depends.length, k.length, Date.now() - t0];
            """, input: bomb).toArray() as? [Int] ?? []
        XCTAssertLessThanOrEqual(result[0], 20, "ports are listed, never expanded")
        XCTAssertLessThanOrEqual(result[1], 50)
        XCTAssertEqual(result[2], 0)
        XCTAssertLessThan(result[3], 1000)
    }

    func testLogLevelsAcrossFormats() throws {
        let lines: [(String, String)] = [
            ("2024-01-01 10:00:00,123 ERROR [main] boom", "e"), ("2024-01-01T10:00:00Z WARN slow", "w"),
            ("[2024-01-01 10:00:00] local.INFO: hello", "i"), ("2024/01/01 10:00:00 [error] 12#0: nginx", "e"),
            ("{\"level\":\"debug\",\"msg\":\"x\"}", "d"), ("{\"level\":50,\"msg\":\"pino\"}", "e"), ("{\"severity\":\"WARNING\"}", "w"),
            ("time=1 level=trace msg=x", "t"), ("E1225 10:00:00.000 1 main.go:1] glog", "e"),
            ("12-25 10:00:00.000  123  456 W ActivityManager: logcat", "w"), ("I/Tag( 123): brief", "i"),
            ("E, [2024-01-01T10:00:00 #1] ERROR -- : ruby", "e"), ("<11>Jan  1 10:00:00 host app: syslog pri", "e"),
            ("2024-01-01 10:00:00.000000-0800 0x1 Fault 0x0 1 0 kernel: x", "e"), ("ERROR:root:python", "e"),
            ("127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] \"GET /x HTTP/1.1\" 503 12", "e"),
            ("127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] \"GET /x HTTP/1.1\" 404 12", "w"),
            ("Jan  1 10:00:00 host app[1]: nothing special", "n"), ("0 errors, 3 warnings", "n"),
        ]
        for (line, level) in lines {
            let got = try js("return ['n','t','d','i','w','e'][GreeceSmart.kind('log').classify(input)[0]];", input: line).toString()
            XCTAssertEqual(got, level, line)
        }
    }

    func testLogAnalysisFoldsRepeatsAndGroupsErrors() throws {
        let result = try js("""
            const a = GreeceSmart.kind('log').analyse(input);
            return { rows: a.rows, collapsed: a.collapsed, counts: Array.from(a.counts), top: a.topErrors.map((g) => g.count + 'x ' + g.message) };
            """, input: try fixture("server.log")).toDictionary() ?? [:]
        XCTAssertEqual(result["rows"] as? Int, 23)
        XCTAssertEqual(result["collapsed"] as? Int, 7)
        XCTAssertEqual(result["counts"] as? [Int], [0, 1, 2, 16, 3, 8])
        XCTAssertEqual((result["top"] as? [String])?.first, "2x Failed to render preview for 9f2c: connection refused (redis:6379)")
    }

    func testHundredThousandLineLogIsFast() throws {
        var lines: [String] = []
        lines.reserveCapacity(100_000)
        let levels = ["INFO", "DEBUG", "WARN", "ERROR", "TRACE"]
        for i in 0..<100_000 { lines.append("2026-11-21 09:00:00.\(String(format: "%03d", i % 1000)) \(levels[(i * 7) % 5]) [w-\(i % 8)] request \(i) took \(i % 300)ms") }
        let text = lines.joined(separator: "\n")
        let started = Date()
        let rows = try js("return GreeceSmart.kind('log').analyse(input).rows;", input: text).toInt32()
        XCTAssertEqual(rows, 100_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }
}
