import Foundation
import CArchive

// MARK: - Thrift compact protocol

/// A value read from Thrift's compact protocol (what Parquet uses for its metadata).
indirect enum ThriftValue {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case binary(Data)
    case list([ThriftValue])
    case map([(ThriftValue, ThriftValue)])
    case structure([Int16: ThriftValue])

    subscript(field: Int16) -> ThriftValue? {
        if case .structure(let fields) = self { return fields[field] }
        return nil
    }
    var int: Int64? { if case .int(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var data: Data? { if case .binary(let v) = self { return v }; return nil }
    var string: String? { data.map { String(decoding: $0, as: UTF8.self) } }
    var list: [ThriftValue] { if case .list(let v) = self { return v }; return [] }
}

struct ThriftReader {
    enum Failure: Error { case truncated, malformed, tooLarge }
    private let bytes: Data
    private(set) var position: Int
    private var budget = 5_000_000

    init(_ bytes: Data, at position: Int = 0) {
        self.bytes = bytes
        self.position = bytes.startIndex + position
    }

    /// The bytes consumed so far, from where reading started.
    var offset: Int { position - bytes.startIndex }

    private mutating func byte() throws -> UInt8 {
        guard position < bytes.endIndex else { throw Failure.truncated }
        defer { position += 1 }
        return bytes[position]
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try byte()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw Failure.malformed }
        }
    }

    private mutating func zigzag() throws -> Int64 {
        let n = try varint()
        return Int64(bitPattern: (n >> 1) ^ (0 &- (n & 1)))
    }

    mutating func readStruct(depth: Int = 0) throws -> ThriftValue {
        guard depth < 32 else { throw Failure.tooLarge }
        var fields: [Int16: ThriftValue] = [:]
        var last: Int16 = 0
        while true {
            let header = try byte()
            if header == 0 { return .structure(fields) }
            let type = header & 0x0F
            let delta = Int16(header >> 4)
            let id = delta == 0 ? Int16(truncatingIfNeeded: try zigzag()) : last &+ delta
            last = id
            fields[id] = try value(type: type, depth: depth)
        }
    }

    private mutating func value(type: UInt8, depth: Int) throws -> ThriftValue {
        budget -= 1
        guard budget > 0 else { throw Failure.tooLarge }
        switch type {
        case 1: return .bool(true)
        case 2: return .bool(false)
        case 3: return .int(Int64(Int8(bitPattern: try byte())))
        case 4, 5, 6: return .int(try zigzag())
        case 7:
            var raw: UInt64 = 0
            for i in 0..<8 { raw |= UInt64(try byte()) << (8 * UInt64(i)) }
            return .double(Double(bitPattern: raw))
        case 8:
            let length = Int(try varint())
            guard length >= 0, length <= 64 * 1024 * 1024, position + length <= bytes.endIndex else { throw Failure.truncated }
            defer { position += length }
            return .binary(bytes[position..<position + length])
        case 9, 10:
            let header = try byte()
            var count = Int(header >> 4)
            if count == 15 { count = Int(try varint()) }
            let element = header & 0x0F
            guard count >= 0, count <= 1_000_000 else { throw Failure.tooLarge }
            var items: [ThriftValue] = []
            items.reserveCapacity(min(count, 4096))
            for _ in 0..<count {
                if element == 1 || element == 2 { items.append(.bool(try byte() == 1)) }
                else { items.append(try value(type: element, depth: depth + 1)) }
            }
            return .list(items)
        case 11:
            let count = Int(try varint())
            guard count >= 0, count <= 1_000_000 else { throw Failure.tooLarge }
            guard count > 0 else { return .map([]) }
            let types = try byte()
            var pairs: [(ThriftValue, ThriftValue)] = []
            for _ in 0..<count {
                pairs.append((try value(type: types >> 4, depth: depth + 1), try value(type: types & 0x0F, depth: depth + 1)))
            }
            return .map(pairs)
        case 12:
            return try readStruct(depth: depth + 1)
        default:
            throw Failure.malformed
        }
    }
}

// MARK: - Codecs

enum Snappy {
    enum Failure: Error { case malformed }

