import AppKit

/// What the page receives up front. Features themselves are fetched from `greece://module/…`.
struct MapPageData: Encodable {
    struct Layer: Encodable {
        var id: Int
        var name: String
        var url: String
        var role: LayerRole
        var count: Int
        var points: Int
        var lines: Int
        var polygons: Int
        var hidden: Bool
        /// Palette index for the layer's default colour.
        var color: Int
    }
    struct Overlay: Encodable {
        var name: String?
        var url: String
        /// Top left, top right, bottom right, bottom left.
        var coordinates: [[Double]]
    }
    struct Stats: Encodable { var features: Int; var points: Int; var lines: Int; var polygons: Int }

    var format: MapFormat
    var formatTitle: String
    var title: String?
    var layers: [Layer]
    var bounds: [Double]?
    var notices: [String]
    var planar: PlanarFrame?
    var tracks: [TrackProfile]
    var overlays: [Overlay]
    var icons: [String]
    var tiles: [TileSet.Info]
    var units: String
    var crs: String
    var reprojected: Bool
    var stats: Stats
    var truncated: Bool
}

enum MapPageBuilder {

    static func preview(_ document: MapDocument, file: FileInfo) -> PreparedPreview {
        let stats = document.stats
        let bounds = document.bounds
        var layers: [MapPageData.Layer] = []
        let offsets = document.layerOffsets
        for (index, layer) in document.layers.enumerated() {
            var s = GeoStats()
            for feature in layer.features { s.add(feature.geometry) }
            layers.append(.init(id: offsets[index], name: layer.name, url: "greece://module/layer/\(index).json", role: layer.role,
                                count: layer.features.count, points: s.points, lines: s.lines + s.mixed, polygons: s.polygons, hidden: layer.isHidden,
                                color: layer.colorIndex ?? index))
        }
        var tileBounds = GeoBounds()
        for set in document.tileSets {
            if let b = set.info.bounds { tileBounds.extend(GeoBounds(minX: b[0], minY: b[1], maxX: b[2], maxY: b[3])) }
        }
        var fit = bounds
        if fit.isEmpty { fit = tileBounds }

        let overlays = document.overlays.enumerated().map { index, o -> MapPageData.Overlay in
            .init(name: o.name, url: "greece://module/overlay/\(index)", coordinates: corners(o))
        }
        let data = MapPageData(
            format: document.format, formatTitle: document.format.title, title: document.title, layers: layers,
            bounds: fit.isEmpty ? nil : fit.array, notices: document.notices + (document.truncated ? [truncationNotice(stats.features)] : []),
            planar: document.planar, tracks: document.tracks, overlays: overlays,
            icons: document.icons.indices.map { "greece://module/icon/\($0)" },
            tiles: document.tileSets.map(\.info),
            units: Locale.current.measurementSystem == .us ? "imperial" : "metric",
            crs: document.projectionText, reprojected: document.isReprojected,
            stats: .init(features: stats.features, points: stats.points, lines: stats.lines + stats.mixed, polygons: stats.polygons),
            truncated: document.truncated)

        var page = WebDocument(module: .init("map"), data: data,
                               scripts: ["vendor/maplibre/maplibre-gl.js", "modules/maps.js"],
                               styles: ["vendor/maplibre/maplibre-gl.css", "modules/maps.css"])
        let resources = MapResources(document: document)
        page.resources = { path in resources.serve(path) }
        return .web(page, summary(document, file: file), NSSize(width: 1040, height: 760))
    }

    static func truncationNotice(_ features: Int) -> String {
        String(localized: "Showing the first \(features) features: this file is larger than Greece draws in a preview.", bundle: .greeceKit,
               comment: "Notice on a map")
    }

    static func summary(_ document: MapDocument, file: FileInfo) -> FileSummary {
        var details: [String] = []
        let stats = document.stats
        if let track = document.tracks.max(by: { $0.distance < $1.distance }), document.format == .gpx || stats.points + stats.polygons == 0 {
            let imperial = Locale.current.measurementSystem == .us
            details.append(MapFormatting.distance(track.distance, imperial: imperial))
            if let duration = track.duration { details.append(MapFormatting.duration(duration)) }
            if let gain = track.gain, gain >= 1 { details.append("↑ " + MapFormatting.elevation(gain, imperial: imperial)) }
            details += document.facts
        } else if document.format == .mbtiles {
            details += document.facts
        } else {
            details.append(stats.text)
            details += document.facts
            details.append(document.projectionText)
        }
        if !document.isPlanar, document.format != .mbtiles {
            let b = document.bounds
            if !b.isEmpty { details.append(MapFormatting.bounds(b)) }
        } else if document.format == .mbtiles, let b = document.tileSets.first?.info.bounds {
            details.append(MapFormatting.bounds(GeoBounds(minX: b[0], minY: b[1], maxX: b[2], maxY: b[3])))
        }
        let title = document.format == .zippedShapefile ? "Shapefile" : document.format.title
        return FileSummary(symbol: document.format.symbol, title: title, details: details, trailing: file.modifiedText)
    }

