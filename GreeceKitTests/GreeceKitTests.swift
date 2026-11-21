import XCTest
@testable import GreeceKit

final class DetectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func file(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testMarkdownAndCode() throws {
        XCTAssertEqual(FileKind.detect(try file("a.md", "# Hi")), .markdown)
        XCTAssertEqual(FileKind.detect(try file("a.mdx", "# Hi")), .markdown)
        guard case .code(let swift) = FileKind.detect(try file("a.swift", "let x = 1")) else { return XCTFail("swift") }
        XCTAssertEqual(swift.grammar, "swift")
        guard case .code(let docker) = FileKind.detect(try file("Dockerfile", "FROM swift")) else { return XCTFail("dockerfile") }
        XCTAssertEqual(docker.grammar, "dockerfile")
    }

    func testTypeScriptVersusVideo() throws {
        guard case .code(let ts) = FileKind.detect(try file("app.ts", "export const a: number = 1;\n")) else { return XCTFail("ts") }
        XCTAssertEqual(ts.grammar, "typescript")
        // MPEG transport streams start with sync bytes and contain NULs.
        XCTAssertEqual(FileKind.detect(try file("clip.ts", bytes: [0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D] + [UInt8](repeating: 0, count: 200))), .video)
    }

    func testShebangAndDiffSniffing() throws {
        guard case .code(let python) = FileKind.detect(try file("tool", "#!/usr/bin/env python3\nprint(1)\n")) else { return XCTFail("shebang") }
        XCTAssertEqual(python.grammar, "python")
        XCTAssertEqual(FileKind.detect(try file("changes", "diff --git a/x b/x\n--- a/x\n+++ b/x\n")), .diff)
    }

    func testDataFormats() throws {
        XCTAssertEqual(FileKind.detect(try file("a.csv", "a,b\n1,2\n")), .delimited(separator: nil))
        XCTAssertEqual(FileKind.detect(try file("a.tsv", "a\tb\n")), .delimited(separator: UInt8(ascii: "\t")))
        XCTAssertEqual(FileKind.detect(try file("a.json", "{}")), .json)
        XCTAssertEqual(FileKind.detect(try file("a.ipynb", "{}")), .notebook)
        XCTAssertEqual(FileKind.detect(try file("x.db", bytes: Array("SQLite format 3\0".utf8) + [UInt8](repeating: 0, count: 84))), .sqlite)
    }

    func testBinaryIsUnsupported() throws {
        XCTAssertEqual(FileKind.detect(try file("blob.swift", bytes: [0, 1, 2, 3, 0, 0, 255])), .unsupported)
    }
}

final class LanguageCatalogTests: XCTestCase {
    /// Every grammar the catalog names must ship in the bundle, or highlighting silently disappears.
    func testEveryGrammarIsBundled() {
        for grammar in LanguageCatalog.allGrammars {
            XCTAssertTrue(WebAssets.hasGrammar(grammar), "missing highlight.js grammar: \(grammar)")
        }
    }

    func testCommonLookups() {
        XCTAssertEqual(LanguageCatalog.language(forExtension: "rs")?.name, "Rust")
        XCTAssertEqual(LanguageCatalog.language(forExtension: "TSX")?.grammar, "typescript")
        XCTAssertEqual(LanguageCatalog.language(forFileName: "Makefile")?.grammar, "makefile")
        XCTAssertEqual(LanguageCatalog.language(forFileName: ".zshrc")?.grammar, "bash")
        XCTAssertEqual(LanguageCatalog.language(forFileName: "Gemfile.lock")?.grammar, "ruby")
    }
}

final class DelimitedTableTests: XCTestCase {
    func testQuotedFieldsAndHeader() {
        let table = DelimitedTable.parse("name,notes,count\n\"Naxos\",\"Big, \"\"bright\"\"\nisland\",3\nIos,,4\n")
        XCTAssertEqual(table.header, ["name", "notes", "count"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0][1], "Big, \"bright\"\nisland")
        XCTAssertEqual(table.rows[1], ["Ios", "", "4"])
        XCTAssertEqual(table.numericColumns(), [2])
    }

