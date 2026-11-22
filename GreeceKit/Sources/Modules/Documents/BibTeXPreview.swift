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
        var details = [DocumentsModule.count(library.entries.count, "reference")]
        var types: [String: Int] = [:]
        for entry in library.entries { types[entry.type, default: 0] += 1 }
        for (type, n) in types.sorted(by: { $0.value > $1.value }).prefix(2) where library.entries.count > 1 {
            let name = (BibTeX.typeNames[type] ?? type.capitalized)
            details.append("\(n) \(n == 1 ? name.lowercased() : plural(name).lowercased())")
        }
        if library.truncated { details.append("Showing first \(library.entries.count.formatted())") }
        return .web(document, FileSummary(symbol: "books.vertical", title: "BibTeX", details: details, trailing: file.modifiedText),
                    NSSize(width: 900, height: 760))
    }

    private static func plural(_ name: String) -> String {
        switch name {
        case "PhD Thesis": return "PhD theses"
        case "Master’s Thesis": return "Master’s theses"
        case "Thesis": return "Theses"
        case "Misc": return "Misc"
        case "In Collection": return "In collection"
        default: return name.hasSuffix("s") ? name : name + "s"
        }
    }
}

/// .mermaid and .mmd diagrams, drawn full page by the bundled Mermaid.
enum MermaidDocument {
    struct Payload: Encodable { var source: String; var type: String; var title: String? }

    static let types: [(keyword: String, name: String)] = [
        ("flowchart", "Flowchart"), ("graph", "Flowchart"), ("sequenceDiagram", "Sequence Diagram"), ("classDiagram", "Class Diagram"),
        ("stateDiagram", "State Diagram"), ("erDiagram", "Entity Relationship Diagram"), ("journey", "User Journey"), ("gantt", "Gantt Chart"),
        ("pie", "Pie Chart"), ("quadrantChart", "Quadrant Chart"), ("requirementDiagram", "Requirement Diagram"), ("gitGraph", "Git Graph"),
        ("C4Context", "C4 Diagram"), ("C4Container", "C4 Diagram"), ("C4Component", "C4 Diagram"), ("C4Dynamic", "C4 Diagram"),
        ("C4Deployment", "C4 Diagram"), ("mindmap", "Mind Map"), ("timeline", "Timeline"), ("zenuml", "ZenUML Diagram"),
        ("sankey", "Sankey Diagram"), ("xychart", "XY Chart"), ("block", "Block Diagram"), ("packet", "Packet Diagram"),
        ("kanban", "Kanban Board"), ("architecture", "Architecture Diagram"), ("radar", "Radar Chart"), ("treemap", "Treemap"),
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
        let type = diagramType(text.text) ?? "Diagram"
        let payload = Payload(source: text.text, type: type, title: title(text.text))
        let document = WebDocument(module: .init("mermaid-file"), data: payload, scripts: ["modules/documents.js"], styles: ["modules/documents.css"],
                                   libraries: [.diagrams, .math])
        var details = [type]
        details.append(DocumentsModule.count(text.lineCount, "line"))
        return .web(document, FileSummary(symbol: "point.3.connected.trianglepath.dotted", title: "Mermaid", details: details, trailing: file.modifiedText),
                    NSSize(width: 1000, height: 720))
    }
}
