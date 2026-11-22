import Foundation

/// A small JSON reader for geodata. Coordinates go straight into `GeoPoint`s, so a 100 MB GeoJSON
/// never becomes millions of Foundation objects. Every recursion has a depth limit.
struct JSONCursor {
    enum Failure: Error { case syntax(Int), depth }

    private let bytes: UnsafeBufferPointer<UInt8>
    private(set) var pos = 0
    let maxDepth: Int
    let maxString: Int

    init(_ bytes: UnsafeBufferPointer<UInt8>, maxDepth: Int = 64, maxString: Int = 32 * 1024) {
        self.bytes = bytes
        self.maxDepth = maxDepth
        self.maxString = maxString
        // UTF-8 byte order mark.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { pos = 3 }
    }

    var atEnd: Bool { mutating get { skipWhitespace(); return pos >= bytes.count } }

    mutating func skipWhitespace() {
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x1E { pos += 1 } else { break }
        }
    }

    mutating func peek() -> UInt8? {
        skipWhitespace()
        return pos < bytes.count ? bytes[pos] : nil
    }

    mutating func expect(_ c: UInt8) throws {
        skipWhitespace()
        guard pos < bytes.count, bytes[pos] == c else { throw Failure.syntax(pos) }
        pos += 1
    }

    // MARK: Containers

    /// Consumes `{`.
    mutating func beginObject() throws { try expect(UInt8(ascii: "{")) }

    /// The next key of an object (consuming the colon), or nil at its closing brace.
    mutating func nextKey(_ first: inout Bool) throws -> String? {
        skipWhitespace()
        guard pos < bytes.count else { throw Failure.syntax(pos) }
        if bytes[pos] == UInt8(ascii: "}") { pos += 1; return nil }
        if !first {
            try expect(UInt8(ascii: ","))
            skipWhitespace()
            // Tolerate a trailing comma.
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return nil }
        }
        first = false
        let key = try string()
        try expect(UInt8(ascii: ":"))
        return key
    }

    mutating func beginArray() throws { try expect(UInt8(ascii: "[")) }

    /// True if another element follows (after consuming its comma), false at the closing bracket.
    mutating func nextElement(_ first: inout Bool) throws -> Bool {
        skipWhitespace()
        guard pos < bytes.count else { throw Failure.syntax(pos) }
        if bytes[pos] == UInt8(ascii: "]") { pos += 1; return false }
        if !first {
            try expect(UInt8(ascii: ","))
            skipWhitespace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return false }
        }
        first = false
        return true
    }

    mutating func isNull() -> Bool {
        skipWhitespace()
        if pos + 4 <= bytes.count, bytes[pos] == UInt8(ascii: "n"), bytes[pos + 1] == UInt8(ascii: "u"),
           bytes[pos + 2] == UInt8(ascii: "l"), bytes[pos + 3] == UInt8(ascii: "l") {
            pos += 4
            return true
        }
        return false
    }

    // MARK: Scalars

    mutating func string() throws -> String {
        skipWhitespace()
        guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw Failure.syntax(pos) }
        pos += 1
        let start = pos
        // Fast path: no escapes.
        while pos < bytes.count {
            let c = bytes[pos]
            if c == UInt8(ascii: "\"") {
                let length = min(pos - start, maxString)
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<(start + length)]), as: UTF8.self)
                pos += 1
                return text
            }
            if c == UInt8(ascii: "\\") { break }
            pos += 1
        }
        pos = start
        var out: [UInt8] = []
        out.reserveCapacity(64)
        while pos < bytes.count {
            let c = bytes[pos]
            pos += 1
            if c == UInt8(ascii: "\"") {
                return String(decoding: out.prefix(maxString), as: UTF8.self)
            }
            if c != UInt8(ascii: "\\") {
                if out.count < maxString + 4 { out.append(c) }
                continue
            }
            guard pos < bytes.count else { break }
            let e = bytes[pos]
            pos += 1
            var scalar: UInt32?
            switch e {
            case UInt8(ascii: "n"): scalar = 0x0A
            case UInt8(ascii: "t"): scalar = 0x09
            case UInt8(ascii: "r"): scalar = 0x0D
            case UInt8(ascii: "b"): scalar = 0x08
            case UInt8(ascii: "f"): scalar = 0x0C
            case UInt8(ascii: "u"):
                guard var value = hex4() else { throw Failure.syntax(pos) }
                if value >= 0xD800, value < 0xDC00, pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                    pos += 2
                    if let low = hex4(), low >= 0xDC00, low < 0xE000 {
                        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        value = 0xFFFD
                    }
                }
                scalar = value
            default: scalar = UInt32(e)
            }
            if out.count < maxString + 4, let scalar {
                let s = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(s)).utf8))
            }
        }
        throw Failure.syntax(pos)
    }

    /// A string, or nil (skipping the value) if it's anything else.
    mutating func stringOrSkip() throws -> String? {
        if peek() == UInt8(ascii: "\"") { return try string() }
        try skipValue()
        return nil
    }

    private mutating func hex4() -> UInt32? {
        guard pos + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 {
            let c = bytes[pos + i]
            let digit: UInt32
            switch c {
            case 0x30...0x39: digit = UInt32(c - 0x30)
            case 0x41...0x46: digit = UInt32(c - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(c - 0x61 + 10)
            default: return nil
            }
            value = value << 4 | digit
        }
        pos += 4
        return value
    }

    private static let powers: [Double] = (0...22).map { pow(10, Double($0)) }

    mutating func isNumberStart() -> Bool {
        guard let c = peek() else { return false }
        return c == UInt8(ascii: "-") || (c >= 0x30 && c <= 0x39)
    }

    mutating func number() throws -> Double {
        skipWhitespace()
        let start = pos
        var negative = false
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") { negative = true; pos += 1 }
        var mantissa: UInt64 = 0
        var digits = 0
        var scale = 0
        while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 {
            if digits < 19 { mantissa = mantissa &* 10 &+ UInt64(bytes[pos] - 0x30); digits += 1 } else { scale += 1 }
            pos += 1
        }
        guard pos > start + (negative ? 1 : 0) else { throw Failure.syntax(pos) }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
            pos += 1
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 {
                if digits < 19 { mantissa = mantissa &* 10 &+ UInt64(bytes[pos] - 0x30); digits += 1; scale -= 1 }
                pos += 1
            }
        }
        var exponent = 0
        var hasExponent = false
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            hasExponent = true
            pos += 1
            var expNegative = false
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") || bytes[pos] == UInt8(ascii: "+") {
                expNegative = bytes[pos] == UInt8(ascii: "-")
                pos += 1
            }
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 {
                if exponent < 10_000 { exponent = exponent * 10 + Int(bytes[pos] - 0x30) }
                pos += 1
            }
            if expNegative { exponent = -exponent }
        }
        let total = scale + exponent
        if digits <= 15, !hasExponent || abs(total) <= 22, abs(total) <= 22 {
            var value = Double(mantissa)
            value = total < 0 ? value / JSONCursor.powers[-total] : value * JSONCursor.powers[total]
            return negative ? -value : value
        }
        // Rare: long mantissas or big exponents. strtod is exact.
        var text = Array(bytes[start..<pos])
        text.append(0)
        return text.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { strtod($0, nil) }
        }
    }

    // MARK: Values

    /// Skips any value without building it.
    mutating func skipValue(depth: Int = 0) throws {
        guard depth < maxDepth * 4 else { throw Failure.depth }
        skipWhitespace()
        guard pos < bytes.count else { throw Failure.syntax(pos) }
        switch bytes[pos] {
        case UInt8(ascii: "\""):
            pos += 1
            while pos < bytes.count {
                let c = bytes[pos]
                if c == UInt8(ascii: "\\") { pos += 2; continue }
                pos += 1
                if c == UInt8(ascii: "\"") { return }
            }
            throw Failure.syntax(pos)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            // Iterative: brackets nest, strings are skipped whole.
            var stack = 0
            while pos < bytes.count {
                let c = bytes[pos]
                if c == UInt8(ascii: "\"") {
                    try skipValue(depth: depth + 1)
                    continue
                }
                pos += 1
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                    stack += 1
                    if stack > maxDepth * 4 { throw Failure.depth }
                } else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                    stack -= 1
                    if stack == 0 { return }
                }
            }
            throw Failure.syntax(pos)
        case UInt8(ascii: "t"): pos += 4
        case UInt8(ascii: "f"): pos += 5
        case UInt8(ascii: "n"): pos += 4
        default: _ = try number()
        }
        if pos > bytes.count { throw Failure.syntax(pos) }
    }

    /// A value as compact JSON text (whitespace outside strings removed), capped in length.
    mutating func compactText(cap: Int) throws -> String {
        skipWhitespace()
        let start = pos
        try skipValue()
        var out: [UInt8] = []
        out.reserveCapacity(min(pos - start, cap))
        var inString = false
        var i = start
        while i < pos, out.count < cap {
            let c = bytes[i]
            if inString {
                out.append(c)
                if c == UInt8(ascii: "\\"), i + 1 < pos { out.append(bytes[i + 1]); i += 2; continue }
                if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
                out.append(c)
            } else if c != 0x20 && c != 0x0A && c != 0x0D && c != 0x09 {
                out.append(c)
            }
            i += 1
        }
        var text = String(decoding: out, as: UTF8.self)
        if pos - start > cap { text += "…" }
        return text
    }

    /// A property value: scalars as themselves, objects and arrays as compact JSON.
    mutating func geoValue() throws -> GeoValue {
        guard let c = peek() else { throw Failure.syntax(pos) }
        switch c {
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): pos += 4; return .bool(true)
        case UInt8(ascii: "f"): pos += 5; return .bool(false)
        case UInt8(ascii: "n"): pos += 4; return .null
        case UInt8(ascii: "{"), UInt8(ascii: "["): return .json(try compactText(cap: maxString))
        default: return .number(try number())
        }
    }

    /// A generic value, for small structures (TopoJSON objects, CRS members).
    mutating func node(depth: Int = 0) throws -> JSONNode {
        guard depth < maxDepth else { throw Failure.depth }
        guard let c = peek() else { throw Failure.syntax(pos) }
        switch c {
        case UInt8(ascii: "{"):
            try beginObject()
            var first = true
            var members: [(String, JSONNode)] = []
            while let key = try nextKey(&first) { members.append((key, try node(depth: depth + 1))) }
            return .object(members)
        case UInt8(ascii: "["):
            try beginArray()
            var first = true
            var items: [JSONNode] = []
            while try nextElement(&first) { items.append(try node(depth: depth + 1)) }
            return .array(items)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): pos += 4; return .bool(true)
        case UInt8(ascii: "f"): pos += 5; return .bool(false)
        case UInt8(ascii: "n"): pos += 4; return .null
        default: return .number(try number())
        }
    }

    // MARK: Coordinates

    enum Coords {
        case position(GeoPoint)
        case positions([GeoPoint])
        indirect case list([Coords])
    }

    /// Nested coordinate arrays. Positions with non-numbers become NaN and are dropped later.
    mutating func coords(depth: Int = 0) throws -> Coords {
        guard depth < 8 else { throw Failure.depth }
        try beginArray()
        skipWhitespace()
        guard pos < bytes.count else { throw Failure.syntax(pos) }
        if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .positions([]) }
        if isNumberStart() || bytes[pos] == UInt8(ascii: "n") {
            return .position(try positionTail())
        }
        let first = try coords(depth: depth + 1)
        if case .position(let p) = first {
            var points = [p]
            while true {
                skipWhitespace()
                guard pos < bytes.count else { throw Failure.syntax(pos) }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; break }
                try expect(UInt8(ascii: ","))
                skipWhitespace()
                if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; break }
                if pos < bytes.count, bytes[pos] == UInt8(ascii: "[") {
                    pos += 1
                    points.append(try positionTail())
                } else {
                    try skipValue()
                }
            }
            return .positions(points)
        }
        var list = [first]
        var more = false
        while try nextElement(&more) { list.append(try coords(depth: depth + 1)) }
        return .list(list)
    }

    /// The rest of a position after its opening bracket: x, y, then any extra ordinates.
    private mutating func positionTail() throws -> GeoPoint {
        var values: [Double] = []
        var first = true
        while try nextElement(&first) {
            if isNull() { values.append(.nan); continue }
            if isNumberStart() { values.append(try number()) } else { try skipValue(); values.append(.nan) }
        }
        guard values.count >= 2 else { return GeoPoint(.nan, .nan) }
        return GeoPoint(values[0], values[1])
    }
}

