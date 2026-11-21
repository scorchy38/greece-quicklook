import Foundation

/// A position: longitude and latitude in degrees once a document is in WGS 84, source units before.
struct GeoPoint: Equatable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    var isFinite: Bool { x.isFinite && y.isFinite }
}

indirect enum GeoGeometry {
    case point(GeoPoint)
    case multiPoint([GeoPoint])
    case lineString([GeoPoint])
    case multiLineString([[GeoPoint]])
    /// Outer ring first, then holes.
    case polygon([[GeoPoint]])
    case multiPolygon([[[GeoPoint]]])
    case collection([GeoGeometry])

    enum Family: String { case point, line, polygon, mixed }

    var family: Family {
        switch self {
        case .point, .multiPoint: return .point
        case .lineString, .multiLineString: return .line
        case .polygon, .multiPolygon: return .polygon
        case .collection(let parts):
            let families = Set(parts.map(\.family))
            return families.count == 1 ? families.first! : .mixed
        }
    }

    var pointCount: Int {
        switch self {
        case .point: return 1
        case .multiPoint(let p), .lineString(let p): return p.count
        case .multiLineString(let l), .polygon(let l): return l.reduce(0) { $0 + $1.count }
        case .multiPolygon(let m): return m.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        case .collection(let g): return g.reduce(0) { $0 + $1.pointCount }
        }
    }

    var isEmpty: Bool { pointCount == 0 }

    /// Applies `transform` to every position, dropping positions it can't convert.
    func mapPoints(_ transform: (GeoPoint) -> GeoPoint?) -> GeoGeometry? {
        func line(_ points: [GeoPoint]) -> [GeoPoint] { points.compactMap(transform) }
        switch self {
        case .point(let p): return transform(p).map(GeoGeometry.point)
        case .multiPoint(let p): return .multiPoint(line(p))
        case .lineString(let p): return .lineString(line(p))
        case .multiLineString(let l): return .multiLineString(l.map(line))
        case .polygon(let r): return .polygon(r.map(line))
        case .multiPolygon(let m): return .multiPolygon(m.map { $0.map(line) })
        case .collection(let g): return .collection(g.compactMap { $0.mapPoints(transform) })
        }
    }

    func forEachPoint(_ body: (GeoPoint) -> Void) {
        switch self {
        case .point(let p): body(p)
        case .multiPoint(let p), .lineString(let p): p.forEach(body)
        case .multiLineString(let l), .polygon(let l): l.forEach { $0.forEach(body) }
        case .multiPolygon(let m): m.forEach { $0.forEach { $0.forEach(body) } }
        case .collection(let g): g.forEach { $0.forEachPoint(body) }
        }
    }

    var bounds: GeoBounds {
        var b = GeoBounds()
        forEachPoint { b.extend($0) }
        return b
    }
}

struct GeoBounds: Equatable {
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity

    init() {}
    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    var isEmpty: Bool { !(minX <= maxX && minY <= maxY) }
    var width: Double { maxX - minX }
    var height: Double { maxY - minY }

    mutating func extend(_ p: GeoPoint) {
        guard p.isFinite else { return }
        if p.x < minX { minX = p.x }
        if p.x > maxX { maxX = p.x }
        if p.y < minY { minY = p.y }
        if p.y > maxY { maxY = p.y }
    }

    mutating func extend(_ other: GeoBounds) {
        guard !other.isEmpty else { return }
        extend(GeoPoint(other.minX, other.minY))
        extend(GeoPoint(other.maxX, other.maxY))
    }

    /// Plausible longitude/latitude (a little slack for sloppy writers).
    var looksGeographic: Bool {
        !isEmpty && minX >= -540 && maxX <= 540 && minY >= -90.5 && maxY <= 90.5
    }

    var array: [Double] { [minX, minY, maxX, maxY] }
}

/// A property value, kept in the file's order and type for the inspector.
enum GeoValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    /// A nested object or array, as compact JSON text.
    case json(String)

    var text: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return GeoValue.format(n)
        case .string(let s), .json(let s): return s
        }
    }

    static func format(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }
}

/// simplestyle-spec styling (https://github.com/mapbox/simplestyle-spec), also used for KML styles.
/// Every value is validated before it reaches the page.
struct GeoStyle: Equatable {
    var stroke: String?
    var strokeWidth: Double?
    var strokeOpacity: Double?
    var fill: String?
    var fillOpacity: Double?
    var markerColor: String?
    /// Key of an icon image the page can load (`icon/<index>`).
    var icon: Int?
    var iconScale: Double?

    var isEmpty: Bool { self == GeoStyle() }

    /// "#rrggbb" for valid CSS hex colours (#rgb, #rrggbb, with or without '#'), nil otherwise.
    static func color(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 3 || text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        return "#" + text.lowercased()
    }

