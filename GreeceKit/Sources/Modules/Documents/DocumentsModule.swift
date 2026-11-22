import AppKit

/// Documents: LaTeX projects and Beamer decks, BibTeX, EPUB books, Org, AsciiDoc and
/// reStructuredText, notebook-style Markdown (Quarto, R Markdown, Livebook, Sweave),
/// Mermaid diagrams, Typst and matplotlib PGF figures.
enum DocumentsModule: PreviewModule {
    static let id = "documents"

    enum Format: Equatable {
        case latex, sweave, bibtex, epub, org, asciidoc, rst, quarto, rmarkdown, livebook, mermaid, multiMarkdown, typst, pgf
    }

    /// The format a file is in, from its extension and first bytes. Cheap: runs for every file.
    static func format(_ file: FileInfo) -> Format? {
        guard !file.isDirectory else { return nil }
        let head = file.probe
        switch file.ext {
        case "epub":
            // A ZIP whose first member is the uncompressed "mimetype" file.
            let zip = head.hasPrefix([0x50, 0x4B, 0x03, 0x04])
            return zip ? .epub : nil
        case "tex", "ltx", "latex", "bbl":
            return head.isText ? .latex : nil
        case "rnw", "snw", "rtex":
            return head.isText ? .sweave : nil
        case "bib":
            return head.isText ? .bibtex : nil
        case "org":
            return head.isText ? .org : nil
        case "adoc", "asciidoc":
            return head.isText ? .asciidoc : nil
        case "rst", "rest":
            return head.isText ? .rst : nil
        case "qmd":
            return head.isText ? .quarto : nil
        case "rmd", "rmarkdown":
            return head.isText ? .rmarkdown : nil
        case "livemd":
            return head.isText ? .livebook : nil
        case "mermaid", "mmd":
            guard head.isText else { return nil }
            if file.ext == "mermaid" { return .mermaid }
            // .mmd is also MultiMarkdown: Mermaid files open with a diagram keyword.
            return MermaidDocument.diagramType(head.text) != nil ? .mermaid : .multiMarkdown
        case "typ":
            return head.isText ? .typst : nil
        case "pgf":
            let text = head.text
            return head.isText && (text.contains("\\begin{pgfpicture}") || text.contains("\\pgfpathmoveto") || text.contains("PGF backend")) ? .pgf : nil
        default:
            return nil
        }
    }

    static func claims(_ file: FileInfo) -> Bool { format(file) != nil }

    static func prepare(_ file: FileInfo, settings: PreviewSettings) throws -> PreparedPreview {
        guard let format = format(file) else { throw PreviewError.unsupported }
        switch format {
        case .latex, .sweave: return try LaTeXPreview.prepare(file, sweave: format == .sweave)
        case .pgf: return try LaTeXPreview.preparePGF(file)
        case .bibtex: return try BibTeXPreview.prepare(file)
        case .epub: return try EPUBPreview.prepare(file)
        case .org, .asciidoc, .rst, .quarto, .rmarkdown, .livebook, .multiMarkdown: return try ProsePreview.prepare(file, format: format)
        case .mermaid: return try MermaidDocument.prepare(file)
        case .typst: return try TypstPreview.prepare(file)
        }
    }

    static func thumbnail(_ file: FileInfo, size: CGSize, settings: PreviewSettings) -> ThumbnailPage? {
        guard let format = format(file) else { return nil }
        return DocumentThumbnails.page(for: file, format: format, size: size, settings: settings)
    }

    // MARK: - Shared facts

    /// "1,204 words", "6 min read".
    static func readingFacts(words: Int) -> [String] {
        guard words > 0 else { return [] }
        let minutes = Double(words) / 230
        let time: String
        if minutes < 1 {
            time = String(localized: "Under 1 min read", bundle: .greeceKit, comment: "Info bar detail: reading time of a short document")
        } else if minutes < 60 {
            let whole = Int(minutes.rounded())
            time = String(localized: "\(whole) min read", bundle: .greeceKit, comment: "Info bar detail: reading time of a document, in minutes")
        } else {
            let total = Int(minutes.rounded())
            let hours = total / 60
            let rest = total % 60
            time = rest > 0
                ? String(localized: "\(hours) h \(rest) min read", bundle: .greeceKit,
                         comment: "Info bar detail: reading time of a long document. The arguments are hours and minutes, such as “2 h 15 min read”")
                : String(localized: "\(hours) h read", bundle: .greeceKit, comment: "Info bar detail: reading time of a long document, in whole hours")
        }
        return [String(localized: "\(words) words", bundle: .greeceKit, comment: "Info bar detail: a document’s word count"), time]
    }

    /// "1 line", "1,204 lines", in English only. Being replaced: a count people see is a whole phrase
    /// with plural variations, `String(localized: "\(count) lines", bundle: .greeceKit)`.
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// Extra highlight.js grammars a page needs for its code (only ones that ship in the bundle).
    static func grammarScripts(_ languages: Set<String>) -> [String] {
        languages.compactMap { name -> String? in
            let lower = name.lowercased()
            let grammar = WebAssets.hasGrammar(lower) ? lower : LanguageCatalog.language(forExtension: lower)?.grammar
            guard let grammar, !LanguageCatalog.commonGrammars.contains(grammar), WebAssets.bundledGrammars.contains(grammar) else { return nil }
            return "vendor/highlight/languages/\(grammar).min.js"
        }.sorted()
    }
}