    func testSemicolonSniffingAndCRLF() {
        let table = DelimitedTable.parse("a;b;c\r\n1;2;3\r\n4;5;6\r\n")
        XCTAssertEqual(table.separator, UInt8(ascii: ";"))
        XCTAssertEqual(table.rows, [["1", "2", "3"], ["4", "5", "6"]])
    }

    func testHeaderlessNumbers() {
        let table = DelimitedTable.parse("1,2\n3,4\n")
        XCTAssertNil(table.header)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(DelimitedTable.columnLetter(0), "A")
        XCTAssertEqual(DelimitedTable.columnLetter(27), "AB")
    }

    func testRowLimitCountsEverything() {
        let csv = "x\n" + (1...500).map(String.init).joined(separator: "\n") + "\n"
        let table = DelimitedTable.parse(csv, maxRows: 100)
        XCTAssertEqual(table.rows.count, 100)
        XCTAssertEqual(table.totalRows, 500)
        XCTAssertTrue(table.truncated)
    }

    func testSpreadsheetNumbers() {
        XCTAssertEqual(DelimitedTable.number("1,234.5"), 1234.5)
        XCTAssertEqual(DelimitedTable.number("$40"), 40)
        XCTAssertEqual(DelimitedTable.number("-12%"), -12)
        XCTAssertNil(DelimitedTable.number("Naxos"))
    }
}