    static func clamp(_ value: Double?, _ low: Double, _ high: Double) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, low), high)
    }
}

struct GeoFeature {
    var geometry: GeoGeometry?
    var properties: [(key: String, value: GeoValue)] = []
    var style: GeoStyle?
    /// A display name (KML/GPX name, or a "name"/"title" property).
    var name: String?
    /// KML/GPX description; may be HTML, sanitised by the page.
    var detail: String?
}

/// How the page draws a layer beyond its features' own styling.
enum LayerRole: String, Encodable {
    /// Ordinary data in the layer's colour.
    case data
    /// A GPX or KML track: a thick line with a casing, like a route in Maps.
    case track
    /// OpenStreetMap layers, styled per feature: roads get casings, paths and rail dashes.
    case area, road, path, rail, place
}

final class GeoLayer {
    var name: String
    var features: [GeoFeature]
    var role: LayerRole = .data
    var isHidden = false

    init(name: String, features: [GeoFeature] = []) {
        self.name = name
        self.features = features
    }

    var bounds: GeoBounds {
        var b = GeoBounds()
        for feature in features { if let g = feature.geometry { b.extend(g.bounds) } }
        return b
    }
}

/// A raster image laid over the map (KML GroundOverlay).
struct GroundOverlay {
    var name: String?
    /// Path of the image inside a KMZ, or an absolute file path beside a KML.
    var source: String
    var north: Double, south: Double, east: Double, west: Double
    var rotation: Double
}

/// Counts and extent for the info bar.
struct GeoStats: Equatable {
    var points = 0, lines = 0, polygons = 0, mixed = 0, empty = 0
    var features: Int { points + lines + polygons + mixed + empty }

    mutating func add(_ geometry: GeoGeometry?) {
        guard let geometry, !geometry.isEmpty else { empty += 1; return }
        switch geometry.family {
        case .point: points += 1
        case .line: lines += 1
        case .polygon: polygons += 1
        case .mixed: mixed += 1
        }
    }

    /// "812 polygons, 392 points" or "1 feature".
    var text: String {
        var parts: [String] = []
        func add(_ n: Int, _ one: String, _ many: String) {
            if n > 0 { parts.append("\(n.formatted()) \(n == 1 ? one : many)") }
        }
        add(polygons, "polygon", "polygons")
        add(lines, "line", "lines")
        add(points, "point", "points")
        add(mixed, "collection", "collections")
        if parts.isEmpty { return features == 0 ? "No features" : "\(features.formatted()) \(features == 1 ? "feature" : "features") without geometry" }
        if empty > 0 { add(empty, "without geometry", "without geometry") }
        return parts.joined(separator: ", ")
    }
}

/// Hard limits for hostile or enormous files.
struct GeoLimits {
    var maxBytes = 192 * 1024 * 1024
    var maxFeatures = 600_000
    var maxPoints = 12_000_000
    var maxProperties = 250
    var maxStringLength = 32 * 1024
    var maxDepth = 64
    var deadline: CFAbsoluteTime = CFAbsoluteTimeGetCurrent() + 12

    static var preview: GeoLimits { GeoLimits() }

    /// Thumbnails have a second or two and a small memory budget.
    static var thumbnail: GeoLimits {
        GeoLimits(maxBytes: 48 * 1024 * 1024, maxFeatures: 120_000, maxPoints: 2_000_000,
                  maxProperties: 0, maxStringLength: 256, maxDepth: 48, deadline: CFAbsoluteTimeGetCurrent() + 2.5)
    }

    var expired: Bool { CFAbsoluteTimeGetCurrent() > deadline }
}

/// Counts what a reader has taken in, so it can stop at the limits.
struct GeoBudget {
    let limits: GeoLimits
    private(set) var features = 0
    private(set) var points = 0
    private(set) var exhausted = false
    private var checks = 0

    init(_ limits: GeoLimits) { self.limits = limits }

    /// False once any limit is reached; the reader should stop adding features.
    mutating func admit(_ geometry: GeoGeometry?) -> Bool {
        guard !exhausted else { return false }
        features += 1
        points += geometry?.pointCount ?? 0
        checks += 1
        if features >= limits.maxFeatures || points >= limits.maxPoints || (checks & 255 == 0 && limits.expired) {
            exhausted = true
        }
        return true
    }

    mutating func checkTime() -> Bool {
        if limits.expired { exhausted = true }
        return !exhausted
    }

    mutating func addPoints(_ n: Int) {
        points += n
        if points >= limits.maxPoints { exhausted = true }
    }
}

enum GeoError: LocalizedError {
    case invalid(String)
    case tooLarge(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .tooLarge(let reason): return reason
        }
    }
}