/// A parsed JSON value, used for small structures only.
indirect enum JSONNode {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONNode])
    case object([(String, JSONNode)])

    subscript(key: String) -> JSONNode? {
        if case .object(let members) = self { return members.first { $0.0 == key }?.1 }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var array: [JSONNode]? { if case .array(let a) = self { return a }; return nil }
    var members: [(String, JSONNode)]? { if case .object(let m) = self { return m }; return nil }

    var geoValue: GeoValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        default: return .json(compactJSON(limit: 32 * 1024))
        }
    }

    func compactJSON(limit: Int) -> String {
        var out = ""
        write(into: &out, limit: limit)
        return out.count > limit ? String(out.prefix(limit)) + "…" : out
    }

    private func write(into out: inout String, limit: Int) {
        guard out.utf8.count <= limit else { return }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += GeoValue.format(n)
        case .string(let s): out += JSONNode.quoted(s)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() { if i > 0 { out += "," }; item.write(into: &out, limit: limit) }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, (key, value)) in members.enumerated() {
                if i > 0 { out += "," }
                out += JSONNode.quoted(key) + ":"
                value.write(into: &out, limit: limit)
            }
            out += "}"
        }
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

// MARK: - GeoJSON

struct GeoJSONResult {
    var features: [GeoFeature] = []
    /// The legacy `crs` member's name ("EPSG:3857", "urn:ogc:def:crs:EPSG::27700").
    var crsName: String?
    var truncated = false
    var skipped = 0
}

