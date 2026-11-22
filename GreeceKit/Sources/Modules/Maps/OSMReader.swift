import Foundation

/// OpenStreetMap XML (.osm): nodes, ways and multipolygon relations, sorted into cartographic
/// layers (land use, water, buildings, roads…) and styled like a map rather than a diagram.
enum OSMReader {

    enum Class: Int, CaseIterable {
        case landuse, green, water, waterway, building, railway, road, path, boundary, other, poi

        var layerName: String {
            switch self {
            case .landuse: return "Land Use"
            case .green: return "Parks and Nature"
            case .water: return "Water"
            case .waterway: return "Rivers and Canals"
            case .building: return "Buildings"
            case .railway: return "Railways"
            case .road: return "Roads"
            case .path: return "Paths"
            case .boundary: return "Boundaries"
            case .other: return "Other"
            case .poi: return "Places"
            }
        }
    }

    private static let ignoredTags: Set<String> = ["created_by", "source", "note", "fixme", "FIXME", "attribution"]

    static func read(_ data: Data, limits: GeoLimits) throws -> MapDocument {
        let document = MapDocument(format: .osm)
        document.crs = .wgs84
        var budget = GeoBudget(limits)
        let stream = XMLStream(deadline: limits.deadline, maxText: 1024)

        var nodes: [Int64: GeoPoint] = [:]
        var ways: [(id: Int64, refs: [Int64], tags: [(String, String)])] = []
        var relations: [(id: Int64, members: [(type: String, ref: Int64, role: String)], tags: [(String, String)])] = []
        var taggedNodes: [(id: Int64, point: GeoPoint, tags: [(String, String)])] = []

        var sawOSM = false
        var element: String?
        var currentID: Int64 = 0
        var currentPoint: GeoPoint?
        var tags: [(String, String)] = []
        var refs: [Int64] = []
        var members: [(type: String, ref: Int64, role: String)] = []
        var bounds: GeoBounds?

        stream.onStart = { [unowned stream] name, attributes in
            switch name {
            case "osm", "osmChange": sawOSM = true
            case "bounds":
                if let a = attributes["minlat"].flatMap(Double.init), let b = attributes["minlon"].flatMap(Double.init),
                   let c = attributes["maxlat"].flatMap(Double.init), let d = attributes["maxlon"].flatMap(Double.init) {
                    bounds = GeoBounds(minX: b, minY: a, maxX: d, maxY: c)
                }
            case "node", "way", "relation":
                element = name
                currentID = attributes["id"].flatMap { Int64($0) } ?? 0
                tags = []
                refs = []
                members = []
                currentPoint = nil
                if name == "node", let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
                   abs(lat) <= 90, abs(lon) <= 180 {
                    currentPoint = GeoPoint(lon, lat)
                }
                if nodes.count + ways.count >= limits.maxPoints { budget.addPoints(limits.maxPoints); stream.stop() }
            case "tag":
                if element != nil, let k = attributes["k"], let v = attributes["v"], tags.count < 200, !ignoredTags.contains(k) {
                    tags.append((String(k.prefix(256)), String(v.prefix(1024))))
                }
            case "nd":
                if element == "way", let ref = attributes["ref"].flatMap({ Int64($0) }), refs.count < 100_000 { refs.append(ref) }
            case "member":
                if element == "relation", let ref = attributes["ref"].flatMap({ Int64($0) }), members.count < 50_000 {
                    members.append((attributes["type"] ?? "", ref, attributes["role"] ?? ""))
                }
            default: break
            }
        }
        stream.onEnd = { name, _ in
            switch name {
            case "node":
                if let p = currentPoint {
                    nodes[currentID] = p
                    if !tags.isEmpty { taggedNodes.append((currentID, p, tags)) }
                }
                element = nil
            case "way":
                if refs.count >= 2 { ways.append((currentID, refs, tags)) }
                element = nil
            case "relation":
                relations.append((currentID, members, tags))
                element = nil
            default: break
            }
        }
        let parsed = stream.parse(data)
        guard sawOSM, parsed, !(stream.failed && nodes.isEmpty) else { throw GeoError.invalid("This OpenStreetMap file is damaged.") }
        if stream.timedOut || budget.exhausted { document.truncated = true }

        var layers: [Class: GeoLayer] = [:]
        func add(_ geometry: GeoGeometry, tags: [(String, String)], type: String, id: Int64) {
            guard !budget.exhausted else { return }
            let lookup = Dictionary(tags, uniquingKeysWith: { a, _ in a })
            let isArea: Bool
            switch geometry { case .polygon, .multiPolygon: isArea = true; default: isArea = false }
            let cls = classify(lookup, isArea: isArea, isNode: type == "node")
            var feature = GeoFeature(geometry: geometry)
            feature.name = lookup["name"]
            feature.properties.append(("OSM", .string("\(type)/\(id)")))
            feature.properties += tags.map { ($0.0, GeoValue.string($0.1)) }
            feature.style = style(cls, lookup)
            guard budget.admit(geometry) else { return }
            if layers[cls] == nil { layers[cls] = GeoLayer(name: cls.layerName) }
            layers[cls]!.features.append(feature)
        }

        // Multipolygons first, so their member ways aren't drawn twice.
        var usedByAreas = Set<Int64>()
        var wayIndex: [Int64: Int] = [:]
        for (i, way) in ways.enumerated() { wayIndex[way.id] = i }
        for relation in relations {
            let lookup = Dictionary(relation.tags, uniquingKeysWith: { a, _ in a })
            guard ["multipolygon", "boundary"].contains(lookup["type"] ?? "") else { continue }
            var segments: [[GeoPoint]] = []
            var segmentIDs: [[Int64]] = []
            for member in relation.members where member.type == "way" {
                guard let index = wayIndex[member.ref] else { continue }
                segmentIDs.append(ways[index].refs)
                if lookup["type"] == "multipolygon" { usedByAreas.insert(member.ref) }
            }
            let rings = joinRings(segmentIDs)
            for ring in rings {
                let points = ring.compactMap { nodes[$0] }
                if points.count >= 4 { segments.append(points) }
            }
            guard !segments.isEmpty else { continue }
            if lookup["type"] == "boundary" {
                add(.multiLineString(segments), tags: relation.tags, type: "relation", id: relation.id)
            } else if let polygons = ShapefileReader.assemblePolygons(segments) {
                add(polygons, tags: relation.tags, type: "relation", id: relation.id)
            }
        }

        for way in ways {
            if usedByAreas.contains(way.id), way.tags.allSatisfy({ ["area", "type", "name"].contains($0.0) }) || way.tags.isEmpty { continue }
            let points = way.refs.compactMap { nodes[$0] }
            guard points.count >= 2 else { continue }
            let lookup = Dictionary(way.tags, uniquingKeysWith: { a, _ in a })
            let closed = way.refs.first == way.refs.last && points.count >= 4
            if closed, isArea(lookup) {
                add(.polygon([points]), tags: way.tags, type: "way", id: way.id)
            } else if !way.tags.isEmpty {
                add(.lineString(points), tags: way.tags, type: "way", id: way.id)
            }
        }
        for node in taggedNodes {
            let lookup = Dictionary(node.tags, uniquingKeysWith: { a, _ in a })
            // Nodes that only describe a way's vertex (crossings, barriers…) without a name aren't places.
            if lookup["name"] == nil, lookup["amenity"] == nil, lookup["shop"] == nil, lookup["tourism"] == nil,
               lookup["place"] == nil, lookup["natural"] == nil, lookup["historic"] == nil, lookup["leisure"] == nil { continue }
            add(.point(node.point), tags: node.tags, type: "node", id: node.id)
        }

        for (cls, layer) in layers {
            switch cls {
            case .landuse, .green, .water, .building, .other: layer.role = .area
            case .road: layer.role = .road
            case .path: layer.role = .path
            case .railway: layer.role = .rail
            case .poi: layer.role = .place
            case .waterway, .boundary: layer.role = .area
            }
        }
        document.layers = Class.allCases.compactMap { layers[$0] }
        if let bounds, document.bounds.isEmpty { document.facts.append("Empty extract of \(String(format: "%.3f", bounds.width))° × \(String(format: "%.3f", bounds.height))°") }
        document.facts.append("\(nodes.count.formatted()) nodes, \(ways.count.formatted()) ways")
        return document
    }

