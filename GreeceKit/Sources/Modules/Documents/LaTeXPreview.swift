import AppKit

/// LaTeX documents, Beamer decks and Sweave files, typeset by `modules/latex.js`.
enum LaTeXPreview {
    struct Payload: Encodable {
        var source: String
        var fileName: String
        var figures: [String: LaTeXProject.Figure]
        var bib: [BibEntry]
        var bbl: String?
        var files: [String]
        var missing: [String]
        var truncated: Bool
    }

    static func prepare(_ file: FileInfo, sweave: Bool) throws -> PreparedPreview {
        let project = try LaTeXProject.load(file.url, sweave: sweave)
        let root = project.mainURL.deletingLastPathComponent()
        let payload = Payload(
            source: project.source,
            fileName: file.url.lastPathComponent,
            figures: project.figures,
            bib: project.bibliography,
            bbl: project.bbl,
            files: project.files.map { relativePath($0, root: root) },
            missing: project.missing,
            truncated: project.truncated)

        var scripts = ["modules/latex.js", "modules/documents.js"]
        scripts.insert(contentsOf: DocumentsModule.grammarScripts(project.languages), at: 0)
        var document = WebDocument(module: .init("latex"), data: payload, scripts: scripts, styles: ["modules/documents.css"],
                                   libraries: [.math], baseDirectory: root)
        let pdfs = project.pdfFigures
        if !pdfs.isEmpty {
            document.resources = { path in
                guard let url = pdfs[path], let png = LaTeXProject.renderPDF(url) else { return nil }
                return (png, "image/png")
            }
        }

        var details: [String] = []
        let title: String
        if project.isBeamer {
            title = String(localized: "Beamer Slides", bundle: .greeceKit, comment: "Info bar title: a LaTeX slide deck made with Beamer")
            let frames = countFrames(project.source)
            details.append(String(localized: "\(frames) slides", bundle: .greeceKit, comment: "Info bar detail: slides in a presentation"))
        } else {
            title = sweave
                ? String(localized: "Sweave Document", bundle: .greeceKit, comment: "Info bar title: a LaTeX document with R code (Sweave)")
                : String(localized: "LaTeX Document", bundle: .greeceKit, comment: "Info bar title")
            details += DocumentsModule.readingFacts(words: TeXText.wordCount(project.source))
        }
        if let host = project.host {
            let name = host.lastPathComponent
            details.append(String(localized: "Part of \(name)", bundle: .greeceKit,
                                  comment: "Info bar detail: this LaTeX file is included by another. The argument is that file’s name, such as “thesis.tex”"))
        } else if !project.files.isEmpty {
            let files = project.files.count + 1
            details.append(String(localized: "\(files) files", bundle: .greeceKit, comment: "Info bar detail: files in a project"))
        }
        if !project.bibliography.isEmpty {
            let references = project.bibliography.count
            details.append(String(localized: "\(references) references", bundle: .greeceKit, comment: "Info bar detail: entries in a BibTeX file or cited by a LaTeX document"))
        }
        if !project.missing.isEmpty {
            let missing = project.missing.count
            details.append(String(localized: "\(missing) missing", bundle: .greeceKit, comment: "Info bar detail: files a LaTeX document includes that weren’t found"))
        }
        let summary = FileSummary(symbol: project.isBeamer ? "rectangle.on.rectangle" : "function", title: title, details: details, trailing: file.modifiedText)
        return .web(document, summary, NSSize(width: project.isBeamer ? 1040 : 980, height: 800))
    }

    static func preparePGF(_ file: FileInfo) throws -> PreparedPreview {
        guard let figure = LaTeXProject.pgfFigure(file.url), let svg = figure.svg else { throw PreviewError.unsupported }
        struct Payload: Encodable { var svg: String; var width: Double; var height: Double; var name: String }
        let payload = Payload(svg: svg, width: figure.width ?? 400, height: figure.height ?? 300, name: file.url.lastPathComponent)
        let document = WebDocument(module: .init("pgf"), data: payload, scripts: ["modules/documents.js"], styles: ["modules/documents.css"], libraries: [.math])
        var details: [String] = []
        if let w = figure.width, let h = figure.height {
            let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
            let width = (w / 72).formatted(style), height = (h / 72).formatted(style)
            details.append(String(localized: "\(width) × \(height) in", bundle: .greeceKit,
                                  comment: "Info bar detail: a figure’s width and height in inches, such as “6.4 × 4.8 in”"))
        }
        if let size = file.sizeText { details.append(size) }
        return .web(document, FileSummary(symbol: "chart.xyaxis.line", title: String(localized: "PGF Figure", bundle: .greeceKit, comment: "Info bar title: a figure exported from matplotlib or TikZ as PGF"), details: details, trailing: file.modifiedText),
                    NSSize(width: 900, height: 700))
    }

    static func countFrames(_ source: String) -> Int {
        var count = 0
        var rest = Substring(source)
        while let range = rest.range(of: "\\begin{frame}") { count += 1; rest = rest[range.upperBound...] }
        return count
    }

    static func relativePath(_ url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }
}

/// Typst source, highlighted (Greece ships its own Typst grammar).
enum TypstPreview {
    static func prepare(_ file: FileInfo) throws -> PreparedPreview {
        let text = try TextFile(url: file.url)
        let document = WebDocument(kind: .code, text: text.text, grammar: "typst", baseDirectory: file.url.deletingLastPathComponent(), truncated: text.truncated)
        let lines = text.lineCount
        var details = [String(localized: "\(lines) lines", bundle: .greeceKit, comment: "Info bar detail: lines in a text file")]
        details += DocumentsModule.readingFacts(words: PreviewFactory.wordCount(TypstPreview.prose(text.text))).prefix(1)
        if let size = file.sizeText { details.append(size) }
        return .web(document, FileSummary(symbol: "doc.text", title: "Typst", details: details, trailing: file.modifiedText), NSSize(width: 920, height: 720))
    }

    /// Rough prose of a Typst file for word counts: markup lines, not code or comments.
    static func prose(_ text: String) -> String {
        text.split(separator: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && !t.hasPrefix("//") && !t.hasPrefix("```")
        }.joined(separator: "\n")
    }
}