final class FormatterTests: XCTestCase {
    func testPrettyPrintKeepsKeyOrder() {
        let pretty = JSONFormatter.prettyPrinted(#"{"z":1,"a":[1,2,{}],"s":"a,b:{c}","e":[]}"#)
        XCTAssertEqual(pretty, """
        {
          "z": 1,
          "a": [
            1,
            2,
            {}
          ],
          "s": "a,b:{c}",
          "e": []
        }

        """)
    }

    func testRejectsUnbalancedJSON() {
        XCTAssertNil(JSONFormatter.prettyPrinted("{\"a\": [1, 2}"))
    }

    func testDiffStatsIgnorePatchSignature() {
        let patch = "Subject: x\n---\n a | 2 +-\n\ndiff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n-- \n2.47.0\n"
        let stats = PreviewFactory.diffStats(patch)
        XCTAssertEqual(stats.files, 1)
        XCTAssertEqual(stats.added, 1)
        XCTAssertEqual(stats.removed, 1)
    }

    func testTextDecoding() {
        XCTAssertEqual(TextFile.decode(Data([0xEF, 0xBB, 0xBF] + Array("hi".utf8))).0, "hi")
        XCTAssertEqual(TextFile.decode(Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])).0, "hi")
        XCTAssertEqual(TextFile.decode(Data([0x63, 0x61, 0x66, 0xE9])).1, "Windows Latin 1")
    }

    func testSettingsDecodeTolerantly() throws {
        let decoded = try JSONDecoder().decode(PreviewSettings.self, from: Data(#"{"theme":"one","codeFontSize":99,"unknown":true}"#.utf8))
        XCTAssertEqual(decoded.theme, "one")
        XCTAssertEqual(decoded.codeFontSize, 24)
        XCTAssertTrue(decoded.lineNumbers)
    }
}

final class ArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceArchives-\(UUID().uuidString)")
        let project = directory.appendingPathComponent("Project/Sources/Deep/Deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "hello".write(to: directory.appendingPathComponent("Project/README.md"), atomically: true, encoding: .utf8)
        try String(repeating: "let x = 1\n", count: 500).write(to: directory.appendingPathComponent("Project/Sources/main.swift"), atomically: true, encoding: .utf8)
        // A name longer than 100 bytes exercises GNU/PAX long names.
        let long = String(repeating: "l", count: 120) + ".txt"
        try "long".write(to: project.appendingPathComponent(long), atomically: true, encoding: .utf8)
        try "Ελλάδα".write(to: directory.appendingPathComponent("Project/Νάξος.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func assertProjectListing(_ listing: ArchiveListing, file: StaticString = #filePath, line: UInt = #line) {
        let files = listing.entries.filter { !$0.isDirectory }.map(\.path)
        XCTAssertTrue(files.contains { $0.hasSuffix("Project/README.md") }, file: file, line: line)
        XCTAssertTrue(files.contains { $0.hasSuffix("Project/Νάξος.txt") }, "unicode names", file: file, line: line)
        XCTAssertTrue(files.contains { $0.hasSuffix(String(repeating: "l", count: 120) + ".txt") }, "long names", file: file, line: line)
        XCTAssertEqual(listing.entries.first { $0.path.hasSuffix("/main.swift") }?.size, 5000, file: file, line: line)
    }

    func testZip() throws {
        try run("/usr/bin/zip", ["-qr", "p.zip", "Project"])
        let url = directory.appendingPathComponent("p.zip")
        XCTAssertEqual(FileKind.detect(url), .module(ArchivesModule.id))
        let listing = try ArchiveReader.read(url, format: .zip)
        assertProjectListing(listing)
        XCTAssertLessThan(listing.entries.first { $0.path.hasSuffix("/main.swift") }?.compressedSize ?? .max, 5000)
    }

    func testTarFamilies() throws {
        for (name, flags, format) in [("p.tar", "-cf", ArchiveFormat.tar), ("p.tgz", "-czf", .gzip), ("p.tbz2", "-cjf", .bzip2), ("p.txz", "-cJf", .xz)] {
            try run("/usr/bin/tar", [flags, name, "Project"])
            let url = directory.appendingPathComponent(name)
            XCTAssertEqual(FileKind.detect(url), .module(ArchivesModule.id), name)
            let listing = try ArchiveReader.read(url, format: format)
            XCTAssertEqual(listing.container, .tar, name)
            assertProjectListing(listing)
        }
    }

    func testSingleCompressedFileShowsContents() throws {
        try run("/usr/bin/gzip", ["-k", "Project/Sources/main.swift"])
        let url = directory.appendingPathComponent("Project/Sources/main.swift.gz")
        let listing = try ArchiveReader.read(url, format: .gzip)
        XCTAssertEqual(listing.container, .compressedFile)
        XCTAssertEqual(listing.entries.first?.path, "main.swift")
        XCTAssertEqual(listing.entries.first?.size, 5000)
        XCTAssertEqual(listing.innerPrefix.map { String(decoding: $0.prefix(9), as: UTF8.self) }, "let x = 1")
    }

    func testTreeBuildsImplicitFolders() {
        let listing = ArchiveListing(format: .zip, container: .zip, entries: [
            ArchiveEntry(path: "a/b/c.txt", isDirectory: false, size: 10),
            ArchiveEntry(path: "a/d.txt", isDirectory: false, size: 5),
            ArchiveEntry(path: "__MACOSX/a/._d.txt", isDirectory: false, size: 1),
        ], archiveSize: 10)
        let root = FileNode.tree(from: listing, showHidden: false)
        XCTAssertEqual(root.children?.map(\.name), ["a"])
        XCTAssertEqual(root.children?.first?.size, 15)
        XCTAssertEqual(root.children?.first?.children?.count, 2)
    }
}

/// Regression tests for crafted, hostile input. Previews render files people download.
final class HardeningTests: XCTestCase {

    func testFenceLanguageCannotShapeScriptTags() {
        // Space-free so it survives as a single fence "language" word.
        let evil = "```x\"></script><meta/http-equiv=\"refresh\"/content=\"0;url=evil.svg\">/../../../../../../markdown-it/markdown-it\nhi\n```\n"
        let html = WebDocument(kind: .markdown, text: evil).html(settings: PreviewSettings())
        let head = html.components(separatedBy: "<script id=\"payload\"").first ?? html
        let tail = html.components(separatedBy: "</script>\n</head>").last ?? html
        XCTAssertFalse(head.contains("http-equiv=\"refresh\""))
        XCTAssertFalse(tail.contains("refresh"), "document text leaked outside the JSON payload")
        XCTAssertFalse(html.contains("<meta/http-equiv"))
    }

    func testOnlyBundledGrammarsLoad() {
        XCTAssertTrue(WebAssets.hasGrammar("rust"))
        XCTAssertFalse(WebAssets.hasGrammar("../markdown-it/markdown-it"))
        XCTAssertFalse(WebAssets.hasGrammar("rust/../rust"))
    }

    private func tarHeader(name: String, size: [UInt8], type: UInt8) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        for (i, byte) in name.utf8.prefix(100).enumerated() { block[i] = byte }
        for (i, byte) in size.prefix(12).enumerated() { block[124 + i] = byte }
        block[156] = type
        for (i, byte) in Array("ustar\0".utf8).enumerated() { block[257 + i] = byte }
        for i in 148..<156 { block[i] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        let checksum = Array(String(format: "%06o\0 ", sum).utf8)
        for (i, byte) in checksum.enumerated() { block[148 + i] = byte }
        return block
    }

    private func write(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("greece-\(UUID().uuidString)-\(name)")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMalformedPAXRecordDoesNotCrash() throws {
        var bytes = tarHeader(name: "pax", size: Array("00000000003\0".utf8), type: UInt8(ascii: "x"))
        bytes += Array("1 x".utf8) + [UInt8](repeating: 0, count: 509)
        bytes += tarHeader(name: "file.txt", size: Array("00000000000\0".utf8), type: UInt8(ascii: "0"))
        bytes += [UInt8](repeating: 0, count: 1024)
        let listing = try ArchiveReader.read(try write(bytes, "pax.tar"), format: .tar)
        XCTAssertEqual(listing.entries.map(\.path), ["file.txt"])
    }

    func testHugeSizeFieldsDoNotTrap() throws {
        // Base-256 size of all ones: 2^64-ish.
        let huge = [UInt8](repeating: 0xFF, count: 12)
        var bytes = tarHeader(name: "big.bin", size: huge, type: UInt8(ascii: "0"))
        bytes += [UInt8](repeating: 0, count: 1024)
        let listing = try ArchiveReader.read(try write(bytes, "huge.tar"), format: .tar)
        XCTAssertLessThanOrEqual(listing.entries.count, 1)
        XCTAssertEqual(listing.totalSize, listing.entries.first?.size ?? 0)
    }

    func testOversizedLongNameIsSkippedNotRead() throws {
        // Declares an 8 GB GNU long name; must not be read into memory.
        var bytes = tarHeader(name: "././@LongLink", size: Array("100000000000".utf8), type: UInt8(ascii: "L"))
        bytes += [UInt8](repeating: 0, count: 1024)
        XCTAssertNoThrow(try? ArchiveReader.read(try write(bytes, "longname.tar"), format: .tar))
    }

    func testDeepArchivePathsDoNotOverflowTheStack() {
        let deep = String(repeating: "a/", count: 20_000) + "file.txt"
        let listing = ArchiveListing(format: .zip, container: .zip, entries: [
            ArchiveEntry(path: deep, isDirectory: false, size: 1),
            ArchiveEntry(path: "ok/readme.md", isDirectory: false, size: 2),
        ], archiveSize: 3)
        let root = FileNode.tree(from: listing, showHidden: false)
        XCTAssertEqual(root.children?.map(\.name), ["ok"])
    }

    func testSaturatingSizes() {
        let listing = ArchiveListing(format: .zip, container: .zip, entries: [
            ArchiveEntry(path: "a", isDirectory: false, size: .max),
            ArchiveEntry(path: "b", isDirectory: false, size: .max),
        ], archiveSize: 1)
        XCTAssertEqual(listing.totalSize, .max)
        XCTAssertEqual(FileNode.tree(from: listing, showHidden: false).size, .max)
    }

    func testJSONNestingBombIsRefusedQuickly() {
        let bomb = String(repeating: "[", count: 20_000) + "1" + String(repeating: "]", count: 20_000)
        let start = Date()
        XCTAssertNil(JSONFormatter.prettyPrinted(bomb))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testColumnFloodIsCapped() {
        let table = DelimitedTable.parse("a,b\n" + String(repeating: ",", count: 200_000) + "\n")
        XCTAssertEqual(table.columnCount, DelimitedTable.maxColumns)
        XCTAssertGreaterThan(table.totalColumns, table.columnCount)
    }

    func testDiffStatsHonourHunkLengths() {
        let diff = "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n--- removed dashes\n+++ added plusses\n ctx\n-- \n2.4\n"
        let stats = PreviewFactory.diffStats(diff)
        XCTAssertEqual(stats.added, 1)
        XCTAssertEqual(stats.removed, 1)
    }

    func testMultiStreamBzip2KeepsEveryByte() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("greece-bz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // Two streams, each larger than the 256 KB read size, concatenated (as pbzip2 writes them).
        let part = String(repeating: "Aegean ferry timetable line\n", count: 20_000)
        try part.write(to: directory.appendingPathComponent("part.txt"), atomically: true, encoding: .utf8)
        let script = "cd '\(directory.path)' && /usr/bin/bzip2 -c part.txt > log.txt.bz2 && /usr/bin/bzip2 -c part.txt >> log.txt.bz2"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
        let listing = try ArchiveReader.read(directory.appendingPathComponent("log.txt.bz2"), format: .bzip2)
        XCTAssertEqual(listing.entries.first?.size, UInt64(part.utf8.count * 2))
    }

    func testCompressedTextPreviewIsNotCutShort() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("greece-gz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let text = String(repeating: "2026-11-21 INFO berth assigned\n", count: 10_000)   // ~310 KB
        try text.write(to: directory.appendingPathComponent("harbor.log"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = [directory.appendingPathComponent("harbor.log").path]
        try process.run()
        process.waitUntilExit()
        let listing = try ArchiveReader.read(directory.appendingPathComponent("harbor.log.gz"), format: .gzip)
        XCTAssertEqual(listing.innerPrefix?.count, text.utf8.count)
    }
}

final class ThumbnailTests: XCTestCase {
    func testPagesForDocumentsButNotBinaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("greece-thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ data: Data) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        let size = CGSize(width: 256, height: 256)
        let swift = Thumbnailer.page(for: try write("a.swift", Data("let x = 1\n".utf8)), maximumSize: size, settings: PreviewSettings())
        XCTAssertEqual(swift?.badge, "SWIFT")
        XCTAssertEqual(swift?.size.height, 256)
        XCTAssertEqual(swift.map { $0.size.width / $0.size.height } ?? 0, 8.5 / 11, accuracy: 0.01)
        XCTAssertEqual(Thumbnailer.page(for: try write("t.tsv", Data("a\tb\n1\t2\n".utf8)), maximumSize: size, settings: PreviewSettings())?.badge, "TSV")
        XCTAssertNil(Thumbnailer.page(for: try write("x.bin", Data([0, 1, 2, 0, 255])), maximumSize: size, settings: PreviewSettings()))
    }

    func testHighlightedSpansTakeThemeColours() {
        let theme = CodeTheme.xcode
        let attributed = Highlighter.shared.attributed("let x = \"hi\"", grammar: "swift", base: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)], theme: theme)
        XCTAssertEqual(attributed?.string, "let x = \"hi\"")
        let keyword = attributed?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let string = attributed?.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor
        XCTAssertEqual(keyword?.usingColorSpace(.sRGB), NSColor(hex: theme.light.keyword).usingColorSpace(.sRGB))
        XCTAssertEqual(string?.usingColorSpace(.sRGB), NSColor(hex: theme.light.string).usingColorSpace(.sRGB))
    }
}
