import Foundation

/// Well-known text geometries: one or many per file, EWKT `SRID=n;` prefixes, Z/M ordinates.
enum WKTReader {

    struct Result {
        var geometries: [GeoGeometry] = []
        var srid: Int?
        var skipped = 0
        var truncated = false
    }

    static func read(_ text: String, limits: GeoLimits) -> Result {
        var parser = Parser(Array(text.utf8.prefix(limits.maxBytes)))
        var result = Result()
        var budget = GeoBudget(limits)
        while !parser.atEnd {
            let start = parser.pos
            if let srid = parser.srid() { result.srid = result.srid ?? srid }
            if let geometry = parser.geometry(depth: 0) {
                if budget.admit(geometry) { result.geometries.append(geometry) }
                if budget.exhausted { result.truncated = true; break }
            } else {
                // Not a geometry here: skip to the next line.
                parser.pos = max(parser.pos, start + 1)
                parser.skipLine()
                result.skipped += 1
                if result.skipped > 10_000 { break }
            }
        }
        return result
    }

    static func geometry(_ text: String) -> GeoGeometry? {
        var parser = Parser(Array(text.utf8.prefix(16 * 1024 * 1024)))
        _ = parser.srid()
        return parser.geometry(depth: 0)
    }

    struct Parser {
        let b: [UInt8]
        var pos = 0

        init(_ bytes: [UInt8]) { b = bytes }

        var atEnd: Bool {
            mutating get {
                skipSeparators()
                return pos >= b.count
            }
        }

        mutating func skipSpace() {
            while pos < b.count, b[pos] == 0x20 || b[pos] == 0x09 || b[pos] == 0x0A || b[pos] == 0x0D { pos += 1 }
        }

        mutating func skipSeparators() {
            while pos < b.count, b[pos] == 0x20 || b[pos] == 0x09 || b[pos] == 0x0A || b[pos] == 0x0D || b[pos] == 0x3B || b[pos] == 0x2C { pos += 1 }
        }

        mutating func skipLine() {
            while pos < b.count, b[pos] != 0x0A { pos += 1 }
        }

        mutating func word() -> String {
            skipSpace()
            let start = pos
            while pos < b.count, (b[pos] >= 0x41 && b[pos] <= 0x5A) || (b[pos] >= 0x61 && b[pos] <= 0x7A) || b[pos] == 0x5F { pos += 1 }
            return String(decoding: b[start..<pos], as: UTF8.self).uppercased()
        }

        mutating func peekIs(_ c: UInt8) -> Bool {
            skipSpace()
            return pos < b.count && b[pos] == c
        }

        mutating func consume(_ c: UInt8) -> Bool {
            if peekIs(c) { pos += 1; return true }
            return false
        }

        /// "SRID=4326;"
        mutating func srid() -> Int? {
            skipSeparators()
            let save = pos
            guard word() == "SRID", consume(0x3D) else { pos = save; return nil }
            let start = pos
            while pos < b.count, b[pos] >= 0x30, b[pos] <= 0x39 { pos += 1 }
            let value = Int(String(decoding: b[start..<pos], as: UTF8.self))
            _ = consume(0x3B)
            return value
        }

        mutating func number() -> Double? {
            skipSpace()
            let start = pos
            while pos < b.count, (b[pos] >= 0x30 && b[pos] <= 0x39) || b[pos] == 0x2E || b[pos] == 0x2D || b[pos] == 0x2B || b[pos] == 0x65 || b[pos] == 0x45 { pos += 1 }
            guard pos > start else { return nil }
            return Double(String(decoding: b[start..<pos], as: UTF8.self))
        }

        /// "x y [z [m]]"
        mutating func point() -> GeoPoint? {
            guard let x = number(), let y = number() else { return nil }
            while number() != nil {}
            return GeoPoint(x, y)
        }

