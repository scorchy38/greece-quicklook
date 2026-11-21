import Foundation

/// What Greece will show for a file.
public enum FileKind: Equatable, Sendable {
    case markdown
    case code(Language)
    case json
    case propertyList
    case notebook
    case delimited(separator: UInt8?)   // nil = sniff
    case sqlite
    case diff
    case archive(ArchiveFormat)
    case folder
    case video
    /// Handled by a `PreviewModule` (apps, 3D models, maps…), by its id.
    case module(String)
    case unsupported

    public static func detect(_ url: URL) -> FileKind {
        detect(FileInfo(url: url))
    }

    static func detect(_ file: FileInfo) -> FileKind {
        let lowerName = file.name
        let ext = file.ext

        // Modules know their formats precisely (magic bytes, package layouts): they go first.
        if let module = PreviewModules.claiming(file) { return .module(module.id) }

        if file.isDirectory {
            if ["textbundle", "textpack"].contains(ext) { return .markdown }
            return file.isPackage ? .unsupported : .folder
        }

        let head = file.probe

        // Formats identified by their bytes win over names.
        if head.hasPrefix(Array("SQLite format 3\0".utf8)) { return .sqlite }
        if let archive = ArchiveFormat.sniff(head.bytes, name: lowerName) { return .archive(archive) }

        switch ext {
        case "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "mdx", "rmd", "qmd", "livemd", "textbundle":
            return .markdown
        case "csv": return .delimited(separator: nil)
        case "tsv", "tab": return .delimited(separator: UInt8(ascii: "\t"))
        case "psv": return .delimited(separator: UInt8(ascii: "|"))
        case "sqlite", "sqlite3", "db", "db3", "sdb", "s3db":
            return head.isText ? .code(.plainText) : .unsupported
        case "diff", "patch", "rej": return .diff
        case "ipynb": return .notebook
        case "json", "jsonc", "json5", "geojson", "webmanifest", "har", "jsonld": return .json
        case "plist": return head.hasPrefix(Array("bplist".utf8)) || head.isText ? .propertyList : .unsupported
        case "ts", "mts", "m2ts":
            // TypeScript and MPEG transport streams share extensions. Bytes decide.
            return head.isText ? .code(LanguageCatalog.language(forExtension: "ts")!) : .video
        default: break
        }

        if head.hasPrefix(Array("bplist".utf8)) { return .propertyList }

        let named = LanguageCatalog.language(forFileName: lowerName) ?? LanguageCatalog.language(forExtension: ext)
        guard head.isText else { return .unsupported }
        if let named, named.grammar == "diff" { return .diff }
        if let named, !named.isPlainText { return .code(named) }
        // Unknown or merely "text" by name (CHANGES, notes.txt…): let the content decide.
        return sniff(head.text) ?? .code(named ?? .plainText)
    }

    private static func sniff(_ text: String) -> FileKind? {
        if text.hasPrefix("diff --git ") || (text.hasPrefix("--- ") && text.contains("\n+++ ")) { return .diff }
        if let language = LanguageCatalog.language(sniffing: text[...]) { return .code(language) }
        return nil
    }
}

/// The first few KB of a file, for sniffing.
struct FileProbe {
    let bytes: [UInt8]

    init(url: URL, length: Int = 8192) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { bytes = []; return }
        defer { try? handle.close() }
        bytes = (try? handle.read(upToCount: length)).map { [UInt8]($0) } ?? []
    }

    func hasPrefix(_ prefix: [UInt8]) -> Bool {
        bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix
    }

    /// Text if there are no NUL bytes (allowing UTF-16 with a BOM) and few control characters.
    var isText: Bool {
        if bytes.isEmpty { return true }
        if hasPrefix([0xFF, 0xFE]) || hasPrefix([0xFE, 0xFF]) { return true }
        var control = 0
        for byte in bytes {
            if byte == 0 { return false }
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x0C && byte != 0x1B { control += 1 }
        }
        return control * 100 <= bytes.count * 2
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }
}