    /// A LatLonBox's corners, rotated about its centre (KML rotation is counter-clockwise).
    static func corners(_ o: GroundOverlay) -> [[Double]] {
        let base = [[o.west, o.north], [o.east, o.north], [o.east, o.south], [o.west, o.south]]
        guard o.rotation != 0, o.rotation.isFinite else { return base }
        let cx = (o.west + o.east) / 2, cy = (o.north + o.south) / 2
        let k = cos(cy * .pi / 180)
        let angle = o.rotation * .pi / 180
        return base.map { p in
            let dx = (p[0] - cx) * k, dy = p[1] - cy
            let rx = dx * cos(angle) - dy * sin(angle), ry = dx * sin(angle) + dy * cos(angle)
            return [cx + rx / max(k, 1e-6), cy + ry]
        }
    }
}

enum MapFormatting {
    /// A measurement in the unit given, with a fixed number of decimals, written the locale's way
    /// ("1.5 km", "1,5 km", "1,5 км").
    static func measurement<U: Dimension>(_ value: Double, _ unit: U, decimals: Int,
                                          width: Measurement<U>.FormatStyle.UnitWidth = .abbreviated) -> String {
        Measurement(value: value, unit: unit)
            .formatted(.measurement(width: width, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(decimals))))
    }

    static func distance(_ metres: Double, imperial: Bool) -> String {
        if imperial {
            let miles = metres / 1609.344
            if miles < 0.2 { return measurement(metres * 3.28084, UnitLength.feet, decimals: 0) }
            return measurement(miles, UnitLength.miles, decimals: miles < 100 ? 1 : 0)
        }
        if metres < 1000 { return measurement(metres, UnitLength.meters, decimals: 0) }
        return measurement(metres / 1000, UnitLength.kilometers, decimals: metres < 100_000 ? 1 : 0)
    }

    static func elevation(_ metres: Double, imperial: Bool) -> String {
        imperial ? measurement(metres * 3.28084, UnitLength.feet, decimals: 0) : measurement(metres, UnitLength.meters, decimals: 0)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86_400, hours = (total % 86_400) / 3600, minutes = (total % 3600) / 60
        let d = String(days), h = String(hours), m = String(minutes)
        if days > 0 { return String(localized: "\(d) d \(h) h", bundle: .greeceKit, comment: "A track’s duration, abbreviated: days and hours, such as “2 d 5 h”") }
        if hours > 0 { return String(localized: "\(h) h \(m) min", bundle: .greeceKit, comment: "A track’s duration, abbreviated: hours and minutes, such as “3 h 12 min”") }
        if minutes > 0 { return String(localized: "\(m) min", bundle: .greeceKit, comment: "A track’s duration, abbreviated: minutes, such as “42 min”") }
        let s = String(total)
        return String(localized: "\(s) s", bundle: .greeceKit, comment: "A track’s duration, abbreviated: seconds, such as “30 s”")
    }

    /// "48.1°N–48.3°N, 16.2°E–16.5°E", precise enough for the extent.
    static func bounds(_ b: GeoBounds) -> String {
        let span = max(b.width, b.height)
        let digits = span >= 20 ? 0 : span >= 2 ? 1 : span >= 0.2 ? 2 : 3
        func degrees(_ v: Double) -> String { abs(v).formatted(.number.precision(.fractionLength(digits))) }
        func lat(_ v: Double) -> String {
            let value = degrees(v)
            return v < 0
                ? String(localized: "\(value)°S", bundle: .greeceKit, comment: "A latitude south of the equator, such as “33.9°S”")
                : String(localized: "\(value)°N", bundle: .greeceKit, comment: "A latitude north of the equator, such as “48.1°N”")
        }
        func lon(_ v: Double) -> String {
            var x = v.truncatingRemainder(dividingBy: 360)
            if x > 180 { x -= 360 } else if x < -180 { x += 360 }
            let value = degrees(x)
            return x < 0
                ? String(localized: "\(value)°W", bundle: .greeceKit, comment: "A longitude west of Greenwich, such as “73.9°W”")
                : String(localized: "\(value)°E", bundle: .greeceKit, comment: "A longitude east of Greenwich, such as “16.2°E”")
        }
        if b.width == 0 && b.height == 0 { return "\(lat(b.minY)), \(lon(b.minX))" }
        return "\(lat(b.minY))–\(lat(b.maxY)), \(lon(b.minX))–\(lon(b.maxX))"
    }
}

