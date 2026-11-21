import AppKit

/// Archives, compressed files, comics and software packages: browse them, preview anything inside,
/// and see a package's metadata or a comic's pages.
enum ArchivesModule: PreviewModule {
    static let id = "archives"

    static func claims(_ file: FileInfo) -> Bool {
        ArchiveSniffer.identify(file) != nil
    }

    static func prepare(_ file: FileInfo, settings: PreviewSettings) throws -> PreparedPreview {
        let session = try ArchiveSession(url: file.url)
        let listing = try session.listAll()
        let summary = FileSummary(symbol: "archivebox", title: listing.title, details: ["\(listing.fileCount) files"], trailing: file.modifiedText)
        return .tree(FileNode.tree(from: listing, showHidden: settings.showHiddenFiles), summary, showsKind: false)
    }
}
