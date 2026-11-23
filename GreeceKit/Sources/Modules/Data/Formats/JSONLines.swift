import Foundation

/// JSON Lines / NDJSON as a table: one row a line, one column a key (the union of every object's
/// keys, in the order they first appear), nested values shown as compact JSON.
struct JSONLinesTable {
    var table: RecordTable
    /// Lines read (non-empty), lines that weren't JSON objects, and lines past the row limit.
    var lines = 0
    var invalid = 0
    var skippedColumns = 0
    var truncated = false

    static let maxColumns = 200
    static let readLimit = 64 * 1024 * 1024

    /// True when the first non-empty line starts an object: JSON Lines of records. (GeoJSON
    /// features are left to the map preview.)
    static func looksLikeRecords(_ probe: FileProbe) -> Bool {
        guard probe.isText else { return false }
        let text = probe.text
        guard let first = text.split(separator: "\n", omittingEmptySubsequences: true).first?.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }),
              first.hasPrefix("{") else { return false }
        let compact = first.replacingOccurrences(of: " ", with: "")
        return !(compact.contains("\"type\":\"Feature\"") && compact.contains("\"geometry\""))
    }

    /// Nil when most lines aren't objects (then the file reads better as code).
    static func load(_ url: URL, maxRows: Int) throws -> JSONLinesTable? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: readLimit) ?? Data()
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
        return data.withUnsafeBytes { raw in parse(raw.bindMemory(to: UInt8.self), maxRows: maxRows, cut: fileSize > data.count) }
    }

    static func parse(_ text: String, maxRows: Int = 100_000) -> JSONLinesTable? {
        var text = text
        return text.withUTF8 { parse($0, maxRows: maxRows, cut: false) }
    }

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>, maxRows: Int, cut: Bool) -> JSONLinesTable? {
        var keys: [String] = []
        var keyIndex: [String: Int] = [:]
        var skipped = Set<String>()
        var records: [[Int: JSONValue]] = []
        var lines = 0, invalid = 0, objects = 0, sampled = 0
        var start = 0
        var reachedLimit = false
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            var line = UnsafeBufferPointer(rebasing: bytes[start..<end])
            if let last = line.last, last == 0x0D { line = UnsafeBufferPointer(rebasing: line.dropLast()) }
            start = end + 1
            // Blank lines don't count.
            guard line.contains(where: { $0 != 0x20 && $0 != 0x09 }) else { continue }
            lines += 1
            if reachedLimit { continue }
            if records.count >= maxRows { reachedLimit = true; continue }
            guard let value = try? JSONReader.parse(line, maxDepth: 64), case .object(let pairs) = value else {
                invalid += 1
                sampled += 1
                // Mostly not objects: not a table.
                if sampled == 100, objects * 2 < sampled { return nil }
                continue
            }
            objects += 1
            sampled += 1
            var record: [Int: JSONValue] = [:]
            for (key, value) in pairs {
                var index = keyIndex[key]
                if index == nil {
                    if keys.count < maxColumns {
                        index = keys.count
                        keyIndex[key] = keys.count
                        keys.append(key)
                    } else {
                        skipped.insert(key)
                        continue
                    }
                }
                record[index!] = value
            }
            records.append(record)
        }
        guard objects > 0, objects * 2 >= objects + invalid || objects >= 100 else { return nil }

        // Column shapes: numbers right-aligned and sorted as numbers.
        var numeric = [Bool](repeating: true, count: keys.count)
        var seen = [Bool](repeating: false, count: keys.count)
        var kinds = [Set<String>](repeating: [], count: keys.count)
        for record in records {
            for (index, value) in record {
                switch value {
                case .number: kinds[index].insert("number"); seen[index] = true
                case .null: break
                case .string: kinds[index].insert("string"); numeric[index] = false; seen[index] = true
                case .bool: kinds[index].insert("boolean"); numeric[index] = false; seen[index] = true
                case .object: kinds[index].insert("object"); numeric[index] = false; seen[index] = true
                case .array: kinds[index].insert("array"); numeric[index] = false; seen[index] = true
                }
            }
        }
        let columns = keys.indices.map { index -> RecordColumn in
            let isNumeric = numeric[index] && seen[index]
            let caption = kinds[index].sorted().joined(separator: " · ")
            return RecordColumn(title: keys[index], toolTip: caption.isEmpty ? nil : caption, numeric: isNumeric,
                                sort: isNumeric ? .numeric : .natural, profiled: true, caption: caption)
        }
        let rows: [[GridValue]] = records.map { record in
            (0..<keys.count).map { index in
                guard let value = record[index] else { return .placeholder("") }
                switch value {
                case .string(let s): return .text(s)
                case .number(let n): return .text(n)
                case .bool(let b): return .text(b ? "true" : "false")
                case .null: return .placeholder("null")
                case .object, .array: return .secondary(value.compact())
                }
            }
        }
        var result = JSONLinesTable(table: RecordTable(columns: columns, rows: rows))
        result.lines = lines
        result.invalid = invalid
        result.skippedColumns = skipped.count
        result.truncated = reachedLimit || cut
        return result
    }
}