/// Serves a document's data to its page, off the main thread.
final class MapResources: @unchecked Sendable {
    private let document: MapDocument
    private let lock = NSLock()

    init(document: MapDocument) {
        self.document = document
    }

    func serve(_ path: String) -> (data: Data, mimeType: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }
        switch first {
        case "layer":
            // Written on request and not kept: the page asks for each layer once.
            guard parts.count == 2, let index = Int(parts[1].replacingOccurrences(of: ".json", with: "")),
                  index >= 0, index < document.layers.count else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return (GeoJSONWriter.layer(document.layers[index], firstID: document.layerOffsets[index]), "application/json")

        case "feature":
            guard parts.count == 2, let id = Int(parts[1]) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard let (layer, feature) = document.feature(id: id) else { return nil }
            return (featureJSON(layer: layer, feature: feature), "application/json")

        case "tile":
            guard parts.count == 5, let z = Int(parts[2]), let x = Int(parts[3]), let y = Int(parts[4].split(separator: ".").first.map(String.init) ?? ""),
                  let set = document.tileSets.first(where: { $0.info.id == parts[1] }) else { return nil }
            let vector = set.info.kind == .vector
            guard let data = set.fetch(z, x, y) else {
                return vector ? (Data(), "application/x-protobuf") : (TileSet.transparentPNG, "image/png")
            }
            if vector { return (data, "application/x-protobuf") }
            switch TileSet.sniffFormat(data) {
            case "jpg": return (data, "image/jpeg")
            case "webp": return (data, "image/webp")
            case "gif": return (data, "image/gif")
            default: return (data, "image/png")
            }

        case "icon", "overlay":
            guard parts.count == 2, let index = Int(parts[1]) else { return nil }
            let source: String
            if first == "icon" {
                guard index >= 0, index < document.icons.count else { return nil }
                source = document.icons[index]
            } else {
                guard index >= 0, index < document.overlays.count else { return nil }
                source = document.overlays[index].source
            }
            let limit = first == "icon" ? 4 << 20 : 48 << 20
            guard let data = image(source, limit: limit) else { return nil }
            return (data, mimeType(data))

        default:
            return nil
        }
    }

    /// KMZ members by path, or files beside a KML (already resolved to absolute paths).
    private func image(_ source: String, limit: Int) -> Data? {
        document.loadImage?(source, limit)
    }

    private func mimeType(_ data: Data) -> String {
        switch TileSet.sniffFormat(data) {
        case "png": return "image/png"
        case "jpg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default:
            let head = String(decoding: data.prefix(256), as: UTF8.self)
            return head.contains("<svg") ? "image/svg+xml" : "application/octet-stream"
        }
    }

    private func featureJSON(layer: GeoLayer, feature: GeoFeature) -> Data {
        var out = "{"
        out += "\"layer\":" + JSONNode.quoted(layer.name)
        if let name = feature.name { out += ",\"name\":" + JSONNode.quoted(String(name.prefix(500))) }
        if let detail = feature.detail, !detail.isEmpty { out += ",\"detail\":" + JSONNode.quoted(String(detail.prefix(64 * 1024))) }
        if let g = feature.geometry {
            out += ",\"geometry\":" + JSONNode.quoted(MapMeasure.typeName(g))
            for (key, value) in MapMeasure.facts(g, planar: document.planar, imperial: Locale.current.measurementSystem == .us) {
                out += ",\"\(key)\":" + JSONNode.quoted(value)
            }
        }
        out += ",\"properties\":["
        for (i, (key, value)) in feature.properties.enumerated() {
            if i > 0 { out += "," }
            let kind: String
            switch value {
            case .null: kind = "z"
            case .bool: kind = "b"
            case .number: kind = "n"
            case .string: kind = "s"
            case .json: kind = "j"
            }
            out += "[" + JSONNode.quoted(key) + "," + JSONNode.quoted(value.text) + ",\"" + kind + "\"]"
        }
        out += "]}"
        return Data(out.utf8)
    }
}