    static func decompress(_ input: Data, limit: Int = 256 * 1024 * 1024) throws -> Data {
        try input.withUnsafeBytes { raw -> Data in
            let src = raw.bindMemory(to: UInt8.self)
            var pos = 0
            func varint() throws -> Int {
                var result = 0, shift = 0
                while true {
                    guard pos < src.count, shift < 35 else { throw Failure.malformed }
                    let b = src[pos]; pos += 1
                    result |= Int(b & 0x7F) << shift
                    if b & 0x80 == 0 { return result }
                    shift += 7
                }
            }
            let length = try varint()
            guard length >= 0, length <= limit else { throw Failure.malformed }
            var out = [UInt8](repeating: 0, count: length)
            var o = 0
            while pos < src.count {
                let tag = src[pos]; pos += 1
                switch tag & 3 {
                case 0:
                    var len = Int(tag >> 2)
                    if len >= 60 {
                        let extra = len - 59
                        guard pos + extra <= src.count else { throw Failure.malformed }
                        len = 0
                        for i in 0..<extra { len |= Int(src[pos + i]) << (8 * i) }
                        pos += extra
                    }
                    len += 1
                    guard pos + len <= src.count, o + len <= length else { throw Failure.malformed }
                    for i in 0..<len { out[o + i] = src[pos + i] }
                    pos += len; o += len
                default:
                    let len: Int, offset: Int
                    switch tag & 3 {
                    case 1:
                        guard pos < src.count else { throw Failure.malformed }
                        len = Int((tag >> 2) & 7) + 4
                        offset = Int(tag >> 5) << 8 | Int(src[pos]); pos += 1
                    case 2:
                        guard pos + 2 <= src.count else { throw Failure.malformed }
                        len = Int(tag >> 2) + 1
                        offset = Int(src[pos]) | Int(src[pos + 1]) << 8; pos += 2
                    default:
                        guard pos + 4 <= src.count else { throw Failure.malformed }
                        len = Int(tag >> 2) + 1
                        offset = Int(src[pos]) | Int(src[pos + 1]) << 8 | Int(src[pos + 2]) << 16 | Int(src[pos + 3]) << 24; pos += 4
                    }
                    guard offset > 0, offset <= o, o + len <= length else { throw Failure.malformed }
                    // Copies may overlap themselves (runs): byte by byte.
                    for i in 0..<len { out[o + i] = out[o - offset + i] }
                    o += len
                }
            }
            guard o == length else { throw Failure.malformed }
            return Data(out)
        }
    }
}

enum Gzip {
    /// Inflates gzip or zlib data with a size cap.
    static func inflate(_ input: Data, expected: Int, limit: Int = 256 * 1024 * 1024) -> Data? {
        guard expected >= 0, expected <= limit else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(expected, 1))
        let status: Int32 = input.withUnsafeBytes { inBuffer in
            output.withUnsafeMutableBytes { outBuffer in
                stream.next_in = UnsafeMutablePointer(mutating: inBuffer.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = outBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outBuffer.count)
                return CArchive.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || status == Z_OK || status == Z_BUF_ERROR else { return nil }
        output.count = Int(stream.total_out)
        return output
    }
}

// MARK: - Parquet

/// A Parquet file's footer (schema, row groups, statistics) and, where its encodings allow, its first rows.
struct ParquetFile {
    enum Physical: Int { case boolean = 0, int32, int64, int96, float, double, byteArray, fixedLenByteArray }

    struct Column {
        var path: [String]
        var physical: Physical?
        var typeLength: Int
        var logical: String
        var repetition: String
        var maxDefinition: Int
        var maxRepetition: Int
        var scale: Int
        /// Formatting hints from the logical type.
        var kind: Kind
        enum Kind { case plain, string, date, timestampMillis, timestampMicros, timestampNanos, timeMillis, timeMicros, decimal, unsigned, uuid, json }
        var name: String { path.joined(separator: ".") }
    }

    struct ColumnChunk {
        var codec: Int
        var encodings: [Int]
        var values: Int
        var compressed: Int
        var uncompressed: Int
        var dataOffset: Int
        var dictionaryOffset: Int?
        var nulls: Int?
        var minimum: Data?
        var maximum: Data?
    }

