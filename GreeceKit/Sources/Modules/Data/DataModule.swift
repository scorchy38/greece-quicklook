import AppKit

/// Data files as tables: dBase/FoxPro, JSON Lines, HAR captures, lock files, string catalogs and
/// Parquet. (Delimited text and SQLite are Greece's own kinds; they share the same table views.)
enum DataModule: PreviewModule {
    static let id = "data"

    enum Kind: Equatable {
        case dbf, jsonLines, har, lockFile(LockFile.Format), stringCatalog, strings, stringsdict, parquet
    }

    static func kind(of file: FileInfo) -> Kind? {
        guard !file.isDirectory else { return nil }
        let probe = file.probe
        if let format = LockFile.format(forName: file.name), probe.isText { return .lockFile(format) }
        if probe.hasPrefix(Array("PAR1".utf8)), probe.bytes.count >= 8 { return .parquet }
        switch file.ext {
        case "dbf":
            return DBFTable.sniff(probe.bytes) ? .dbf : nil
        case "jsonl", "ndjson", "jsonlines":
            return JSONLinesTable.looksLikeRecords(probe) ? .jsonLines : nil
        case "har":
            return probe.isText && HARCapture.sniff(probe.text) ? .har : nil
        case "json":
            // A HAR capture saved as .json.
            return probe.isText && HARCapture.sniff(probe.text) && probe.text.contains("\"entries\"") ? .har : nil
        case "xcstrings":
            return probe.isText && probe.text.contains("\"strings\"") ? .stringCatalog : nil
        case "strings":
            return probe.isText || probe.hasPrefix(Array("bplist".utf8)) ? .strings : nil
        case "stringsdict":
            return probe.isText || probe.hasPrefix(Array("bplist".utf8)) ? .stringsdict : nil
        default:
            return nil
        }
    }

    static func claims(_ file: FileInfo) -> Bool { kind(of: file) != nil }

    static let tableSize = NSSize(width: 1060, height: 700)