enum GeoJSONReader {

    static func read(_ data: Data, limits: GeoLimits) throws -> GeoJSONResult {
        try data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            var cursor = JSONCursor(buffer, maxDepth: limits.maxDepth, maxString: limits.maxStringLength)
            var budget = GeoBudget(limits)
            var result = GeoJSONResult()
            do {
                try readRoot(&cursor, &result, &budget, limits: limits)
            } catch let failure as JSONCursor.Failure {
                // Keep what was read before the damage, but a file with nothing usable is invalid.
                if result.features.isEmpty { throw GeoError.invalid(message(failure)) }
                result.truncated = true
            }
            if budget.exhausted { result.truncated = true }
            return result
        }
    }

    /// GeoJSON Lines and RFC 8142 text sequences: one feature (or collection) per line.
    static func readLines(_ data: Data, limits: GeoLimits) throws -> GeoJSONResult {
        var result = GeoJSONResult()
        var budget = GeoBudget(limits)
        data.withUnsafeBytes { raw in
            let all = raw.bindMemory(to: UInt8.self)
            var start = 0
            var lineNumber = 0
            while start < all.count, !budget.exhausted {
                var end = start
                while end < all.count, all[end] != 0x0A, all[end] != 0x1E { end += 1 }
                lineNumber += 1
                if end > start {
                    let line = UnsafeBufferPointer(rebasing: all[start..<end])
                    var cursor = JSONCursor(line, maxDepth: limits.maxDepth, maxString: limits.maxStringLength)
                    if !cursor.atEnd {
                        do { try readRoot(&cursor, &result, &budget, limits: limits) } catch { result.skipped += 1 }
                    }
                }
                start = end + 1
                if lineNumber & 1023 == 0, !budget.checkTime() { break }
            }
        }
        if budget.exhausted { result.truncated = true }
        if result.features.isEmpty && result.skipped > 0 { throw GeoError.invalid("No line of this file is a GeoJSON feature.") }
        return result
    }

    private static func message(_ failure: JSONCursor.Failure) -> String {
        switch failure {
        case .syntax(let offset): return "This GeoJSON is damaged near byte \(offset.formatted())."
        case .depth: return "This GeoJSON nests too deeply to read."
        }
    }

    /// A FeatureCollection, a Feature, or a bare geometry.
    private static func readRoot(_ c: inout JSONCursor, _ result: inout GeoJSONResult, _ budget: inout GeoBudget, limits: GeoLimits) throws {
        guard c.peek() == UInt8(ascii: "{") else {
            if c.peek() == UInt8(ascii: "[") {
                // An array of features (seen in the wild).
                try c.beginArray()
                var first = true
                while try c.nextElement(&first) {
                    if budget.exhausted { try c.skipValue(); continue }
                    try readRoot(&c, &result, &budget, limits: limits)
                }
                return
            }
            throw JSONCursor.Failure.syntax(c.pos)
        }
        try c.beginObject()
        var first = true
        var type: String?
        var geometry: GeoGeometry?
        var hasGeometryMember = false
        var properties: [(key: String, value: GeoValue)] = []
        var coords: JSONCursor.Coords?
        var geometries: [GeoGeometry]?
        var id: GeoValue?
        while let key = try c.nextKey(&first) {
            switch key {
            case "type": type = try c.stringOrSkip()
            case "features":
                guard c.peek() == UInt8(ascii: "[") else { try c.skipValue(); continue }
                try c.beginArray()
                var firstFeature = true
                while try c.nextElement(&firstFeature) {
                    if budget.exhausted { try c.skipValue(); continue }
                    if c.peek() != UInt8(ascii: "{") { try c.skipValue(); result.skipped += 1; continue }
                    let feature = try readFeature(&c, limits: limits)
                    if budget.admit(feature.geometry) { result.features.append(feature) }
                }
            case "geometry":
                hasGeometryMember = true
                geometry = try readGeometry(&c, depth: 0)
            case "properties": properties = try readProperties(&c, limits: limits)
            case "coordinates":
                if c.peek() == UInt8(ascii: "[") { coords = try c.coords() } else { try c.skipValue() }
            case "geometries": geometries = try readGeometryList(&c, depth: 0)
            case "id": id = try c.geoValue()
            case "crs":
                let node = try c.node()
                result.crsName = node["properties"]?["name"]?.string
                    ?? node["properties"]?["code"]?.number.map { "EPSG:\(Int($0))" }
            default: try c.skipValue()
            }
        }
        if type == "FeatureCollection" || type == "Topology" { return }
        if type == "Feature" || (type == nil && hasGeometryMember) {
            var feature = GeoFeature(geometry: geometry, properties: properties)
            if let id { feature.properties.insert(("id", id), at: 0) }
            finish(&feature)
            if budget.admit(feature.geometry) { result.features.append(feature) }
        } else if let type, let geometry = makeGeometry(type: type, coords: coords, geometries: geometries) {
            if budget.admit(geometry) { result.features.append(GeoFeature(geometry: geometry)) }
        }
    }

    private static func readFeature(_ c: inout JSONCursor, limits: GeoLimits) throws -> GeoFeature {
        try c.beginObject()
        var first = true
        var feature = GeoFeature()
        var id: GeoValue?
        while let key = try c.nextKey(&first) {
            switch key {
            case "geometry": feature.geometry = try readGeometry(&c, depth: 0)
            case "properties": feature.properties = try readProperties(&c, limits: limits)
            case "id": id = try c.geoValue()
            default: try c.skipValue()
            }
        }
        if let id { feature.properties.insert(("id", id), at: 0) }
        finish(&feature)
        return feature
    }

    /// Picks up a display name and simplestyle styling from the properties.
    static func finish(_ feature: inout GeoFeature) {
        var style = GeoStyle()
        for (key, value) in feature.properties {
            switch key {
            case "name", "Name", "NAME", "title", "Title":
                if feature.name == nil, case .string(let s) = value, !s.isEmpty { feature.name = s }
            case "stroke": style.stroke = GeoStyle.color(value.text)
            case "stroke-width": if case .number(let n) = value { style.strokeWidth = GeoStyle.clamp(n, 0, 24) }
            case "stroke-opacity": if case .number(let n) = value { style.strokeOpacity = GeoStyle.clamp(n, 0, 1) }
            case "fill": style.fill = GeoStyle.color(value.text)
            case "fill-opacity": if case .number(let n) = value { style.fillOpacity = GeoStyle.clamp(n, 0, 1) }
            case "marker-color": style.markerColor = GeoStyle.color(value.text)
            default: break
            }
        }
        if !style.isEmpty { feature.style = style }
    }

    static func readProperties(_ c: inout JSONCursor, limits: GeoLimits) throws -> [(key: String, value: GeoValue)] {
        guard c.peek() == UInt8(ascii: "{") else { try c.skipValue(); return [] }
        try c.beginObject()
        var first = true
        var properties: [(key: String, value: GeoValue)] = []
        while let key = try c.nextKey(&first) {
            if properties.count < limits.maxProperties {
                properties.append((key, try c.geoValue()))
            } else {
                try c.skipValue()
            }
        }
        return properties
    }

    private static func readGeometry(_ c: inout JSONCursor, depth: Int) throws -> GeoGeometry? {
        guard depth < 8 else { throw JSONCursor.Failure.depth }
        if c.isNull() { return nil }
        guard c.peek() == UInt8(ascii: "{") else { try c.skipValue(); return nil }
        try c.beginObject()
        var first = true
        var type: String?
        var coords: JSONCursor.Coords?
        var geometries: [GeoGeometry]?
        while let key = try c.nextKey(&first) {
            switch key {
            case "type": type = try c.stringOrSkip()
            case "coordinates":
                if c.peek() == UInt8(ascii: "[") { coords = try c.coords() } else { try c.skipValue() }
            case "geometries": geometries = try readGeometryList(&c, depth: depth + 1)
            default: try c.skipValue()
            }
        }
        guard let type else { return nil }
        return makeGeometry(type: type, coords: coords, geometries: geometries)
    }

    private static func readGeometryList(_ c: inout JSONCursor, depth: Int) throws -> [GeoGeometry] {
        guard c.peek() == UInt8(ascii: "[") else { try c.skipValue(); return [] }
        try c.beginArray()
        var first = true
        var list: [GeoGeometry] = []
        while try c.nextElement(&first) {
            if let g = try readGeometry(&c, depth: depth + 1) { list.append(g) }
        }
        return list
    }

    static func makeGeometry(type: String, coords: JSONCursor.Coords?, geometries: [GeoGeometry]?) -> GeoGeometry? {
        func positions(_ c: JSONCursor.Coords?) -> [GeoPoint] {
            switch c {
            case .position(let p): return p.isFinite ? [p] : []
            case .positions(let p): return p.filter(\.isFinite)
            default: return []
            }
        }
        func lists(_ c: JSONCursor.Coords?) -> [[GeoPoint]] {
            switch c {
            case .list(let items): return items.map { positions($0) }
            case .positions(let p) where p.isEmpty: return []
            default: return []
            }
        }
        switch type {
        case "Point":
            guard case .position(let p) = coords, p.isFinite else { return .multiPoint([]) }
            return .point(p)
        case "MultiPoint": return .multiPoint(positions(coords))
        case "LineString": return .lineString(positions(coords))
        case "MultiLineString": return .multiLineString(lists(coords))
        case "Polygon": return .polygon(lists(coords))
        case "MultiPolygon":
            guard case .list(let polygons) = coords else { return .multiPolygon([]) }
            return .multiPolygon(polygons.map { lists($0) })
        case "GeometryCollection": return .collection(geometries ?? [])
        default: return nil
        }
    }
}

