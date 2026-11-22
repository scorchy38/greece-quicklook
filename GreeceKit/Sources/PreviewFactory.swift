import AppKit
import AVKit

public enum PreviewError: LocalizedError {
    case unsupported
    public var errorDescription: String? { "Greece can’t preview this file." }
}

/// Turns a file into a finished `PreviewView`. Heavy work runs off the main thread.
public enum PreviewFactory {

    /// - Parameter scroll: where to open the preview, measured from the top (a reload, a remembered position).
    @MainActor
    public static func makePreview(for url: URL, settings: PreviewSettings, scroll: CGPoint? = nil) async throws -> PreviewView {
        var prepared = try await Task.detached(priority: .userInitiated) { try prepare(url, settings: settings) }.value
        if case .web(var document, let summary, let size) = prepared {
            document.initialScroll = scroll
            if document.fileName == nil { document.fileName = url.lastPathComponent }
            prepared = .web(document, summary, size)
        }
        let view = try build(prepared, url: url, settings: settings)
        view.fileURL = url
        await view.waitUntilReady()
        if let scroll { view.restoreScroll(scroll) }
        return view
    }

    // MARK: - Off-main preparation

    /// Internal so archives can preview the files they extract (`prepare` off main, then `build`).
    static func prepare(_ url: URL, settings: PreviewSettings) throws -> PreparedPreview {
        let info = FileInfo(url: url)
        let kind = FileKind.detect(info)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let modified = values?.contentModificationDate.map(modifiedText)
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }

        switch kind {
        case .markdown:
            var fileURL = url
            var base = url.deletingLastPathComponent()
            if ["textbundle", "textpack"].contains(url.pathExtension.lowercased()) {
                base = url
                fileURL = ["text.md", "text.markdown", "text.txt"].map { url.appendingPathComponent($0) }
                    .first { FileManager.default.fileExists(atPath: $0.path) } ?? url.appendingPathComponent("text.md")
            }
            let file = try TextFile(url: fileURL)
            let words = wordCount(file.text)
            let minutes = max(1, Int((Double(words) / 230).rounded()))
            let summary = FileSummary(symbol: "doc.richtext", title: markdownFlavour(url.pathExtension),
                                      details: ["\(words.formatted()) words", "\(minutes) min read"], trailing: modified)
            return .web(WebDocument(kind: .markdown, text: file.text, baseDirectory: base, truncated: file.truncated), summary, NSSize(width: 980, height: 780))

        case .code(let language):
            let file = try TextFile(url: url)
            var text = file.text
            var formatted = false
            if settings.prettyPrint, !file.truncated,
               let pretty = CodeFormatter.formatIfMinified(text, language: language, fileExtension: url.pathExtension) {
                text = pretty
                formatted = true
            }
            // A .env file is highlighted as shell, but it's a list of settings, often secret.
            let isEnvironment = EnvMask.applies(to: url.lastPathComponent)
            var summary = codeSummary(isEnvironment ? "Environment" : language.name, symbol: isEnvironment ? "key" : language.symbol,
                                      file: file, size: size, modified: modified, lineCount: formatted ? TextFile(text: text).lineCount : nil)
            if formatted { summary.details.append("Formatted") }
            return .web(WebDocument(kind: .code, text: text, grammar: language.grammar, baseDirectory: url.deletingLastPathComponent(), truncated: file.truncated),
                        summary, NSSize(width: 920, height: 720))

        case .json:
            let file = try TextFile(url: url)
            var text = file.text
            var details: [String] = []
            let ext = url.pathExtension.lowercased()
            // A truncated file is formatted leniently: it ends mid-document by design.
            if settings.prettyPrint, !["jsonl", "ndjson"].contains(ext), JSONFormatter.looksMinified(text),
               let pretty = JSONFormatter.prettyPrinted(text, indent: 2, lenient: file.truncated) {
                text = pretty
                details.append("Formatted")
            }
            let formatted = TextFile(text: text)
            var summary = codeSummary("JSON", symbol: "curlybraces.square", file: file, size: size, modified: modified, lineCount: formatted.lineCount)
            summary.details += details
            var document = WebDocument(kind: .code, text: text, grammar: "json", truncated: file.truncated)
            if file.truncated {
                // The tree view reads the whole file, which the code view only shows the start of.
                document.resources = { path in
                    guard path == "source", let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                          data.count <= 256 * 1024 * 1024 else { return nil }
                    return (data, "application/json")
                }
            }
            return .web(document, summary, NSSize(width: 920, height: 720))

        case .propertyList:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            var text: String
            var format = PropertyListSerialization.PropertyListFormat.xml
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            if let object, format == .binary,
               let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) {
                text = String(decoding: xml, as: UTF8.self)
            } else {
                text = TextFile.decode(data.prefix(TextFile.defaultLimit)).0
            }
            var formatted = false
            if settings.prettyPrint, format != .binary, Minified.looksMinified(text, separators: .tags),
               let pretty = XMLFormatter.prettyPrinted(text) {
                text = pretty
                formatted = true
            }
            var summary = codeSummary("Property List", symbol: "list.bullet.indent", file: TextFile(text: text), size: size, modified: modified)
            if format == .binary { summary.details.insert("Binary", at: 0) }
            if formatted { summary.details.append("Formatted") }
            var document = WebDocument(kind: .code, text: text, grammar: "xml")
            // The same values as a tree (Code / Tree in the preview).
            document.data = object.flatMap(PropertyListTree.json(from:))
            return .web(document, summary, NSSize(width: 920, height: 720))