    struct RowGroup {
        var rows: Int
        var bytes: Int
        var compressed: Int
        var chunks: [ColumnChunk]
    }

    var version: Int
    var rows: Int
    var createdBy: String?
    var columns: [Column]
    /// Columns nested in structs, lists or maps (shown in the schema, not as table columns).
    var nested: [String]
    var groups: [RowGroup]
    var metadata: [(String, String)]
    var fileSize: Int

    static let maxFooter = 64 * 1024 * 1024

    enum Failure: Error { case notParquet, malformed }

    static func open(_ url: URL) throws -> ParquetFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        guard size >= 12 else { throw Failure.notParquet }
        try handle.seek(toOffset: UInt64(size - 8))
        let tail = try handle.read(upToCount: 8) ?? Data()
        guard tail.count == 8, tail.suffix(4) == Data("PAR1".utf8) else { throw Failure.notParquet }
        let length = Int(UInt32(tail[tail.startIndex]) | UInt32(tail[tail.startIndex + 1]) << 8 | UInt32(tail[tail.startIndex + 2]) << 16 | UInt32(tail[tail.startIndex + 3]) << 24)
        guard length > 0, length <= maxFooter, length <= size - 12 else { throw Failure.malformed }
        try handle.seek(toOffset: UInt64(size - 8 - length))
        let footer = try handle.read(upToCount: length) ?? Data()
        return try parse(footer: footer, fileSize: size)
    }

    static func parse(footer: Data, fileSize: Int) throws -> ParquetFile {
        var reader = ThriftReader(footer)
        let meta = try reader.readStruct()
        let schema = meta[2]?.list ?? []
        guard !schema.isEmpty else { throw Failure.malformed }

        // Walk the flattened schema tree: depth-first, children counted on each group.
        var columns: [Column] = []
        var nested: [String] = []
        var index = 1
        func walk(prefix: [String], definition: Int, repetition: Int, count: Int, insideGroup: Bool) {
            for _ in 0..<count {
                guard index < schema.count, index < 100_000 else { return }
                let element = schema[index]
                index += 1
                let name = element[4]?.string ?? "?"
                let repetitionType = Int(element[3]?.int ?? 0)
                let def = definition + (repetitionType == 0 ? 0 : 1)
                let rep = repetition + (repetitionType == 2 ? 1 : 0)
                let children = Int(element[5]?.int ?? 0)
                if children > 0 {
                    walk(prefix: prefix + [name], definition: def, repetition: rep, count: children, insideGroup: true)
                    continue
                }
                var column = Column(path: prefix + [name], physical: element[1]?.int.flatMap { Physical(rawValue: Int($0)) },
                                    typeLength: Int(element[2]?.int ?? 0), logical: "", repetition: ["Required", "Optional", "Repeated"][min(max(repetitionType, 0), 2)],
                                    maxDefinition: def, maxRepetition: rep, scale: Int(element[7]?.int ?? 0), kind: .plain)
                describeLogical(&column, element)
                if insideGroup || rep > 0 { nested.append(column.name) }
                columns.append(column)
            }
        }
        walk(prefix: [], definition: 0, repetition: 0, count: Int(schema[0][5]?.int ?? 0), insideGroup: false)

        let groups = (meta[4]?.list ?? []).prefix(10_000).map { group -> RowGroup in
            let chunks = (group[1]?.list ?? []).map { chunk -> ColumnChunk in
                let m = chunk[3]
                let stats = m?[12]
                return ColumnChunk(codec: Int(m?[4]?.int ?? 0), encodings: (m?[2]?.list ?? []).compactMap { $0.int.map(Int.init) },
                                   values: Int(m?[5]?.int ?? 0), compressed: Int(m?[7]?.int ?? 0), uncompressed: Int(m?[6]?.int ?? 0),
                                   dataOffset: Int(m?[9]?.int ?? 0), dictionaryOffset: m?[11]?.int.map(Int.init),
                                   nulls: stats?[3]?.int.map(Int.init), minimum: stats?[6]?.data ?? stats?[2]?.data, maximum: stats?[5]?.data ?? stats?[1]?.data)
            }
            return RowGroup(rows: Int(group[3]?.int ?? 0), bytes: Int(group[2]?.int ?? 0), compressed: Int(group[6]?.int ?? 0), chunks: chunks)
        }
        let metadata = (meta[5]?.list ?? []).prefix(200).compactMap { pair -> (String, String)? in
            guard let key = pair[1]?.string else { return nil }
            return (key, String((pair[2]?.string ?? "").prefix(2000)))
        }
        return ParquetFile(version: Int(meta[1]?.int ?? 0), rows: Int(meta[3]?.int ?? 0), createdBy: meta[6]?.string,
                           columns: columns, nested: nested, groups: Array(groups), metadata: Array(metadata), fileSize: fileSize)
    }