// MARK: - TopoJSON

struct TopoJSONResult {
    /// One layer per object in `objects`.
    var layers: [GeoLayer] = []
    var truncated = false
}

enum TopoJSONReader {

    static func read(_ data: Data, limits: GeoLimits) throws -> TopoJSONResult {
        var arcs: [[GeoPoint]] = []
        var objects: [(String, JSONNode)] = []
        var transform: (scale: GeoPoint, translate: GeoPoint)?
        var isTopology = false
        try data.withUnsafeBytes { raw in
            var c = JSONCursor(raw.bindMemory(to: UInt8.self), maxDepth: limits.maxDepth, maxString: limits.maxStringLength)
            do {
                try c.beginObject()
                var first = true
                while let key = try c.nextKey(&first) {
                    switch key {
                    case "type": isTopology = try c.stringOrSkip() == "Topology"
                    case "arcs":
                        guard c.peek() == UInt8(ascii: "[") else { try c.skipValue(); continue }
                        switch try c.coords() {
                        case .list(let items):
                            arcs = items.map { item in
                                switch item {
                                case .positions(let p): return p
                                case .position(let p): return [p]
                                case .list: return []
                                }
                            }
                        case .positions(let p) where p.isEmpty: arcs = []
                        case .positions(let p): arcs = [p]
                        case .position: arcs = []
                        }
                    case "objects": objects = try c.node().members ?? []
                    case "transform":
                        let node = try c.node()
                        if let s = node["scale"]?.array?.compactMap(\.number), let t = node["translate"]?.array?.compactMap(\.number),
                           s.count >= 2, t.count >= 2 {
                            transform = (GeoPoint(s[0], s[1]), GeoPoint(t[0], t[1]))
                        }
                    default: try c.skipValue()
                    }
                }
            } catch {
                throw GeoError.invalid("This TopoJSON is damaged.")
            }
        }
        guard isTopology else { throw GeoError.invalid("This file isn’t a TopoJSON topology.") }

        // Quantized topologies store arcs as deltas from the previous position.
        if let transform {
            arcs = arcs.map { arc in
                var x = 0.0, y = 0.0
                return arc.map { p in
                    x += p.x; y += p.y
                    return GeoPoint(x * transform.scale.x + transform.translate.x, y * transform.scale.y + transform.translate.y)
                }
            }
        }
        func position(_ node: JSONNode) -> GeoPoint? {
            guard let values = node.array?.compactMap(\.number), values.count >= 2 else { return nil }
            var p = GeoPoint(values[0], values[1])
            if let transform {
                p = GeoPoint(p.x * transform.scale.x + transform.translate.x, p.y * transform.scale.y + transform.translate.y)
            }
            return p
        }
        func line(_ node: JSONNode?) -> [GeoPoint] {
            var points: [GeoPoint] = []
            for index in node?.array?.compactMap(\.number) ?? [] {
                guard index.isFinite, abs(index) < 1e9 else { continue }
                let i = Int(index)
                let reversed = i < 0
                let arcIndex = reversed ? ~i : i
                guard arcIndex >= 0, arcIndex < arcs.count else { continue }
                var arc = arcs[arcIndex]
                if reversed { arc.reverse() }
                if !points.isEmpty, !arc.isEmpty { arc.removeFirst() }
                points += arc
            }
            return points
        }

        var budget = GeoBudget(limits)
        var result = TopoJSONResult()
        func geometry(_ node: JSONNode, depth: Int) -> GeoGeometry? {
            guard depth < 16, let type = node["type"]?.string else { return nil }
            switch type {
            case "Point": return node["coordinates"].flatMap(position).map(GeoGeometry.point)
            case "MultiPoint": return .multiPoint(node["coordinates"]?.array?.compactMap(position) ?? [])
            case "LineString": return .lineString(line(node["arcs"]))
            case "MultiLineString": return .multiLineString(node["arcs"]?.array?.map { line($0) } ?? [])
            case "Polygon": return .polygon(node["arcs"]?.array?.map { line($0) } ?? [])
            case "MultiPolygon": return .multiPolygon(node["arcs"]?.array?.map { $0.array?.map { line($0) } ?? [] } ?? [])
            case "GeometryCollection": return .collection(node["geometries"]?.array?.compactMap { geometry($0, depth: depth + 1) } ?? [])
            default: return nil
            }
        }
        func feature(_ node: JSONNode) -> GeoFeature {
            var f = GeoFeature(geometry: geometry(node, depth: 0))
            if let id = node["id"] { f.properties.append(("id", id.geoValue)) }
            for (key, value) in (node["properties"]?.members ?? []).prefix(limits.maxProperties) {
                f.properties.append((key, value.geoValue))
            }
            GeoJSONReader.finish(&f)
            return f
        }
        for (name, object) in objects {
            let layer = GeoLayer(name: name)
            if object["type"]?.string == "GeometryCollection" {
                for member in object["geometries"]?.array ?? [] {
                    if budget.exhausted { break }
                    let f = feature(member)
                    if budget.admit(f.geometry) { layer.features.append(f) }
                }
            } else if !budget.exhausted {
                let f = feature(object)
                if budget.admit(f.geometry) { layer.features.append(f) }
            }
            result.layers.append(layer)
        }
        result.truncated = budget.exhausted
        return result
    }
}