    static func prepare(_ file: FileInfo, settings: PreviewSettings) throws -> PreparedPreview {
        guard let kind = kind(of: file) else { throw PreviewError.unsupported }
        let modified = file.modifiedText
        switch kind {
        case .jsonLines:
            guard let lines = try JSONLinesTable.load(file.url, maxRows: settings.maxRows) else {
                return try codeFallback(file, title: "JSON Lines", modified: modified)
            }
            let rows = lines.table.rowCount
            let records = lines.lines - lines.invalid
            let fields = lines.table.columns.count
            var details = [String(localized: "\(records) records", bundle: .greeceKit, comment: "Info bar detail: records (rows) in a data file"),
                           String(localized: "\(fields) fields", bundle: .greeceKit, comment: "Info bar detail: fields (columns) of a data file’s records")]
            if lines.invalid > 0 {
                let invalid = lines.invalid
                details.append(String(localized: "\(invalid) invalid lines", bundle: .greeceKit, comment: "Info bar detail: lines of a JSON Lines file that aren’t valid JSON"))
            }
            if lines.truncated { details.append(showingFirst(rows)) }
            if lines.skippedColumns > 0 {
                let shown = JSONLinesTable.maxColumns
                details.append(String(localized: "First \(shown) fields", bundle: .greeceKit, comment: "Info bar detail: only this many fields of a JSON Lines file are shown"))
            }
            let summary = FileSummary(symbol: "list.bullet.rectangle", title: "JSON Lines", details: details, trailing: modified)
            var options = DataTableView.Options()
            options.unit = .records
            return .native(summary, tableSize) { settings in DataTableView(store: lines.table, settings: settings, options: options) }

        case .lockFile(let format):
            guard let lock = try LockFile.load(file.url) else {
                return try codeFallback(file, title: String(localized: "Lock File", bundle: .greeceKit, comment: "Info bar title: a package manager’s lock file"), modified: modified)
            }
            let packages = lock.packages.count
            var details = [String(localized: "\(packages) packages", bundle: .greeceKit, comment: "Info bar detail: packages a lock file pins")]
            if lock.knowsDirect {
                let direct = lock.direct
                details.append(String(localized: "\(direct) direct", bundle: .greeceKit, comment: "Info bar detail: packages a project depends on directly, not through other packages"))
            }
            if let detail = lock.detail { details.append(detail) }
            let ecosystem = format.ecosystem
            let summary = FileSummary(symbol: "lock.doc", title: String(localized: "\(ecosystem) Lock File", bundle: .greeceKit,
                                                                        comment: "Info bar title. The argument is a package manager, such as “Cargo” or “npm”"),
                                      details: details, trailing: modified)
            let store = lockStore(lock)
            var options = DataTableView.Options()
            options.unit = .packages
            options.filterPlaceholder = String(localized: "Filter Packages", bundle: .greeceKit, comment: "Placeholder of a lock file table’s filter field")
            options.profiles = false
            return .native(summary, NSSize(width: 860, height: 680)) { settings in DataTableView(store: store, settings: settings, options: options) }

        case .stringCatalog:
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            guard data.count < 64 * 1024 * 1024, let catalog = StringTable.catalog(data) else {
                return try codeFallback(file, title: StringTable.catalogTitle, modified: modified)
            }
            return stringsPreview(catalog, symbol: "globe", modified: modified)

        case .strings:
            guard let table = try StringTable.strings(file.url) else { return try codeFallback(file, title: StringTable.stringsTitle, modified: modified) }
            return stringsPreview(table, symbol: "text.bubble", modified: modified)

        case .stringsdict:
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            guard data.count < 32 * 1024 * 1024, let rules = StringTable.stringsdict(data) else {
                return try codeFallback(file, title: StringTable.stringsdictTitle, modified: modified)
            }
            let keys = Set(rules.map(\.key)).count
            let count = rules.count
            let summary = FileSummary(symbol: "text.bubble", title: StringTable.stringsdictTitle,
                                      details: [String(localized: "\(keys) keys", bundle: .greeceKit, comment: "Info bar detail: keys in a .stringsdict file"),
                                                String(localized: "\(count) plural rules", bundle: .greeceKit, comment: "Info bar detail: plural rules in a .stringsdict file")],
                                      trailing: modified)
            let store = StringTable.stringsdictStore(rules)
            var options = DataTableView.Options()
            options.unit = .rules
            options.profiles = false
            return .native(summary, tableSize) { settings in DataTableView(store: store, settings: settings, options: options) }

        case .dbf:
            let table = try DBFTable.load(file.url, maxRecords: settings.maxRows)
            let visible = table.fields.filter { !$0.isSystem }.count
            let records = table.recordCount
            var details = [String(localized: "\(records) records", bundle: .greeceKit, comment: "Info bar detail: records (rows) in a data file"),
                           String(localized: "\(visible) fields", bundle: .greeceKit, comment: "Info bar detail: fields (columns) of a data file’s records")]
            let deleted = table.deleted.count
            let deletedText = String(localized: "\(deleted) deleted", bundle: .greeceKit, comment: "Records of a dBase table marked as deleted")
            if deleted > 0 { details.append(deletedText) }
            details.append(table.encodingName)
            if let memo = table.memoFile { details.append(memo) }
            if table.truncated { details.append(showingFirst(table.rows.count)) }
            let summary = FileSummary(symbol: "tablecells", title: table.versionName, details: details, trailing: modified)
            let store = table.store()
            var options = DataTableView.Options()
            options.unit = .records
            if deleted > 0 { options.note = deletedText }
            return .native(summary, tableSize) { settings in DataTableView(store: store, settings: settings, options: options) }

        case .har:
            return try HARPage.prepare(file, modified: modified)

        case .parquet:
            return try ParquetPage.prepare(file, settings: settings, modified: modified)
        }
    }

