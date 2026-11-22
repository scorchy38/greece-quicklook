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
            var details = ["\(records.formatted()) \(records == 1 ? "record" : "records")",
                           "\(lines.table.columns.count) \(lines.table.columns.count == 1 ? "field" : "fields")"]
            if lines.invalid > 0 { details.append("\(lines.invalid.formatted()) invalid \(lines.invalid == 1 ? "line" : "lines")") }
            if lines.truncated { details.append("Showing first \(rows.formatted())") }
            if lines.skippedColumns > 0 { details.append("First \(JSONLinesTable.maxColumns) fields") }
            let summary = FileSummary(symbol: "list.bullet.rectangle", title: "JSON Lines", details: details, trailing: modified)
            var options = DataTableView.Options()
            options.unit = ("record", "records")
            return .native(summary, tableSize) { settings in DataTableView(store: lines.table, settings: settings, options: options) }

        case .lockFile(let format):
            guard let lock = try LockFile.load(file.url) else { return try codeFallback(file, title: "Lock File", modified: modified) }
            let packages = lock.packages.count
            var details = ["\(packages.formatted()) \(packages == 1 ? "package" : "packages")"]
            if lock.knowsDirect { details.append("\(lock.direct.formatted()) direct") }
            if let detail = lock.detail { details.append(detail) }
            let summary = FileSummary(symbol: "lock.doc", title: "\(format.ecosystem) Lock File", details: details, trailing: modified)
            let store = lockStore(lock)
            var options = DataTableView.Options()
            options.unit = ("package", "packages")
            options.filterPlaceholder = "Filter Packages"
            options.profiles = false
            return .native(summary, NSSize(width: 860, height: 680)) { settings in DataTableView(store: store, settings: settings, options: options) }

        case .stringCatalog:
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            guard data.count < 64 * 1024 * 1024, let catalog = StringTable.catalog(data) else {
                return try codeFallback(file, title: "String Catalog", modified: modified)
            }
            return stringsPreview(catalog, symbol: "globe", modified: modified)

        case .strings:
            guard let table = try StringTable.strings(file.url) else { return try codeFallback(file, title: "Strings", modified: modified) }
            return stringsPreview(table, symbol: "text.bubble", modified: modified)

        case .stringsdict:
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            guard data.count < 32 * 1024 * 1024, let rules = StringTable.stringsdict(data) else {
                return try codeFallback(file, title: "Strings Dictionary", modified: modified)
            }
            let keys = Set(rules.map(\.key)).count
            let summary = FileSummary(symbol: "text.bubble", title: "Strings Dictionary",
                                      details: ["\(keys) \(keys == 1 ? "key" : "keys")", "\(rules.count) plural \(rules.count == 1 ? "rule" : "rules")"], trailing: modified)
            let store = StringTable.stringsdictStore(rules)
            var options = DataTableView.Options()
            options.unit = ("rule", "rules")
            options.profiles = false
            return .native(summary, tableSize) { settings in DataTableView(store: store, settings: settings, options: options) }

        case .dbf:
            let table = try DBFTable.load(file.url, maxRecords: settings.maxRows)
            let visible = table.fields.filter { !$0.isSystem }.count
            var details = ["\(table.recordCount.formatted()) \(table.recordCount == 1 ? "record" : "records")",
                           "\(visible) \(visible == 1 ? "field" : "fields")"]
            if !table.deleted.isEmpty { details.append("\(table.deleted.count.formatted()) deleted") }
            details.append(table.encodingName)
            if let memo = table.memoFile { details.append(memo) }
            if table.truncated { details.append("Showing first \(table.rows.count.formatted())") }
            let summary = FileSummary(symbol: "tablecells", title: table.versionName, details: details, trailing: modified)
            let store = table.store()
            var options = DataTableView.Options()
            options.unit = ("record", "records")
            if !table.deleted.isEmpty { options.note = "\(table.deleted.count.formatted()) deleted" }
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

    static func lockStore(_ lock: LockFile) -> RecordTable {
        var columns = [
            RecordColumn(title: "Package", profiled: false),
            RecordColumn(title: "Version", profiled: false),
            RecordColumn(title: "Source", profiled: false),
        ]
        if lock.knowsDirect { columns.append(RecordColumn(title: "Dependency", profiled: false, width: 130)) }
        let rows: [[GridValue]] = lock.packages.map { package in
            var row: [GridValue] = [.text(package.name), .text(package.version), package.source.isEmpty ? .placeholder("") : .secondary(package.source)]
            if lock.knowsDirect {
                row.append(package.kind == .unknown ? .placeholder("") : .status(package.kind.rawValue, package.kind.tint))
            }
            return row
        }
        return RecordTable(columns: columns, rows: rows)
    }

    private static func stringsPreview(_ table: StringTable, symbol: String, modified: String?) -> PreparedPreview {
        var details = ["\(table.rows.count.formatted()) \(table.rows.count == 1 ? "string" : "strings")"]
        if table.languages.count > 1 || table.sourceLanguage != nil {
            details.append("\(table.languages.count) \(table.languages.count == 1 ? "language" : "languages")")
        }
        if table.languages.count > 1, table.sourceLanguage != nil { details.append("\(ColumnProfile.percent(table.overallCompletion)) translated") }
        let summary = FileSummary(symbol: symbol, title: table.title, details: details, trailing: modified)
        let store = table.store()
        var options = DataTableView.Options()
        options.unit = ("string", "strings")
        options.filterPlaceholder = "Filter Strings"
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
        var details = ["\(text.lineCount.formatted()) \(text.lineCount == 1 ? "line" : "lines")"]
        if let size = file.sizeText { details.append(size) }
        let summary = FileSummary(symbol: "doc.text", title: title, details: details, trailing: modified)
        return .web(WebDocument(kind: .code, text: text.text, grammar: grammar, truncated: text.truncated), summary, NSSize(width: 920, height: 720))
    }
}