/// Lengths, areas and positions for the inspector, measured on the sphere.
enum MapMeasure {
    /// The feature inspector's subtitle: "Polygon", "3 lines". A multi-geometry of one part is named as that part.
    static func typeName(_ g: GeoGeometry) -> String {
        let point = String(localized: "Point [map geometry]", defaultValue: "Point", bundle: .greeceKit, comment: "Map feature inspector: the feature is a point")
        let line = String(localized: "Line [map geometry]", defaultValue: "Line", bundle: .greeceKit, comment: "Map feature inspector: the feature is a line")
        let polygon = String(localized: "Polygon", bundle: .greeceKit, comment: "Map feature inspector: the feature is a polygon")
        switch g {
        case .point: return point
        case .multiPoint(let p): return p.count == 1 ? point : GeoStats.points(p.count)
        case .lineString: return line
        case .multiLineString(let l): return l.count == 1 ? line : GeoStats.lines(l.count)
        case .polygon: return polygon
        case .multiPolygon(let p): return p.count == 1 ? polygon : GeoStats.polygons(p.count)
        case .collection(let parts):
            let count = parts.count
            return String(localized: "Collection of \(count)", bundle: .greeceKit,
                          comment: "Map feature inspector: a geometry collection. The argument is how many geometries it holds")
        }
    }

    static func facts(_ g: GeoGeometry, planar: PlanarFrame?, imperial: Bool) -> [(String, String)] {
        switch g.family {
        case .point:
            var first: GeoPoint?
            g.forEachPoint { if first == nil { first = $0 } }
            guard let p = first else { return [] }
            if let planar {
                let mx = p.x * .pi / 180 * PlanarFrame.radius, my = log(tan(.pi / 4 + p.y * .pi / 360)) * PlanarFrame.radius
                let y = my / planar.scale * (planar.yDown ? -1 : 1) + planar.cy
                return [("position", String(format: "%.3f, %.3f", mx / planar.scale + planar.cx, y))]
            }
            return [("position", String(format: "%.6f, %.6f", p.y, p.x))]
        case .line:
            guard planar == nil else { return [] }
            return [("length", MapFormatting.distance(length(g), imperial: imperial))]
        case .polygon:
            guard planar == nil else { return [] }
            return [("area", area(squareMetres: area(g), imperial: imperial))]
        case .mixed:
            return []
        }
    }

    static func length(_ g: GeoGeometry) -> Double {
        func line(_ p: [GeoPoint]) -> Double {
            guard p.count > 1 else { return 0 }
            return (1..<p.count).reduce(0) { $0 + TrackProfile.haversine(p[$1 - 1], p[$1]) }
        }
        switch g {
        case .lineString(let p): return line(p)
        case .multiLineString(let l): return l.reduce(0) { $0 + line($1) }
        case .collection(let parts): return parts.reduce(0) { $0 + length($1) }
        default: return 0
        }
    }

    /// Spherical excess of each ring (Chamberlain and Duquette).
    static func ringArea(_ ring: [GeoPoint]) -> Double {
        guard ring.count > 2 else { return 0 }
        let r = 6_371_008.8
        var total = 0.0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            total += (b.x - a.x) * .pi / 180 * (2 + sin(a.y * .pi / 180) + sin(b.y * .pi / 180))
        }
        return abs(total * r * r / 2)
    }

    static func area(_ g: GeoGeometry) -> Double {
        func polygon(_ rings: [[GeoPoint]]) -> Double {
            guard let outer = rings.first else { return 0 }
            return max(0, ringArea(outer) - rings.dropFirst().reduce(0) { $0 + ringArea($1) })
        }
        switch g {
        case .polygon(let r): return polygon(r)
        case .multiPolygon(let p): return p.reduce(0) { $0 + polygon($1) }
        case .collection(let parts): return parts.reduce(0) { $0 + area($1) }
        default: return 0
        }
    }

    static func area(squareMetres m2: Double, imperial: Bool) -> String {
        if imperial {
            let acres = m2 / 4046.8564224
            if acres >= 640 { return MapFormatting.measurement(m2 / 2_589_988.11, UnitArea.squareMiles, decimals: 1) }
            return acres >= 1 ? MapFormatting.measurement(acres, UnitArea.acres, decimals: 1, width: .wide)
                              : MapFormatting.measurement(m2 * 10.7639, UnitArea.squareFeet, decimals: 0)
        }
        if m2 >= 1_000_000 { return MapFormatting.measurement(m2 / 1_000_000, UnitArea.squareKilometers, decimals: m2 >= 100_000_000 ? 0 : 2) }
        if m2 >= 10_000 { return MapFormatting.measurement(m2 / 10_000, UnitArea.hectares, decimals: 2) }
        return MapFormatting.measurement(m2, UnitArea.squareMeters, decimals: 0)
    }
}
