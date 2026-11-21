import Foundation

enum MapFormat: String, Encodable {
    case geojson, geojsonLines, topojson, kml, kmz, gpx, shapefile, zippedShapefile, geopackage, mbtiles, osm, wkt

    var title: String {
        switch self {
        case .geojson: return "GeoJSON"
        case .geojsonLines: return "GeoJSON Lines"
        case .topojson: return "TopoJSON"
        case .kml: return "KML"
        case .kmz: return "KMZ"
        case .gpx: return "GPX"
        case .shapefile: return "Shapefile"
        case .zippedShapefile: return "Shapefile Archive"
        case .geopackage: return "GeoPackage"
        case .mbtiles: return "MBTiles"
        case .osm: return "OpenStreetMap"
        case .wkt: return "Well-Known Text"
        }
    }

    var symbol: String {
        switch self {
        case .gpx: return "figure.hiking"
        case .mbtiles: return "square.stack.3d.up"
        case .geopackage: return "shippingbox"
        case .osm: return "map"
        case .kml, .kmz: return "mappin.and.ellipse"
        default: return "map"
        }
    }

    var badge: String {
        switch self {
        case .geojson: return "GEOJSON"
        case .geojsonLines: return "GEOJSONL"
        case .topojson: return "TOPOJSON"
        case .kml: return "KML"
        case .kmz: return "KMZ"
        case .gpx: return "GPX"
        case .shapefile: return "SHP"
        case .zippedShapefile: return "ZIP"
        case .geopackage: return "GPKG"
        case .mbtiles: return "MBTILES"
        case .osm: return "OSM"
        case .wkt: return "WKT"
        }
    }
}

/// Planar coordinates (no known CRS) laid out linearly in Web Mercator so the map draws them
/// undistorted. The page inverts this to show original coordinates.
struct PlanarFrame: Encodable {
    var cx: Double
    var cy: Double
    var scale: Double
    /// Screen-style coordinates (pre-projected TopoJSON): y grows downwards.
    var yDown: Bool

    static let radius = 6378137.0

    init(bounds: GeoBounds, yDown: Bool = false) {
        cx = (bounds.minX + bounds.maxX) / 2
        cy = (bounds.minY + bounds.maxY) / 2
        let extent = max(bounds.width, bounds.height, 1e-9)
        // The larger side spans 70% of the world's width.
        scale = 0.7 * 2 * .pi * PlanarFrame.radius / extent
        self.yDown = yDown
    }

    func apply(_ p: GeoPoint) -> GeoPoint? {
        guard p.isFinite else { return nil }
        let mx = (p.x - cx) * scale, my = (p.y - cy) * scale * (yDown ? -1 : 1)
        return GeoPoint(mx / PlanarFrame.radius * 180 / .pi, atan(sinh(my / PlanarFrame.radius)) * 180 / .pi)
    }
}

/// What every reader produces: layers of features, plus what the page needs to explain them.
final class MapDocument {
    enum Projection { case wgs84, assumedWGS84, reprojected(String), planar(String) }

    var format: MapFormat
    var title: String?
    var layers: [GeoLayer] = []
    /// The source CRS, if the file names one.
    var crs: CRS?
    private(set) var projection: Projection = .wgs84
    var notices: [String] = []
    var truncated = false
    var tracks: [TrackProfile] = []
    var overlays: [GroundOverlay] = []
    /// Icon images (KMZ members or files beside a KML), referenced by `GeoStyle.icon`.
    var icons: [String] = []
    var planar: PlanarFrame?
    /// Extra facts for the info bar ("3 waypoints").
    var facts: [String] = []
    /// MBTiles and GeoPackage tile tables, served tile by tile.
    var tileSets: [TileSet] = []
    /// Set when a reader already reprojected its layers (GeoPackage tables, zipped shapefiles
    /// whose layers each have their own CRS).
    private var reprojectedByReader: String?

    init(format: MapFormat) { self.format = format }

    func markReprojected(_ name: String) {
        reprojectedByReader = name
    }

    var isReprojected: Bool { if case .reprojected = projection { return true }; return false }

    var stats: GeoStats {
        var stats = GeoStats()
        for layer in layers { for feature in layer.features { stats.add(feature.geometry) } }
        return stats
    }

    var bounds: GeoBounds {
        var b = GeoBounds()
        for layer in layers { b.extend(layer.bounds) }
        for overlay in overlays {
            b.extend(GeoPoint(overlay.west, overlay.south))
            b.extend(GeoPoint(overlay.east, overlay.north))
        }
        return b
    }

    /// Several coordinate systems in one file (GeoPackage tables), named together.
    var crsSummary: String?

    var projectionText: String {
        if let crsSummary, !isPlanar { return crsSummary }
        switch projection {
        case .wgs84: return crs?.name ?? "WGS 84"
        case .assumedWGS84: return "WGS 84"
        case .reprojected(let name): return name
        case .planar: return "No coordinate system"
        }
    }

