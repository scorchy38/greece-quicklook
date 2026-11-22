import AppKit

/// Maps and geodata: GeoJSON (and Lines), TopoJSON, KML/KMZ, GPX, shapefiles (also zipped),
/// GeoPackage, MBTiles (raster and vector), OpenStreetMap XML and WKT, drawn on an offline map.
enum MapsModule: PreviewModule {
    static let id = "maps"

    static func claims(_ file: FileInfo) -> Bool {
        guard !file.isDirectory else { return false }
        return MapDetection.format(of: file) != nil
    }

    static func prepare(_ file: FileInfo, settings: PreviewSettings) throws -> PreparedPreview {
        guard let format = MapDetection.format(of: file) else { throw PreviewError.unsupported }
        let document: MapDocument
        do {
            document = try MapLoader.load(file, format: format, limits: .preview)
        } catch {
            // A file that only looked like geodata still deserves a readable preview.
            if let fallback = MapLoader.textFallback(file, format: format) { return fallback }
            throw error
        }
        document.normalize()
        return MapPageBuilder.preview(document, file: file)
    }

    static func thumbnail(_ file: FileInfo, size: CGSize, settings: PreviewSettings) -> ThumbnailPage? {
        guard let format = MapDetection.format(of: file),
              let document = try? MapLoader.load(file, format: format, limits: .thumbnail) else { return nil }
        document.normalize()
        return MapThumbnail.page(document, maximumSize: size)
    }
}

// MARK: - Detection

enum MapDetection {
    static let sqliteMagic = Array("SQLite format 3\0".utf8)

    static func format(of file: FileInfo) -> MapFormat? {
        let probe = file.probe
        switch file.ext {
        case "geojson":
            return probe.isText ? .geojson : nil
        case "geojsonl", "geojsonseq", "geojsons", "ndgeojson":
            return probe.isText ? .geojsonLines : nil
        case "topojson":
            return probe.isText ? .topojson : nil
        case "json":
            return probe.isText ? sniffJSON(probe.bytes) : nil
        case "jsonl", "ndjson":
            return probe.isText && sniffJSONLines(probe.bytes) ? .geojsonLines : nil
        case "kml":
            return probe.isText && probe.text.contains("<kml") ? .kml : nil
        case "kmz":
            return probe.hasPrefix([0x50, 0x4B, 0x03, 0x04]) ? .kmz : nil
        case "gpx":
            return probe.isText && probe.text.contains("<gpx") ? .gpx : nil
        case "osm":
            return probe.isText && probe.text.contains("<osm") ? .osm : nil
        case "wkt":
            return probe.isText && looksLikeWKT(probe.text) ? .wkt : nil
        case "shp":
            return probe.bytes.count >= 100 && probe.hasPrefix([0x00, 0x00, 0x27, 0x0A]) ? .shapefile : nil
        case "gpkg":
            return probe.hasPrefix(sqliteMagic) ? .geopackage : nil
        case "mbtiles":
            return probe.hasPrefix(sqliteMagic) ? .mbtiles : nil
        case "zip":
            return probe.hasPrefix([0x50, 0x4B, 0x03, 0x04]) && isZippedShapefile(file.url) ? .zippedShapefile : nil
        default:
            return nil
        }
    }

    private static let geometryTypes: Set<String> = ["Point", "MultiPoint", "LineString", "MultiLineString", "Polygon", "MultiPolygon", "GeometryCollection"]

    /// A .json whose top level is clearly a FeatureCollection, a Feature with a geometry, or a
    /// TopoJSON topology. Reads only the probe; anything less certain stays with the JSON viewer.
    static func sniffJSON(_ bytes: [UInt8]) -> MapFormat? {
        var i = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return nil }

