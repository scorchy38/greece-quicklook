import AppKit

enum ParquetPage {
    static let sampleRows = 1_000

    static func prepare(_ file: FileInfo, settings: PreviewSettings, modified: String?) throws -> PreparedPreview {
        let parquet = try ParquetFile.open(file.url)
        let (values, reasons) = parquet.firstRows(file.url, limit: sampleRows)
        var details = facts(parquet)
        details += parquet.codecs.filter { $0 != ParquetFile.codecName(0) }
        if let size = file.sizeText { details.append(size) }
        let summary = FileSummary(symbol: "square.stack.3d.up", title: "Parquet", details: details, trailing: modified)
        let store = table(parquet, values: values, reasons: reasons)
        let readable = values.contains { $0 != nil }
        return .native(summary, NSSize(width: 1060, height: 720)) { settings in
            ParquetView(parquet: parquet, store: store, readable: readable, settings: settings)
        }
    }

    /// "1,204 rows", "12 columns", "3 row groups".
    static func facts(_ parquet: ParquetFile) -> [String] {
        let rows = Int(clamping: parquet.rows), columns = parquet.columns.count, groups = parquet.groups.count
        return [String(localized: "\(rows) rows", bundle: .greeceKit, comment: "Rows in a table"),
                String(localized: "\(columns) columns", bundle: .greeceKit, comment: "Columns in a table"),
                String(localized: "\(groups) row groups", bundle: .greeceKit, comment: "Row groups (blocks of rows) in a Parquet file")]
    }

    static func table(_ parquet: ParquetFile, values: [[GridValue]?], reasons: [String?]) -> RecordTable {
        let rows = values.compactMap { $0?.count }.max() ?? 0
        let columns = parquet.columns.enumerated().map { index, column -> RecordColumn in
            let numeric = [.int32, .int64, .float, .double].contains(column.physical) && [.plain, .decimal, .unsigned].contains(column.kind)
            var tip = parquet.typeName(column)
            if let reason = reasons[index] {
                tip += " · " + String(localized: "not shown: \(reason)", bundle: .greeceKit,
                                      comment: "Tooltip of a Parquet column whose values aren’t shown. The argument is why, such as “Nested” or a compression name")
            }
            return RecordColumn(title: column.name, toolTip: tip, numeric: numeric, sort: numeric ? .numeric : .natural,
                                profiled: values[index] != nil, caption: parquet.typeName(column))
        }
        let grid: [[GridValue]] = (0..<rows).map { row in
            values.enumerated().map { index, column in
                guard let column else { return .placeholder(reasons[index] ?? "") }
                return row < column.count ? column[row] : .null
            }
        }
        return RecordTable(columns: columns, rows: grid)
    }
}

/// Rows and schema of a Parquet file: the first rows as a table, or the columns, row groups and
/// metadata.
final class ParquetView: NSView, PreviewSettingsAware {
    private let tableView: DataTableView
    private let schema: SchemaPageView
    private let modes = NSSegmentedControl(labels: [SchemaPageView.dataMode, SchemaPageView.schemaMode], trackingMode: .selectOne, target: nil, action: nil)

    init(parquet: ParquetFile, store: RecordTable, readable: Bool, settings: PreviewSettings) {
        var options = DataTableView.Options()
        options.leading = [modes]
        options.unit = .rows
        let shown = store.rowCount
        if shown < parquet.rows {
            let total = Int(clamping: parquet.rows)
            options.note = String(localized: "first \(shown) of \(total)", bundle: .greeceKit,
                                  comment: "After a Parquet table’s row count: only its first rows are read, such as “first 1,000 of 52,000”")
        }
        tableView = DataTableView(store: store, settings: settings, options: options)
        schema = ParquetSchemaView(parquet: parquet)
        super.init(frame: .zero)
        modes.segmentStyle = .automatic
        modes.controlSize = .small
        modes.target = self
        modes.action = #selector(modeChanged(_:))
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        var initial = readable ? 0 : 1
        #if DEBUG
        if ProcessInfo.processInfo.environment["GREECE_STATE"] == "schema" { initial = 1 }
        #endif
        modes.setEnabled(readable, forSegment: 0)
        modes.selectedSegment = initial
        modeChanged(modes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ settings: PreviewSettings) { tableView.apply(settings) }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        tableView.setAlternateContent(sender.selectedSegment == 1 ? schema : nil)
    }
}