        case .notebook:
            let file = try TextFile(url: url)
            var details: [String] = []
            if let json = try? JSONSerialization.jsonObject(with: Data(file.text.utf8)) as? [String: Any] {
                let cells = (json["cells"] as? [Any])?.count ?? 0
                details.append("\(cells) \(cells == 1 ? "cell" : "cells")")
                if let kernel = (json["metadata"] as? [String: Any])?["kernelspec"] as? [String: Any],
                   let name = kernel["display_name"] as? String { details.append(name) }
            }
            if let size { details.append(size) }
            let summary = FileSummary(symbol: "book.pages", title: "Jupyter Notebook", details: details, trailing: modified)
            return .web(WebDocument(kind: .notebook, text: file.text, baseDirectory: url.deletingLastPathComponent(), truncated: file.truncated),
                        summary, NSSize(width: 1000, height: 780))

        case .delimited(let separator):
            let file = try TextFile(url: url, limit: 64 * 1024 * 1024)
            let table = DelimitedTable.parse(file.text, separator: separator, maxRows: settings.maxRows)
            let ext = url.pathExtension.lowercased()
            var details = ["\(table.totalRows.formatted()) \(table.totalRows == 1 ? "row" : "rows")",
                           "\(table.columnCount) \(table.columnCount == 1 ? "column" : "columns")",
                           table.separatorName]
            if table.truncated { details.append("Showing first \(table.rows.count.formatted())") }
            if table.totalColumns > table.columnCount { details.append("First \(table.columnCount.formatted()) columns") }
            if file.encodingName != "UTF-8" { details.append(file.encodingName) }
            let title: String
            switch table.separator {
            case UInt8(ascii: "\t"): title = "TSV"
            case UInt8(ascii: "|"): title = "PSV"
            default: title = ext == "tsv" || ext == "tab" ? "TSV" : ext == "psv" ? "PSV" : "CSV"
            }
            return .table(table, FileSummary(symbol: "tablecells", title: title, details: details, trailing: modified))

        case .sqlite:
            let database = try SQLiteDatabase(url: url)
            let tables = database.objects.filter { !$0.isView }.count
            let views = database.objects.count - tables
            var details = ["\(tables) \(tables == 1 ? "table" : "tables")"]
            if views > 0 { details.append("\(views) \(views == 1 ? "view" : "views")") }
            if let size { details.append(size) }
            return .sqlite(database, FileSummary(symbol: "cylinder.split.1x2", title: "SQLite Database", details: details, trailing: modified))