        var depth = 0
        var topKeys = Set<String>()
        var topType: String?
        var featureTypeInArray = false
        var lastKey: String?
        var lastKeyDepth = -1
        var expectingValue = false
        var inFeatures = false
        var featuresDepth = -1
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                // Read a string.
                var j = i + 1
                var chars: [UInt8] = []
                var closed = false
                while j < bytes.count {
                    if bytes[j] == UInt8(ascii: "\\") { j += 2; continue }
                    if bytes[j] == UInt8(ascii: "\"") { closed = true; break }
                    if chars.count < 64 { chars.append(bytes[j]) }
                    j += 1
                }
                guard closed else { break }
                let text = String(decoding: chars, as: UTF8.self)
                var k = j + 1
                while k < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[k]) { k += 1 }
                if k < bytes.count, bytes[k] == UInt8(ascii: ":"), !expectingValue {
                    lastKey = text
                    lastKeyDepth = depth
                    if depth == 1 { topKeys.insert(text) }
                    expectingValue = true
                    i = k + 1
                    continue
                }
                if expectingValue, lastKey == "type" {
                    if lastKeyDepth == 1 { topType = text }
                    if inFeatures, lastKeyDepth == featuresDepth + 2, text == "Feature" { featureTypeInArray = true }
                }
                expectingValue = false
                i = j + 1
                continue
            }
            switch c {
            case UInt8(ascii: "{"):
                depth += 1
                expectingValue = false
            case UInt8(ascii: "["):
                if expectingValue, lastKey == "features", lastKeyDepth == 1 { inFeatures = true; featuresDepth = depth }
                depth += 1
                expectingValue = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if inFeatures, depth <= featuresDepth { inFeatures = false }
                expectingValue = false
                if depth <= 0 { i = bytes.count }
            case UInt8(ascii: ","):
                expectingValue = false
            default:
                break
            }
            i += 1
        }
        switch topType {
        case "FeatureCollection": return .geojson
        case "Feature": return topKeys.contains("geometry") ? .geojson : nil
        case "Topology": return topKeys.contains("arcs") || topKeys.contains("objects") ? .topojson : nil
        case nil:
            // "features" before "type": the first feature tells.
            return featureTypeInArray ? .geojson : nil
        default:
            return nil
        }
    }

    static func sniffJSONLines(_ bytes: [UInt8]) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{1E}" }).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.hasPrefix("{") && compact.contains("\"type\":\"Feature\"") && compact.contains("\"geometry\"")
    }

    static func looksLikeWKT(_ text: String) -> Bool {
        let head = text.drop(while: { $0.isWhitespace }).prefix(64).uppercased()
        let stripped = head.hasPrefix("SRID=") ? String(head.drop(while: { $0 != ";" }).dropFirst()) : String(head)
        return ["POINT", "LINESTRING", "POLYGON", "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION", "TRIANGLE", "TIN", "POLYHEDRALSURFACE"]
            .contains { stripped.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
    }

    private static let shapefileParts: Set<String> = ["shp", "shx", "dbf", "prj", "cpg", "sbn", "sbx", "qix", "fix", "xml", "qmd", "aih", "ain", "atx", "idx", "qpj", "txt", "html", "htm", "pdf", "md"]

    /// A ZIP made of one or more shapefiles (and their sidecars). Reads only the central directory.
    static func isZippedShapefile(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 1 << 30, let zip = try? ZipMembers(url: url, maxMembers: 400) else { return false }
        let files = zip.members.filter { !$0.name.hasSuffix("/") && !$0.name.hasPrefix("__MACOSX") && !($0.name as NSString).lastPathComponent.hasPrefix(".") }
        guard !files.isEmpty, files.count < 400 else { return false }
        let extensions = files.map { ($0.name as NSString).pathExtension.lowercased() }
        guard extensions.contains("shp"), extensions.contains("dbf") || extensions.contains("shx") else { return false }
        let parts = extensions.filter { shapefileParts.contains($0) }.count
        return parts * 10 >= files.count * 8
    }
}

// MARK: - Loading

enum MapLoader {

