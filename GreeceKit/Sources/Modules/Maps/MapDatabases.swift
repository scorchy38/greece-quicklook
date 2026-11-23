import Foundation
import ImageIO
import SQLite3

/// A read-only, immutable SQLite connection for MBTiles and GeoPackages. Every query runs against
/// a deadline; access is serialised because tiles are requested from several threads at once.
final class MapSQLite: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSLock()
    private var deadline = CFAbsoluteTimeGetCurrent() + 2

    init(url: URL) throws {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1"), URLQueryItem(name: "mode", value: "ro")]
        var db: OpaquePointer?
        let uri = components.string ?? "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw GeoError.invalid(String(localized: "This database can’t be opened.", bundle: .greeceKit))
        }
        handle = db
        sqlite3_progress_handler(db, 5_000, { context in
            let owner = Unmanaged<MapSQLite>.fromOpaque(context!).takeUnretainedValue()
            return CFAbsoluteTimeGetCurrent() > owner.deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        _ = try? query("PRAGMA trusted_schema = OFF", budget: 0.5) { _ in true }
    }

    deinit {
        sqlite3_progress_handler(handle, 0, nil, nil)
        sqlite3_close(handle)
    }

    struct Row {
        fileprivate let statement: OpaquePointer
        var count: Int { Int(sqlite3_column_count(statement)) }
        func name(_ i: Int) -> String { sqlite3_column_name(statement, Int32(i)).map { String(cString: $0) } ?? "" }
        func isNull(_ i: Int) -> Bool { sqlite3_column_type(statement, Int32(i)) == SQLITE_NULL }
        func isBlob(_ i: Int) -> Bool { sqlite3_column_type(statement, Int32(i)) == SQLITE_BLOB }
        func int(_ i: Int) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(statement, Int32(i)) }
        func double(_ i: Int) -> Double? { isNull(i) ? nil : sqlite3_column_double(statement, Int32(i)) }
        func text(_ i: Int, limit: Int = 32 * 1024) -> String? {
            guard !isNull(i), let pointer = sqlite3_column_text(statement, Int32(i)) else { return nil }
            let length = Int(sqlite3_column_bytes(statement, Int32(i)))
            return String(decoding: UnsafeBufferPointer(start: pointer, count: min(length, limit)), as: UTF8.self)
        }
        func blob(_ i: Int, limit: Int) -> Data? {
            guard isBlob(i) else { return nil }
            let length = Int(sqlite3_column_bytes(statement, Int32(i)))
            guard length <= limit, let pointer = sqlite3_column_blob(statement, Int32(i)) else { return nil }
            return Data(bytes: pointer, count: length)
        }
        func value(_ i: Int) -> GeoValue {
            switch sqlite3_column_type(statement, Int32(i)) {
            case SQLITE_NULL: return .null
            case SQLITE_INTEGER, SQLITE_FLOAT: return .number(sqlite3_column_double(statement, Int32(i)))
            case SQLITE_BLOB: return .string("\(ByteCountFormatter.string(fromByteCount: Int64(sqlite3_column_bytes(statement, Int32(i))), countStyle: .file)) of binary data")
            default: return .string(text(i) ?? "")
            }
        }
    }

    /// Runs `sql` with integer or text bindings; `body` returns false to stop early.
    func query(_ sql: String, _ bindings: [Any] = [], budget: TimeInterval = 2, _ body: (Row) -> Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        deadline = CFAbsoluteTimeGetCurrent() + budget
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw GeoError.invalid(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let v as Int: sqlite3_bind_int64(statement, position, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, position, v)
            case let v as String: sqlite3_bind_text(statement, position, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            default: sqlite3_bind_null(statement, position)
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw GeoError.invalid(String(cString: sqlite3_errmsg(handle))) }
            if !body(Row(statement: statement)) { return }
        }
    }

    func scalar(_ sql: String, _ bindings: [Any] = [], budget: TimeInterval = 1) -> Int64? {
        var result: Int64?
        try? query(sql, bindings, budget: budget) { row in result = row.int(0); return false }
        return result
    }

    func tableExists(_ name: String) -> Bool {
        scalar("SELECT count(*) FROM sqlite_master WHERE type IN ('table','view') AND name = ?", [name]) ?? 0 > 0
    }

    static func quote(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

/// Map tiles served to the page on demand.
final class TileSet: @unchecked Sendable {
    enum Kind: String, Encodable { case raster, vector }
    struct VectorLayer: Encodable {
        var id: String
        var description: String?
        var minzoom: Int?
        var maxzoom: Int?
        var fields: [String]
    }
    struct Info: Encodable {
        var id: String
        var name: String
        var kind: Kind
        var format: String
        var minzoom: Int
        var maxzoom: Int
        var tileSize: Int
        var bounds: [Double]?
        var center: [Double]?
        var vectorLayers: [VectorLayer]
        var metadata: [[String]]
        var attribution: String?
        var url: String { "greece://module/tile/\(id)/{z}/{x}/{y}" }

        enum CodingKeys: String, CodingKey { case id, name, kind, format, minzoom, maxzoom, tileSize, bounds, center, vectorLayers, metadata, attribution, url }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind)
            try c.encode(format, forKey: .format); try c.encode(minzoom, forKey: .minzoom); try c.encode(maxzoom, forKey: .maxzoom)
            try c.encode(tileSize, forKey: .tileSize); try c.encodeIfPresent(bounds, forKey: .bounds); try c.encodeIfPresent(center, forKey: .center)
            try c.encode(vectorLayers, forKey: .vectorLayers); try c.encode(metadata, forKey: .metadata)
            try c.encodeIfPresent(attribution, forKey: .attribution); try c.encode(url, forKey: .url)
        }
    }

    var info: Info
    let fetch: @Sendable (_ z: Int, _ x: Int, _ y: Int) -> Data?

    init(info: Info, fetch: @escaping @Sendable (Int, Int, Int) -> Data?) {
        self.info = info
        self.fetch = fetch
    }

    static func sniffFormat(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return "webp" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "pbf"
    }

    /// An empty, fully transparent 1×1 PNG for missing raster tiles.
    static let transparentPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
}