    private static func describeLogical(_ column: inout Column, _ element: ThriftValue) {
        if let logical = element[10], case .structure(let fields) = logical, let (id, value) = fields.first {
            switch id {
            case 1: column.logical = "String"; column.kind = .string
            case 2: column.logical = "Map"
            case 3: column.logical = "List"
            case 4: column.logical = "Enum"; column.kind = .string
            case 5:
                let scale = Int(value[1]?.int ?? 0), precision = Int(value[2]?.int ?? 0)
                column.logical = "Decimal(\(precision),\(scale))"; column.scale = scale; column.kind = .decimal
            case 6: column.logical = "Date"; column.kind = .date
            case 7:
                let unit = value[2].flatMap { u -> Int16? in if case .structure(let f) = u { return f.keys.first }; return nil } ?? 1
                column.logical = "Time"; column.kind = unit == 1 ? .timeMillis : .timeMicros
            case 8:
                let unit = value[2].flatMap { u -> Int16? in if case .structure(let f) = u { return f.keys.first }; return nil } ?? 1
                column.logical = "Timestamp"
                column.kind = unit == 1 ? .timestampMillis : unit == 2 ? .timestampMicros : .timestampNanos
            case 10:
                let width = Int(value[1]?.int ?? 32), signed = value[2]?.bool ?? true
                column.logical = (signed ? "Int" : "UInt") + "\(width)"
                if !signed { column.kind = .unsigned }
            case 11: column.logical = "Null"
            case 12: column.logical = "JSON"; column.kind = .json
            case 13: column.logical = "BSON"
            case 14: column.logical = "UUID"; column.kind = .uuid
            case 15: column.logical = "Float16"
            default: break
            }
            return
        }
        guard let converted = element[6]?.int else { return }
        switch converted {
        case 0: column.logical = "UTF8"; column.kind = .string
        case 4: column.logical = "Enum"; column.kind = .string
        case 5: column.logical = "Decimal"; column.kind = .decimal
        case 6: column.logical = "Date"; column.kind = .date
        case 7: column.logical = "Time"; column.kind = .timeMillis
        case 8: column.logical = "Time"; column.kind = .timeMicros
        case 9: column.logical = "Timestamp"; column.kind = .timestampMillis
        case 10: column.logical = "Timestamp"; column.kind = .timestampMicros
        case 11, 12, 13, 14: column.logical = "UInt"; column.kind = .unsigned
        case 19: column.logical = "JSON"; column.kind = .json
        default: break
        }
    }

    // MARK: - Names

    static func codecName(_ codec: Int) -> String {
        ["Uncompressed", "Snappy", "Gzip", "LZO", "Brotli", "LZ4", "Zstandard", "LZ4 (raw)"][min(max(codec, 0), 7)]
    }

    static func encodingName(_ encoding: Int) -> String {
        switch encoding {
        case 0: return "Plain"
        case 2: return "Plain dictionary"
        case 3: return "RLE"
        case 4: return "Bit-packed"
        case 5: return "Delta binary"
        case 6: return "Delta length"
        case 7: return "Delta byte array"
        case 8: return "RLE dictionary"
        case 9: return "Byte stream split"
        default: return "Encoding \(encoding)"
        }
    }