    var isPlanar: Bool { if case .planar = projection { return true }; return false }

    /// Brings every position to WGS 84: reprojects from a known CRS, or lays out planar data
    /// whose CRS is unknown or unsupported.
    func normalize() {
        if let name = reprojectedByReader {
            projection = .reprojected(name)
            return
        }
        if let crs, !crs.isWGS84Compatible {
            if crs.canTransform {
                transformAll { crs.transform($0) }
                projection = .reprojected(crs.name)
                return
            }
            if case .unsupported(let method) = crs.kind {
                layOutPlanar(reason: "Greece can’t reproject \(crs.name) (\(method)), so it’s drawn in its own coordinates without a basemap.")
                return
            }
        }
        let extent = bounds
        if extent.isEmpty { projection = crs == nil ? .assumedWGS84 : .wgs84; return }
        if extent.looksGeographic {
            projection = crs == nil ? .assumedWGS84 : .wgs84
            return
        }
        layOutPlanar(reason: "This file has no coordinate system and isn’t in longitude and latitude, so it’s drawn in its own coordinates without a basemap.")
    }

    private func layOutPlanar(reason: String) {
        // Pre-projected TopoJSON is made for SVG and canvas, where y grows downwards.
        let frame = PlanarFrame(bounds: bounds, yDown: format == .topojson)
        transformAll { frame.apply($0) }
        overlays.removeAll()
        planar = frame
        projection = .planar(reason)
        notices.append(reason)
    }

    private func transformAll(_ transform: (GeoPoint) -> GeoPoint?) {
        for layer in layers {
            for index in layer.features.indices {
                if let g = layer.features[index].geometry { layer.features[index].geometry = g.mapPoints(transform) }
            }
        }
    }

    // MARK: Feature lookup

    /// Global feature ids: layer offsets so the page can ask for any feature's properties.
    private(set) lazy var layerOffsets: [Int] = {
        var offsets: [Int] = []
        var total = 0
        for layer in layers { offsets.append(total); total += layer.features.count }
        return offsets
    }()

    func feature(id: Int) -> (layer: GeoLayer, feature: GeoFeature)? {
        guard id >= 0 else { return nil }
        for (index, offset) in layerOffsets.enumerated().reversed() where id >= offset {
            let layer = layers[index]
            let local = id - offset
            return local < layer.features.count ? (layer, layer.features[local]) : nil
        }
        return nil
    }
}

// MARK: - GeoJSON for the page

/// Writes compact GeoJSON for MapLibre: geometry, a numeric id and validated styling only.
/// Properties stay in Swift and are fetched one feature at a time by the inspector.
struct GeoJSONWriter {
    private(set) var bytes: [UInt8] = []

    static func layer(_ layer: GeoLayer, firstID: Int) -> Data {
        var writer = GeoJSONWriter()
        writer.bytes.reserveCapacity(64 + layer.features.count * 96)
        writer.raw("{\"type\":\"FeatureCollection\",\"features\":[")
        var first = true
        for (index, feature) in layer.features.enumerated() {
            guard let geometry = feature.geometry, !geometry.isEmpty else { continue }
            let mark = writer.bytes.count
            if !first { writer.raw(",") }
            writer.raw("{\"type\":\"Feature\",\"id\":")
            writer.integer(firstID + index)
            writer.raw(",\"properties\":{")
            writer.style(feature)
            writer.raw("},\"geometry\":")
            if writer.geometry(geometry, depth: 0) {
                writer.raw("}")
                first = false
            } else {
                writer.bytes.removeSubrange(mark...)
            }
        }
        writer.raw("]}")
        return Data(writer.bytes)
    }