        /// "(x y, x y …)"; points may also be wrapped in their own parentheses (MULTIPOINT).
        mutating func points() -> [GeoPoint]? {
            guard consume(0x28) else { return nil }
            var result: [GeoPoint] = []
            repeat {
                if consume(0x28) {
                    guard let p = point(), consume(0x29) else { return nil }
                    result.append(p)
                } else if word() == "EMPTY" {
                    continue
                } else {
                    guard let p = point() else { return nil }
                    result.append(p)
                }
            } while consume(0x2C)
            return consume(0x29) ? result : nil
        }

        mutating func lists() -> [[GeoPoint]]? {
            guard consume(0x28) else { return nil }
            var result: [[GeoPoint]] = []
            repeat {
                let save = pos
                if word() == "EMPTY" { continue }
                pos = save
                guard let list = points() else { return nil }
                result.append(list)
            } while consume(0x2C)
            return consume(0x29) ? result : nil
        }

        mutating func polygons() -> [[[GeoPoint]]]? {
            guard consume(0x28) else { return nil }
            var result: [[[GeoPoint]]] = []
            repeat {
                let save = pos
                if word() == "EMPTY" { continue }
                pos = save
                guard let rings = lists() else { return nil }
                result.append(rings)
            } while consume(0x2C)
            return consume(0x29) ? result : nil
        }

        mutating func geometry(depth: Int) -> GeoGeometry? {
            guard depth < 16 else { return nil }
            skipSeparators()
            var type = word()
            for suffix in ["ZM", "Z", "M"] where type.hasSuffix(suffix) && type.count > suffix.count + 4 {
                type = String(type.dropLast(suffix.count))
                break
            }
            guard !type.isEmpty else { return nil }
            // Optional dimension word: "POINT Z (…)".
            let save = pos
            let dimension = word()
            if !["Z", "M", "ZM"].contains(dimension) { pos = save }
            let saveEmpty = pos
            if word() == "EMPTY" {
                switch type {
                case "POINT", "MULTIPOINT": return .multiPoint([])
                case "LINESTRING", "MULTILINESTRING", "CIRCULARSTRING": return .lineString([])
                case "POLYGON", "MULTIPOLYGON", "TRIANGLE": return .polygon([])
                default: return .collection([])
                }
            }
            pos = saveEmpty
            switch type {
            case "POINT":
                guard consume(0x28), let p = point(), consume(0x29) else { return nil }
                return .point(p)
            case "MULTIPOINT": return points().map(GeoGeometry.multiPoint)
            case "LINESTRING", "CIRCULARSTRING", "LINEARRING": return points().map(GeoGeometry.lineString)
            case "MULTILINESTRING": return lists().map(GeoGeometry.multiLineString)
            case "POLYGON", "TRIANGLE": return lists().map(GeoGeometry.polygon)
            case "MULTIPOLYGON", "POLYHEDRALSURFACE", "TIN": return polygons().map(GeoGeometry.multiPolygon)
            case "GEOMETRYCOLLECTION":
                guard consume(0x28) else { return nil }
                var parts: [GeoGeometry] = []
                repeat {
                    guard let g = geometry(depth: depth + 1) else { return nil }
                    parts.append(g)
                } while consume(0x2C)
                return consume(0x29) ? .collection(parts) : nil
            default:
                return nil
            }
        }
    }
}

/// Well-known binary (ISO, OGC and EWKB flavours), as stored in GeoPackages.
enum WKBReader {
    static func geometry(_ data: Data) -> GeoGeometry? {
        var reader = Reader(data: data)
        return reader.geometry(depth: 0)
    }

    /// A GeoPackage geometry blob: "GP" header (with optional envelope) then WKB. Also accepts bare WKB.
    static func geoPackage(_ data: Data) -> (geometry: GeoGeometry?, srs: Int32?)? {
        guard data.count >= 8 else { return nil }
        let s = data.startIndex
        if data[s] == 0x47, data[s + 1] == 0x50 {
            let flags = data[s + 3]
            let little = flags & 1 == 1
            let envelope = Int((flags >> 1) & 0x07)
            let sizes = [0, 32, 48, 48, 64]
            guard envelope < sizes.count else { return nil }
            let raw = data.u32(4)
            let srs = Int32(bitPattern: little ? raw : raw.byteSwapped)
            if flags & 0x10 != 0 { return (nil, srs) }
            let start = 8 + sizes[envelope]
            guard start < data.count else { return (nil, srs) }
            return (geometry(data.subdata(in: (s + start)..<data.endIndex)), srs)
        }
        return (geometry(data), nil)
    }