    static func isArea(_ tags: [String: String]) -> Bool {
        if tags["area"] == "yes" { return true }
        if tags["area"] == "no" { return false }
        for key in ["building", "landuse", "leisure", "amenity", "shop", "tourism", "place", "water", "wetland", "military",
                    "building:part", "historic", "office", "craft", "public_transport", "boundary"] where tags[key] != nil {
            if key == "boundary" { return false }
            return true
        }
        if let natural = tags["natural"] { return !["coastline", "cliff", "ridge", "arete", "tree_row", "valley"].contains(natural) }
        if let waterway = tags["waterway"] { return ["riverbank", "dock", "boatyard"].contains(waterway) }
        if let aeroway = tags["aeroway"] { return !["runway", "taxiway"].contains(aeroway) }
        if let manMade = tags["man_made"] { return !["pipeline", "embankment", "breakwater", "groyne", "pier"].contains(manMade) }
        if let power = tags["power"] { return ["plant", "substation", "generator"].contains(power) }
        return false
    }

    static func classify(_ tags: [String: String], isArea: Bool, isNode: Bool) -> Class {
        if isNode { return .poi }
        if isArea {
            if tags["building"] != nil || tags["building:part"] != nil { return .building }
            if tags["natural"] == "water" || tags["water"] != nil || tags["waterway"] != nil || ["reservoir", "basin"].contains(tags["landuse"] ?? "") { return .water }
            let green: Set<String> = ["park", "garden", "pitch", "playground", "golf_course", "nature_reserve", "dog_park", "grass", "meadow", "forest",
                                      "recreation_ground", "village_green", "cemetery", "allotments", "orchard", "vineyard", "wood", "scrub", "grassland", "heath"]
            if green.contains(tags["leisure"] ?? "") || green.contains(tags["landuse"] ?? "") || green.contains(tags["natural"] ?? "") { return .green }
            if tags["landuse"] != nil || tags["amenity"] != nil || tags["leisure"] != nil { return .landuse }
            return .other
        }
        if tags["waterway"] != nil { return .waterway }
        if tags["railway"] != nil { return .railway }
        if let highway = tags["highway"] {
            return ["footway", "path", "cycleway", "steps", "pedestrian", "track", "bridleway", "corridor"].contains(highway) ? .path : .road
        }
        if tags["boundary"] != nil || tags["admin_level"] != nil { return .boundary }
        return .other
    }