    func typeName(_ column: Column) -> String {
        let physical: String
        switch column.physical {
        case .boolean: physical = "BOOLEAN"
        case .int32: physical = "INT32"
        case .int64: physical = "INT64"
        case .int96: physical = "INT96"
        case .float: physical = "FLOAT"
        case .double: physical = "DOUBLE"
        case .byteArray: physical = "BYTE_ARRAY"
        case .fixedLenByteArray: physical = "FIXED(\(column.typeLength))"
        case nil: physical = "?"
        }
        return column.logical.isEmpty ? physical : "\(column.logical) · \(physical)"
    }

    var codecs: [String] {
        Array(Set(groups.flatMap { $0.chunks.map { Self.codecName($0.codec) } })).sorted()
    }

    // MARK: - Rows

    /// The first rows of the top-level columns, as far as their codecs and encodings allow.
    /// Columns that can't be read come back nil, with the reason.
    func firstRows(_ url: URL, limit: Int = 1000) -> (columns: [[GridValue]?], reasons: [String?]) {
        guard let group = groups.first, let handle = try? FileHandle(forReadingFrom: url) else {
            return (columns.map { _ in nil }, columns.map { _ in "No row groups" })
        }
        defer { try? handle.close() }
        var result: [[GridValue]?] = []
        var reasons: [String?] = []
        for (index, column) in columns.enumerated() {
            guard index < group.chunks.count else { result.append(nil); reasons.append("Missing"); continue }
            guard column.maxRepetition == 0, !nested.contains(column.name) else { result.append(nil); reasons.append("Nested"); continue }
            do {
                result.append(try readColumn(column, group.chunks[index], handle: handle, limit: limit))
                reasons.append(nil)
            } catch let error as ColumnFailure {
                result.append(nil)
                reasons.append(error.reason)
            } catch {
                result.append(nil)
                reasons.append("Unreadable")
            }
        }
        return (result, reasons)
    }

    struct ColumnFailure: Error { let reason: String }

    private func readColumn(_ column: Column, _ chunk: ColumnChunk, handle: FileHandle, limit: Int) throws -> [GridValue] {
        guard [0, 1, 2].contains(chunk.codec) else { throw ColumnFailure(reason: Self.codecName(chunk.codec)) }
        let start = min(chunk.dictionaryOffset ?? chunk.dataOffset, chunk.dataOffset)
        guard start >= 4, start < fileSize, chunk.compressed > 0 else { throw ColumnFailure(reason: "Unreadable") }
        // The chunk (dictionary page included), capped: the first rows are near its start.
        let length = min(chunk.compressed, 64 * 1024 * 1024, fileSize - start)
        try handle.seek(toOffset: UInt64(start))
        guard let data = try handle.read(upToCount: length), !data.isEmpty else { throw ColumnFailure(reason: "Unreadable") }

        var values: [GridValue] = []
        var dictionary: [GridValue] = []
        var offset = 0
        while offset < data.count, values.count < limit {
            var reader = ThriftReader(data, at: offset)
            let header = try reader.readStruct()
            // The reader reports where it stopped, from the start of `data`.
            offset = reader.offset
            let type = Int(header[1]?.int ?? -1)
            let uncompressed = Int(header[2]?.int ?? 0)
            let compressed = Int(header[3]?.int ?? 0)
            guard compressed >= 0, offset + compressed <= data.count, uncompressed >= 0, uncompressed <= 256 * 1024 * 1024 else { break }
            let payload = data[(data.startIndex + offset)..<(data.startIndex + offset + compressed)]
            offset += compressed
            switch type {
            case 2: // dictionary
                let page = try decompress(payload, codec: chunk.codec, size: uncompressed)
                let count = Int(header[7]?[1]?.int ?? 0)
                dictionary = try plain(page, column: column, count: min(count, 1_000_000))
            case 0: // data page v1
                let page = try decompress(payload, codec: chunk.codec, size: uncompressed)
                let h = header[5]
                let count = Int(h?[1]?.int ?? 0)
                let encoding = Int(h?[2]?.int ?? 0)
                var cursor = page.startIndex
                var defined = [Bool](repeating: true, count: count)
                if column.maxDefinition > 0 {
                    guard cursor + 4 <= page.endIndex else { throw ColumnFailure(reason: "Unreadable") }
                    let length = Int(page[cursor]) | Int(page[cursor + 1]) << 8 | Int(page[cursor + 2]) << 16 | Int(page[cursor + 3]) << 24
                    cursor += 4
                    guard length >= 0, cursor + length <= page.endIndex else { throw ColumnFailure(reason: "Unreadable") }
                    let levels = try Hybrid.decode(page[cursor..<cursor + length], bitWidth: bitWidth(column.maxDefinition), count: count)
                    defined = levels.map { Int($0) == column.maxDefinition }
                    cursor += length
                }
                values += try decodeValues(page[cursor...], encoding: encoding, column: column, defined: defined, dictionary: dictionary)
            case 3: // data page v2: levels uncompressed ahead of the (maybe compressed) values
                let h = header[8]
                let count = Int(h?[1]?.int ?? 0)
                let encoding = Int(h?[4]?.int ?? 0)
                let defLength = Int(h?[5]?.int ?? 0), repLength = Int(h?[6]?.int ?? 0)
                let isCompressed = h?[7]?.bool ?? true
                guard defLength >= 0, repLength >= 0, defLength + repLength <= payload.count else { throw ColumnFailure(reason: "Unreadable") }
                var defined = [Bool](repeating: true, count: count)
                let levelStart = payload.startIndex + repLength
                if column.maxDefinition > 0, defLength > 0 {
                    let levels = try Hybrid.decode(payload[levelStart..<levelStart + defLength], bitWidth: bitWidth(column.maxDefinition), count: count)
                    defined = levels.map { Int($0) == column.maxDefinition }
                }
                let body = payload[(levelStart + defLength)...]
                let page = isCompressed ? try decompress(Data(body), codec: chunk.codec, size: uncompressed - defLength - repLength) : Data(body)
                values += try decodeValues(page[page.startIndex...], encoding: encoding, column: column, defined: defined, dictionary: dictionary)
            default:
                continue
            }
        }
        return Array(values.prefix(limit))
    }