    static func load(_ file: FileInfo, format: MapFormat, limits: GeoLimits) throws -> MapDocument {
        let size = file.fileSize ?? 0
        func readAll() throws -> Data {
            guard size <= limits.maxBytes else {
                throw GeoError.tooLarge("This file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), more than Greece draws as a map.")
            }
            return try Data(contentsOf: file.url, options: .alwaysMapped)
        }
        let name = file.url.deletingPathExtension().lastPathComponent

        switch format {
        case .geojson, .geojsonLines:
            let data = try readAll()
            let lines = format == .geojsonLines
            let result = lines ? try GeoJSONReader.readLines(data, limits: limits) : try GeoJSONReader.read(data, limits: limits)
            let document = MapDocument(format: format)
            document.layers = [GeoLayer(name: name, features: result.features)]
            document.truncated = result.truncated
            if let crsName = result.crsName {
                if let crs = CRS.named(crsName) { document.crs = crs } else { document.notices.append("Unknown coordinate system “\(crsName)”.") }
            }
            if result.skipped > 0 { document.notices.append("\(result.skipped.formatted()) unreadable \(result.skipped == 1 ? "line" : "lines") skipped.") }
            return document

        case .topojson:
            let result = try TopoJSONReader.read(try readAll(), limits: limits)
            let document = MapDocument(format: .topojson)
            document.layers = result.layers
            document.truncated = result.truncated
            return document

        case .gpx:
            let document = try GPXReader.read(try readAll(), limits: limits)
            document.title = document.title ?? name
            return document

        case .kml:
            let folder = file.url.deletingLastPathComponent().standardizedFileURL
            var icons: [String] = []
            let document = try KMLReader.read(try readAll(), format: .kml, limits: limits) { href in
                guard !href.contains("://") || href.hasPrefix("file://") else { return nil }
                let path = href.hasPrefix("file://") ? URL(string: href)?.path ?? "" : folder.appendingPathComponent(href).standardizedFileURL.path
                guard path.hasPrefix(folder.path + "/"), FileManager.default.fileExists(atPath: path) else { return nil }
                icons.append(path)
                return icons.count - 1
            }
            document.icons = icons
            document.overlays = document.overlays.compactMap { overlay in
                guard !overlay.source.contains("://") else { return nil }
                let path = folder.appendingPathComponent(overlay.source).standardizedFileURL.path
                guard path.hasPrefix(folder.path + "/"), FileManager.default.fileExists(atPath: path) else { return nil }
                var o = overlay
                o.source = path
                return o
            }
            let root = folder.path + "/"
            document.loadImage = { path, limit in
                // Only files inside the KML's own folder, resolved paths and all.
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                guard url.path.hasPrefix(root),
                      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit else { return nil }
                return try? Data(contentsOf: url)
            }
            return document

        case .kmz:
            let zip = try ZipMembers(url: file.url)
            let kml = zip.member(named: "doc.kml") ?? zip.members.first { $0.name.lowercased().hasSuffix(".kml") && !$0.name.hasPrefix("__MACOSX") }
            guard let kml, let data = zip.data(kml, limit: limits.maxBytes) else { throw GeoError.invalid("This KMZ has no readable KML inside.") }
            let base = (kml.name as NSString).deletingLastPathComponent
            func memberPath(_ href: String) -> String? {
                guard !href.contains("://") else { return nil }
                let joined = base.isEmpty ? href : base + "/" + href
                let normalized = (joined as NSString).standardizingPath
                if let member = zip.member(named: normalized) ?? zip.member(named: href) { return member.name }
                return nil
            }
            var icons: [String] = []
            let document = try KMLReader.read(data, format: .kmz, limits: limits) { href in
                guard let path = memberPath(href) else { return nil }
                icons.append(path)
                return icons.count - 1
            }
            document.icons = icons
            document.overlays = document.overlays.compactMap { overlay in
                guard let path = memberPath(overlay.source) else { return nil }
                var o = overlay
                o.source = path
                return o
            }
            let lock = NSLock()
            document.loadImage = { name, limit in
                lock.lock()
                defer { lock.unlock() }
                guard let member = zip.member(named: name) else { return nil }
                return zip.data(member, limit: limit)
            }
            return document

        case .osm:
            return try OSMReader.read(try readAll(), limits: limits)

        case .wkt:
            let data = try readAll()
            let result = WKTReader.read(String(decoding: data, as: UTF8.self), limits: limits)
            guard !result.geometries.isEmpty else { throw GeoError.invalid("No well-known text geometry found.") }
            let document = MapDocument(format: .wkt)
            let features = result.geometries.enumerated().map { index, geometry -> GeoFeature in
                var f = GeoFeature(geometry: geometry)
                f.properties = [("Geometry", .number(Double(index + 1)))]
                return f
            }
            document.layers = [GeoLayer(name: name, features: features)]
            if let srid = result.srid {
                if let crs = CRS.epsg(srid) { document.crs = crs } else { document.notices.append("Unknown SRID \(srid).") }
            }
            if result.skipped > 0 { document.notices.append("\(result.skipped.formatted()) unreadable \(result.skipped == 1 ? "line" : "lines") skipped.") }
            document.truncated = result.truncated
            return document

        case .shapefile:
            let sources = try ShapefileReader.sources(for: file.url, maxBytes: limits.maxBytes)
            var budget = GeoBudget(limits)
            let result = try ShapefileReader.read(sources, limits: limits, budget: &budget)
            let document = MapDocument(format: .shapefile)
            document.layers = [result.layer]
            document.crs = result.crs
            document.truncated = budget.exhausted
            if sources.dbf == nil { document.notices.append("No .dbf beside this shapefile, so features have no attributes.") }
            if result.prjUnreadable { document.notices.append("The .prj file couldn’t be read.") }
            if sources.prj == nil { document.facts.append("No .prj") }
            return document

        case .zippedShapefile:
            let zip = try ZipMembers(url: file.url)
            let all = ShapefileReader.sources(in: zip, maxBytes: limits.maxBytes)
            guard !all.isEmpty else { throw GeoError.invalid("No readable shapefile in this archive.") }
            var budget = GeoBudget(limits)
            let document = MapDocument(format: .zippedShapefile)
            var reprojected: [String] = []
            var crsNames = Set<String>()
            for sources in all {
                guard let result = try? ShapefileReader.read(sources, limits: limits, budget: &budget) else { continue }
                if let crs = result.crs {
                    crsNames.insert(crs.name)
                    if !crs.isWGS84Compatible, crs.canTransform {
                        for i in result.layer.features.indices {
                            result.layer.features[i].geometry = result.layer.features[i].geometry?.mapPoints { crs.transform($0) }
                        }
                        if !reprojected.contains(crs.name) { reprojected.append(crs.name) }
                    } else if !crs.canTransform {
                        document.crs = crs
                    }
                    if document.crs == nil { document.crs = crs }
                }
                document.layers.append(result.layer)
            }
            if !reprojected.isEmpty { document.markReprojected(reprojected.joined(separator: ", ")) }
            document.truncated = budget.exhausted
            return document

        case .geopackage:
            return try GeoPackageReader.read(file.url, limits: limits)

        case .mbtiles:
            let (set, metadata, count) = try MBTilesReader.read(file.url, name: name)
            let document = MapDocument(format: .mbtiles)
            document.crs = .wgs84
            document.title = set.info.name
            document.tileSets = [set]
            document.facts.append(set.info.kind == .vector
                                  ? "Vector · \(set.info.vectorLayers.count) \(set.info.vectorLayers.count == 1 ? "layer" : "layers")"
                                  : "Raster · \(set.info.format.uppercased())")
            document.facts.append(set.info.minzoom == set.info.maxzoom ? "Zoom \(set.info.minzoom)" : "Zoom \(set.info.minzoom)–\(set.info.maxzoom)")
            if let count { document.facts.append("\(count.formatted()) \(count == 1 ? "tile" : "tiles")") }
            _ = metadata
            return document
        }
    }

    /// Text formats that turn out not to be geodata are shown as code instead.
    static func textFallback(_ file: FileInfo, format: MapFormat) -> PreparedPreview? {
        let grammar: String
        switch format {
        case .geojson, .geojsonLines, .topojson: grammar = "json"
        case .kml, .gpx, .osm: grammar = "xml"
        case .wkt: grammar = "plaintext"
        default: return nil
        }
        guard let text = try? TextFile(url: file.url) else { return nil }
        let lines = text.lineCount
        let summary = FileSummary(symbol: grammar == "json" ? "curlybraces.square" : "chevron.left.forwardslash.chevron.right",
                                  title: grammar == "json" ? "JSON" : (grammar == "xml" ? "XML" : "Text"),
                                  details: ["\(lines.formatted()) \(lines == 1 ? "line" : "lines")"] + [file.sizeText].compactMap { $0 },
                                  trailing: file.modifiedText)
        return .web(WebDocument(kind: .code, text: text.text, grammar: grammar, truncated: text.truncated), summary, NSSize(width: 920, height: 720))
    }
}
