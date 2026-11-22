import AppKit

enum ParquetPage {
    static let sampleRows = 1_000

    static func prepare(_ file: FileInfo, settings: PreviewSettings, modified: String?) throws -> PreparedPreview {
        let parquet = try ParquetFile.open(file.url)
        let (values, reasons) = parquet.firstRows(file.url, limit: sampleRows)
        var details = ["\(parquet.rows.formatted()) \(parquet.rows == 1 ? "row" : "rows")",
                       "\(parquet.columns.count) \(parquet.columns.count == 1 ? "column" : "columns")",
                       "\(parquet.groups.count) row \(parquet.groups.count == 1 ? "group" : "groups")"]
        details += parquet.codecs.filter { $0 != "Uncompressed" }
        if let size = file.sizeText { details.append(size) }
        let summary = FileSummary(symbol: "square.stack.3d.up", title: "Parquet", details: details, trailing: modified)
        let store = table(parquet, values: values, reasons: reasons)
        let readable = values.contains { $0 != nil }
        return .native(summary, NSSize(width: 1060, height: 720)) { settings in
            ParquetView(parquet: parquet, store: store, readable: readable, settings: settings)
        }
    }

    static func table(_ parquet: ParquetFile, values: [[GridValue]?], reasons: [String?]) -> RecordTable {
        let rows = values.compactMap { $0?.count }.max() ?? 0
        let columns = parquet.columns.enumerated().map { index, column -> RecordColumn in
            let numeric = [.int32, .int64, .float, .double].contains(column.physical) && [.plain, .decimal, .unsigned].contains(column.kind)
            var tip = parquet.typeName(column)
            if let reason = reasons[index] { tip += " · not shown: \(reason)" }
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
    private let modes = NSSegmentedControl(labels: ["Data", "Schema"], trackingMode: .selectOne, target: nil, action: nil)

    init(parquet: ParquetFile, store: RecordTable, readable: Bool, settings: PreviewSettings) {
        var options = DataTableView.Options()
        options.leading = [modes]
        options.unit = ("row", "rows")
        let shown = store.rowCount
        if shown < parquet.rows { options.note = "first \(shown.formatted()) of \(parquet.rows.formatted())" }
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
        var facts = ["\(parquet.rows.formatted()) rows", "\(parquet.columns.count) columns", "\(parquet.groups.count) row \(parquet.groups.count == 1 ? "group" : "groups")"]
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
            let size = uncompressed > 0 ? "\(ByteCountFormatter.string(fromByteCount: Int64(compressed), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(uncompressed), countStyle: .file))" : ""
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
        addSection("Columns", count: parquet.columns.count)
        addFullWidth(SchemaCard(content: SchemaTableView(headers: ["Name", "Type", "Repetition", "Encodings", "Compression", "Size", "Nulls", "Range"],
                                                         rows: rows, flexible: 7)))

        addSection("Row Groups", count: parquet.groups.count)
        let groups: [[SchemaTableView.Cell]] = parquet.groups.prefix(500).enumerated().map { index, group in
            let compressed = group.compressed > 0 ? group.compressed : group.chunks.reduce(0) { $0 + $1.compressed }
            return [.name("Group \(index + 1)"), .plain("\(group.rows.formatted()) rows"),
                    .plain(ByteCountFormatter.string(fromByteCount: Int64(group.bytes), countStyle: .file)),
                    .plain(ByteCountFormatter.string(fromByteCount: Int64(compressed), countStyle: .file))]
        }
        addFullWidth(SchemaCard(content: SchemaTableView(headers: ["Group", "Rows", "Size", "Compressed"], rows: groups, flexible: 0)))

        var metadata: [[SchemaTableView.Cell]] = []
        if let createdBy = parquet.createdBy { metadata.append([.name("Created by"), .plain(createdBy)]) }
        metadata.append([.name("Format version"), .plain(String(parquet.version))])
        for (key, value) in parquet.metadata {
            // Embedded schemas (Arrow, pandas) are long and binary-ish: name them, don't print them.
            let shown = key == "ARROW:schema" ? "Arrow schema · \(value.count.formatted()) characters"
                : value.count > 160 ? String(value.prefix(160)) + "…" : value
            metadata.append([.name(key), .code(shown.replacingOccurrences(of: "\n", with: " "))])
        }
        addSection("Metadata")
        addFullWidth(SchemaCard(content: SchemaTableView(headers: ["Key", "Value"], rows: metadata, flexible: 1)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