    private func bitWidth(_ max: Int) -> Int {
        var width = 0, value = max
        while value > 0 { width += 1; value >>= 1 }
        return width
    }

    private func decompress(_ data: Data, codec: Int, size: Int) throws -> Data {
        switch codec {
        case 0: return data
        case 1: return try Snappy.decompress(data, limit: max(size, 0) + 16)
        case 2: guard let out = Gzip.inflate(data, expected: size) else { throw ColumnFailure(reason: "Unreadable") }; return out
        default: throw ColumnFailure(reason: Self.codecName(codec))
        }
    }

    private func decodeValues(_ data: Data.SubSequence, encoding: Int, column: Column, defined: [Bool], dictionary: [GridValue]) throws -> [GridValue] {
        let present = defined.filter { $0 }.count
        var raw: [GridValue]
        switch encoding {
        case 0:
            raw = try plain(Data(data), column: column, count: present)
        case 2, 8:
            guard let width = data.first else { return defined.map { _ in .null } }
            let indices = try Hybrid.decode(data.dropFirst(), bitWidth: Int(width), count: present)
            raw = indices.map { Int($0) < dictionary.count ? dictionary[Int($0)] : .null }
        case 3 where column.physical == .boolean:
            // Booleans in v2 pages: RLE with a 4-byte length.
            guard data.count >= 4 else { return defined.map { _ in .null } }
            let start = data.startIndex
            let length = Int(data[start]) | Int(data[start + 1]) << 8 | Int(data[start + 2]) << 16 | Int(data[start + 3]) << 24
            guard length >= 0, start + 4 + length <= data.endIndex else { throw ColumnFailure(reason: "Unreadable") }
            raw = try Hybrid.decode(data[(start + 4)..<(start + 4 + length)], bitWidth: 1, count: present).map { .text($0 == 1 ? "true" : "false") }
        default:
            throw ColumnFailure(reason: Self.encodingName(encoding))
        }
        var result: [GridValue] = []
        result.reserveCapacity(defined.count)
        var next = 0
        for isDefined in defined {
            if isDefined, next < raw.count { result.append(raw[next]); next += 1 } else { result.append(.null) }
        }
        return result
    }

