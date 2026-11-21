import AppKit

/// Archives, compressed files, comics and software packages: browse them, preview anything inside,
/// and see a package's metadata or a comic's pages.
enum ArchivesModule: PreviewModule {
    static let id = "archives"

    static func claims(_ file: FileInfo) -> Bool {
        ArchiveSniffer.identify(file) != nil
    }

    static func prepare(_ file: FileInfo, settings: PreviewSettings) throws -> PreparedPreview {
        guard let identity = ArchiveSniffer.identify(file) else { throw PreviewError.unsupported }
        let document = try ArchiveDocument(url: file.url, identity: identity, showHidden: settings.showHiddenFiles)
        let modified = file.modifiedText

        if document.listing.container == .compressedFile, let single = try? singleFile(document, settings: settings, modified: modified) {
            return single
        }
        let summary = document.summary(modified: modified, loading: document.isLoading)
        return .native(summary, NSSize(width: 980, height: 680)) { settings in
            ArchiveBrowserView(document: document, settings: settings, modified: modified)
        }
    }

    /// A lone compressed file (a .log.gz, a .json.zst): show what's inside directly, with Greece's
    /// own renderer for it, and say what it was compressed with.
    private static func singleFile(_ document: ArchiveDocument, settings: PreviewSettings, modified: String?) throws -> PreparedPreview {
        guard let entry = document.listing.entries.first else { throw PreviewError.unsupported }
        let file = try document.session.extract(entry, to: document.scratch, limit: 64 * 1024 * 1024)
        ScratchKeeper.keep(document.scratch)
        let inner = try PreviewFactory.prepare(file, settings: settings)
        func wrap(_ summary: FileSummary) -> FileSummary {
            var details = [entry.path]
            details += summary.details.filter { !$0.hasPrefix("Modified") }
            if document.listing.truncated { details.append("Showing the beginning") }
            return FileSummary(symbol: "doc.zipper", title: document.listing.title, details: details, trailing: modified)
        }
        switch inner {
        case .web(let web, let summary, let size): return .web(web, wrap(summary), size)
        case .native(let summary, let size, let make): return .native(wrap(summary), size, make: make)
        case .table(let table, let summary): return .table(table, wrap(summary))
        case .sqlite(let database, let summary): return .sqlite(database, wrap(summary))
        case .tree(let node, let summary, let kind): return .tree(node, wrap(summary), showsKind: kind)
        case .video(let summary): return .video(wrap(summary))
        }
    }
}

/// Keeps the last few single-file extractions on disk while their previews may still be showing
/// (a SQLite database or a video reads its file after the preview is built).
enum ScratchKeeper {
    private static let lock = NSLock()
    private static var kept: [ArchiveScratch] = []

    static func keep(_ scratch: ArchiveScratch) {
        lock.lock()
        defer { lock.unlock() }
        kept.append(scratch)
        if kept.count > 4 { kept.removeFirst(kept.count - 4) }
    }
}
