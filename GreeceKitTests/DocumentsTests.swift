import XCTest
import JavaScriptCore
@testable import GreeceKit

/// Shared helpers: a temporary folder, fixture paths and a JavaScriptCore context with latex.js.
class DocumentsTestCase: XCTestCase {
    var directory: URL!
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/documents")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceDocs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func file(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func format(_ url: URL) -> DocumentsModule.Format? { DocumentsModule.format(FileInfo(url: url)) }

    /// latex.js in JavaScriptCore, the same code the page runs.
    func latex() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        let source = try String(contentsOf: try XCTUnwrap(WebAssets.url("modules/latex.js")), encoding: .utf8)
        context.exceptionHandler = { _, exception in XCTFail("JS exception: \(exception?.toString() ?? "?")") }
        context.evaluateScript(source)
        return context
    }

    func convert(_ tex: String, options: [String: Any] = [:]) throws -> [String: Any] {
        let context = try latex()
        let converter = try XCTUnwrap(context.objectForKeyedSubscript("GreeceLaTeX"))
        let result = try XCTUnwrap(converter.invokeMethod("convert", withArguments: [tex, options]))
        return try XCTUnwrap(result.toDictionary() as? [String: Any])
    }

    /// A minimal EPUB written with the archive's own conventions: mimetype first, stored.
    func epub(_ name: String, files: [(String, String)], rawFiles: [(String, Data)] = []) throws -> URL {
        var entries: [(String, Data)] = [("mimetype", Data("application/epub+zip".utf8))]
        entries += files.map { ($0.0, Data($0.1.utf8)) }
        entries += rawFiles
        let url = directory.appendingPathComponent(name)
        try ZipWriter.stored(entries).write(to: url)
        return url
    }
}

