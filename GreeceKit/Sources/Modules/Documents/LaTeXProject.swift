import AppKit
import PDFKit
import ImageIO

/// A LaTeX project as one document: \input, \include, \subfile and \import inlined (inside the
/// project folder, with cycle, depth and size limits), figures resolved, bibliographies read.
struct LaTeXProject {
    struct Figure: Encodable {
        var kind: String            // image, pdf, svg, missing, unsupported
        var src: String?
        var svg: String?
        var width: Double?          // natural size in points
        var height: Double?
        var note: String?
    }

    var mainURL: URL
    var source: String
    var files: [URL] = []
    var missing: [String] = []
    var truncated = false
    var figures: [String: Figure] = [:]
    var pdfFigures: [String: URL] = [:]
    var bibliography: [BibEntry] = []
    var bibFiles: [URL] = []
    var bbl: String?
    var languages: Set<String> = []

    static let fileLimit = 4 * 1024 * 1024
    static let totalLimit = 8 * 1024 * 1024
    static let depthLimit = 12
    static let includeLimit = 256
    static let figureLimit = 300

    var isBeamer: Bool {
        source.range(of: #"\\documentclass\s*(\[[^\]]*\])?\s*\{beamer\}"#, options: .regularExpression) != nil
    }

    // MARK: - Loading

    /// The main file that includes this one, when this one is a section of a bigger project.
    var host: URL?

    static func load(_ url: URL, sweave: Bool = false) throws -> LaTeXProject {
        let file = try TextFile(url: url, limit: fileLimit)
        var main = file.text
        if sweave { main = Sweave.latex(main) }
        var project = LaTeXProject(mainURL: url, source: "")
        project.truncated = file.truncated
        var root = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        // A section of a larger project borrows its main file's preamble (macros, theorems,
        // bibliography) and folder, so it previews as it reads in the full document.
        if let host = hostDocument(for: url, text: main), let hostText = try? TextFile(url: host, limit: fileLimit).text,
           let begin = hostText.range(of: "\\begin{document}") {
            project.host = host
            project.mainURL = host
            root = host.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            var bibliography = ""
            if ["bibliography", "printbibliography"].contains(where: { hostText.contains("\\" + $0) }) && !main.contains("\\bibliography") {
                // Citations in this part resolve against the project's references, in its style.
                if let style = TeXText.argument(of: "bibliographystyle", in: hostText) { bibliography += "\n\\bibliographystyle{\(style)}" }
                bibliography += TeXText.argument(of: "bibliography", in: hostText).map { "\n\\bibliography{\($0)}" } ?? "\n\\printbibliography"
            }
            main = String(hostText[..<begin.lowerBound]) + "\\begin{document}\n" + main + bibliography + "\n\\end{document}\n"
        }
        var resolver = IncludeResolver(root: root, mainDirectory: root)
        resolver.visiting = [url.resolvingSymlinksInPath().standardizedFileURL.path]
        project.source = resolver.expand(main, directory: root, depth: 0)
        project.files = resolver.files
        project.missing = resolver.missing
        project.truncated = project.truncated || resolver.truncated
        project.figures = resolver.pgfFigures
        project.resolveFigures(root: root)
        project.loadBibliography(root: root)
        project.languages = LaTeXProject.listingLanguages(project.source)
        return project
    }

    /// For a file without \\documentclass: a .tex file beside it or one folder up that has a
    /// preamble and includes it (\\input, \\include, \\subfile, \\import).
    static func hostDocument(for url: URL, text: String) -> URL? {
        guard !text.contains("\\documentclass") else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        for directory in [folder, folder.deletingLastPathComponent()] {
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted().prefix(200) where ["tex", "ltx"].contains((name as NSString).pathExtension.lowercased()) {
                let candidate = directory.appendingPathComponent(name)
                guard candidate.standardizedFileURL != url.standardizedFileURL,
                      let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 2 * 1024 * 1024,
                      let head = try? TextFile(url: candidate, limit: 2 * 1024 * 1024).text, head.contains("\\documentclass") else { continue }
                let pattern = #"\\(input|include|subfile|import|subimport)\s*(\{[^}]*\}\s*)?\{[^}]*\b"# + NSRegularExpression.escapedPattern(for: stem) + #"(\.tex)?\}"#
                if head.range(of: pattern, options: .regularExpression) != nil { return candidate }
            }
        }
        return nil
    }

    // MARK: - Figures

    private mutating func resolveFigures(root: URL) {
        let source = self.source
        var searchPaths = [root]
        if let raw = TeXText.argument(of: "graphicspath", in: source) {
            for match in raw.split(separator: "}").map({ $0.replacingOccurrences(of: "{", with: "").trimmingCharacters(in: .whitespaces) }) where !match.isEmpty {
                searchPaths.append(root.appendingPathComponent(match, isDirectory: true).standardizedFileURL)
            }
        }
        let pattern = try! NSRegularExpression(pattern: #"\\includegraphics\s*\*?\s*(?:<[^>]*>)?\s*(?:\[[^\]]*\])?\s*\{([^}]+)\}"#)
        let range = NSRange(source.startIndex..., in: source)
        var count = 0
        pattern.enumerateMatches(in: source, range: range) { match, _, stop in
            guard let match, let r = Range(match.range(at: 1), in: source) else { return }
            let name = source[r].trimmingCharacters(in: .whitespacesAndNewlines)
            guard figures[name] == nil else { return }
            count += 1
            if count > Self.figureLimit { stop.pointee = true; return }
            figures[name] = figure(named: name, searchPaths: searchPaths, index: count)
        }
    }

    private static let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "bmp", "svg"]
    private static let allExtensions = ["pdf", "png", "jpg", "jpeg", "eps", "ps", "svg", "gif", "webp", "tif", "tiff", "pgf", "heic", "bmp"]

    private mutating func figure(named name: String, searchPaths: [URL], index: Int) -> Figure {
        let clean = name.replacingOccurrences(of: "\"", with: "")
        var candidates: [URL] = []
        let hasExtension = !(clean as NSString).pathExtension.isEmpty && Self.allExtensions.contains((clean as NSString).pathExtension.lowercased())
        for base in searchPaths {
            let url = clean.hasPrefix("/") ? URL(fileURLWithPath: clean) : base.appendingPathComponent(clean)
            if hasExtension { candidates.append(url) }
            else { candidates += Self.allExtensions.map { url.appendingPathExtension($0) } }
        }
        guard let found = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            return Figure(kind: "missing")
        }
        let ext = found.pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) {
            var figure = Figure(kind: "image", src: Self.fileURL(found))
            if let size = Self.imageSize(found) { figure.width = size.width; figure.height = size.height }
            return figure
        }
        if ext == "pdf" {
            let id = "pdf/\(index).png"
            pdfFigures[id] = found
            var figure = Figure(kind: "pdf", src: "greece://module/" + id)
            if let document = PDFDocument(url: found), let page = document.page(at: 0) {
                let box = page.bounds(for: .cropBox)
                figure.width = box.width
                figure.height = box.height
            }
            return figure
        }
        if ext == "pgf" {
            return Self.pgfFigure(found) ?? Figure(kind: "unsupported", note: Self.pgfNote)
        }
        let note = ext == "eps" || ext == "ps"
            ? String(localized: "PostScript figure", bundle: .greeceKit, comment: "Placeholder for a LaTeX figure in a format Greece can’t draw")
            : String(localized: "Figure", bundle: .greeceKit, comment: "Cross reference in a document, or a placeholder for a figure that can’t be shown")
        return Figure(kind: "unsupported", note: note)
    }

    static var pgfNote: String {
        String(localized: "PGF figure", bundle: .greeceKit, comment: "Placeholder for a LaTeX figure in PGF that Greece can’t draw")
    }

    static func pgfFigure(_ url: URL) -> Figure? {
        guard let text = try? TextFile(url: url, limit: 16 * 1024 * 1024).text else { return nil }
        let directory = url.deletingLastPathComponent()
        guard let picture = PGF.parse(text, image: { name in
            let target = directory.appendingPathComponent(name).standardizedFileURL
            guard target.path.hasPrefix(directory.standardizedFileURL.path + "/") else { return nil }
            return try? Data(contentsOf: target, options: .mappedIfSafe)
        }) else { return nil }
        return Figure(kind: "svg", svg: PGF.svg(picture), width: picture.bounds.width, height: picture.bounds.height)
    }

    static func fileURL(_ url: URL) -> String {
        "greece://file" + (url.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)
    }

    /// Natural size in points (pixels at the image's own resolution, 72 dpi if it doesn't say).
    static func imageSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 1 ? $0 : nil } ?? 72
        return CGSize(width: width * 72 / dpi, height: height * 72 / dpi)
    }

    /// The first page of a PDF figure as a PNG, rendered sharp for Retina.
    static func renderPDF(_ url: URL) -> Data? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(3, max(1, 2400 / max(box.width, box.height)))
        let size = CGSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Bibliography

    private mutating func loadBibliography(root: URL) {
        let source = TeXText.stripComments(self.source)
        var names: [String] = []
        for command in ["bibliography", "addbibresource", "addglobalbib", "nobibliography"] {
            var rest = Substring(source)
            while let range = rest.range(of: "\\\(command)") {
                rest = rest[range.upperBound...]
                guard let arg = TeXText.argument(of: command, in: "\\" + command + rest.prefix(2000)) else { continue }
                names += arg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        var seen = Set<String>()
        for name in names where !name.isEmpty && seen.insert(name).inserted && bibFiles.count < 16 {
            var url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : root.appendingPathComponent(name)
            if url.pathExtension.lowercased() != "bib" { url = url.appendingPathExtension("bib") }
            guard url.pathExtension.lowercased() == "bib", let text = try? TextFile(url: url, limit: 8 * 1024 * 1024).text else { continue }
            bibFiles.append(url)
            bibliography += BibTeX.parse(text).entries
        }
        // A compiled .bbl beside the main file is exactly what LaTeX would print.
        let bblURL = mainURL.deletingPathExtension().appendingPathExtension("bbl")
        if !names.isEmpty, let text = try? TextFile(url: bblURL, limit: 2 * 1024 * 1024).text, text.contains("\\begin{thebibliography}") {
            bbl = text
        }
    }

    private static func listingLanguages(_ source: String) -> Set<String> {
        var languages = Set<String>()
        let patterns = [#"language\s*=\s*(?:\[[^\]]*\])?\{?([A-Za-z+#]+)"#, #"\\begin\{minted\}(?:\[[^\]]*\])?\{([A-Za-z+#]+)\}"#, #"\\mintinline\{([A-Za-z+#]+)\}"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).prefix(100) {
                if let r = Range(match.range(at: 1), in: source) { languages.insert(String(source[r]).lowercased().replacingOccurrences(of: "c++", with: "cpp")) }
            }
        }
        if source.contains("\\Sexpr") || source.contains("greececode") { languages.insert("r") }
        return languages
    }
}

