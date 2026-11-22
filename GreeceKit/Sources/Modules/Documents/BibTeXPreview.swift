import AppKit

/// A .bib file as a reference list: formatted entries, types, keys, DOIs and links.
enum BibTeXPreview {
    struct Payload: Encodable {
        var entries: [BibEntry]
        var strings: Int
        var preambles: Int
        var comments: Int
        var truncated: Bool
        var fileName: String
    }

    static func prepare(_ file: FileInfo) throws -> PreparedPreview {
        let text = try TextFile(url: file.url, limit: 16 * 1024 * 1024)
        let library = BibTeX.parse(text.text)
        let payload = Payload(entries: library.entries, strings: library.strings.count, preambles: library.preambles.count,
                              comments: library.comments, truncated: library.truncated || text.truncated, fileName: file.url.lastPathComponent)
        let document = WebDocument(module: .init("bibtex"), data: payload, scripts: ["modules/latex.js", "modules/documents.js"],
                                   styles: ["modules/documents.css"], libraries: [.math])
        let references = library.entries.count
        var details = [String(localized: "\(references) references", bundle: .greeceKit, comment: "Info bar detail: entries in a BibTeX file or cited by a LaTeX document")]
        var types: [String: Int] = [:]
        for entry in library.entries { types[entry.type, default: 0] += 1 }
        for (type, n) in types.sorted(by: { $0.value > $1.value }).prefix(2) where library.entries.count > 1 {
            details.append(typeCount(type, n))
        }
        if library.truncated {
            details.append(String(localized: "Showing first \(references)", bundle: .greeceKit, comment: "Info bar detail: only this many references of a long BibTeX file are shown"))
        }
        return .web(document, FileSummary(symbol: "books.vertical", title: "BibTeX", details: details, trailing: file.modifiedText),
                    NSSize(width: 900, height: 760))
    }

    /// "12 articles", "1 book": how many entries of one BibTeX type a file holds.
    static func typeCount(_ type: String, _ n: Int) -> String {
        switch type {
        case "article": return String(localized: "\(n) articles", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "book": return String(localized: "\(n) books", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "booklet": return String(localized: "\(n) booklets", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "inbook": return String(localized: "\(n) chapters", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "incollection": return String(localized: "\(n) in collection", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "inproceedings", "conference": return String(localized: "\(n) conference papers", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "manual": return String(localized: "\(n) manuals", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "mastersthesis": return String(localized: "\(n) master’s theses", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "misc": return String(localized: "\(n) misc", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "phdthesis": return String(localized: "\(n) PhD theses", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "proceedings": return String(localized: "\(n) proceedings", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "techreport", "report": return String(localized: "\(n) reports", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "unpublished": return String(localized: "\(n) unpublished", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "online", "electronic", "www": return String(localized: "\(n) online", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "thesis": return String(localized: "\(n) theses", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "software": return String(localized: "\(n) software", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "dataset": return String(localized: "\(n) datasets", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "patent": return String(localized: "\(n) patents", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "collection": return String(localized: "\(n) collections", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        case "preprint": return String(localized: "\(n) preprints", bundle: .greeceKit, comment: "Info bar detail: entries of one BibTeX type in a .bib file")
        default:
            return String(localized: "\(n) \(type) entries", bundle: .greeceKit,
                          comment: "Info bar detail: how many entries of an unusual BibTeX entry type a .bib file holds. The second argument is the type as written in the file, such as “talk”")
        }
    }
}

/// .mermaid and .mmd diagrams, drawn full page by the bundled Mermaid.
enum MermaidDocument {
    struct Payload: Encodable { var source: String; var type: String; var title: String? }

    static let types: [(keyword: String, name: String)] = [
        ("flowchart", String(localized: "Flowchart", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("graph", String(localized: "Flowchart", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("sequenceDiagram", String(localized: "Sequence Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("classDiagram", String(localized: "Class Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("stateDiagram", String(localized: "State Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("erDiagram", String(localized: "Entity Relationship Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("journey", String(localized: "User Journey", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("gantt", String(localized: "Gantt Chart", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("pie", String(localized: "Pie Chart", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("quadrantChart", String(localized: "Quadrant Chart", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("requirementDiagram", String(localized: "Requirement Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("gitGraph", String(localized: "Git Graph", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("C4Context", String(localized: "C4 Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("C4Container", String(localized: "C4 Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("C4Component", String(localized: "C4 Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("C4Dynamic", String(localized: "C4 Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("C4Deployment", String(localized: "C4 Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("mindmap", String(localized: "Mind Map", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("timeline", String(localized: "Timeline", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("zenuml", String(localized: "ZenUML Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("sankey", String(localized: "Sankey Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("xychart", String(localized: "XY Chart", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("block", String(localized: "Block Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("packet", String(localized: "Packet Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("kanban", String(localized: "Kanban Board", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("architecture", String(localized: "Architecture Diagram", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("radar", String(localized: "Radar Chart", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
        ("treemap", String(localized: "Treemap", bundle: .greeceKit, comment: "Kind of Mermaid diagram")),
    ]

    /// The diagram's type from its first meaningful line (after front matter, directives and comments).
    static func diagramType(_ text: String) -> String? {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst()
            while let line = lines.first, line.trimmingCharacters(in: .whitespaces) != "---" { lines = lines.dropFirst() }
            lines = lines.dropFirst()
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("%%") { continue }
            let word = t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" || $0 == ":" }).first.map(String.init) ?? t
            let base = word.replacingOccurrences(of: "-beta", with: "").replacingOccurrences(of: "-v2", with: "")
            return types.first { $0.keyword == base }?.name
        }
        return nil
    }

    static func title(_ text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        for line in text.components(separatedBy: "\n").dropFirst().prefix(30) {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if line.hasPrefix("title:") {
                return line.dropFirst(6).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    static func prepare(_ file: FileInfo) throws -> PreparedPreview {
        let text = try TextFile(url: file.url, limit: 2 * 1024 * 1024)
        let type = diagramType(text.text) ?? String(localized: "Diagram", bundle: .greeceKit, comment: "Info bar detail: a Mermaid diagram of an unknown kind")
        let payload = Payload(source: text.text, type: type, title: title(text.text))
        let document = WebDocument(module: .init("mermaid-file"), data: payload, scripts: ["modules/documents.js"], styles: ["modules/documents.css"],
                                   libraries: [.diagrams, .math])
        let lines = text.lineCount
        let details = [type, String(localized: "\(lines) lines", bundle: .greeceKit, comment: "Info bar detail: lines in a text file")]
        return .web(document, FileSummary(symbol: "point.3.connected.trianglepath.dotted", title: "Mermaid", details: details, trailing: file.modifiedText),
                    NSSize(width: 1000, height: 720))
    }
}
