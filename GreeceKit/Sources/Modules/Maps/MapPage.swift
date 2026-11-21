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
                                count: layer.features.count, points: s.points, lines: s.lines + s.mixed, polygons: s.polygons, hidden: layer.isHidden))
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
            bounds: fit.isEmpty ? nil : fit.array, notices: document.notices + (document.truncated ? ["Showing the first \(stats.features.formatted()) features: this file is larger than Greece draws in a preview."] : []),
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
        let resources = MapResources(document: document, source: file.url)
        page.resources = { path in resources.serve(path) }
        return .web(page, summary(document, file: file), NSSize(width: 1040, height: 760))
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
    static func distance(_ metres: Double, imperial: Bool) -> String {
        if imperial {
            let miles = metres / 1609.344
            return miles < 0.2 ? "\(Int((metres * 3.28084).rounded()).formatted()) ft" : String(format: miles < 100 ? "%.1f mi" : "%.0f mi", miles)
        }
        if metres < 1000 { return "\(Int(metres.rounded()).formatted()) m" }
        return String(format: metres < 100_000 ? "%.1f km" : "%.0f km", metres / 1000)
    }

    static func elevation(_ metres: Double, imperial: Bool) -> String {
        imperial ? "\(Int((metres * 3.28084).rounded()).formatted()) ft" : "\(Int(metres.rounded()).formatted()) m"
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86_400, hours = (total % 86_400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    /// "48.1°N–48.3°N, 16.2°E–16.5°E", precise enough for the extent.
    static func bounds(_ b: GeoBounds) -> String {
        let span = max(b.width, b.height)
        let digits = span >= 20 ? 0 : span >= 2 ? 1 : span >= 0.2 ? 2 : 3
        func lat(_ v: Double) -> String { String(format: "%.\(digits)f°%@", abs(v), v < 0 ? "S" : "N") }
        func lon(_ v: Double) -> String {
            var x = v.truncatingRemainder(dividingBy: 360)
            if x > 180 { x -= 360 } else if x < -180 { x += 360 }
            return String(format: "%.\(digits)f°%@", abs(x), x < 0 ? "W" : "E")
        }
        if b.width == 0 && b.height == 0 { return "\(lat(b.minY)), \(lon(b.minX))" }
        return "\(lat(b.minY))–\(lat(b.maxY)), \(lon(b.minX))–\(lon(b.maxX))"
    }
}

/// Serves a document's data to its page, off the main thread.
final class MapResources: @unchecked Sendable {
    private let document: MapDocument
    private let source: URL
    private let lock = NSLock()
    private var layerCache: [Int: Data] = [:]
    private var zip: ZipMembers?

    init(document: MapDocument, source: URL) {
        self.document = document
        self.source = source
    }

    func serve(_ path: String) -> (data: Data, mimeType: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }
        switch first {
        case "layer":
            guard parts.count == 2, let index = Int(parts[1].replacingOccurrences(of: ".json", with: "")),
                  index >= 0, index < document.layers.count else { return nil }
            lock.lock()
            defer { lock.unlock() }
            if let cached = layerCache[index] { return (cached, "application/json") }
            let data = GeoJSONWriter.layer(document.layers[index], firstID: document.layerOffsets[index])
            layerCache[index] = data
            return (data, "application/json")

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
        if document.format == .kmz {
            lock.lock()
            defer { lock.unlock() }
            if zip == nil { zip = try? ZipMembers(url: self.source) }
            guard let zip, let member = zip.member(named: source) else { return nil }
            return zip.data(member, limit: limit)
        }
        guard source.hasPrefix("/"), let size = (try? URL(fileURLWithPath: source).resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: source))
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
    static func typeName(_ g: GeoGeometry) -> String {
        switch g {
        case .point: return "Point"
        case .multiPoint(let p): return p.count == 1 ? "Point" : "\(p.count.formatted()) points"
        case .lineString: return "Line"
        case .multiLineString(let l): return l.count == 1 ? "Line" : "\(l.count.formatted()) lines"
        case .polygon: return "Polygon"
        case .multiPolygon(let p): return p.count == 1 ? "Polygon" : "\(p.count.formatted()) polygons"
        case .collection(let parts): return "Collection of \(parts.count.formatted())"
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
            if acres >= 640 { return String(format: "%.1f sq mi", m2 / 2_589_988.11) }
            return acres >= 1 ? String(format: "%.1f acres", acres) : "\(Int((m2 * 10.7639).rounded()).formatted()) sq ft"
        }
        if m2 >= 1_000_000 { return String(format: m2 >= 100_000_000 ? "%.0f km²" : "%.2f km²", m2 / 1_000_000) }
        if m2 >= 10_000 { return String(format: "%.2f ha", m2 / 10_000) }
        return "\(Int(m2.rounded()).formatted()) m²"
    }
}