        case .diff:
            let file = try TextFile(url: url)
            let stats = diffStats(file.text)
            let ext = url.pathExtension.lowercased()
            var details = ["\(stats.files) \(stats.files == 1 ? "file" : "files")", "+\(stats.added.formatted())", "−\(stats.removed.formatted())"]
            let commits = file.text.components(separatedBy: "\n").filter { $0.range(of: #"^(commit [0-9a-f]{7,64}\b|From [0-9a-f]{40} )"#, options: .regularExpression) != nil }.count
            if commits > 1 { details.insert("\(commits) commits", at: 0) }
            let summary = FileSummary(symbol: "plus.forwardslash.minus", title: ext == "patch" ? "Patch" : "Diff", details: details, trailing: modified)
            return .web(WebDocument(kind: .diff, text: file.text, truncated: file.truncated), summary, NSSize(width: 1000, height: 760))

        case .archive(let format):
            let listing = try ArchiveReader.read(url, format: format)
            if listing.container == .compressedFile, let inner = listing.innerPrefix, let entry = listing.entries.first,
               FileProbe(bytes: [UInt8](inner.prefix(8192))).isText {
                // A compressed text file (logs, dumps): show its contents directly.
                let text = TextFile.decode(inner).0
                let language = LanguageCatalog.language(forFileName: entry.path) ?? LanguageCatalog.language(forExtension: (entry.path as NSString).pathExtension) ?? .plainText
                let kind: WebDocument.Kind = (entry.path as NSString).pathExtension.lowercased() == "md" ? .markdown : .code
                let details = [entry.path, ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file) + " uncompressed"]
                let summary = FileSummary(symbol: "doc.zipper", title: listing.title, details: details, trailing: modified)
                return .web(WebDocument(kind: kind, text: text, grammar: language.grammar, truncated: UInt64(inner.count) < entry.size), summary, NSSize(width: 920, height: 720))
            }
            var details = ["\(listing.fileCount.formatted()) \(listing.fileCount == 1 ? "file" : "files")",
                           ByteCountFormatter.string(fromByteCount: Int64(clamping: listing.totalSize), countStyle: .file)]
            if listing.totalSize > 0, listing.archiveSize > 0, listing.archiveSize < listing.totalSize {
                let saved = 100 - Int((Double(listing.archiveSize) / Double(listing.totalSize) * 100).rounded())
                if saved > 0 { details.append("\(saved)% smaller") }
            }
            if listing.isEncrypted { details.append("Encrypted") }
            if listing.truncated { details.append("Showing first \(listing.entries.count.formatted())") }
            let summary = FileSummary(symbol: listing.isEncrypted ? "lock.doc" : "archivebox", title: listing.title, details: details, trailing: modified)
            return .tree(FileNode.tree(from: listing, showHidden: settings.showHiddenFiles), summary, showsKind: false)

        case .folder:
            let node = FileNode.folder(at: url, showHidden: settings.showHiddenFiles)
            let count = node.children?.count ?? 0
            let folders = node.children?.filter { $0.isDirectory && !$0.isPackage }.count ?? 0
            var details = ["\(count.formatted()) \(count == 1 ? "item" : "items")"]
            if folders > 0 { details.append("\(folders) \(folders == 1 ? "folder" : "folders")") }
            return .tree(node, FileSummary(symbol: "folder", title: "Folder", details: details, trailing: modified), showsKind: true)

        case .video:
            return .video(FileSummary(symbol: "film", title: "MPEG Transport Stream", details: [size].compactMap { $0 }, trailing: modified))

        case .module(let id):
            guard let module = PreviewModules.module(id: id) else { throw PreviewError.unsupported }
            return try module.prepare(info, settings: settings)

        case .unsupported:
            throw PreviewError.unsupported
        }
    }

    // MARK: - Main-thread construction

    @MainActor
    static func build(_ prepared: PreparedPreview, url: URL, settings: PreviewSettings) throws -> PreviewView {
        switch prepared {
        case .web(let document, let summary, let size):
            let content = WebPreviewView(document: document, settings: settings, size: NSSize(width: size.width, height: size.height - 28))
            return PreviewView(content: content, summary: summary, preferredSize: size, settings: settings)
        case .native(let summary, let size, let make):
            let content = try make(settings)
            return PreviewView(content: content, summary: summary, preferredSize: size, settings: settings)
        case .table(let table, let summary):
            let content = DataTableView(store: DelimitedStore(table: table), settings: settings)
            return PreviewView(content: content, summary: summary, preferredSize: NSSize(width: 1060, height: 680), settings: settings)
        case .sqlite(let database, let summary):
            let browser = SQLiteBrowserView(database: database, settings: settings)
            let view = PreviewView(content: browser, summary: summary, preferredSize: NSSize(width: 1100, height: 720), settings: settings)
            browser.onSelectionChange = { [weak view] object in
                guard let view else { return }
                var updated = summary
                if let object {
                    let rows = object.rowCount.map { "\($0.formatted()) \($0 == 1 ? "row" : "rows")" }
                        ?? object.estimatedRows.map { "about \($0.formatted()) rows" }
                    updated.details = [rows.map { "\(object.name) · \($0)" } ?? object.name] + summary.details
                }
                view.setSummary(updated)
            }
            browser.reportSelection()
            return view
        case .tree(let root, let summary, let showsKind):
            // A folder on disk previews whatever is selected in it, as an archive does.
            if root.url != nil {
                let browser = MemberBrowserView(root: root, source: LocalMembers(), scratch: ArchiveScratch(), settings: settings, showsKind: showsKind)
                return PreviewView(content: browser, summary: summary, preferredSize: NSSize(width: 980, height: 640), settings: settings)
            }
            let tree = FileTreeView(root: root, settings: settings, showsKind: showsKind)
            return PreviewView(content: tree, summary: summary, preferredSize: NSSize(width: 820, height: 600), settings: settings)
        case .video(let summary):
            let player = AVPlayerView()
            player.controlsStyle = .floating
            player.player = AVPlayer(url: url)
            return PreviewView(content: player, summary: summary, preferredSize: NSSize(width: 960, height: 600), settings: settings)
        }
    }

    // MARK: - Facts

    /// What the info bar calls a Markdown file: its flavour when the extension says which.
    static func markdownFlavour(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mdx": return "MDX"
        case "rmd": return "R Markdown"
        case "qmd": return "Quarto"
        case "livemd": return "Livebook"
        default: return "Markdown"
        }
    }

    private static func codeSummary(_ name: String, symbol: String, file: TextFile, size: String?, modified: String?, lineCount: Int? = nil) -> FileSummary {
        let lines = lineCount ?? file.lineCount
        var details = ["\(lines.formatted()) \(lines == 1 ? "line" : "lines")"]
        if let size { details.append(size) }
        if file.encodingName != "UTF-8" { details.append(file.encodingName) }
        if file.truncated { details.append("Showing first \(ByteCountFormatter.string(fromByteCount: Int64(TextFile.defaultLimit), countStyle: .file))") }
        return FileSummary(symbol: symbol, title: name, details: details, trailing: modified)
    }

    static func modifiedText(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age >= 0 && age < 60 { return "Modified just now" }
        if age >= 0 && age < 7 * 86_400 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Modified " + formatter.localizedString(for: date, relativeTo: Date())
        }
        return "Modified " + date.formatted(date: .abbreviated, time: .omitted)
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1; inWord = true }
            } else if scalar != "'" && scalar != "’" && scalar != "-" {
                inWord = false
            }
        }
        return count
    }

    /// Counts files and changed lines, honouring each hunk's declared length (same rules as the page).
    static func diffStats(_ text: String) -> (files: Int, added: Int, removed: Int) {
        var files = 0, added = 0, removed = 0
        var sawGitHeader = false
        var oldLeft = 0, newLeft = 0
        text.enumerateLines { line, _ in
            if oldLeft > 0 || newLeft > 0 {
                switch line.first {
                case "+": added += 1; newLeft -= 1; return
                case "-": removed += 1; oldLeft -= 1; return
                case " ", nil: oldLeft -= 1; newLeft -= 1; return
                case "\\": return
                default: oldLeft = 0; newLeft = 0
                }
            }
            if line.hasPrefix("diff --git ") { files += 1; sawGitHeader = true }
            else if line.hasPrefix("+++ ") { if !sawGitHeader { files += 1 } }
            else if line.hasPrefix("@@"), let counts = hunkCounts(line) { (oldLeft, newLeft) = counts }
        }
        return (max(files, 1), added, removed)
    }

    private static func hunkCounts(_ line: String) -> (Int, Int)? {
        // @@ -a[,b] +c[,d] @@
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func count(_ range: Substring) -> Int {
            let pieces = range.dropFirst().split(separator: ",")
            return pieces.count > 1 ? Int(pieces[1]) ?? 0 : 1
        }
        return (count(parts[1]), count(parts[2]))
    }
}

extension FileProbe {
    init(bytes: [UInt8]) { self.bytes = bytes }
}
