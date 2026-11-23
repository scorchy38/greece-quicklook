import AppKit

/// Finder thumbnails for data files: a page with a title strip and the file's first rows, a
/// waterfall for network captures, translation progress for string catalogs.
enum DataThumbnails {

    static func page(for file: FileInfo, kind: DataModule.Kind?, size: CGSize) -> ThumbnailPage? {
        guard let kind else { return nil }
        let page = Thumbnailer.pageSize(fitting: size)
        let badge = file.ext.isEmpty ? "DATA" : file.ext.uppercased()
        switch kind {
        case .jsonLines:
            guard let lines = try? JSONLinesTable.load(file.url, maxRows: 40) else { return nil }
            let fields = lines.table.columns.count
            return table(lines.table, title: file.url.deletingPathExtension().lastPathComponent,
                         subtitle: String(localized: "\(fields) fields", bundle: .greeceKit, comment: "Thumbnail caption: fields (columns) of a data file’s records"),
                         size: page, badge: badge)
        case .dbf:
            guard let dbf = try? DBFTable.load(file.url, maxRecords: 40) else { return nil }
            return table(dbf.store(), title: file.url.deletingPathExtension().lastPathComponent,
                         subtitle: records(dbf.recordCount), size: page, badge: badge)
        case .parquet:
            guard let parquet = try? ParquetFile.open(file.url) else { return nil }
            let (values, reasons) = parquet.firstRows(file.url, limit: 40)
            let store = ParquetPage.table(parquet, values: values, reasons: reasons)
            return table(store, title: file.url.deletingPathExtension().lastPathComponent,
                         subtitle: rows(Int(clamping: parquet.rows)), size: page, badge: "PARQUET")
        case .lockFile(let format):
            guard let lock = try? LockFile.load(file.url) else { return nil }
            return ThumbnailPage(size: page, badge: "LOCK") { rect in drawLock(lock, format: format, in: rect) }
        case .har:
            guard let capture = try? HARCapture.load(file.url) else { return nil }
            return ThumbnailPage(size: page, badge: "HAR") { rect in drawWaterfall(capture.summary, in: rect) }
        case .stringCatalog:
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe), data.count < 64 * 1024 * 1024,
                  let catalog = StringTable.catalog(data) else { return nil }
            return ThumbnailPage(size: page, badge: "XCSTRINGS") { rect in drawLanguages(catalog, in: rect) }
        case .strings:
            guard let table = try? StringTable.strings(file.url) else { return nil }
            if table.languages.count > 1 { return ThumbnailPage(size: page, badge: "STRINGS") { rect in drawLanguages(table, in: rect) } }
            let strings = table.rows.count
            return self.table(table.store(), title: file.url.deletingPathExtension().lastPathComponent,
                              subtitle: String(localized: "\(strings) strings", bundle: .greeceKit, comment: "Thumbnail caption: translatable strings in a strings file"),
                              size: page, badge: "STRINGS")
        case .stringsdict:
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe), let rules = StringTable.stringsdict(data) else { return nil }
            let count = rules.count
            return table(StringTable.stringsdictStore(rules), title: file.url.deletingPathExtension().lastPathComponent,
                         subtitle: String(localized: "\(count) rules", bundle: .greeceKit, comment: "Thumbnail caption: plural rules in a .stringsdict file"),
                         size: page, badge: "STRINGSDICT")
        }
    }

    /// "1.2K rows" under a thumbnail's title: compact once it's in the thousands.
    static func rows(_ count: Int) -> String {
        guard count >= 1_000 else { return String(localized: "\(count) rows", bundle: .greeceKit, comment: "Rows in a table") }
        let compact = ColumnProfile.short(Double(count))
        return String(localized: "\(compact) rows", bundle: .greeceKit, comment: "Thumbnail caption: rows in a table. The argument is a compact number, such as “1.2K”")
    }

    /// "1.2K records" under a thumbnail's title: compact once it's in the thousands.
    static func records(_ count: Int) -> String {
        guard count >= 1_000 else { return String(localized: "\(count) records", bundle: .greeceKit, comment: "Records (rows) in a data file") }
        let compact = ColumnProfile.short(Double(count))
        return String(localized: "\(compact) records", bundle: .greeceKit, comment: "Thumbnail caption: records in a data file. The argument is a compact number, such as “1.2K”")
    }

    // MARK: - Shared drawing

    private static let ink = NSColor(white: 0.11, alpha: 1)
    private static let secondary = NSColor(white: 0.45, alpha: 1)
    private static let tertiary = NSColor(white: 0.62, alpha: 1)
    private static let rule = NSColor(white: 0.88, alpha: 1)
    private static let stripe = NSColor(white: 0.972, alpha: 1)
    private static let accent = NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)

    private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, mono: Bool = false,
                             align: NSTextAlignment = .left, in rect: CGRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: string.replacingOccurrences(of: "\n", with: " "), attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let height = ceil(attributed.size().height)
        attributed.draw(with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The page and its title strip; returns the area below the strip.
    private static func frame(_ rect: CGRect, title: String, subtitle: String?) -> CGRect {
        NSColor.white.setFill()
        rect.fill()
        let padding = rect.width * 0.065
        let titleSize = max(rect.width / 24, 1)
        let strip = CGRect(x: rect.minX + padding, y: rect.maxY - padding - titleSize * 1.6, width: rect.width - padding * 2, height: titleSize * 1.6)
        var titleWidth = strip.width
        if let subtitle {
            let subtitleWidth = min(strip.width * 0.45, (subtitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: titleSize * 0.8)]).width + 4)
            text(subtitle, size: titleSize * 0.8, color: secondary, mono: true, align: .right,
                 in: CGRect(x: strip.maxX - subtitleWidth, y: strip.minY, width: subtitleWidth, height: strip.height))
            titleWidth -= subtitleWidth + titleSize * 0.6
        }
        text(title, size: titleSize, weight: .semibold, color: ink, in: CGRect(x: strip.minX, y: strip.minY, width: titleWidth, height: strip.height))
        return CGRect(x: rect.minX + padding, y: rect.minY + padding, width: rect.width - padding * 2, height: strip.minY - rect.minY - padding - titleSize * 0.7)
    }

    /// A table of the first rows: header, hairlines, numbers right-aligned.
    static func table(_ store: RecordStore, title: String, subtitle: String?, size: CGSize, badge: String) -> ThumbnailPage? {
        guard !store.columns.isEmpty else { return nil }
        return ThumbnailPage(size: size, badge: badge) { rect in
            let area = frame(rect, title: title, subtitle: subtitle)
            drawRows(store, in: area, pageWidth: rect.width)
        }
    }

    static func drawRows(_ store: RecordStore, in area: CGRect, pageWidth: CGFloat) {
        let fontSize = max(pageWidth / 40, 1)
        let rowHeight = fontSize * 1.85
        // As many columns as fit at a readable width.
        let count = min(store.columns.count, max(2, Int(area.width / (fontSize * 9))))
        let columnWidth = area.width / CGFloat(count)
        var top = area.maxY
        // Header
        let header = CGRect(x: area.minX, y: top - rowHeight, width: area.width, height: rowHeight)
        NSColor(white: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: header, xRadius: fontSize * 0.3, yRadius: fontSize * 0.3).fill()
        for column in 0..<count {
            let info = store.columns[column]
            text(info.title, size: fontSize, weight: .semibold, color: ink, align: info.numeric ? .right : .left,
                 in: CGRect(x: area.minX + CGFloat(column) * columnWidth + fontSize * 0.45, y: header.minY, width: columnWidth - fontSize * 0.9, height: rowHeight))
        }
        top -= rowHeight
        var row = 0
        while top - rowHeight >= area.minY, row < store.rowCount {
            let frame = CGRect(x: area.minX, y: top - rowHeight, width: area.width, height: rowHeight)
            if row % 2 == 1 { stripe.setFill(); frame.fill() }
            rule.setFill()
            CGRect(x: area.minX, y: frame.minY, width: area.width, height: max(pageWidth / 1000, 0.5)).fill()
            for column in 0..<count {
                let info = store.columns[column]
                let value = store.value(row: row, column: column)
                let color: NSColor
                switch value {
                case .text: color = store.isDimmed(row: row) ? tertiary : NSColor(white: 0.2, alpha: 1)
                case .null, .placeholder: color = tertiary
                default: color = secondary
                }
                let string: String
                switch value {
                case .null: string = "NULL"
                case .placeholder(let s): string = s
                case .blob(let n): string = "BLOB \(n)"
                default: string = value.plainText
                }
                text(string, size: fontSize, color: color, mono: true, align: info.numeric ? .right : .left,
                     in: CGRect(x: area.minX + CGFloat(column) * columnWidth + fontSize * 0.45, y: frame.minY, width: columnWidth - fontSize * 0.9, height: rowHeight))
            }
            top -= rowHeight
            row += 1
        }
    }

    // MARK: - Delimited text

    static func delimited(_ table: DelimitedTable, title: String, badge: String, size: CGSize) -> ThumbnailPage? {
        guard table.columnCount > 0 else { return nil }
        let rows = table.totalRows
        return self.table(DelimitedStore(table: table), title: title, subtitle: self.rows(rows), size: size, badge: badge)
    }

    // MARK: - SQLite

    static func sqlite(_ url: URL, size: CGSize) -> ThumbnailPage? {
        guard let sample = SQLiteDatabase.thumbnailSample(url) else { return nil }
        let page = Thumbnailer.pageSize(fitting: size)
        let ext = url.pathExtension.uppercased()
        var subtitle = sample.rows.map(rows)
        if sample.tables > 1 {
            let tables = sample.tables
            subtitle = String(localized: "\(tables) tables", bundle: .greeceKit, comment: "Tables in a database")
        }
        return table(sample.store, title: sample.name, subtitle: subtitle, size: page, badge: ext.isEmpty ? "SQLITE" : ext)
    }

    // MARK: - Lock files

    static func drawLock(_ lock: LockFile, format: LockFile.Format, in rect: CGRect) {
        let packageCount = lock.packages.count
        let area = frame(rect, title: format.ecosystem, subtitle: String(localized: "\(packageCount) packages", bundle: .greeceKit, comment: "Packages a lock file pins"))
        let fontSize = max(rect.width / 36, 1)
        let rowHeight = fontSize * 1.75
        // Direct dependencies first: they're what the project asks for.
        let packages = lock.packages.sorted { a, b in
            let da = a.kind == .direct || a.kind == .directDev, db = b.kind == .direct || b.kind == .directDev
            return da != db ? da : false
        }
        var top = area.maxY
        for package in packages {
            guard top - rowHeight >= area.minY else { break }
            let row = CGRect(x: area.minX, y: top - rowHeight, width: area.width, height: rowHeight)
            let dot = fontSize * 0.42
            let tint: NSColor = package.kind == .direct ? accent : package.kind == .directDev ? .systemPurple : NSColor(white: 0.8, alpha: 1)
            tint.setFill()
            NSBezierPath(ovalIn: CGRect(x: row.minX, y: row.midY - dot / 2, width: dot, height: dot)).fill()
            let nameX = row.minX + dot + fontSize * 0.6
            let versionWidth = row.width * 0.32
            text(package.name, size: fontSize, weight: package.kind == .direct || package.kind == .directDev ? .medium : .regular, color: ink,
                 in: CGRect(x: nameX, y: row.minY, width: row.maxX - nameX - versionWidth, height: rowHeight))
            text(package.version, size: fontSize * 0.92, color: secondary, mono: true, align: .right,
                 in: CGRect(x: row.maxX - versionWidth, y: row.minY, width: versionWidth, height: rowHeight))
            rule.setFill()
            CGRect(x: nameX, y: row.minY, width: row.maxX - nameX, height: max(rect.width / 1000, 0.5)).fill()
            top -= rowHeight
        }
    }

    // MARK: - HAR

    static func drawWaterfall(_ summary: HARCapture.Summary, in rect: CGRect) {
        let title = summary.pages.first?.title.isEmpty == false ? summary.pages.first!.title
            : String(localized: "Network", bundle: .greeceKit, comment: "Thumbnail title of a network capture (.har) without a page title")
        let requests = summary.entries.count
        let area = frame(rect, title: title, subtitle: String(localized: "\(requests) requests", bundle: .greeceKit, comment: "Network requests in an HTTP Archive"))
        let fontSize = max(rect.width / 44, 1)
        let rowHeight = fontSize * 1.7
        let nameWidth = area.width * 0.42
        let fall = CGRect(x: area.minX + nameWidth + fontSize, y: area.minY, width: area.width - nameWidth - fontSize, height: area.height)
        let total = max(summary.duration, 1)
        let rows = Int(area.height / rowHeight)
        let entries = summary.entries.sorted { $0.start < $1.start }.prefix(rows)
        // Page markers.
        for page in summary.pages.prefix(1) {
            for (value, color) in [(page.contentLoad, NSColor.systemBlue), (page.load, NSColor.systemRed)] {
                guard let value else { continue }
                color.withAlphaComponent(0.45).setFill()
                CGRect(x: fall.minX + fall.width * CGFloat(value / total), y: area.minY, width: max(rect.width / 700, 0.5), height: area.height).fill()
            }
        }
        var top = area.maxY
        for entry in entries {
            let row = CGRect(x: area.minX, y: top - rowHeight, width: area.width, height: rowHeight)
            let name = entry.path.split(separator: "?").first.flatMap { $0.split(separator: "/").last }.map(String.init) ?? entry.host
            let failing = entry.failed || entry.status >= 400
            text(name.isEmpty ? entry.host : name, size: fontSize, color: failing ? .systemRed : NSColor(white: 0.2, alpha: 1),
                 in: CGRect(x: row.minX, y: row.minY, width: nameWidth, height: rowHeight))
            let x = fall.minX + fall.width * CGFloat(entry.start / total)
            let width = max(fall.width * CGFloat(entry.time / total), rect.width / 300)
            let bar = CGRect(x: x, y: row.midY - fontSize * 0.32, width: min(width, fall.maxX - x), height: fontSize * 0.64)
            let wait = entry.timings.wait ?? 0, receive = entry.timings.receive ?? 0
            let before = max(0, entry.time - wait - receive)
            let parts: [(Double, NSColor)] = [(before, NSColor(white: 0.78, alpha: 1)),
                                              (wait, NSColor(srgbRed: 0.6, green: 0.86, blue: 0.66, alpha: 1)), (receive, accent)]
            var cursor = bar.minX
            let sum = max(parts.reduce(0) { $0 + $1.0 }, 0.0001)
            for (value, color) in parts where value > 0 {
                let w = bar.width * CGFloat(value / sum)
                color.setFill()
                CGRect(x: cursor, y: bar.minY, width: w, height: bar.height).fill()
                cursor += w
            }
            if parts.allSatisfy({ $0.0 <= 0 }) { accent.setFill(); bar.fill() }
            top -= rowHeight
        }
    }

    // MARK: - String catalogs

    static func drawLanguages(_ table: StringTable, in rect: CGRect) {
        let others = table.languages.filter { $0 != table.sourceLanguage }
        let languages = table.languages.count
        let area = frame(rect, title: table.title, subtitle: String(localized: "\(languages) languages", bundle: .greeceKit, comment: "Languages a string catalog holds"))
        let fontSize = max(rect.width / 34, 1)
        let rowHeight = fontSize * 2.1
        var top = area.maxY
        for language in [table.sourceLanguage].compactMap({ $0 }) + others {
            guard top - rowHeight >= area.minY else { break }
            let row = CGRect(x: area.minX, y: top - rowHeight, width: area.width, height: rowHeight)
            let name = Locale.current.localizedString(forIdentifier: language) ?? language
            let isSource = language == table.sourceLanguage
            let c = table.completion(language)
            let fraction = isSource ? 1 : (c.total == 0 ? 1 : Double(c.done) / Double(c.total))
            text(name, size: fontSize, weight: isSource ? .semibold : .regular, color: ink, in: CGRect(x: row.minX, y: row.minY, width: row.width * 0.4, height: rowHeight))
            let track = CGRect(x: row.minX + row.width * 0.42, y: row.midY - fontSize * 0.2, width: row.width * 0.38, height: fontSize * 0.4)
            NSColor(white: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
            (fraction >= 0.999 ? NSColor.systemGreen : accent).setFill()
            NSBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: max(track.height, track.width * CGFloat(fraction)), height: track.height),
                         xRadius: track.height / 2, yRadius: track.height / 2).fill()
            text(isSource ? String(localized: "source", bundle: .greeceKit, comment: "Thumbnail of a string catalog: beside the language strings are written in") : ColumnProfile.percent(fraction), size: fontSize * 0.9, color: secondary, mono: true, align: .right,
                 in: CGRect(x: row.maxX - row.width * 0.16, y: row.minY, width: row.width * 0.16, height: rowHeight))
            top -= rowHeight
        }
    }
}