    /// PLAIN-encoded values.
    private func plain(_ data: Data, column: Column, count: Int) throws -> [GridValue] {
        var values: [GridValue] = []
        values.reserveCapacity(min(count, 100_000))
        let bytes = [UInt8](data)
        var i = 0
        func le(_ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<n { v |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
            return v
        }
        for index in 0..<count {
            switch column.physical {
            case .boolean:
                guard index / 8 < bytes.count else { return values }
                values.append(.text(bytes[index / 8] & (1 << UInt8(index % 8)) != 0 ? "true" : "false"))
            case .int32:
                guard i + 4 <= bytes.count else { return values }
                values.append(format(Int64(Int32(bitPattern: UInt32(le(4)))), column: column)); i += 4
            case .int64:
                guard i + 8 <= bytes.count else { return values }
                values.append(format(Int64(bitPattern: le(8)), column: column)); i += 8
            case .int96:
                guard i + 12 <= bytes.count else { return values }
                let nanos = Double(le(8)); i += 8
                let day = Double(UInt32(le(4))); i += 4
                values.append(.text(Self.dateTime((day - 2_440_588) * 86_400 + nanos / 1e9, fraction: true)))
            case .float:
                guard i + 4 <= bytes.count else { return values }
                values.append(.text(ColumnProfile.full(Double(Float(bitPattern: UInt32(le(4))))))); i += 4
            case .double:
                guard i + 8 <= bytes.count else { return values }
                values.append(.text(ColumnProfile.full(Double(bitPattern: le(8))))); i += 8
            case .byteArray:
                guard i + 4 <= bytes.count else { return values }
                let length = Int(UInt32(le(4))); i += 4
                guard length >= 0, i + length <= bytes.count else { return values }
                values.append(binary(Array(bytes[i..<i + length]), column: column)); i += length
            case .fixedLenByteArray:
                let length = column.typeLength
                guard length > 0, i + length <= bytes.count else { return values }
                values.append(binary(Array(bytes[i..<i + length]), column: column)); i += length
            case nil:
                return values
            }
        }
        return values
    }

    private func format(_ value: Int64, column: Column) -> GridValue {
        switch column.kind {
        case .date: return .text(Self.dateTime(Double(value) * 86_400, dateOnly: true))
        case .timestampMillis: return .text(Self.dateTime(Double(value) / 1e3, fraction: value % 1000 != 0))
        case .timestampMicros: return .text(Self.dateTime(Double(value) / 1e6, fraction: value % 1_000_000 != 0))
        case .timestampNanos: return .text(Self.dateTime(Double(value) / 1e9, fraction: true))
        case .timeMillis: return .text(Self.time(Double(value) / 1e3))
        case .timeMicros: return .text(Self.time(Double(value) / 1e6))
        case .decimal: return .text(Self.decimal(String(value.magnitude), negative: value < 0, scale: column.scale))
        case .unsigned: return .text(String(column.physical == .int32 ? UInt64(UInt32(truncatingIfNeeded: value)) : UInt64(bitPattern: value)))
        default: return .text(String(value))
        }
    }

    private func binary(_ bytes: [UInt8], column: Column) -> GridValue {
        switch column.kind {
        case .string, .json:
            return .text(String(decoding: bytes.prefix(4096), as: UTF8.self))
        case .uuid where bytes.count == 16:
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
            return .text(parts.joined(separator: "-"))
        case .decimal:
            // Big-endian two's complement.
            guard !bytes.isEmpty, bytes.count <= 16 else { return .secondary("\(bytes.count) bytes") }
            let negative = bytes[0] & 0x80 != 0
            var magnitude = bytes
            if negative {
                // Two's complement → magnitude.
                for i in magnitude.indices { magnitude[i] = ~magnitude[i] }
                var carry = true
                for i in magnitude.indices.reversed() where carry {
                    let (sum, overflow) = magnitude[i].addingReportingOverflow(1)
                    magnitude[i] = sum
                    carry = overflow
                }
            }
            return .text(Self.decimal(Self.bigEndianDecimalString(magnitude), negative: negative, scale: column.scale))
        default:
            if let text = String(bytes: bytes.prefix(4096), encoding: .utf8), !text.contains("\0") { return .text(text) }
            return .secondary(bytes.count <= 16 ? "x'" + bytes.map { String(format: "%02x", $0) }.joined() + "'" : "\(bytes.count) bytes")
        }
    }

    /// An unsigned big-endian integer of up to 16 bytes, in decimal.
    static func bigEndianDecimalString(_ bytes: [UInt8]) -> String {
        var digits: [UInt8] = [0]
        for byte in bytes {
            var carry = Int(byte)
            for i in digits.indices {
                let value = Int(digits[i]) * 256 + carry
                digits[i] = UInt8(value % 10)
                carry = value / 10
            }
            while carry > 0 { digits.append(UInt8(carry % 10)); carry /= 10 }
        }
        while digits.count > 1, digits.last == 0 { digits.removeLast() }
        return String(digits.reversed().map { Character(String($0)) })
    }

    static func decimal(_ digits: String, negative: Bool, scale: Int) -> String {
        guard scale > 0 else { return (negative ? "-" : "") + digits }
        let padded = String(repeating: "0", count: max(0, scale + 1 - digits.count)) + digits
        let point = padded.index(padded.endIndex, offsetBy: -scale)
        return (negative ? "-" : "") + padded[..<point] + "." + padded[point...]
    }

    private static let utc = TimeZone(secondsFromGMT: 0)!

    static func dateTime(_ seconds: Double, dateOnly: Bool = false, fraction: Bool = false) -> String {
        guard seconds.isFinite, abs(seconds) < 1e12 else { return "—" }
        let date = Date(timeIntervalSince1970: seconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        if dateOnly { return day }
        var text = day + String(format: " %02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        if fraction { text += String(format: ".%03d", (c.nanosecond ?? 0) / 1_000_000) }
        return text
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// A statistics value (min/max), decoded like a column value.
    func statistic(_ data: Data?, column: Column) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let values = try? plain(column.physical == .byteArray ? (withUnsafeBytes(of: UInt32(data.count).littleEndian) { Data($0) } + data) : data, column: column, count: 1)
        return values?.first.map(\.plainText)
    }
}

/// Parquet's RLE / bit-packed hybrid encoding (levels and dictionary indices).
enum Hybrid {
    struct Failure: Error {}

    static func decode(_ data: Data.SubSequence, bitWidth: Int, count: Int) throws -> [UInt32] {
        guard bitWidth >= 0, bitWidth <= 32, count >= 0, count <= 10_000_000 else { throw Failure() }
        var result: [UInt32] = []
        result.reserveCapacity(count)
        if bitWidth == 0 { return [UInt32](repeating: 0, count: count) }
        let bytes = [UInt8](data)
        var i = 0
        let byteWidth = (bitWidth + 7) / 8
        while result.count < count, i < bytes.count {
            var header = 0, shift = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                header |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { break }
                shift += 7
                guard shift < 35 else { throw Failure() }
            }
            if header & 1 == 0 {
                let run = header >> 1
                guard i + byteWidth <= bytes.count else { throw Failure() }
                var value: UInt32 = 0
                for k in 0..<byteWidth { value |= UInt32(bytes[i + k]) << (8 * UInt32(k)) }
                i += byteWidth
                result.append(contentsOf: repeatElement(value, count: min(run, count - result.count)))
            } else {
                let groups = header >> 1
                let total = groups * 8
                let needed = groups * bitWidth
                guard i + needed <= bytes.count || total > 0 else { throw Failure() }
                var bitPosition = i * 8
                let end = min(bytes.count * 8, (i + needed) * 8)
                for _ in 0..<total where result.count < count {
                    guard bitPosition + bitWidth <= end else { break }
                    var value: UInt32 = 0
                    for bit in 0..<bitWidth {
                        let p = bitPosition + bit
                        if bytes[p / 8] & (1 << UInt8(p % 8)) != 0 { value |= 1 << UInt32(bit) }
                    }
                    result.append(value)
                    bitPosition += bitWidth
                }
                i += needed
            }
        }
        return result
    }
}
