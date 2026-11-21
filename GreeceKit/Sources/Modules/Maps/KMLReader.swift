import Foundation

/// KML 2.2 (and Google's gx: extensions): placemarks with their shared and inline styles,
/// folders as layers, tracks, and ground overlays. Network links are never followed.
enum KMLReader {

    struct Style {
        var lineColor: (String, Double)?
        var lineWidth: Double?
        var polyColor: (String, Double)?
        var fill = true
        var outline = true
        var iconColor: (String, Double)?
        var iconScale: Double?
        var iconHref: String?

        mutating func merge(_ other: Style) {
            if let v = other.lineColor { lineColor = v }
            if let v = other.lineWidth { lineWidth = v }
            if let v = other.polyColor { polyColor = v }
            if !other.fill { fill = false }
            if !other.outline { outline = false }
            if let v = other.iconColor { iconColor = v }
            if let v = other.iconScale { iconScale = v }
            if let v = other.iconHref { iconHref = v }
        }
    }

    /// KML colours are aabbggrr.
    static func color(_ text: String) -> (String, Double)? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 8, hex.allSatisfy(\.isHexDigit) else {
            if hex.count == 6, hex.allSatisfy(\.isHexDigit) {
                let c = Array(hex)
                return ("#" + String([c[4], c[5], c[2], c[3], c[0], c[1]]).lowercased(), 1)
            }
            return nil
        }
        let c = Array(hex)
        let alpha = Double(Int(String(c[0...1]), radix: 16) ?? 255) / 255
        return ("#" + String([c[6], c[7], c[4], c[5], c[2], c[3]]).lowercased(), alpha)
    }

    /// "lon,lat[,alt] lon,lat[,alt] …", tolerant of stray spaces after commas.
    static func coordinates(_ text: String) -> (points: [GeoPoint], altitudes: [Double?]) {
        var points: [GeoPoint] = []
        var altitudes: [Double?] = []
        let normalized = text.replacingOccurrences(of: ", ", with: ",").replacingOccurrences(of: " ,", with: ",")
        for tuple in normalized.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
            let parts = tuple.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]), lon.isFinite, lat.isFinite else { continue }
            points.append(GeoPoint(lon, lat))
            altitudes.append(parts.count >= 3 ? Double(parts[2]) : nil)
        }
        return (points, altitudes)
    }

    /// Google's standard icons by name, so remote icons still get their colour.
    static func iconColor(forHref href: String) -> String? {
        let name = (href as NSString).lastPathComponent.lowercased()
        let table: [(String, String)] = [("ltblu", "#5ac8fa"), ("red", "#ff3b30"), ("ylw", "#ffcc00"), ("yellow", "#ffcc00"),
                                         ("grn", "#34c759"), ("green", "#34c759"), ("blu", "#007aff"), ("blue", "#007aff"),
                                         ("purple", "#af52de"), ("pink", "#ff2d55"), ("orange", "#ff9500"), ("wht", "#ffffff"),
                                         ("white", "#ffffff")]
        return table.first { name.contains($0.0) }?.1
    }

    /// - Parameters:
    ///   - resolveIcon: turns an icon href into an index in `document.icons`, or nil for remote icons.
    static func read(_ data: Data, format: MapFormat, limits: GeoLimits, resolveIcon: (String) -> Int?) throws -> MapDocument {
        let document = MapDocument(format: format)
        document.crs = .wgs84
        var budget = GeoBudget(limits)
        let stream = XMLStream(deadline: limits.deadline, maxText: limits.maxStringLength * 8)

        var sawKML = false
        var styles: [String: Style] = [:]
        var styleMaps: [String: String] = [:]
        var currentStyleID: String?
        var currentStyle: Style?
        var styleMapID: String?
        var pairKey: String?
        var pairURL: String?

        var folderNames: [String] = []
        var folderDepth = 0
        var documentName: String?

        struct Pending {
            var name: String?
            var detail: String?
            var styleURL: String?
            var inline: Style?
            var data: [(key: String, value: GeoValue)] = []
            var frames: [[GeoGeometry]] = [[]]
            var rings: [[GeoPoint]] = []
            var outer: [GeoPoint]?
            var trackPoints: [GeoPoint] = []
            var trackTimes: [Double?] = []
            var trackAltitudes: [Double?] = []
            var dataName: String?
            var folder: String?
        }
        var placemark: Pending?
        var pendingPlacemarks: [Pending] = []
        var profiles: [(name: String, samples: [TrackProfile.Sample])] = []

        var overlay: (name: String?, href: String?, north: Double?, south: Double?, east: Double?, west: Double?, rotation: Double, quad: [GeoPoint])?
        var networkLinks = 0

        stream.onStart = { [unowned stream] name, attributes in
            switch name {
            case "kml": sawKML = true
            case "Folder":
                folderDepth += 1
                folderNames.append("")
            case "Style":
                currentStyleID = attributes["id"]
                currentStyle = Style()
            case "StyleMap":
                styleMapID = attributes["id"]
            case "Pair":
                pairKey = nil
                pairURL = nil
            case "Placemark":
                if !budget.exhausted {
                    var p = Pending()
                    p.folder = folderNames.first.flatMap { $0.isEmpty ? nil : $0 }
                    placemark = p
                }
            case "MultiGeometry", "MultiTrack":
                placemark?.frames.append([])
            case "Polygon":
                placemark?.rings = []
                placemark?.outer = nil
            case "Track":
                placemark?.trackPoints = []
                placemark?.trackTimes = []
                placemark?.trackAltitudes = []
            case "Data":
                placemark?.dataName = attributes["name"]
            case "SimpleData":
                if let key = attributes["name"] { placemark?.dataName = key }
            case "GroundOverlay":
                overlay = (nil, nil, nil, nil, nil, nil, 0, [])
            case "NetworkLink":
                networkLinks += 1
            default: break
            }
        }

        func addGeometry(_ geometry: GeoGeometry) {
            guard placemark != nil else { return }
            placemark!.frames[placemark!.frames.count - 1].append(geometry)
        }

        stream.onEnd = { [unowned stream] name, text in
            // Styles.
            if currentStyle != nil {
                switch name {
                case "color":
                    if let c = color(text) {
                        switch stream.parent {
                        case "LineStyle": currentStyle?.lineColor = c
                        case "PolyStyle": currentStyle?.polyColor = c
                        case "IconStyle": currentStyle?.iconColor = c
                        default: break
                        }
                    }
                case "width": if stream.parent == "LineStyle", let w = Double(text) { currentStyle?.lineWidth = w }
                case "fill": if stream.parent == "PolyStyle" { currentStyle?.fill = text != "0" }
                case "outline": if stream.parent == "PolyStyle" { currentStyle?.outline = text != "0" }
                case "scale": if stream.parent == "IconStyle", let s = Double(text) { currentStyle?.iconScale = s }
                case "href": if stream.within("IconStyle") { currentStyle?.iconHref = text }
                case "Style":
                    if let style = currentStyle {
                        if placemark != nil, stream.parent == "Placemark" {
                            placemark?.inline = style
                        } else if let id = currentStyleID {
                            styles[id] = style
                            // A style inline in a StyleMap pair.
                            if pairKey == nil || pairKey == "normal", stream.parent == "Pair" { pairURL = "#" + id }
                        } else if stream.parent == "Pair" {
                            let id = "__pair\(styles.count)"
                            styles[id] = style
                            pairURL = "#" + id
                        }
                    }
                    currentStyle = nil
                    currentStyleID = nil
                default: break
                }
                return
            }
            switch name {
            case "key": if stream.parent == "Pair" { pairKey = text }
            case "styleUrl":
                if stream.parent == "Pair" { pairURL = text }
                else if stream.parent == "Placemark" { placemark?.styleURL = text }
            case "Pair":
                if pairKey == "normal", let id = styleMapID, let url = pairURL { styleMaps[id] = url }
            case "StyleMap": styleMapID = nil
            case "name":
                switch stream.parent {
                case "Placemark": placemark?.name = text
                case "Folder": if folderDepth >= 1, !folderNames.isEmpty, folderNames[folderNames.count - 1].isEmpty { folderNames[folderNames.count - 1] = text }
                case "Document": if documentName == nil { documentName = text }
                case "GroundOverlay": overlay?.name = text
                default: break
                }
            case "description":
                if stream.parent == "Placemark" { placemark?.detail = text }
            case "value":
                if stream.parent == "Data", let key = placemark?.dataName {
                    placemark?.data.append((key, Double(text).map(GeoValue.number) ?? .string(text)))
                }
            case "SimpleData":
                if let key = placemark?.dataName {
                    placemark?.data.append((key, Double(text).map(GeoValue.number) ?? .string(text)))
                }
            case "coordinates":
                if placemark != nil {
                    let parsed = coordinates(text)
                    budget.addPoints(parsed.points.count)
                    switch stream.parent {
                    case "Point": if let p = parsed.points.first { addGeometry(.point(p)) }
                    case "LineString": addGeometry(.lineString(parsed.points))
                    case "LinearRing":
                        if stream.within("outerBoundaryIs") { placemark?.outer = parsed.points }
                        else if stream.within("innerBoundaryIs") { placemark?.rings.append(parsed.points) }
                        else { addGeometry(.polygon([parsed.points])) }
                    default: break
                    }
                } else if overlay != nil, stream.parent == "LatLonQuad" {
                    overlay?.quad = coordinates(text).points
                }
            case "Polygon":
                if let outer = placemark?.outer { addGeometry(.polygon([outer] + (placemark?.rings ?? []))) }
                placemark?.outer = nil
                placemark?.rings = []
            case "when":
                if stream.parent == "Track" { placemark?.trackTimes.append(ISOTime.parse(text)) }
            case "coord":
                if stream.parent == "Track" {
                    let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    if parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]) {
                        placemark?.trackPoints.append(GeoPoint(lon, lat))
                        placemark?.trackAltitudes.append(parts.count >= 3 ? Double(parts[2]) : nil)
                        budget.addPoints(1)
                    }
                }
            case "Track":
                if let p = placemark, p.trackPoints.count >= 2 {
                    addGeometry(.lineString(p.trackPoints))
                    var samples: [TrackProfile.Sample] = []
                    for (i, point) in p.trackPoints.enumerated() {
                        samples.append(.init(point: point,
                                             elevation: i < p.trackAltitudes.count ? p.trackAltitudes[i] : nil,
                                             time: i < p.trackTimes.count ? p.trackTimes[i] : nil))
                    }
                    profiles.append((p.name ?? "Track", samples))
                }
            case "MultiGeometry", "MultiTrack":
                if var p = placemark, p.frames.count > 1 {
                    let parts = p.frames.removeLast()
                    p.frames[p.frames.count - 1].append(simplify(parts))
                    placemark = p
                }
            case "Location":
                // A 3D model's position.
                break
            case "longitude", "latitude":
                if stream.parent == "Location", let v = Double(text) {
                    placemark?.data.append((name, .number(v)))
                }
            case "Model":
                if let p = placemark,
                   let lon = p.data.first(where: { $0.key == "longitude" })?.value, let lat = p.data.first(where: { $0.key == "latitude" })?.value,
                   case .number(let x) = lon, case .number(let y) = lat {
                    addGeometry(.point(GeoPoint(x, y)))
                }
            case "Placemark":
                if let p = placemark {
                    pendingPlacemarks.append(p)
                    let geometry = p.frames.first.map(simplify)
                    if !budget.admit(geometry) { stream.stop() }
                }
                placemark = nil
            case "Folder":
                folderDepth -= 1
                if !folderNames.isEmpty { folderNames.removeLast() }
            case "href":
                if overlay != nil, stream.within("Icon"), !stream.within("IconStyle") { overlay?.href = text }
            case "north": overlay?.north = Double(text)
            case "south": overlay?.south = Double(text)
            case "east": overlay?.east = Double(text)
            case "west": overlay?.west = Double(text)
            case "rotation": if stream.parent == "LatLonBox", let r = Double(text) { overlay?.rotation = r }
            case "GroundOverlay":
                if let o = overlay, let href = o.href, !href.isEmpty, document.overlays.count < 32 {
                    var north = o.north, south = o.south, east = o.east, west = o.west
                    if o.quad.count == 4 {
                        west = o.quad.map(\.x).min(); east = o.quad.map(\.x).max()
                        south = o.quad.map(\.y).min(); north = o.quad.map(\.y).max()
                    }
                    if let n = north, let s = south, let e = east, let w = west, n > s, abs(n) <= 90, abs(s) <= 90, abs(e) <= 540, abs(w) <= 540 {
                        document.overlays.append(GroundOverlay(name: o.name, source: href, north: n, south: s, east: e, west: w, rotation: o.rotation))
                    }
                }
                overlay = nil
            default: break
            }
        }

        let parsed = stream.parse(data)
        guard sawKML || !pendingPlacemarks.isEmpty, parsed else { throw GeoError.invalid("This KML file is damaged.") }
        if stream.timedOut || budget.exhausted { document.truncated = true }

        // Resolve styles now that every shared style has been read.
        func resolve(_ url: String?, depth: Int = 0) -> Style? {
            guard let url, depth < 4, let hash = url.firstIndex(of: "#") else { return nil }
            let id = String(url[url.index(after: hash)...])
            if let style = styles[id] { return style }
            if let mapped = styleMaps[id] { return resolve(mapped, depth: depth + 1) }
            return nil
        }
        var iconIndex: [String: Int?] = [:]
        var layersByName: [String: GeoLayer] = [:]
        var order: [GeoLayer] = []
        let defaultName = documentName.flatMap { $0.isEmpty ? nil : $0 } ?? "Placemarks"
        for p in pendingPlacemarks {
            let geometry = p.frames.first.map(simplify)
            var feature = GeoFeature(geometry: geometry)
            feature.name = p.name
            feature.detail = p.detail
            if let name = p.name { feature.properties.append(("name", .string(name))) }
            feature.properties += p.data.prefix(limits.maxProperties)
            var style = resolve(p.styleURL) ?? Style()
            if let inline = p.inline { style.merge(inline) }
            var geo = GeoStyle()
            let family = geometry?.family
            if let (c, a) = style.lineColor { geo.stroke = c; geo.strokeOpacity = a }
            if let w = style.lineWidth { geo.strokeWidth = GeoStyle.clamp(w, 0.5, 12) }
            if let (c, a) = style.polyColor {
                geo.fill = c
                geo.fillOpacity = style.fill ? min(a, 0.85) : 0
            } else if !style.fill {
                geo.fillOpacity = 0
            }
            if !style.outline, family == .polygon { geo.strokeOpacity = 0 }
            if let href = style.iconHref {
                if iconIndex[href] == nil { iconIndex[href] = resolveIcon(href) }
                if let index = iconIndex[href] ?? nil { geo.icon = index }
                if let (c, _) = style.iconColor, c != "#ffffff" { geo.markerColor = c } else { geo.markerColor = iconColor(forHref: href) }
            } else if let (c, _) = style.iconColor, c != "#ffffff" {
                geo.markerColor = c
            }
            if let s = style.iconScale { geo.iconScale = GeoStyle.clamp(s, 0.2, 4) }
            if !geo.isEmpty { feature.style = geo }
            let layerName = p.folder ?? defaultName
            if layersByName[layerName] == nil {
                let layer = GeoLayer(name: layerName)
                layersByName[layerName] = layer
                order.append(layer)
            }
            layersByName[layerName]!.features.append(feature)
        }
        document.layers = order
        document.title = documentName
        for (name, samples) in profiles where samples.count >= 2 {
            document.tracks.append(TrackProfile(name: name, segments: [samples]))
        }
        if networkLinks > 0 {
            document.notices.append("\(networkLinks) network \(networkLinks == 1 ? "link isn’t" : "links aren’t") loaded: previews never go online.")
        }
        return document
    }

    /// A MultiGeometry of one kind becomes the matching multi-geometry.
    static func simplify(_ parts: [GeoGeometry]) -> GeoGeometry {
        if parts.count == 1 { return parts[0] }
        if parts.allSatisfy({ if case .point = $0 { return true }; return false }) {
            return .multiPoint(parts.compactMap { if case .point(let p) = $0 { return p }; return nil })
        }
        if parts.allSatisfy({ if case .lineString = $0 { return true }; return false }) {
            return .multiLineString(parts.compactMap { if case .lineString(let l) = $0 { return l }; return nil })
        }
        if parts.allSatisfy({ if case .polygon = $0 { return true }; return false }) {
            return .multiPolygon(parts.compactMap { if case .polygon(let r) = $0 { return r }; return nil })
        }
        return .collection(parts)
    }
}