final class ParquetSchemaView: SchemaPageView {
    init(parquet: ParquetFile) {
        super.init(frame: .zero)
        var facts = ParquetPage.facts(parquet)
        facts.append(ByteCountFormatter.string(fromByteCount: Int64(parquet.fileSize), countStyle: .file))
        addHeader(symbol: "square.stack.3d.up", title: "Parquet", subtitle: facts.joined(separator: " · "))

        // Columns, with sizes and statistics summed over row groups.
        let rows: [[SchemaTableView.Cell]] = parquet.columns.prefix(2000).enumerated().map { index, column in
            let chunks = parquet.groups.compactMap { index < $0.chunks.count ? $0.chunks[index] : nil }
            let compressed = chunks.reduce(0) { $0 + $1.compressed }
            let uncompressed = chunks.reduce(0) { $0 + $1.uncompressed }
            let nulls = chunks.compactMap(\.nulls)
            let codec = Set(chunks.map { ParquetFile.codecName($0.codec) }).sorted().joined(separator: ", ")
            let encodings = Set(chunks.flatMap(\.encodings)).filter { $0 != 3 && $0 != 4 }.map(ParquetFile.encodingName).sorted().joined(separator: ", ")
            let minimum = chunks.first.flatMap { parquet.statistic($0.minimum, column: column) }
            let maximum = chunks.last.flatMap { parquet.statistic($0.maximum, column: column) }
            let range = [minimum, maximum].compactMap { $0.map { String($0.prefix(24)) } }.joined(separator: " … ")
            let compressedText = ByteCountFormatter.string(fromByteCount: Int64(compressed), countStyle: .file)
            let uncompressedText = ByteCountFormatter.string(fromByteCount: Int64(uncompressed), countStyle: .file)
            let size = uncompressed > 0
                ? String(localized: "\(compressedText) of \(uncompressedText)", bundle: .greeceKit,
                         comment: "A Parquet column’s size: compressed, of uncompressed, such as “1.2 MB of 4.8 MB”")
                : ""
            return [
                .name(column.name, symbol: parquet.nested.contains(column.name) ? "list.bullet.indent" : nil),
                .code(parquet.typeName(column)),
                .plain(column.repetition),
                encodings.isEmpty ? .none : .plain(encodings),
                codec.isEmpty ? .none : .plain(codec),
                size.isEmpty ? .none : .plain(size),
                nulls.isEmpty ? .none : .plain(nulls.reduce(0, +).formatted()),
                range.isEmpty ? .none : .code(range),
            ]
        }
        addSection(SchemaPageView.columnsTitle, count: parquet.columns.count)
        let columnHeaders = [
            SchemaPageView.nameTitle, SchemaPageView.typeTitle,
            String(localized: "Repetition", bundle: .greeceKit, comment: "Column header in a Parquet schema: required, optional or repeated"),
            String(localized: "Encodings", bundle: .greeceKit, comment: "Column header in a Parquet schema: how values are encoded"),
            String(localized: "Compression", bundle: .greeceKit, comment: "Column header in a Parquet schema"),
            SchemaPageView.sizeTitle,
            String(localized: "Nulls", bundle: .greeceKit, comment: "Column header in a Parquet schema: how many values are null (missing)"),
            String(localized: "Range", bundle: .greeceKit, comment: "Column header in a Parquet schema: the smallest and largest values"),
        ]
        addFullWidth(SchemaCard(content: SchemaTableView(headers: columnHeaders, rows: rows, flexible: 7)))

        addSection(String(localized: "Row Groups", bundle: .greeceKit, comment: "Section title in a Parquet schema: blocks of rows stored together"), count: parquet.groups.count)
        let groups: [[SchemaTableView.Cell]] = parquet.groups.prefix(500).enumerated().map { index, group in
            let compressed = group.compressed > 0 ? group.compressed : group.chunks.reduce(0) { $0 + $1.compressed }
            let number = index + 1, rows = Int(clamping: group.rows)
            return [.name(String(localized: "Group \(number)", bundle: .greeceKit, comment: "A Parquet row group. The argument is its number")),
                    .plain(String(localized: "\(rows) rows", bundle: .greeceKit, comment: "Rows in a table")),
                    .plain(ByteCountFormatter.string(fromByteCount: Int64(group.bytes), countStyle: .file)),
                    .plain(ByteCountFormatter.string(fromByteCount: Int64(compressed), countStyle: .file))]
        }
        let groupHeaders = [
            String(localized: "Group", bundle: .greeceKit, comment: "Column header in a Parquet schema: a row group"),
            String(localized: "Rows", bundle: .greeceKit, comment: "Column header: how many rows"),
            SchemaPageView.sizeTitle,
            String(localized: "Compressed", bundle: .greeceKit, comment: "Column header in a Parquet schema: the size after compression"),
        ]
        addFullWidth(SchemaCard(content: SchemaTableView(headers: groupHeaders, rows: groups, flexible: 0)))

        var metadata: [[SchemaTableView.Cell]] = []
        if let createdBy = parquet.createdBy {
            metadata.append([.name(String(localized: "Created by", bundle: .greeceKit, comment: "Parquet metadata row: the software that wrote the file")), .plain(createdBy)])
        }
        metadata.append([.name(String(localized: "Format version", bundle: .greeceKit, comment: "Parquet metadata row: the version of the Parquet format")), .plain(String(parquet.version))])
        for (key, value) in parquet.metadata {
            // Embedded schemas (Arrow, pandas) are long and binary-ish: name them, don't print them.
            let characters = value.count
            let shown = key == "ARROW:schema"
                ? [String(localized: "Arrow schema", bundle: .greeceKit, comment: "Parquet metadata: an embedded Apache Arrow schema, named rather than shown"),
                   String(localized: "\(characters) characters", bundle: .greeceKit, comment: "The length of a text")].joined(separator: " · ")
                : value.count > 160 ? String(value.prefix(160)) + "…" : value
            metadata.append([.name(key), .code(shown.replacingOccurrences(of: "\n", with: " "))])
        }
        addSection(String(localized: "Metadata", bundle: .greeceKit, comment: "Section title in a Parquet schema: the file’s key–value metadata"))
        let metadataHeaders = [
            String(localized: "Key", bundle: .greeceKit, comment: "Column header: a metadata key"),
            String(localized: "Value", bundle: .greeceKit, comment: "Column header: a metadata value"),
        ]
        addFullWidth(SchemaCard(content: SchemaTableView(headers: metadataHeaders, rows: metadata, flexible: 1)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