    struct Reader {
        let data: Data
        var pos = 0

        mutating func u8() -> UInt8? {
            guard pos < data.count else { return nil }
            defer { pos += 1 }
            return data[data.startIndex + pos]
        }

        mutating func u32(_ little: Bool) -> UInt32? {
            guard pos + 4 <= data.count else { return nil }
            defer { pos += 4 }
            let v = data.u32(pos)
            return little ? v : v.byteSwapped
        }

        mutating func f64(_ little: Bool) -> Double? {
            guard pos + 8 <= data.count else { return nil }
            defer { pos += 8 }
            let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt64.self) }
            return Double(bitPattern: little ? UInt64(littleEndian: raw) : UInt64(bigEndian: raw))
        }

        mutating func points(_ little: Bool, dims: Int) -> [GeoPoint]? {
            guard let count = u32(little), Int(count) <= (data.count - pos) / (8 * dims) else { return nil }
            var result: [GeoPoint] = []
            result.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                guard let x = f64(little), let y = f64(little) else { return nil }
                pos += 8 * (dims - 2)
                if x.isFinite, y.isFinite { result.append(GeoPoint(x, y)) }
            }
            return result
        }

        mutating func geometry(depth: Int) -> GeoGeometry? {
            guard depth < 8, let order = u8(), order <= 1 else { return nil }
            let little = order == 1
            guard var type = u32(little) else { return nil }
            var dims = 2
            // EWKB flags.
            if type & 0x8000_0000 != 0 { dims += 1 }
            if type & 0x4000_0000 != 0 { dims += 1 }
            if type & 0x2000_0000 != 0 { pos += 4 }
            type &= 0x0FFF_FFFF
            // ISO: thousands encode Z, M, ZM.
            switch type / 1000 {
            case 1, 2: dims = max(dims, 3)
            case 3: dims = max(dims, 4)
            default: break
            }
            let base = type % 1000
            switch base {
            case 1:
                guard let x = f64(little), let y = f64(little) else { return nil }
                pos += 8 * (dims - 2)
                // NaN coordinates mean an empty point.
                return x.isFinite && y.isFinite ? .point(GeoPoint(x, y)) : .multiPoint([])
            case 2, 8:
                return points(little, dims: dims).map(GeoGeometry.lineString)
            case 3, 17:
                guard let count = u32(little), count <= 1_000_000 else { return nil }
                var rings: [[GeoPoint]] = []
                for _ in 0..<count { guard let ring = points(little, dims: dims) else { return nil }; rings.append(ring) }
                return .polygon(rings)
            case 4, 5, 6, 7, 9, 10, 11, 12, 15, 16:
                guard let count = u32(little), Int(count) <= data.count - pos else { return nil }
                var parts: [GeoGeometry] = []
                for _ in 0..<count {
                    guard let g = geometry(depth: depth + 1) else { return nil }
                    parts.append(g)
                }
                switch base {
                case 4: return .multiPoint(parts.compactMap { if case .point(let p) = $0 { return p }; return nil })
                case 5, 9, 11:
                    return .multiLineString(parts.flatMap { g -> [[GeoPoint]] in
                        switch g {
                        case .lineString(let l): return [l]
                        case .multiLineString(let m): return m
                        default: return []
                        }
                    })
                case 6, 12, 15, 16, 10:
                    let polygons = parts.compactMap { g -> [[GeoPoint]]? in
                        switch g {
                        case .polygon(let r): return r
                        case .lineString(let l): return [l]
                        case .multiLineString(let m): return m
                        default: return nil
                        }
                    }
                    return base == 10 ? .polygon(polygons.flatMap { $0 }) : .multiPolygon(polygons)
                default: return .collection(parts)
                }
            default:
                return nil
            }
        }
    }
}