    private mutating func raw(_ text: StaticString) {
        text.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    private mutating func integer(_ value: Int) {
        bytes.append(contentsOf: String(value).utf8)
    }

    /// Up to seven decimals (about a centimetre), trailing zeros trimmed.
    mutating func number(_ value: Double) {
        guard value.isFinite else { bytes.append(0x30); return }
        let clamped = min(max(value, -1e9), 1e9)
        var scaled = (abs(clamped) * 1e7).rounded()
        if scaled == 0 { bytes.append(0x30); return }
        if clamped < 0 { bytes.append(0x2D) }
        if scaled > 9.2e18 { scaled = 9.2e18 }
        let v = UInt64(scaled)
        let whole = v / 10_000_000
        var fraction = v % 10_000_000
        bytes.append(contentsOf: String(whole).utf8)
        guard fraction > 0 else { return }
        var digits = 7
        while fraction % 10 == 0 { fraction /= 10; digits -= 1 }
        bytes.append(0x2E)
        let text = String(fraction)
        for _ in 0..<(digits - text.utf8.count) { bytes.append(0x30) }
        bytes.append(contentsOf: text.utf8)
    }

    private mutating func string(_ text: String) {
        bytes.append(contentsOf: JSONNode.quoted(text).utf8)
    }

    private mutating func style(_ feature: GeoFeature) {
        var first = true
        func key(_ name: StaticString, _ writer: inout GeoJSONWriter) {
            if !first { writer.raw(",") }
            first = false
            writer.raw("\"")
            writer.raw(name)
            writer.raw("\":")
        }
        if let style = feature.style {
            if let v = style.stroke { key("stroke", &self); string(v) }
            if let v = style.strokeWidth { key("stroke-width", &self); number(v) }
            if let v = style.strokeOpacity { key("stroke-opacity", &self); number(v) }
            if let v = style.fill { key("fill", &self); string(v) }
            if let v = style.fillOpacity { key("fill-opacity", &self); number(v) }
            if let v = style.markerColor { key("marker-color", &self); string(v) }
            if let v = style.icon { key("icon", &self); string("icon-\(v)") }
            if let v = style.iconScale { key("icon-scale", &self); number(v) }
        }
        if let name = feature.name, case .point = feature.geometry?.family ?? .mixed {
            key("label", &self)
            string(String(name.prefix(80)))
        }
    }

    private mutating func position(_ p: GeoPoint) {
        bytes.append(0x5B)
        number(p.x)
        bytes.append(0x2C)
        number(p.y)
        bytes.append(0x5D)
    }

    private mutating func positions(_ points: [GeoPoint]) {
        bytes.append(0x5B)
        for (i, p) in points.enumerated() {
            if i > 0 { bytes.append(0x2C) }
            position(p)
        }
        bytes.append(0x5D)
    }

    /// Closes rings and winds them for MapLibre: outer rings counter-clockwise, holes clockwise.
    static func cleanRings(_ rings: [[GeoPoint]]) -> [[GeoPoint]] {
        var result: [[GeoPoint]] = []
        for (index, ring) in rings.enumerated() {
            var ring = ring.filter(\.isFinite)
            if let first = ring.first, ring.last != first { ring.append(first) }
            guard ring.count >= 4 else { if index == 0 { return [] } else { continue } }
            let ccw = signedArea(ring) > 0
            if ccw != (index == 0) { ring.reverse() }
            result.append(ring)
        }
        return result
    }

    static func signedArea(_ ring: [GeoPoint]) -> Double {
        var sum = 0.0
        for i in 0..<(ring.count - 1) { sum += ring[i].x * ring[i + 1].y - ring[i + 1].x * ring[i].y }
        return sum / 2
    }

    /// False if nothing drawable remains.
    private mutating func geometry(_ geometry: GeoGeometry, depth: Int) -> Bool {
        switch geometry {
        case .point(let p):
            guard p.isFinite else { return false }
            raw("{\"type\":\"Point\",\"coordinates\":")
            position(p)
        case .multiPoint(let points):
            let points = points.filter(\.isFinite)
            guard !points.isEmpty else { return false }
            raw("{\"type\":\"MultiPoint\",\"coordinates\":")
            positions(points)
        case .lineString(let points):
            let points = points.filter(\.isFinite)
            guard points.count >= 2 else { return false }
            raw("{\"type\":\"LineString\",\"coordinates\":")
            positions(points)
        case .multiLineString(let lines):
            let lines = lines.map { $0.filter(\.isFinite) }.filter { $0.count >= 2 }
            guard !lines.isEmpty else { return false }
            raw("{\"type\":\"MultiLineString\",\"coordinates\":[")
            for (i, line) in lines.enumerated() { if i > 0 { raw(",") }; positions(line) }
            raw("]")
        case .polygon(let rings):
            let rings = GeoJSONWriter.cleanRings(rings)
            guard !rings.isEmpty else { return false }
            raw("{\"type\":\"Polygon\",\"coordinates\":[")
            for (i, ring) in rings.enumerated() { if i > 0 { raw(",") }; positions(ring) }
            raw("]")
        case .multiPolygon(let polygons):
            let polygons = polygons.map(GeoJSONWriter.cleanRings).filter { !$0.isEmpty }
            guard !polygons.isEmpty else { return false }
            raw("{\"type\":\"MultiPolygon\",\"coordinates\":[")
            for (i, rings) in polygons.enumerated() {
                if i > 0 { raw(",") }
                raw("[")
                for (j, ring) in rings.enumerated() { if j > 0 { raw(",") }; positions(ring) }
                raw("]")
            }
            raw("]")
        case .collection(let parts):
            guard depth < 4 else { return false }
            raw("{\"type\":\"GeometryCollection\",\"geometries\":[")
            var any = false
            for part in parts {
                let mark = bytes.count
                if any { raw(",") }
                if self.geometry(part, depth: depth + 1) { any = true } else { bytes.removeSubrange(mark...) }
            }
            raw("]")
            guard any else { return false }
        }
        raw("}")
        return true
    }
}