    static func thumbnail(_ file: FileInfo, size: CGSize, settings: PreviewSettings) -> ThumbnailPage? {
        DataThumbnails.page(for: file, kind: kind(of: file), size: size)
    }

    // MARK: - Shared

    /// "Showing first 1,000": a long file's info bar, when only its start is read.
    static func showingFirst(_ count: Int) -> String {
        String(localized: "Showing first \(count)", bundle: .greeceKit, comment: "Info bar detail: only this many rows or entries of a long file are shown")
    }

    static func lockStore(_ lock: LockFile) -> RecordTable {
        var columns = [
            RecordColumn(title: String(localized: "Package", bundle: .greeceKit, comment: "Column header in a lock file’s table"), profiled: false),
            RecordColumn(title: String(localized: "Version", bundle: .greeceKit, comment: "Column header in a lock file’s table"), profiled: false),
            RecordColumn(title: String(localized: "Source", bundle: .greeceKit, comment: "Column header in a lock file’s table: where a package comes from"), profiled: false),
        ]
        if lock.knowsDirect {
            columns.append(RecordColumn(title: String(localized: "Dependency", bundle: .greeceKit, comment: "Column header in a lock file’s table: direct, dev, transitive…"),
                                        profiled: false, width: 130))
        }
        let rows: [[GridValue]] = lock.packages.map { package in
            let source = package.source == LockFile.localSource
                ? String(localized: "local", bundle: .greeceKit, comment: "Source of a package in a lock file: a folder on disk, not a registry")
                : package.source
            var row: [GridValue] = [.text(package.name), .text(package.version), source.isEmpty ? .placeholder("") : .secondary(source)]
            if lock.knowsDirect {
                row.append(package.kind == .unknown ? .placeholder("") : .status(package.kind.title, package.kind.tint))
            }
            return row
        }
        return RecordTable(columns: columns, rows: rows)
    }

    private static func stringsPreview(_ table: StringTable, symbol: String, modified: String?) -> PreparedPreview {
        let strings = table.rows.count
        var details = [String(localized: "\(strings) strings", bundle: .greeceKit, comment: "Info bar detail: translatable strings in a strings file or string catalog")]
        if table.languages.count > 1 || table.sourceLanguage != nil {
            let languages = table.languages.count
            details.append(String(localized: "\(languages) languages", bundle: .greeceKit, comment: "Info bar detail: languages a string catalog holds"))
        }
        if table.languages.count > 1, table.sourceLanguage != nil {
            let share = ColumnProfile.percent(table.overallCompletion)
            details.append(String(localized: "\(share) translated", bundle: .greeceKit, comment: "Info bar detail: how much of a string catalog is translated, such as “84% translated”"))
        }
        let summary = FileSummary(symbol: symbol, title: table.title, details: details, trailing: modified)
        let store = table.store()
        var options = DataTableView.Options()
        options.unit = .strings
        options.filterPlaceholder = String(localized: "Filter Strings", bundle: .greeceKit, comment: "Placeholder of a string catalog table’s filter field")
        options.profiles = false
        if table.languages.count > 1 {
            options.strip = { table.strip(forColumn: $0) }
            options.stripHeight = 22
        }
        return .native(summary, tableSize) { settings in DataTableView(store: store, settings: settings, options: options) }
    }

    /// Files that turn out not to be what their name says still read well as text.
    static func codeFallback(_ file: FileInfo, title: String, modified: String?) throws -> PreparedPreview {
        let text = try TextFile(url: file.url)
        let grammar = file.probe.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") || file.probe.text.hasPrefix("[") ? "json" : "plaintext"
        let lines = text.lineCount
        var details = [String(localized: "\(lines) lines", bundle: .greeceKit, comment: "Info bar detail: lines in a text file")]
        if let size = file.sizeText { details.append(size) }
        let summary = FileSummary(symbol: "doc.text", title: title, details: details, trailing: modified)
        return .web(WebDocument(kind: .code, text: text.text, grammar: grammar, truncated: text.truncated), summary, NSSize(width: 920, height: 720))
    }
}