// MARK: - MBTiles

enum MBTilesReader {

    static func read(_ url: URL, name fileName: String) throws -> (TileSet, [String: String], tileCount: Int?) {
        let db = try MapSQLite(url: url)
        guard db.tableExists("tiles") else { throw GeoError.invalid(String(localized: "This MBTiles file has no tiles table.", bundle: .greeceKit)) }
        var metadata: [String: String] = [:]
        var order: [String] = []
        if db.tableExists("metadata") {
            try? db.query("SELECT name, value FROM metadata LIMIT 500") { row in
                if let key = row.text(0, limit: 256), let value = row.text(1, limit: 256 * 1024) {
                    if metadata[key] == nil { order.append(key) }
                    metadata[key] = value
                }
                return true
            }
        }
        var format = metadata["format"]?.lowercased()
        var sample: Data?
        try? db.query("SELECT tile_data FROM tiles LIMIT 1", budget: 1) { row in sample = row.blob(0, limit: 16 * 1024 * 1024); return false }
        if format == nil || format?.isEmpty == true, let sample { format = TileSet.sniffFormat(sample) }
        if format == "jpeg" { format = "jpg" }
        if format == "application/x-protobuf" || format == "mvt" { format = "pbf" }
        let isVector = format == "pbf"

        var minzoom = metadata["minzoom"].flatMap { Int(Double($0) ?? -1) }
        var maxzoom = metadata["maxzoom"].flatMap { Int(Double($0) ?? -1) }
        if minzoom == nil || maxzoom == nil || minzoom! < 0 || maxzoom! < 0 {
            try? db.query("SELECT MIN(zoom_level), MAX(zoom_level) FROM tiles", budget: 1.5) { row in
                minzoom = row.int(0).map(Int.init); maxzoom = row.int(1).map(Int.init); return false
            }
        }
        let zmin = max(0, min(minzoom ?? 0, 30)), zmax = max(zmin, min(maxzoom ?? 14, 30))

        var bounds = metadata["bounds"].flatMap(numbers).flatMap { $0.count == 4 ? $0 : nil }
        if bounds == nil {
            try? db.query("SELECT MIN(tile_column), MAX(tile_column), MIN(tile_row), MAX(tile_row) FROM tiles WHERE zoom_level = ?", [zmin], budget: 1) { row in
                if let x0 = row.int(0), let x1 = row.int(1), let y0 = row.int(2), let y1 = row.int(3) {
                    let n = Double(1 << zmin)
                    func lon(_ x: Double) -> Double { x / n * 360 - 180 }
                    func lat(_ tmsY: Double) -> Double { let y = n - tmsY; return atan(sinh(.pi * (1 - 2 * y / n))) * 180 / .pi }
                    bounds = [lon(Double(x0)), lat(Double(y0)), lon(Double(x1 + 1)), lat(Double(y1 + 1))]
                }
                return false
            }
        }
        if let b = bounds, !(b[0] < b[2] && b[1] < b[3] && abs(b[1]) <= 90 && abs(b[3]) <= 90) { bounds = nil }
        if let b = bounds { bounds = [max(b[0], -180), max(b[1], -85.0511), min(b[2], 180), min(b[3], 85.0511)] }
        let center = metadata["center"].flatMap(numbers).flatMap { $0.count >= 2 ? $0 : nil }

        var tileSize = 256
        if !isVector, let sample, let source = CGImageSourceCreateWithData(sample as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, width >= 512 {
            tileSize = 512
        }

        var vectorLayers: [TileSet.VectorLayer] = []
        if isVector, let json = metadata["json"], let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let layers = object["vector_layers"] as? [[String: Any]] {
            for layer in layers.prefix(200) {
                guard let id = layer["id"] as? String else { continue }
                let fields = (layer["fields"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
                vectorLayers.append(.init(id: id, description: layer["description"] as? String,
                                          minzoom: (layer["minzoom"] as? NSNumber)?.intValue, maxzoom: (layer["maxzoom"] as? NSNumber)?.intValue,
                                          fields: Array(fields.prefix(100))))
            }
        }
        if isVector, vectorLayers.isEmpty, let sample {
            // No metadata: find the layers in a tile.
            let tile = Inflate.isGzip(sample) || Inflate.isZlib(sample) ? Inflate.decompress(sample, mode: .gzipOrZlib, limit: 32 << 20) : sample
            if let tile, let decoded = VectorTile.decode(tile) {
                vectorLayers = decoded.layers.map { .init(id: $0.name, fields: Array(Set($0.features.flatMap { $0.properties.map(\.key) })).sorted()) }
            }
        }

        let shown = ["name", "description", "attribution", "format", "type", "version", "minzoom", "maxzoom", "bounds", "center", "scheme", "generator", "compression"]
        let metadataRows = order.filter { shown.contains($0) || !["json"].contains($0) }.prefix(40).map { [$0, String(metadata[$0]!.prefix(2000))] }
        let flipY = metadata["scheme"]?.lowercased() != "xyz"
        let info = TileSet.Info(id: "mbtiles", name: metadata["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fileName,
                                kind: isVector ? .vector : .raster, format: format ?? "png",
                                minzoom: zmin, maxzoom: zmax, tileSize: tileSize, bounds: bounds, center: center,
                                vectorLayers: vectorLayers, metadata: Array(metadataRows), attribution: metadata["attribution"])
        let set = TileSet(info: info) { z, x, y in
            guard z >= 0, z <= 30, x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
            let row = flipY ? (1 << z) - 1 - y : y
            var data: Data?
            try? db.query("SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?", [z, x, row], budget: 1.5) { r in
                data = r.blob(0, limit: 16 * 1024 * 1024)
                return false
            }
            guard let data else { return nil }
            if isVector, Inflate.isGzip(data) || Inflate.isZlib(data) { return Inflate.decompress(data, mode: .gzipOrZlib, limit: 64 << 20) }
            return data
        }
        let count = db.scalar("SELECT count(*) FROM tiles", budget: 0.4).map(Int.init)
        return (set, metadata, count)
    }

    static func numbers(_ text: String) -> [Double]? {
        let values = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        return values.allSatisfy(\.isFinite) ? values : nil
    }
}

// MARK: - GeoPackage

enum GeoPackageReader {

    static func read(_ url: URL, limits: GeoLimits) throws -> MapDocument {
        let db = try MapSQLite(url: url)
        guard db.tableExists("gpkg_contents") else { throw GeoError.invalid(String(localized: "This GeoPackage has no contents table.", bundle: .greeceKit)) }
        let document = MapDocument(format: .geopackage)

        struct Content { var table: String; var type: String; var identifier: String?; var srs: Int64? }
        var contents: [Content] = []
        try? db.query("SELECT table_name, data_type, identifier, srs_id FROM gpkg_contents LIMIT 500") { row in
            if let table = row.text(0, limit: 512), let type = row.text(1, limit: 64) {
                contents.append(Content(table: table, type: type.lowercased(), identifier: row.text(2, limit: 512), srs: row.int(3)))
            }
            return true
        }
        var geometryColumns: [String: (column: String, type: String, srs: Int64?)] = [:]
        try? db.query("SELECT table_name, column_name, geometry_type_name, srs_id FROM gpkg_geometry_columns LIMIT 500") { row in
            if let table = row.text(0, limit: 512), let column = row.text(1, limit: 512) {
                geometryColumns[table.lowercased()] = (column, row.text(2, limit: 64) ?? "GEOMETRY", row.int(3))
            }
            return true
        }
        var references: [Int64: CRS] = [:]
        func crs(for srs: Int64?) -> CRS? {
            guard let srs else { return nil }
            if let known = references[srs] { return known }
            var result: CRS?
            try? db.query("SELECT srs_name, organization, organization_coordsys_id, definition FROM gpkg_spatial_ref_sys WHERE srs_id = ?", [Int(srs)]) { row in
                let definition = row.text(3, limit: 64 * 1024) ?? ""
                if let parsed = CRS.parse(wkt: definition) { result = parsed }
                else if row.text(1)?.uppercased() == "EPSG", let code = row.int(2) { result = CRS.epsg(Int(code)) }
                if result == nil, srs == 4326 { result = .wgs84 }
                if var r = result, let name = row.text(0, limit: 200), !name.isEmpty, r.isUnnamed { r.name = name; result = r }
                return false
            }
            if result == nil, srs > 0 { result = CRS.epsg(Int(srs)) }
            references[srs] = result
            return result
        }

        var budget = GeoBudget(limits)
        var reprojected: [String] = []
        var crsNames: [String] = []
        var attributes = 0
        for content in contents {
            switch content.type {
            case "features":
                guard let column = geometryColumns[content.table.lowercased()], !budget.exhausted else { continue }
                let layer = GeoLayer(name: content.identifier.flatMap { $0.isEmpty ? nil : $0 } ?? content.table)
                let tableCRS = crs(for: column.srs ?? content.srs)
                let transform: ((GeoPoint) -> GeoPoint?)?
                if let tableCRS, !tableCRS.isWGS84Compatible, tableCRS.canTransform {
                    transform = { tableCRS.transform($0) }
                    if !reprojected.contains(tableCRS.name) { reprojected.append(tableCRS.name) }
                } else {
                    transform = nil
                }
                let sql = "SELECT * FROM \(MapSQLite.quote(content.table)) LIMIT \(max(0, limits.maxFeatures - budget.features))"
                try? db.query(sql, budget: max(1, limits.deadline - CFAbsoluteTimeGetCurrent())) { row in
                    var feature = GeoFeature()
                    for i in 0..<row.count {
                        let name = row.name(i)
                        if name.caseInsensitiveCompare(column.column) == .orderedSame {
                            if let blob = row.blob(i, limit: 64 * 1024 * 1024), let parsed = WKBReader.geoPackage(blob) {
                                feature.geometry = parsed.geometry
                                if let transform, let g = feature.geometry { feature.geometry = g.mapPoints(transform) }
                            }
                        } else if feature.properties.count < limits.maxProperties {
                            feature.properties.append((name, row.value(i)))
                        }
                    }
                    GeoJSONReader.finish(&feature)
                    if budget.admit(feature.geometry) { layer.features.append(feature) }
                    return !budget.exhausted
                }
                document.layers.append(layer)
                if document.crs == nil, let tableCRS { document.crs = tableCRS }
                let name = tableCRS?.name ?? String(localized: "Undefined coordinate system", bundle: .greeceKit,
                                                    comment: "Info bar detail, in a list of a GeoPackage’s coordinate systems: a table that names none")
                if !crsNames.contains(name) { crsNames.append(name) }
            case "attributes":
                attributes += 1
            case "tiles", "2d-gridded-coverage":
                if let set = tileSet(db, table: content.table, index: document.tileSets.count, name: content.identifier ?? content.table, crs: crs(for: content.srs)) {
                    document.tileSets.append(set)
                } else {
                    document.notices.append(String(localized: "The tile table “\(content.table)” isn’t in Web Mercator, so it isn’t drawn.", bundle: .greeceKit,
                                                   comment: "Notice on a map. The argument is a table’s name in a GeoPackage"))
                }
            default: break
            }
        }
        if !reprojected.isEmpty { document.markReprojected(reprojected.joined(separator: ", ")) }
        if crsNames.count > 1 { document.crsSummary = crsNames.joined(separator: ", ") }
        if budget.exhausted { document.truncated = true }
        let tables = document.layers.count, tileTables = document.tileSets.count
        if tables > 0 { document.facts.append(String(localized: "\(tables) feature tables", bundle: .greeceKit, comment: "Info bar detail: tables of map features in a GeoPackage")) }
        if tileTables > 0 { document.facts.append(String(localized: "\(tileTables) tile tables", bundle: .greeceKit, comment: "Info bar detail: tables of map tiles in a GeoPackage")) }
        if attributes > 0 { document.facts.append(String(localized: "\(attributes) attribute tables", bundle: .greeceKit, comment: "Info bar detail: tables without geometry in a GeoPackage")) }
        return document
    }

    /// GeoPackage tiles drawn when they use the standard Web Mercator tile grid.
    private static func tileSet(_ db: MapSQLite, table: String, index: Int, name: String, crs: CRS?) -> TileSet? {
        guard let crs, case .projected(let projection) = crs.kind, projection.method == .webMercator || crs.epsg == 3857 else { return nil }
        var matrixSet: [Double] = []
        try? db.query("SELECT min_x, min_y, max_x, max_y FROM gpkg_tile_matrix_set WHERE table_name = ?", [table]) { row in
            matrixSet = (0..<4).compactMap { row.double($0) }
            return false
        }
        let world = 20037508.342789244
        guard matrixSet.count == 4, abs(matrixSet[0] + world) < 1, abs(matrixSet[2] - world) < 1,
              abs(matrixSet[1] + world) < 1, abs(matrixSet[3] - world) < 1 else { return nil }
        var zooms: [Int] = []
        var tileSize = 256
        try? db.query("SELECT zoom_level, matrix_width, tile_width FROM gpkg_tile_matrix WHERE table_name = ? ORDER BY zoom_level", [table]) { row in
            if let z = row.int(0), let width = row.int(1), z >= 0, z <= 30, width == Int64(1) << z { zooms.append(Int(z)) }
            if let w = row.int(2), w >= 512 { tileSize = 512 }
            return true
        }
        guard let zmin = zooms.min(), let zmax = zooms.max() else { return nil }
        var sample: Data?
        try? db.query("SELECT tile_data FROM \(MapSQLite.quote(table)) LIMIT 1") { row in sample = row.blob(0, limit: 16 << 20); return false }
        let format = sample.map(TileSet.sniffFormat) ?? "png"
        let id = "gpkg\(index)"
        let info = TileSet.Info(id: id, name: name, kind: .raster, format: format, minzoom: zmin, maxzoom: zmax, tileSize: tileSize,
                                bounds: nil, center: nil, vectorLayers: [], metadata: [["Table", table]], attribution: nil)
        let quoted = MapSQLite.quote(table)
        return TileSet(info: info) { z, x, y in
            var data: Data?
            try? db.query("SELECT tile_data FROM \(quoted) WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?", [z, x, y], budget: 1.5) { row in
                data = row.blob(0, limit: 16 << 20)
                return false
            }
            return data
        }
    }
}
