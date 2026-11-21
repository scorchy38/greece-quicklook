import Foundation

/// A track's statistics and a decimated profile for the elevation chart.
struct TrackProfile: Encodable {
    var name: String
    var distance: Double = 0
    var duration: Double?
    var movingTime: Double?
    var gain: Double?
    var loss: Double?
    var minElevation: Double?
    var maxElevation: Double?
    var maxSpeed: Double?
    var averageSpeed: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var start: Double?
    var pointCount = 0
    /// [distance m, elevation m or null, seconds from start or null, lon, lat, heart rate or null].
    var samples: [[Double?]] = []

    struct Sample {
        var point: GeoPoint
        var elevation: Double?
        var time: Double?
        var speed: Double?
        var heartRate: Double?
    }

    static func haversine(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6_371_008.8
        let p1 = a.y * .pi / 180, p2 = b.y * .pi / 180
        let dp = p2 - p1, dl = (b.x - a.x) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Computes everything from the samples of one or more segments (gaps between segments
    /// don't count as distance).
    init(name: String, segments: [[Sample]], maxSamples: Int = 1600) {
        self.name = name
        let all = segments.flatMap { $0 }
        pointCount = all.count
        guard !all.isEmpty else { return }

        var cumulative: [Double] = []
        cumulative.reserveCapacity(all.count)
        var total = 0.0
        var moving = 0.0
        var maxSpeed = 0.0
        for segment in segments {
            let base = cumulative.count
            for (i, sample) in segment.enumerated() {
                if i > 0 {
                    let previous = segment[i - 1]
                    let d = TrackProfile.haversine(previous.point, sample.point)
                    if d.isFinite { total += d }
                    if let t0 = previous.time, let t1 = sample.time, t1 > t0 {
                        let dt = t1 - t0
                        if dt < 300, d / dt >= 0.4 { moving += dt }
                    }
                }
                cumulative.append(total)
            }
            // Speed over windows of at least ten seconds smooths GPS jitter.
            var j = 0
            for i in segment.indices {
                guard let ti = segment[i].time else { continue }
                while j < i, let tj = segment[j + 1].time, ti - tj >= 10 { j += 1 }
                if j < i, let tj = segment[j].time, ti - tj >= 10, ti - tj <= 120 {
                    let v = (cumulative[base + i] - cumulative[base + j]) / (ti - tj)
                    if v.isFinite, v < 140 { maxSpeed = max(maxSpeed, v) }
                }
            }
        }
        distance = total

        let recorded = all.compactMap(\.speed).filter { $0.isFinite && $0 >= 0 && $0 < 140 }
        if let top = recorded.max() { maxSpeed = max(maxSpeed, top) }
        let times = all.compactMap(\.time)
        if let first = times.first, let last = times.last, last > first {
            start = first
            duration = last - first
            movingTime = moving > 0 ? moving : nil
            if maxSpeed > 0 { self.maxSpeed = maxSpeed }
            let basis = moving > 0 ? moving : last - first
            if basis > 0 { averageSpeed = total / basis }
        } else if !recorded.isEmpty, maxSpeed > 0 {
            self.maxSpeed = maxSpeed
        }

        // Elevation gain with light smoothing and a 2 m hysteresis, so GPS noise doesn't add up.
        let elevations = all.map(\.elevation)
        let known = elevations.compactMap { $0 }.filter { $0.isFinite && abs($0) < 12_000 }
        if known.count >= 2 {
            minElevation = known.min()
            maxElevation = known.max()
            var smoothed: [Double] = []
            let radius = 2
            for i in known.indices {
                let lo = max(0, i - radius), hi = min(known.count - 1, i + radius)
                smoothed.append(known[lo...hi].reduce(0, +) / Double(hi - lo + 1))
            }
            var up = 0.0, down = 0.0
            var anchor = smoothed[0]
            for value in smoothed.dropFirst() {
                let delta = value - anchor
                if delta >= 2 { up += delta; anchor = value } else if delta <= -2 { down -= delta; anchor = value }
            }
            gain = up
            loss = down
        }
        let rates = all.compactMap(\.heartRate).filter { $0 > 20 && $0 < 260 }
        if !rates.isEmpty {
            averageHeartRate = rates.reduce(0, +) / Double(rates.count)
            maxHeartRate = rates.max()
        }

        // Evenly spaced by distance where possible, always keeping the first and last points.
        let stride = max(1, Int((Double(all.count) / Double(maxSamples)).rounded(.up)))
        var index = 0
        while index < all.count {
            let s = all[index]
            let seconds = (s.time != nil && start != nil) ? s.time! - start! : nil
            samples.append([round(cumulative[index] * 10) / 10, s.elevation.map { round($0 * 10) / 10 }, seconds,
                            s.point.x, s.point.y, s.heartRate])
            if index == all.count - 1 { break }
            index = min(index + stride, all.count - 1)
        }
    }
}

enum GPXReader {

    static func read(_ data: Data, limits: GeoLimits) throws -> MapDocument {
        let document = MapDocument(format: .gpx)
        document.crs = .wgs84
        let waypoints = GeoLayer(name: "Waypoints")
        let routes = GeoLayer(name: "Routes")
        let tracks = GeoLayer(name: "Tracks")
        routes.role = .track
        tracks.role = .track
        var budget = GeoBudget(limits)

        let stream = XMLStream(deadline: limits.deadline)
        var sawGPX = false
        var point: TrackProfile.Sample?
        var pointFields: [(key: String, value: GeoValue)] = []
        var segments: [[TrackProfile.Sample]] = []
        var segment: [TrackProfile.Sample] = []
        var itemFields: [(key: String, value: GeoValue)] = []
        var itemName: String?
        var itemDetail: String?
        var metadataName: String?

        func coordinate(_ attributes: [String: String]) -> GeoPoint? {
            guard let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
                  lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 360 else { return nil }
            return GeoPoint(lon, lat)
        }

        stream.onStart = { [unowned stream] name, attributes in
            switch name {
            case "gpx": sawGPX = true
            case "wpt", "rtept", "trkpt":
                if let p = coordinate(attributes) { point = .init(point: p) } else { point = nil }
                pointFields = []
                if name == "wpt" { itemName = nil; itemDetail = nil }
            case "trk", "rte":
                segments = []
                segment = []
                itemFields = []
                itemName = nil
                itemDetail = nil
            case "trkseg":
                segment = []
            default: break
            }
        }

        stream.onEnd = { [unowned stream] name, text in
            let inPoint = point != nil && (stream.within("wpt") || stream.within("rtept") || stream.within("trkpt"))
            switch name {
            case "ele":
                if inPoint, let v = Double(text) { point?.elevation = v; pointFields.append(("ele", .number(v))) }
            case "time":
                if inPoint {
                    point?.time = ISOTime.parse(text)
                    pointFields.append(("time", .string(text)))
                }
            case "speed":
                if inPoint, let v = Double(text) { point?.speed = v }
            case "hr":
                if inPoint, let v = Double(text) { point?.heartRate = v }
            case "name":
                if stream.parent == "metadata" || (stream.parent == "gpx") { metadataName = metadataName ?? text }
                else if stream.parent == "wpt" { itemName = text }
                else if stream.parent == "trk" || stream.parent == "rte" { itemName = text }
            case "desc", "cmt":
                if stream.parent == "wpt" || stream.parent == "trk" || stream.parent == "rte" {
                    if itemDetail == nil { itemDetail = text } else if !text.isEmpty { itemFields.append((name == "desc" ? "Description" : "Comment", .string(text))) }
                }
            case "sym", "type", "src", "number":
                if stream.parent == "wpt" { pointFields.append((name, .string(text))) }
                else if stream.parent == "trk" || stream.parent == "rte" { itemFields.append((name, .string(text))) }
            case "wpt":
                if let p = point, !budget.exhausted {
                    var f = GeoFeature(geometry: .point(p.point))
                    f.name = itemName
                    f.detail = itemDetail
                    if let itemName { f.properties.append(("name", .string(itemName))) }
                    f.properties += pointFields
                    if budget.admit(f.geometry) { waypoints.features.append(f) }
                }
                point = nil
                itemName = nil
                itemDetail = nil
            case "rtept":
                if let p = point { segment.append(p) }
                point = nil
            case "trkpt":
                if let p = point, !budget.exhausted {
                    segment.append(p)
                    budget.addPoints(1)
                }
                point = nil
            case "trkseg":
                if !segment.isEmpty { segments.append(segment) }
                segment = []
            case "trk", "rte":
                if name == "rte", !segment.isEmpty { segments.append(segment) }
                let lines = segments.map { $0.map(\.point) }.filter { $0.count >= 1 }
                let label = itemName ?? (name == "trk" ? "Track \(tracks.features.count + 1)" : "Route \(routes.features.count + 1)")
                if !lines.isEmpty {
                    var f = GeoFeature(geometry: lines.count == 1 ? .lineString(lines[0]) : .multiLineString(lines))
                    f.name = label
                    f.detail = itemDetail
                    f.properties.append(("name", .string(label)))
                    f.properties += itemFields
                    let profile = TrackProfile(name: label, segments: segments)
                    f.properties.append(("Points", .number(Double(profile.pointCount))))
                    if budget.admit(nil) {
                        (name == "trk" ? tracks : routes).features.append(f)
                        if profile.pointCount >= 2 { document.tracks.append(profile) }
                    }
                }
                segments = []
                segment = []
                itemName = nil
                itemDetail = nil
            default: break
            }
        }
        let parsed = stream.parse(data)
        let empty = tracks.features.isEmpty && routes.features.isEmpty && waypoints.features.isEmpty
        guard sawGPX, parsed, !(stream.failed && empty) else { throw GeoError.invalid("This GPX file is damaged.") }
        if stream.timedOut || budget.exhausted { document.truncated = true }
        document.title = metadataName
        document.layers = [tracks, routes, waypoints].filter { !$0.features.isEmpty }
        let count = waypoints.features.count
        if count > 0 { document.facts.append("\(count.formatted()) \(count == 1 ? "waypoint" : "waypoints")") }
        return document
    }
}