// MARK: - Includes

/// Inlines \input-style commands. Works on characters, skipping comments and verbatim text.
private struct IncludeResolver {
    let root: URL
    let mainDirectory: URL
    var files: [URL] = []
    var missing: [String] = []
    var truncated = false
    var total = 0
    var visiting: [String] = []
    var pgfFigures: [String: LaTeXProject.Figure] = [:]
    var pgfCount = 0

    private static let commands: Set<String> = ["input", "include", "subfile", "import", "subimport", "inputfrom", "includefrom", "subinputfrom", "subincludefrom", "InputIfFileExists"]
    private static let verbatim = ["greececode", "verbatim", "Verbatim", "lstlisting", "minted", "comment", "filecontents", "filecontents*"]

    init(root: URL, mainDirectory: URL) {
        self.root = root
        self.mainDirectory = mainDirectory
    }

    mutating func expand(_ text: String, directory: URL, depth: Int) -> String {
        let chars = Array(text)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%" {
                while i < chars.count, chars[i] != "\n" { out.append(chars[i]); i += 1 }
                continue
            }
            guard c == "\\", i + 1 < chars.count else { out.append(c); i += 1; continue }
            if chars[i + 1] == "\\" || chars[i + 1] == "%" { out.append(c); out.append(chars[i + 1]); i += 2; continue }
            var j = i + 1
            var name = ""
            while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
            if name == "begin", let env = Self.groupText(chars, from: j), Self.verbatim.contains(env.text) {
                // Copy verbatim environments untouched.
                let end = "\\end{\(env.text)}"
                let rest = String(chars[i...])
                if let range = rest.range(of: end) {
                    let chunk = rest[..<range.upperBound]
                    out += chunk
                    i += chunk.count
                } else { out += rest; i = chars.count }
                continue
            }
            guard Self.commands.contains(name) else {
                out.append(c)
                i += 1
                continue
            }
            // Arguments: \import{dir}{file}, \input{file} or \input file
            var k = j
            while k < chars.count, chars[k] == " " { k += 1 }
            var directoryArg: String?
            var fileArg: String
            if ["import", "subimport", "inputfrom", "includefrom", "subinputfrom", "subincludefrom"].contains(name) {
                guard let first = Self.groupText(chars, from: k) else { out.append(c); i += 1; continue }
                directoryArg = first.text
                guard let second = Self.groupText(chars, from: first.end) else { out.append(c); i += 1; continue }
                fileArg = second.text
                k = second.end
            } else if let group = Self.groupText(chars, from: k) {
                fileArg = group.text
                k = group.end
                if name == "InputIfFileExists" {
                    // \InputIfFileExists{file}{then}{else}: keep the branches out.
                    if let a = Self.groupText(chars, from: k) { k = a.end; if let b = Self.groupText(chars, from: k) { k = b.end } }
                }
            } else if name == "input" {
                // TeX primitive syntax: \input file
                var word = ""
                while k < chars.count, !chars[k].isWhitespace, chars[k] != "%", chars[k] != "}", chars[k] != "\\" { word.append(chars[k]); k += 1 }
                guard !word.isEmpty else { out.append(c); i += 1; continue }
                fileArg = word
            } else {
                out.append(c); i += 1; continue
            }
            i = k
            let fileName = fileArg.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            guard !fileName.isEmpty else { continue }
            out += include(name: name, file: fileName, directoryArg: directoryArg, directory: directory, depth: depth)
        }
        return out
    }

    private mutating func include(name: String, file: String, directoryArg: String?, directory: URL, depth: Int) -> String {
        let shown = (directoryArg ?? "") + file
        let escapedShown = shown.replacingOccurrences(of: "}", with: "").replacingOccurrences(of: "{", with: "")
        // The page shows a placeholder for an include it can’t follow, with the reason after the path.
        func missingFile(_ reason: String? = nil) -> String {
            guard let reason else { return "\\greecemissing{\(escapedShown)}" }
            let shownReason = reason.filter { !"{}\\%".contains($0) }
            return "\\greecemissing{\(shownReason)}"
        }
        guard depth < LaTeXProject.depthLimit else {
            truncated = true
            return missingFile(String(localized: "\(escapedShown) (nested too deeply)", bundle: .greeceKit,
                                      comment: "Placeholder for a LaTeX file that wasn’t included because includes are nested too deeply. The argument is its path, such as “chapters/intro.tex”"))
        }
        guard files.count < LaTeXProject.includeLimit else { truncated = true; return missingFile() }
        var bases: [URL] = []
        if let directoryArg {
            let sub = directoryArg.hasPrefix("/") ? URL(fileURLWithPath: directoryArg) : (name.hasPrefix("sub") ? directory : mainDirectory).appendingPathComponent(directoryArg)
            bases = [sub.standardizedFileURL]
        } else {
            bases = [mainDirectory, directory]
        }
        var candidates: [URL] = []
        for base in bases {
            let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : base.appendingPathComponent(file)
            candidates.append(url)
            if !["tex", "ltx", "pgf", "tikz", "latex"].contains(url.pathExtension.lowercased()) { candidates.append(url.appendingPathExtension("tex")) }
        }
        guard let found = candidates.first(where: { isInside($0) && FileManager.default.isReadableFile(atPath: $0.path) && !isDirectory($0) }) else {
            missing.append(shown)
            return missingFile()
        }
        let resolved = found.resolvingSymlinksInPath().standardizedFileURL
        if found.pathExtension.lowercased() == "pgf" {
            pgfCount += 1
            let key = "greece-pgf-\(pgfCount)"
            pgfFigures[key] = LaTeXProject.pgfFigure(resolved) ?? LaTeXProject.Figure(kind: "unsupported", note: LaTeXProject.pgfNote)
            files.append(resolved)
            return "\\includegraphics{\(key)}"
        }
        guard !visiting.contains(resolved.path) else {
            return missingFile(String(localized: "\(escapedShown) (includes itself)", bundle: .greeceKit,
                                      comment: "Placeholder for a LaTeX file that wasn’t included because it includes itself. The argument is its path, such as “chapters/intro.tex”"))
        }
        guard let text = try? TextFile(url: resolved, limit: LaTeXProject.fileLimit) else {
            missing.append(shown)
            return missingFile()
        }
        guard total + text.text.utf8.count <= LaTeXProject.totalLimit else {
            truncated = true
            return missingFile(String(localized: "\(escapedShown) (project too large)", bundle: .greeceKit,
                                      comment: "Placeholder for a LaTeX file that wasn’t included because the project is too large to show. The argument is its path"))
        }
        total += text.text.utf8.count
        files.append(resolved)
        var body = text.text
        if name == "subfile" {
            // A subfile is a whole document: keep only its body.
            if let start = body.range(of: "\\begin{document}") {
                body = String(body[start.upperBound...])
                if let end = body.range(of: "\\end{document}") { body = String(body[..<end.lowerBound]) }
            }
        }
        visiting.append(resolved.path)
        let expanded = expand(body, directory: resolved.deletingLastPathComponent(), depth: depth + 1)
        visiting.removeLast()
        let separator = name == "include" ? "\n\n" : ""
        return separator + expanded + (expanded.hasSuffix("\n") ? "" : "\n") + separator
    }

    private func isInside(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(rootPath)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    static func groupText(_ chars: [Character], from start: Int) -> (text: String, end: Int)? {
        var k = start
        while k < chars.count, chars[k] == " " || chars[k] == "\n" { k += 1 }
        guard k < chars.count, chars[k] == "{" else { return nil }
        var depth = 0
        var text = ""
        while k < chars.count {
            let c = chars[k]
            if c == "{" { depth += 1; if depth == 1 { k += 1; continue } }
            if c == "}" { depth -= 1; if depth == 0 { return (text, k + 1) } }
            if c == "\n" && text.count > 300 { return nil }
            text.append(c)
            k += 1
        }
        return nil
    }
}