    /// Apple Maps-like colours; the page adapts them for dark mode.
    static func style(_ cls: Class, _ tags: [String: String]) -> GeoStyle {
        var s = GeoStyle()
        switch cls {
        case .building: s.fill = "#e0d9d0"; s.fillOpacity = 1; s.stroke = "#cbbfb2"; s.strokeWidth = 0.6
        case .water: s.fill = "#a6cff2"; s.fillOpacity = 1; s.stroke = "#a6cff2"; s.strokeWidth = 0.5
        case .green: s.fill = "#c8e6b5"; s.fillOpacity = 1; s.stroke = "#b6d9a0"; s.strokeWidth = 0.5
        case .landuse:
            let commercial = ["commercial", "retail", "industrial"].contains(tags["landuse"] ?? "")
            s.fill = commercial ? "#efe4e4" : "#efece6"; s.fillOpacity = 1; s.strokeOpacity = 0
        case .waterway:
            s.stroke = "#86bdf0"
            s.strokeWidth = ["river", "canal"].contains(tags["waterway"] ?? "") ? 4 : 1.6
        case .railway: s.stroke = "#9a9ca3"; s.strokeWidth = 1.6
        case .road:
            switch tags["highway"] ?? "" {
            case "motorway", "motorway_link", "trunk", "trunk_link": s.stroke = "#f7b955"; s.strokeWidth = 6
            case "primary", "primary_link": s.stroke = "#fbd77a"; s.strokeWidth = 5
            case "secondary", "secondary_link", "tertiary", "tertiary_link": s.stroke = "#ffffff"; s.strokeWidth = 4.5
            case "service", "living_street": s.stroke = "#ffffff"; s.strokeWidth = 2
            default: s.stroke = "#ffffff"; s.strokeWidth = 3.2
            }
        case .path: s.stroke = "#c9b9a8"; s.strokeWidth = 1.2
        case .boundary: s.stroke = "#a593b8"; s.strokeWidth = 1.2
        case .other: s.stroke = "#9a9aa0"; s.strokeWidth = 1; s.fill = "#d8d8dc"; s.fillOpacity = 0.5
        case .poi:
            if tags["amenity"] != nil, ["cafe", "restaurant", "bar", "pub", "fast_food", "ice_cream"].contains(tags["amenity"]!) { s.markerColor = "#ff9500" }
            else if tags["shop"] != nil { s.markerColor = "#ffcc00" }
            else if tags["tourism"] != nil || tags["historic"] != nil { s.markerColor = "#af52de" }
            else if tags["leisure"] != nil || tags["natural"] != nil { s.markerColor = "#34c759" }
            else { s.markerColor = "#8e8e93" }
        }
        return s
    }

    /// Joins way node lists end to end into closed rings.
    static func joinRings(_ segments: [[Int64]]) -> [[Int64]] {
        var open = segments.filter { $0.count >= 2 }
        var rings: [[Int64]] = []
        var guardCount = 0
        while !open.isEmpty, guardCount < 100_000 {
            guardCount += 1
            var ring = open.removeFirst()
            var progress = true
            while ring.first != ring.last, progress {
                progress = false
                for (i, segment) in open.enumerated() {
                    if segment.first == ring.last { ring += segment.dropFirst(); open.remove(at: i); progress = true; break }
                    if segment.last == ring.last { ring += segment.reversed().dropFirst(); open.remove(at: i); progress = true; break }
                    if segment.last == ring.first { ring = segment + ring.dropFirst(); open.remove(at: i); progress = true; break }
                    if segment.first == ring.first { ring = segment.reversed() + ring.dropFirst(); open.remove(at: i); progress = true; break }
                }
            }
            if ring.first == ring.last, ring.count >= 4 { rings.append(ring) }
        }
        return rings
    }
}