/// Writes uncompressed ZIP archives for tests.
enum ZipWriter {
    static func stored(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: Int, _ d: inout Data) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: Int, _ d: inout Data) { var x = UInt32(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        for (name, data) in entries {
            let offset = out.count
            let nameData = Data(name.utf8)
            let crc = crc32(data)
            u32(0x04034B50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(0, &out); u16(0, &out)
            u32(Int(crc), &out); u32(data.count, &out); u32(data.count, &out); u16(nameData.count, &out); u16(0, &out)
            out.append(nameData); out.append(data)
            u32(0x02014B50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(Int(crc), &central); u32(data.count, &central); u32(data.count, &central); u16(nameData.count, &central)
            u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central); u32(offset, &central)
            central.append(nameData)
        }
        let start = out.count
        out.append(central)
        u32(0x06054B50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(central.count, &out); u32(start, &out); u16(0, &out)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}

// MARK: - Detection

final class DocumentDetectionTests: DocumentsTestCase {
    func testFormatsByExtensionAndContent() throws {
        XCTAssertEqual(format(try file("paper.tex", "\\documentclass{article}")), .latex)
        XCTAssertEqual(format(try file("refs.bib", "@article{a, title={T}}")), .bibtex)
        XCTAssertEqual(format(try file("notes.org", "* Heading")), .org)
        XCTAssertEqual(format(try file("guide.adoc", "= Title")), .asciidoc)
        XCTAssertEqual(format(try file("readme.rst", "Title\n=====")), .rst)
        XCTAssertEqual(format(try file("a.qmd", "# Q")), .quarto)
        XCTAssertEqual(format(try file("a.Rmd", "# R")), .rmarkdown)
        XCTAssertEqual(format(try file("a.livemd", "# L")), .livebook)
        XCTAssertEqual(format(try file("report.Rnw", "\\documentclass{article}")), .sweave)
        XCTAssertEqual(format(try file("doc.typ", "= Heading")), .typst)
        XCTAssertEqual(format(try file("flow.mmd", "%% comment\nflowchart LR\n A --> B")), .mermaid)
        XCTAssertEqual(format(try file("seq.mermaid", "sequenceDiagram\n A->>B: hi")), .mermaid)
        XCTAssertEqual(format(try file("notes.mmd", "Title: Notes\n\n# MultiMarkdown")), .multiMarkdown)
        XCTAssertEqual(format(try file("plot.pgf", "%% Creator: Matplotlib, PGF backend\n\\begin{pgfpicture}")), .pgf)
        XCTAssertNil(format(try file("other.pgf", "just some text")))
        if case .module(let id) = FileKind.detect(try file("x.tex", "\\section{A}")) { XCTAssertEqual(id, DocumentsModule.id) } else { XCTFail("tex not claimed") }
    }

    func testBinaryAndMisnamedFilesAreNotClaimed() throws {
        let binary = directory.appendingPathComponent("blob.tex")
        try Data([0, 1, 2, 3, 0, 0, 255, 0]).write(to: binary)
        XCTAssertNil(format(binary))
        XCTAssertNil(format(try file("fake.epub", "not a zip")))
        XCTAssertNil(format(try file("note.md", "# Markdown stays Markdown")))
    }

    func testMermaidTypes() {
        XCTAssertEqual(MermaidDocument.diagramType("---\ntitle: T\n---\nflowchart TD\n A-->B"), "Flowchart")
        XCTAssertEqual(MermaidDocument.diagramType("%%{init: {}}%%\nsequenceDiagram"), "Sequence Diagram")
        XCTAssertEqual(MermaidDocument.diagramType("radar-beta\n axis a"), "Radar Chart")
        XCTAssertEqual(MermaidDocument.diagramType("treemap-beta"), "Treemap")
        XCTAssertNil(MermaidDocument.diagramType("# Not a diagram"))
    }

    func testEveryFixtureDiagramHasAType() throws {
        let folder = fixtures.appendingPathComponent("mermaid")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 22)
        var types = Set<String>()
        for url in files {
            let type = MermaidDocument.diagramType(try String(contentsOf: url, encoding: .utf8))
            XCTAssertNotNil(type, url.lastPathComponent)
            if let type { types.insert(type) }
            XCTAssertEqual(format(url), .mermaid, url.lastPathComponent)
        }
        XCTAssertEqual(types.count, 22)
    }
}

// MARK: - BibTeX

final class BibTeXTests: DocumentsTestCase {
    func testStringsConcatenationMonthsAndCrossref() {
        let library = BibTeX.parse("""
        @string{acm = "Communications of the ACM"}
        @comment{ignored @article{nope, title={x}} }
        @preamble{"\\newcommand{\\noop}[1]{}"}
        @article{knuth, author = {Donald E. Knuth and Michael F. Plass}, title = {Breaking {P}aragraphs into Lines},
          journal = acm # " (" # "special" # ")", year = 1981, month = nov}
        @inproceedings{child, crossref = {proc}, title = "Generating Long Sequences", author = "Child, Rewon and others"}
        @proceedings{proc, title = {Proceedings of Something}, year = {2019}, publisher = {PMLR}}
        """)
        XCTAssertEqual(library.entries.map(\.key), ["knuth", "child", "proc"])
        XCTAssertEqual(library.comments, 1)
        XCTAssertEqual(library.preambles.count, 1)
        let knuth = library.entries[0]
        XCTAssertEqual(knuth.fields["journal"], "Communications of the ACM (special)")
        XCTAssertEqual(knuth.fields["month"], "November")
        XCTAssertEqual(knuth.fields["year"], "1981")
        XCTAssertEqual(knuth.fields["title"], "Breaking {P}aragraphs into Lines")
        XCTAssertEqual(knuth.authorSurnames, ["Knuth", "Plass"])
        let child = library.entries[1]
        XCTAssertEqual(child.fields["booktitle"], "Proceedings of Something")
        XCTAssertEqual(child.fields["year"], "2019")
        XCTAssertEqual(BibTeX.shortCitation(child), "Child et al., 2019")
    }

    func testAccentsBecomeLetters() {
        let entry = BibEntry(type: "article", key: "k", fields: ["author": "Erd{\\H{o}}s, Paul and M{\\\"u}ller, J{\\'e}r{\\^o}me and {\\O}stergaard, Lars"])
        XCTAssertEqual(entry.authorSurnames, ["Erdős", "Müller", "Østergaard"])
    }

    func testMalformedInputNeverCrashes() {
        let inputs = ["@", "@article", "@article{", "@article{key,", "@article{key, title = {unclosed", "@@@@{{{{", "@string{x = }",
                      "@article(key, title = \"a\")", String(repeating: "{", count: 50_000), "@misc{a, title = " + String(repeating: "{", count: 10_000)]
        for input in inputs { _ = BibTeX.parse(input) }
        XCTAssertEqual(BibTeX.parse("@article(key, title = \"a\")").entries.first?.fields["title"], "a")
    }

    func testEntryLimit() {
        let text = (0..<300).map { "@misc{k\($0), title={T}}" }.joined(separator: "\n")
        let library = BibTeX.parse(text, limit: 100)
        XCTAssertEqual(library.entries.count, 100)
        XCTAssertTrue(library.truncated)
    }

    func testFixtureLibrary() throws {
        let library = BibTeX.parse(try String(contentsOf: fixtures.appendingPathComponent("bib/library.bib"), encoding: .utf8))
        XCTAssertGreaterThanOrEqual(library.entries.count, 15)
        XCTAssertEqual(library.strings.count, 4)
        XCTAssertTrue(library.entries.allSatisfy { !$0.key.isEmpty })
    }
}

// MARK: - LaTeX projects (Swift side)

final class LaTeXProjectTests: DocumentsTestCase {
    func testInputIncludeAndComments() throws {
        try file("sections/intro.tex", "Intro text \\input{sections/deep}")
        try file("sections/deep.tex", "Deep text")
        try file("results.tex", "Results text")
        let main = try file("main.tex", """
        \\documentclass{article}
        \\begin{document}
        \\input{sections/intro}
        \\include{results}
        % \\input{commented}
        \\begin{verbatim}
        \\input{verbatim-only}
        \\end{verbatim}
        \\input{missing-file}
        \\end{document}
        """)
        let project = try LaTeXProject.load(main)
        XCTAssertTrue(project.source.contains("Intro text Deep text"))
        XCTAssertTrue(project.source.contains("Results text"))
        XCTAssertTrue(project.source.contains("% \\input{commented}"))
        XCTAssertTrue(project.source.contains("\\input{verbatim-only}"))
        XCTAssertTrue(project.source.contains("\\greecemissing{missing-file}"))
        XCTAssertEqual(project.files.count, 3)
        XCTAssertEqual(project.missing, ["missing-file"])
    }

    func testIncludeCyclesStop() throws {
        try file("a.tex", "A \\input{b}")
        try file("b.tex", "B \\input{a}")
        let main = try file("main.tex", "\\input{a} \\input{main}")
        let project = try LaTeXProject.load(main)
        XCTAssertTrue(project.source.contains("A B"))
        XCTAssertTrue(project.source.contains("includes itself"))
    }

    func testIncludeDepthIsLimited() throws {
        for n in 0..<30 { try file("f\(n).tex", "level\(n) \\input{f\(n + 1)}") }
        let project = try LaTeXProject.load(try file("main.tex", "\\input{f0}"))
        XCTAssertTrue(project.source.contains("nested too deeply"))
        XCTAssertLessThanOrEqual(project.files.count, LaTeXProject.depthLimit)
    }

    func testIncludesStayInsideTheProject() throws {
        let outside = directory.appendingPathComponent("secret.tex")
        try "SECRET".write(to: outside, atomically: true, encoding: .utf8)
        let project = try LaTeXProject.load(try file("project/main.tex", "\\input{../secret} \\input{/etc/passwd} \\input{\(outside.path)}"))
        XCTAssertFalse(project.source.contains("SECRET"))
        XCTAssertFalse(project.source.contains("root:"))
        XCTAssertEqual(project.missing.count, 3)
    }

    func testSubfilesImportAndPgf() throws {
        try file("chapters/one.tex", "\\documentclass[../main]{subfiles}\n\\begin{document}\nChapter body\n\\end{document}")
        try file("figs/plot.tex", "Imported")
        try file("figs/fig.pgf", "\\begin{pgfpicture}\\pgfpathrectangle{\\pgfpointorigin}{\\pgfqpoint{2in}{1in}}\\pgfusepath{use as bounding box, clip}\\pgfpathmoveto{\\pgfqpoint{0in}{0in}}\\pgfpathlineto{\\pgfqpoint{1in}{1in}}\\pgfusepath{stroke}\\end{pgfpicture}")
        let project = try LaTeXProject.load(try file("main.tex", "\\subfile{chapters/one} \\import{figs/}{plot} \\input{figs/fig.pgf}"))
        XCTAssertTrue(project.source.contains("Chapter body"))
        XCTAssertFalse(project.source.contains("subfiles}"))
        XCTAssertTrue(project.source.contains("Imported"))
        XCTAssertTrue(project.source.contains("\\includegraphics{greece-pgf-1}"))
        XCTAssertEqual(project.figures["greece-pgf-1"]?.kind, "svg")
        XCTAssertTrue(project.figures["greece-pgf-1"]?.svg?.hasPrefix("<svg") == true)
    }

    func testPaperFixture() throws {
        let project = try LaTeXProject.load(fixtures.appendingPathComponent("latex/paper/main.tex"))
        XCTAssertEqual(project.files.count, 3)            // method, results, loss.pgf
        XCTAssertEqual(project.bibliography.count, 12)
        XCTAssertEqual(project.figures["figures/attention.png"]?.kind, "image")
        XCTAssertTrue(project.figures["figures/attention.png"]?.src?.hasPrefix("greece://file/") == true)
        XCTAssertEqual(project.figures["figures/pipeline"]?.kind, "pdf")
        XCTAssertEqual(project.pdfFigures.count, 1)
        let png = try XCTUnwrap(LaTeXProject.renderPDF(try XCTUnwrap(project.pdfFigures.values.first)))
        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertTrue(project.figures.values.contains { $0.kind == "svg" })
        XCTAssertGreaterThan(TeXText.wordCount(project.source), 800)
    }

    func testSectionsBorrowTheirMainFile() throws {
        let section = fixtures.appendingPathComponent("latex/paper/sections/method.tex")
        let project = try LaTeXProject.load(section)
        XCTAssertEqual(project.host?.lastPathComponent, "main.tex")
        XCTAssertTrue(project.source.contains("\\newcommand{\\topk}"))
        XCTAssertTrue(project.source.contains("\\bibliographystyle{plainnat}"))
        XCTAssertEqual(project.bibliography.count, 12)
        XCTAssertEqual(project.figures["figures/pipeline"]?.kind, "pdf")
        XCTAssertNil(LaTeXProject.hostDocument(for: fixtures.appendingPathComponent("latex/paper/main.tex"), text: "\\documentclass{article}"))
        XCTAssertNil(LaTeXProject.hostDocument(for: try file("loose.tex", "Just a fragment."), text: "Just a fragment."))
    }

    func testSweaveChunks() {
        let latex = Sweave.latex("Text\n<<plot, echo=FALSE>>=\nx %>% filter(y > 1)\n@\n\\Sexpr{1+1}")
        XCTAssertTrue(latex.contains("\\begin{greececode}{plot}{echo=FALSE}"))
        XCTAssertTrue(latex.contains("x %>% filter(y > 1)"))
        XCTAssertTrue(latex.contains("\\end{greececode}"))
    }

    func testPlainTextHelpers() {
        XCTAssertEqual(TeXText.tidy(TeXText.plain("Sch\\\"onberg and Ren\\'e met \\emph{twice}---in 1920.")), "Schönberg and René met twice—in 1920.")
        XCTAssertEqual(TeXText.argument(of: "title", in: "% \\title{No}\n\\title[short]{Real {Title}}"), "Real {Title}")
        XCTAssertEqual(TeXText.authors("A. One\\thanks{x} \\and B. Two \\\\ Affil"), ["A. One", "B. Two"])
    }
}

// MARK: - LaTeX converter (latex.js in JavaScriptCore)

final class LaTeXConverterTests: DocumentsTestCase {
    func testStructureNumberingAndReferences() throws {
        let result = try convert("""
        \\documentclass{article}
        \\title{T}\\author{A \\and B}\\date{}
        \\begin{document}\\maketitle
        \\section{One}\\label{s1}
        See Section~\\ref{s2} and Eq.~\\eqref{e1}.
        \\begin{equation}\\label{e1} a = b \\end{equation}
        \\subsection{One A}
        \\section*{Unnumbered}
        \\section{Two}\\label{s2}
        \\begin{figure}\\caption{Cap}\\label{f1}\\end{figure}
        Figure~\\ref{f1}.\\footnote{A note.}
        \\end{document}
        """)
        let html = try XCTUnwrap(result["html"] as? String)
        XCTAssertTrue(html.contains("<span class=\"num\">1</span>One"))
        XCTAssertTrue(html.contains("<span class=\"num\">1.1</span>One A"))
        XCTAssertTrue(html.contains("<span class=\"num\">2</span>Two"))
        XCTAssertTrue(html.contains(">2</a> and Eq.&nbsp;<a class=\"ref\""))
        XCTAssertTrue(html.contains(">(1)</a>"))
        XCTAssertTrue(html.contains("Figure 1:"))
        XCTAssertTrue(html.contains("tex-fn-1"))
        XCTAssertTrue(html.contains("class=\"tex-title\""))
        let labels = try XCTUnwrap(result["labels"] as? [String: String])
        XCTAssertEqual(labels, ["s1": "1", "s2": "2", "e1": "1", "f1": "1"])
        let math = try XCTUnwrap(result["math"] as? [[String: Any]])
        XCTAssertTrue((math.first?["tex"] as? String)?.contains("\\tag{1}") == true)
    }

    func testCitationsAuthorYearAndNumeric() throws {
        let bib: [[String: Any]] = [
            ["type": "article", "key": "smith", "fields": ["author": "Smith, Jane and Doe, John", "title": "A", "year": "2020", "journal": "J"]],
            ["type": "book", "key": "lee", "fields": ["author": "Lee, Ann and Kim, B. and Park, C.", "title": "B", "year": "2018", "publisher": "P"]],
        ]
        let authorYear = try convert("\\usepackage{natbib}\\begin{document}\\citep{smith,lee} \\citet{lee}\\bibliographystyle{plainnat}\\bibliography{x}\\end{document}", options: ["bib": bib])
        let a = try XCTUnwrap(authorYear["html"] as? String)
        XCTAssertTrue(a.contains("Smith and Doe, 2020"))
        XCTAssertTrue(a.contains("Lee et al. <a"))
        XCTAssertTrue(a.contains("References"))
        let numeric = try convert("\\begin{document}\\cite{lee,smith,missing}\\bibliographystyle{plain}\\bibliography{x}\\end{document}", options: ["bib": bib])
        let n = try XCTUnwrap(numeric["html"] as? String)
        XCTAssertTrue(n.contains("[<a class=\"cite\" href=\"#bib-1\">1</a>, <a class=\"cite\" href=\"#bib-2\">2</a>, <span class=\"cite missing\""))
        XCTAssertTrue(n.contains("bib-label\">[1]"))
    }

    func testThebibliography() throws {
        let result = try convert("\\begin{document}See \\cite{b}.\\begin{thebibliography}{9}\\bibitem{a} First.\\bibitem{b} Second.\\end{thebibliography}\\end{document}")
        let html = try XCTUnwrap(result["html"] as? String)
        XCTAssertTrue(html.contains("href=\"#bib-2\">2</a>"))
        XCTAssertTrue(html.contains("Second."))
    }

    func testTablesListsAndTheorems() throws {
        let result = try convert("""
        \\begin{document}
        \\begin{tabular}{lr}\\toprule A & B \\\\ \\midrule \\multicolumn{2}{c}{wide} \\\\ x & 1 \\\\ \\bottomrule\\end{tabular}
        \\begin{enumerate}\\item one \\begin{enumerate}\\item inner\\end{enumerate}\\item two\\end{enumerate}
        \\newtheorem{theorem}{Theorem}
        \\begin{theorem}[Name] Body.\\end{theorem}
        \\begin{proof} Done. \\end{proof}
        \\end{document}
        """)
        let html = try XCTUnwrap(result["html"] as? String)
        XCTAssertTrue(html.contains("<table class=\"tabular bottom-bottom\">"))
        XCTAssertTrue(html.contains("colspan=\"2\""))
        XCTAssertTrue(html.contains("<span class=\"lbl\">1.</span>"))
        XCTAssertTrue(html.contains("<span class=\"lbl\">(a)</span>"))
        XCTAssertTrue(html.contains("Theorem 1</span> <span class=\"thm-note\">(Name)"))
        XCTAssertTrue(html.contains("class=\"qed\""))
    }

    func testBeamerFramesBecomeSlides() throws {
        let result = try convert("""
        \\documentclass{beamer}\\title{Talk}\\author{Me}
        \\begin{document}
        \\begin{frame}\\titlepage\\end{frame}
        \\section{Intro}
        \\begin{frame}{First}\\begin{itemize}\\item<2-> a \\pause \\item b\\end{itemize}\\end{frame}
        \\begin{frame}\\frametitle{Second}\\begin{block}{Note}x\\end{block}\\end{frame}
        \\end{document}
        """)
        XCTAssertEqual(result["kind"] as? String, "beamer")
        let slides = try XCTUnwrap(result["slides"] as? [[String: Any]])
        XCTAssertEqual(slides.count, 3)
        XCTAssertEqual(slides[0]["isTitle"] as? Bool, true)
        XCTAssertEqual(slides[1]["title"] as? String, "First")
        XCTAssertEqual(slides[1]["section"] as? String, "Intro")
        XCTAssertEqual(slides[2]["title"] as? String, "Second")
        XCTAssertTrue((slides[2]["html"] as? String)?.contains("slide-block") == true)
    }

    func testUnknownCommandsKeepTheirText() throws {
        let html = try XCTUnwrap(try convert("\\begin{document}\\mysterious[opt]{Kept text} and \\begin{weirdenv}inside\\end{weirdenv}\\end{document}")["html"] as? String)
        XCTAssertTrue(html.contains("Kept text"))
        XCTAssertTrue(html.contains("inside"))
    }

    func testMacroBombsStop() throws {
        let start = Date()
        let result = try convert("\\def\\a{\\a\\a}\\a \\newcommand{\\b}{\\b x}\\b")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        XCTAssertNotNil(result["stopped"] as? String)
    }

    func testDeepNestingStops() throws {
        let deep = String(repeating: "{", count: 100_000) + "x" + String(repeating: "}", count: 100_000)
        let result = try convert("\\begin{document}" + deep + "\\end{document}")
        XCTAssertNotNil(result["html"])
        let unbalanced = try convert(String(repeating: "\\begin{itemize}\\item ", count: 5000))
        XCTAssertNotNil(unbalanced["html"])
    }

    func testHugeDocumentIsTimeBounded() throws {
        let paragraph = "Some text with $x^2$ math and \\textbf{bold}. "
        let huge = "\\begin{document}" + String(repeating: paragraph + "\n\n", count: 40_000) + "\\end{document}"
        let start = Date()
        let result = try convert(huge)
        XCTAssertLessThan(Date().timeIntervalSince(start), 12)
        XCTAssertNotNil(result["html"])
    }

    func testHostileMarkupIsEscaped() throws {
        let html = try XCTUnwrap(try convert("""
        \\begin{document}
        <script>alert(1)</script> <img src=x onerror=alert(1)>
        \\href{javascript:alert(1)}{click} \\url{javascript:alert(2)}
        \\includegraphics{"><script>alert(3)</script>}
        \\textcolor{red;background:url(x)}{c}
        \\end{document}
        """)["html"] as? String)
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<img src=x"))
        XCTAssertFalse(html.contains("href=\"javascript"))
        XCTAssertFalse(html.contains("url(x)"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testFiguresOnlyUseGreeceURLs() throws {
        let figures: [String: Any] = ["evil": ["kind": "image", "src": "https://example.com/x.png"], "good": ["kind": "image", "src": "greece://file/tmp/a.png", "width": 100]]
        let html = try XCTUnwrap(try convert("\\begin{document}\\includegraphics{evil}\\includegraphics[width=0.5\\linewidth]{good}\\end{document}", options: ["figures": figures])["html"] as? String)
        XCTAssertFalse(html.contains("example.com"))
        XCTAssertTrue(html.contains("src=\"greece://file/tmp/a.png\""))
        XCTAssertTrue(html.contains("width:50.0%"))
    }

    func testFixturesConvertCompletely() throws {
        for path in ["latex/paper/main.tex", "latex/notes.tex", "latex/beamer/talk.tex"] {
            let project = try LaTeXProject.load(fixtures.appendingPathComponent(path))
            let bib = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(project.bibliography))
            let result = try convert(project.source, options: ["bib": bib])
            XCTAssertNil(result["stopped"] as? String, path)
            XCTAssertNil(result["error"] as? String, path)
            let html = (result["html"] as? String ?? "") + ((result["slides"] as? [[String: Any]])?.compactMap { $0["html"] as? String }.joined() ?? "")
            XCTAssertFalse(html.contains("??"), "unresolved reference in \(path)")
            XCTAssertFalse(html.contains("cite missing"), "missing citation in \(path)")
        }
    }
}

// MARK: - EPUB

final class EPUBTests: DocumentsTestCase {
    private func book(chapter: String) throws -> URL {
        try epub("book.epub", files: [
            ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"),
            ("OEBPS/content.opf", """
            <package version="3.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata>
            <dc:title id="t">Book &amp; Title</dc:title><dc:creator id="c1">Jane Author</dc:creator><meta refines="#c1" property="role">aut</meta>
            <dc:creator id="c2">Ill Ustrator</dc:creator><meta refines="#c2" property="role">ill</meta>
            <dc:identifier>urn:isbn:978-0-306-40615-7</dc:identifier><dc:language>en</dc:language><dc:publisher>Pub</dc:publisher>
            <dc:subject>Fiction</dc:subject><dc:description>&lt;p&gt;Blurb&lt;/p&gt;</dc:description></metadata>
            <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
            <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
            """),
            ("OEBPS/nav.xhtml", "<html><body><nav epub:type=\"toc\"><ol><li><a href=\"text/ch1.xhtml\">One</a><ol><li><a href=\"text/ch1.xhtml#s\">One A</a></li></ol></li><li><a href=\"text/ch2.xhtml\">Two</a></li></ol></nav></body></html>"),
            ("OEBPS/text/ch1.xhtml", chapter),
            ("OEBPS/text/ch2.xhtml", "<html><body><h1>Two</h1><p>" + String(repeating: "Words here. ", count: 100) + "</p></body></html>"),
        ], rawFiles: [("OEBPS/images/cover.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))])
    }

    func testMetadataCoverAndContents() throws {
        let url = try book(chapter: "<html><body><h1>One</h1><p>" + String(repeating: "Some story text. ", count: 80) + "</p></body></html>")
        XCTAssertEqual(format(url), .epub)
        let book = try EPUBBook(url: url)
        XCTAssertEqual(book.title, "Book & Title")
        XCTAssertEqual(book.creators.map(\.name), ["Jane Author"])
        XCTAssertEqual(book.contributors.first?.role, "ill")
        XCTAssertEqual(book.isbn, "978-0-306-40615-7")
        XCTAssertEqual(book.coverPath, "OEBPS/images/cover.png")
        XCTAssertEqual(book.toc.map(\.title), ["One", "Two"])
        XCTAssertEqual(book.toc.first?.children.first?.anchor, "s")
        XCTAssertEqual(book.toc.last?.chapter, 1)
        XCTAssertEqual(book.firstChapter(), 0)
        let chapter = try XCTUnwrap(book.chapterHTML(0))
        XCTAssertEqual(chapter.title, "One")
        XCTAssertGreaterThan(book.wordCount().words, 300)
    }

    func testHostileChapterIsSanitised() throws {
        let hostile = """
        <html><head><script>alert(1)</script><style>body{background:url(https://evil.example/x)}</style>
        <link rel="stylesheet" href="https://evil.example/s.css"/></head><body>
        <h1 onclick="alert(2)">Title</h1>
        <p style="background:url(https://evil.example/y)">Text <a href="javascript:alert(3)">js</a> <a href="https://ok.example/">web</a>
        <a href="ch2.xhtml#x">next</a> <a href="#local">here</a></p>
        <img src="https://evil.example/track.png"/><img src="../images/cover.png" onerror="alert(4)"/>
        <iframe src="https://evil.example/"></iframe><object data="x.swf"></object><form action="https://evil.example"><input name="q"/></form>
        <svg><script>alert(5)</script><image xlink:href="../images/cover.png"/></svg>
        <math><mi>x</mi><annotation-xml encoding="text/html"><script>alert(6)</script></annotation-xml></math>
        <p id="local">Target &lt;b&gt;not bold&lt;/b&gt;</p><scr<script>ipt>alert(7)</script>
        </body></html>
        """
        let book = try EPUBBook(url: try book(chapter: hostile))
        let html = try XCTUnwrap(book.chapterHTML(0)?.html)
        for bad in ["<script", "onclick", "onerror", "javascript:", "evil.example", "<style", "<link", "<iframe", "<object", "<form", "<input", "style=", "<scr"] {
            XCTAssertFalse(html.lowercased().contains(bad), "sanitised chapter still contains \(bad): \(html)")
        }
        XCTAssertTrue(html.contains("href=\"https://ok.example/\""))
        XCTAssertTrue(html.contains("data-chapter=\"1\""))
        XCTAssertTrue(html.contains("href=\"#c0-local\""))
        XCTAssertTrue(html.contains("id=\"c0-local\""))
        XCTAssertTrue(html.contains("src=\"greece://module/item/OEBPS/images/cover.png\""))
        XCTAssertTrue(html.contains("&lt;b&gt;not bold&lt;/b&gt;"))
        XCTAssertTrue(html.contains("<mi>x</mi>"))
    }

    func testPathsCannotEscapeTheArchive() throws {
        let book = try EPUBBook(url: try book(chapter: "<p>x</p>"))
        XCTAssertEqual(book.resolve("../../../../etc/passwd", relativeTo: "OEBPS/text/ch1.xhtml"), "etc/passwd")
        XCTAssertEqual(book.resolve("/abs/x.png", relativeTo: "OEBPS/text/ch1.xhtml"), "abs/x.png")
        XCTAssertNil(book.archive.contents(named: "etc/passwd"))
        XCTAssertNil(book.archive.contents(named: "OEBPS/../../etc/passwd"))
    }

    func testCorruptBooksFailCleanly() throws {
        XCTAssertThrowsError(try EPUBBook(url: try file("bad.epub", "PK\u{3}\u{4}garbage")))
        XCTAssertThrowsError(try EPUBBook(url: try epub("nocontainer.epub", files: [("x.txt", "x")])))
        XCTAssertThrowsError(try EPUBBook(url: try epub("noopf.epub", files: [("META-INF/container.xml", "<rootfile full-path=\"missing.opf\"/>")])))
    }

    func testFixtureBooks() throws {
        let alice = try EPUBBook(url: fixtures.appendingPathComponent("epub/alice.epub"))
        XCTAssertEqual(alice.title, "Alice’s Adventures in Wonderland")
        XCTAssertEqual(alice.creators.map(\.name), ["Lewis Carroll"])
        XCTAssertEqual(alice.isbn, "9781234567897")
        XCTAssertNotNil(alice.coverPath)
        XCTAssertEqual(alice.subjects.count, 2)
        XCTAssertGreaterThanOrEqual(alice.toc.count, 3)
        let first = alice.firstChapter()
        XCTAssertTrue(alice.chapterHTML(first)?.html.contains("Rabbit") == true)
        let fables = try EPUBBook(url: fixtures.appendingPathComponent("epub/minimal-epub2.epub"))
        XCTAssertEqual(fables.version, "2.0")
        XCTAssertNotNil(fables.coverPath)
        XCTAssertEqual(fables.toc.count, 2)
    }
}

// MARK: - Org, AsciiDoc, reStructuredText, notebook Markdown

final class ProseConversionTests: DocumentsTestCase {
    func testOrg() {
        let doc = OrgConverter.convert("""
        #+TITLE: Plan
        #+AUTHOR: Ann
        #+FILETAGS: :work:
        * TODO [#A] Write it [1/2] :docs:urgent:
        DEADLINE: <2026-04-15 Wed>
        - [X] outline
        - [ ] draft
        * DONE Ship
        Some *bold*, /italic/, =code=, +gone+ and [[https://orgmode.org][Org]].
        | a | b |
        |---+---|
        | 1 | 2 |
        #+BEGIN_SRC python
        print("hi")
        #+END_SRC
        #+BEGIN_NOTE
        Careful.
        #+END_NOTE
        <script>alert(1)</script>
        """)
        XCTAssertEqual(doc.title, "Plan")
        XCTAssertEqual(doc.authors, ["Ann"])
        XCTAssertEqual(doc.tags, ["work"])
        XCTAssertEqual(doc.tasks.open, 1)
        XCTAssertEqual(doc.tasks.done, 1)
        let md = doc.markdown
        XCTAssertTrue(md.contains("<span class=\"org-todo todo\">TODO</span>"))
        XCTAssertTrue(md.contains("org-priority pa"))
        XCTAssertTrue(md.contains("<span class=\"org-tag\">urgent</span>"))
        XCTAssertTrue(md.contains("org-cookie"))
        XCTAssertTrue(md.contains("Deadline"))
        XCTAssertTrue(md.contains("- [x] outline"))
        XCTAssertTrue(md.contains("<strong>bold</strong>"))
        XCTAssertTrue(md.contains("<code>code</code>"))
        XCTAssertTrue(md.contains("[Org](https://orgmode.org)"))
        XCTAssertTrue(md.contains("| a | b |"))
        XCTAssertTrue(md.contains("```python\nprint(\"hi\")\n```"))
        XCTAssertTrue(md.contains("> [!NOTE]"))
        XCTAssertFalse(md.contains("<script>"))
    }

    func testAsciiDoc() {
        let doc = AsciiDocConverter.convert("""
        = Guide
        Jane Doe <jane@example.com>
        v1.2, 2026-01-02
        :product: Widget

        == Use {product}

        NOTE: Be careful with {product}.

        [source,ruby]
        ----
        puts 1
        ----

        [cols="1,1",options="header"]
        |===
        | Option | Value
        | name | widget
        |===

        * item *strong* `mono` link:https://example.com[site] footnote:[A
        note spanning lines]
        """)
        XCTAssertEqual(doc.title, "Guide")
        XCTAssertEqual(doc.authors, ["Jane Doe"])
        XCTAssertEqual(doc.date, "2026-01-02")
        let md = doc.markdown
        XCTAssertTrue(md.contains("## Use Widget"))
        XCTAssertTrue(md.contains("> [!NOTE]"))
        XCTAssertTrue(md.contains("Be careful with Widget."))
        XCTAssertTrue(md.contains("```ruby\nputs 1\n```"))
        XCTAssertTrue(md.contains("| Option | Value |"))
        XCTAssertTrue(md.contains("| name | widget |"))
        XCTAssertTrue(md.contains("<strong>strong</strong>"))
        XCTAssertTrue(md.contains("[site](https://example.com)"))
    }

    func testRestructuredText() {
        let doc = RSTConverter.convert("""
        =======
        Project
        =======
        --------
        Subtitle
        --------

        :Author: Ann
        :Version: 2.0

        Usage
        =====

        Read the `docs <https://example.com>`_ and run ``tool``::

            $ tool --help

        .. note:: Mind the gap.

        .. code-block:: python

            def f():
                return 1

        =====  =====
        A      B
        =====  =====
        1      2
        =====  =====

        .. image:: pic.png
           :alt: A picture
        """)
        XCTAssertEqual(doc.title, "Project")
        XCTAssertEqual(doc.subtitle, "Subtitle")
        XCTAssertEqual(doc.authors, ["Ann"])
        XCTAssertEqual(doc.meta.first, ["Version", "2.0"])
        let md = doc.markdown
        XCTAssertTrue(md.contains("## Usage"))
        XCTAssertTrue(md.contains("[docs](https://example.com)"))
        XCTAssertTrue(md.contains("<code>tool</code>"))
        XCTAssertTrue(md.contains("```\n$ tool --help\n```"))
        XCTAssertTrue(md.contains("> [!NOTE]"))
        XCTAssertTrue(md.contains("```python\ndef f():\n    return 1\n```"))
        XCTAssertTrue(md.contains("| A | B |"))
        XCTAssertTrue(md.contains("![A picture](pic.png)"))
    }

    func testNotebookMarkdown() {
        let rmd = NotebookMarkdown.convert("""
        ---
        title: "Report"
        author:
          - name: Ann
          - Bob
        date: "`r Sys.Date()`"
        output: html_document
        ---

        ```{r plot, echo=FALSE, fig.cap="A, B"}
        plot(x)
        ```
        Mean is `r mean(x)`.
        """, format: "R Markdown")
        XCTAssertEqual(rmd.title, "Report")
        XCTAssertEqual(rmd.authors, ["Ann", "Bob"])
        XCTAssertEqual(rmd.date?.count, 10)
        XCTAssertTrue(rmd.markdown.contains("<span class=\"chip\">plot</span><span class=\"chip\">echo=FALSE</span><span class=\"chip\">fig.cap=&quot;A, B&quot;</span>"))
        XCTAssertTrue(rmd.markdown.contains("```r\nplot(x)\n```"))
        XCTAssertTrue(rmd.markdown.contains("<code class=\"inline-chunk\">mean(x)</code>"))
        let qmd = NotebookMarkdown.convert("""
        ::: {.callout-warning title="Careful"}
        Body text.
        :::

        ```{python}
        #| label: fig-x
        #| fig-cap: "Plot"
        x = 1
        ```

        See @fig-x and @eq-a.

        $$ y = x $$ {#eq-a}
        """, format: "Quarto")
        XCTAssertTrue(qmd.markdown.contains("> [!WARNING]"))
        XCTAssertTrue(qmd.markdown.contains("> **Careful**"))
        XCTAssertTrue(qmd.markdown.contains("<span class=\"chip\">fig-x</span>"))
        XCTAssertFalse(qmd.markdown.contains("#|"))
        XCTAssertTrue(qmd.markdown.contains("Figure 1"))
        XCTAssertTrue(qmd.markdown.contains("Equation (1)"))
        XCTAssertTrue(qmd.markdown.contains("\\tag{1}$$"))
    }

    func testMarkdownEscapingKeepsTextLiteral() {
        XCTAssertEqual(MD.escape("*a* <b> $1 [x](y)"), "\\*a\\* \\<b\\> \\$1 \\[x\\](y)")
        XCTAssertNil(MD.url("javascript:alert(1)"))
        XCTAssertNil(MD.url("data:text/html,x"))
        XCTAssertEqual(MD.url("https://a.example/b c"), "https://a.example/b%20c")
        XCTAssertEqual(MD.url("img/a.png"), "img/a.png")
    }

    func testConvertersSurviveHostileInput() {
        let junk = [String(repeating: "*", count: 20_000), String(repeating: "[[", count: 5000), String(repeating: "|", count: 5000),
                    String(repeating: "#+BEGIN_SRC\n", count: 1000), String(repeating: "=", count: 10_000), String(repeating: ".. note::\n  ", count: 2000),
                    String(repeating: "----\n", count: 2001), String(repeating: "::: {.callout-note}\n", count: 3000), "---\n" + String(repeating: "  - a:\n", count: 2000)]
        for text in junk {
            _ = OrgConverter.convert(text)
            _ = AsciiDocConverter.convert(text)
            _ = RSTConverter.convert(text)
            _ = NotebookMarkdown.convert(text, format: "Quarto")
        }
    }
}

// MARK: - PGF

final class PGFTests: DocumentsTestCase {
    func testMatplotlibFixture() throws {
        let text = try String(contentsOf: fixtures.appendingPathComponent("latex/paper/figures/loss.pgf"), encoding: .utf8)
        let picture = try XCTUnwrap(PGF.parse(text))
        XCTAssertEqual(picture.bounds.width, 4.6 * 72, accuracy: 0.5)
        XCTAssertEqual(picture.bounds.height, 2.9 * 72, accuracy: 0.5)
        XCTAssertGreaterThan(picture.pathCount, 20)
        XCTAssertGreaterThanOrEqual(picture.textCount, 12)
        let svg = PGF.svg(picture)
        XCTAssertTrue(svg.contains("training step"))
        XCTAssertTrue(svg.contains("validation loss ℓ"))
        XCTAssertTrue(svg.contains("stroke-dasharray"))
        XCTAssertTrue(svg.contains("clip-path"))
        XCTAssertFalse(svg.contains("pgfscope"))
        XCTAssertFalse(svg.contains("12.000000"))
    }

    func testTextIsEscapedAndLimitsHold() throws {
        let hostile = "\\begin{pgfpicture}\\pgfpathrectangle{\\pgfpointorigin}{\\pgfqpoint{1in}{1in}}\\pgfusepath{use as bounding box}\\pgftext[x=0in,y=0in]{<script>alert(1)</script>}\\end{pgfpicture}"
        let svg = PGF.svg(try XCTUnwrap(PGF.parse(hostile)))
        XCTAssertFalse(svg.contains("<script"))
        XCTAssertTrue(svg.contains("&lt;script&gt;"))
        let huge = "\\begin{pgfpicture}" + String(repeating: "\\pgfpathlineto{\\pgfqpoint{1in}{1in}}", count: 500_000) + "\\pgfusepath{stroke}"
        let start = Date()
        _ = PGF.parse(huge)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        XCTAssertNil(PGF.parse("not pgf at all"))
        let recursive = "\\pgfsys@defobject{a}{}{}{\\pgfsys@useobject{a}{}}\\pgfsys@useobject{a}{}"
        _ = PGF.parse(recursive)
    }
}

// MARK: - Module previews and thumbnails

final class DocumentPreviewTests: DocumentsTestCase {
    private var fixtureFiles: [URL] {
        let paths = ["latex/paper/main.tex", "latex/notes.tex", "latex/beamer/talk.tex", "latex/paper/figures/loss.pgf", "bib/library.bib",
                     "epub/alice.epub", "epub/minimal-epub2.epub", "org/project.org", "asciidoc/guide.adoc", "rst/readme.rst",
                     "quarto/analysis.qmd", "rmarkdown/report.Rmd", "sweave/report.Rnw", "livebook/intro.livemd", "mermaid/flowchart.mmd",
                     "mermaid/sequence.mermaid", "typst/report.typ"]
        return paths.map { fixtures.appendingPathComponent($0) }
    }

    func testEveryFixturePreparesAWebPage() throws {
        for url in fixtureFiles {
            let info = FileInfo(url: url)
            XCTAssertTrue(DocumentsModule.claims(info), url.lastPathComponent)
            guard case .web(let document, let summary, _) = try DocumentsModule.prepare(info, settings: PreviewSettings()) else {
                XCTFail("not a web page: \(url.lastPathComponent)"); continue
            }
            let html = document.html(settings: PreviewSettings())
            XCTAssertTrue(html.contains("Content-Security-Policy"), url.lastPathComponent)
            XCTAssertFalse(summary.title.isEmpty)
            XCTAssertFalse(summary.details.isEmpty, url.lastPathComponent)
        }
    }

    func testReadingFactsInSummaries() throws {
        guard case .web(_, let summary, _) = try DocumentsModule.prepare(FileInfo(url: fixtures.appendingPathComponent("latex/paper/main.tex")), settings: PreviewSettings()) else { return XCTFail() }
        XCTAssertTrue(summary.details.contains { $0.hasSuffix("words") })
        XCTAssertTrue(summary.details.contains { $0.hasSuffix("min read") })
        XCTAssertTrue(summary.details.contains("12 references"))
        guard case .web(let epub, let book, _) = try DocumentsModule.prepare(FileInfo(url: fixtures.appendingPathComponent("epub/alice.epub")), settings: PreviewSettings()) else { return XCTFail() }
        XCTAssertEqual(book.details.first, "Lewis Carroll")
        let cover = try XCTUnwrap(epub.resources?("item/OEBPS/images/cover.jpg"))
        XCTAssertEqual(cover.mimeType, "image/jpeg")
        XCTAssertNil(epub.resources?("item/META-INF/container.xml"))     // not an image
        XCTAssertNil(epub.resources?("chapter/999"))
        XCTAssertNotNil(epub.resources?("chapter/2"))
    }

    func testThumbnailsDrawForEveryFormat() throws {
        for url in fixtureFiles {
            let info = FileInfo(url: url)
            let page = try XCTUnwrap(DocumentsModule.thumbnail(info, size: CGSize(width: 256, height: 256), settings: PreviewSettings()), url.lastPathComponent)
            XCTAssertLessThanOrEqual(page.size.width, 256)
            XCTAssertLessThanOrEqual(page.size.height, 256)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(page.size.width), pixelsHigh: Int(page.size.height), bitsPerSample: 8,
                                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            page.draw()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func testEPUBThumbnailIsTheCoverAndPaperIsTypeset() throws {
        let page = try XCTUnwrap(DocumentsModule.thumbnail(FileInfo(url: fixtures.appendingPathComponent("epub/alice.epub")), size: CGSize(width: 512, height: 512), settings: PreviewSettings()))
        XCTAssertEqual(page.badge, "EPUB")
        XCTAssertEqual(page.size.width / page.size.height, 600.0 / 900.0, accuracy: 0.02)
        let paper = DocumentThumbnails.Paper(try String(contentsOf: fixtures.appendingPathComponent("latex/paper/main.tex"), encoding: .utf8))
        XCTAssertEqual(paper.title, "Sparse Attention for Long-Context Retrieval")
        XCTAssertEqual(paper.authors.count, 3)
        XCTAssertTrue(paper.abstract?.hasPrefix("Transformer language models") == true)
        XCTAssertEqual(paper.sections.first?.title, "Introduction")
        XCTAssertEqual(paper.sections.first?.number, "1")
        XCTAssertTrue(DocumentThumbnails.Paper(try String(contentsOf: fixtures.appendingPathComponent("latex/beamer/talk.tex"), encoding: .utf8)).isBeamer)
    }
}