// MARK: - Sweave

/// Sweave and knitr's LaTeX flavour: <<label, options>>= code @ chunks become highlighted R.
enum Sweave {
    static func latex(_ text: String) -> String {
        var out: [String] = []
        var chunk: [String]? = nil
        var header = ""
        for line in text.components(separatedBy: "\n") {
            if chunk == nil, let match = line.range(of: #"^\s*<<(.*)>>=\s*$"#, options: .regularExpression) {
                header = String(line[match]).trimmingCharacters(in: .whitespaces).dropFirst(2).dropLast(3).description
                chunk = []
                continue
            }
            if var lines = chunk {
                if line.trimmingCharacters(in: .whitespaces) == "@" || line.hasPrefix("@ ") {
                    let parts = header.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    var label = parts.first ?? ""
                    var options = parts.count > 1 ? parts[1] : ""
                    if label.contains("=") { options = header; label = "" }
                    let code = lines.joined(separator: "\n").replacingOccurrences(of: "\\end{greececode}", with: "")
                    out.append("\\begin{greececode}{\(brace(label))}{\(brace(options))}\n\(code)\n\\end{greececode}")
                    chunk = nil
                    continue
                }
                lines.append(line)
                chunk = lines
                continue
            }
            if line.hasPrefix("\\SweaveOpts") || line.hasPrefix("\\SweaveInput") { continue }
            out.append(line)
        }
        if let lines = chunk { out.append("\\begin{greececode}{}{}\n\(lines.joined(separator: "\n").replacingOccurrences(of: "\\end{greececode}", with: ""))\n\\end{greececode}") }
        return out.joined(separator: "\n")
    }

    /// Makes text safe inside a braced argument by balancing braces.
    private static func brace(_ text: String) -> String {
        var depth = 0
        var result = ""
        for c in text {
            if c == "{" { depth += 1 }
            if c == "}" { if depth == 0 { result += "\\}"; continue }; depth -= 1 }
            result.append(c)
        }
        return result + String(repeating: "}", count: depth)
    }
}
