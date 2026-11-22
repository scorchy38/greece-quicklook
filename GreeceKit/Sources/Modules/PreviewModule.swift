import AppKit

/// What a module sees of a file when deciding whether it's one of its own.
struct FileInfo {
    let url: URL
    /// Lowercased file name and extension.
    let name: String
    let ext: String
    let isDirectory: Bool
    let isPackage: Bool
    /// The first 8 KB (empty for folders).
    let probe: FileProbe

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        isDirectory = values?.isDirectory == true
        isPackage = values?.isPackage == true
        name = url.lastPathComponent.lowercased()
        ext = url.pathExtension.lowercased()
        probe = isDirectory ? FileProbe(bytes: []) : FileProbe(url: url)
    }

    var fileSize: Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }

    /// "Modified 3 hours ago", for the info bar's trailing text.
    var modifiedText: String? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map(PreviewFactory.modifiedText)
    }

    var sizeText: String? {
        fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}

/// A file prepared off the main thread, ready to become a view.
enum PreparedPreview {
    /// Rendered by the web engine (greece.js plus the document's module scripts).
    case web(WebDocument, FileSummary, NSSize)
    /// A native view, built on the main thread.
    case native(FileSummary, NSSize, make: @MainActor (PreviewSettings) throws -> NSView)
    case table(DelimitedTable, FileSummary)
    case sqlite(SQLiteDatabase, FileSummary)
    case tree(FileNode, FileSummary, showsKind: Bool)
    case video(FileSummary)
}

/// A family of formats with its own detection, renderer and Finder thumbnail
/// (apps and binaries, 3D models, maps…). Modules are consulted before Greece's
/// generic detection, so they should only claim files they're sure about.
protocol PreviewModule {
    /// Stable identifier, used in `FileKind.module` and in settings.
    static var id: String { get }
    /// True if this module should handle the file. Called for every previewed file: keep it cheap
    /// (extension, name and the first 8 KB in `file.probe`).
    static func claims(_ file: FileInfo) -> Bool
    /// Off the main thread: read and parse the file.
    static func prepare(_ file: FileInfo, settings: PreviewSettings) throws -> PreparedPreview
    /// A Finder thumbnail, or nil to leave the file to macOS.
    static func thumbnail(_ file: FileInfo, size: CGSize, settings: PreviewSettings) -> ThumbnailPage?
}

extension PreviewModule {
    static func thumbnail(_ file: FileInfo, size: CGSize, settings: PreviewSettings) -> ThumbnailPage? { nil }
}

/// Native preview content that restyles itself when settings change (appearance, theme, fonts).
@MainActor
protocol PreviewSettingsAware: AnyObject {
    func apply(_ settings: PreviewSettings)
}

enum PreviewModules {
    /// Every module, in the order they're asked. Add new modules here.
    static let all: [PreviewModule.Type] = [
        DocumentsModule.self,
    ]

    static func module(id: String) -> PreviewModule.Type? {
        all.first { $0.id == id }
    }

    static func claiming(_ file: FileInfo) -> PreviewModule.Type? {
        all.first { $0.claims(file) }
    }
}
