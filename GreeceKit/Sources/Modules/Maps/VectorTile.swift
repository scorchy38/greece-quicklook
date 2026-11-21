import Foundation

/// Mapbox Vector Tile 2.x decoding: layers, features, tags and command-encoded geometry.
/// Counts and lengths are checked against the buffer at every step.
struct VectorTile {
    struct Feature {
        /// 1 point, 2 line, 3 polygon.
        var type: Int
        /// Parts in tile coordinates (0…extent): points, lines or rings.
        var parts: [[(Int32, Int32)]]
        var properties: [(key: String, value: GeoValue)]
    }

    struct Layer {
        var name: String
        var extent: Int
        var features: [Feature]
    }

    var layers: [Layer]

    static func decode(_ data: Data, maxFeatures: Int = 200_000, withProperties: Bool = true) -> VectorTile? {
        var reader = ProtoReader(data: data)
        var layers: [Layer] = []
        var features = 0
        while let (field, wire) = reader.key() {
            if field == 3, wire == 2, let slice = reader.bytes() {
                if let layer = decodeLayer(slice, budget: maxFeatures - features, withProperties: withProperties) {
                    features += layer.features.count
                    layers.append(layer)
                }
                if layers.count >= 1000 || features >= maxFeatures { break }
            } else if !reader.skip(wire) {
                return layers.isEmpty ? nil : VectorTile(layers: layers)
            }
        }
        return VectorTile(layers: layers)
    }

    private static func decodeLayer(_ data: Data, budget: Int, withProperties: Bool) -> Layer? {
        var reader = ProtoReader(data: data)
        var name = ""
        var extent = 4096
        var keys: [String] = []
        var values: [GeoValue] = []
        var rawFeatures: [Data] = []
        while let (field, wire) = reader.key() {
            switch (field, wire) {
            case (1, 2): name = reader.bytes().map { String(decoding: $0.prefix(256), as: UTF8.self) } ?? ""
            case (2, 2): if let f = reader.bytes(), rawFeatures.count < budget { rawFeatures.append(f) }
            case (3, 2): if let k = reader.bytes(), keys.count < 65_536 { keys.append(String(decoding: k.prefix(256), as: UTF8.self)) }
            case (4, 2): if let v = reader.bytes(), values.count < 65_536 { values.append(decodeValue(v)) }
            case (5, 0): extent = max(1, min(Int(reader.varint() ?? 4096), 1 << 16))
            default: if !reader.skip(wire) { return nil }
            }
        }
        var features: [Feature] = []
        features.reserveCapacity(rawFeatures.count)
        for raw in rawFeatures {
            var r = ProtoReader(data: raw)
            var type = 0
            var tags: [UInt32] = []
            var geometry: [UInt32] = []
            while let (field, wire) = r.key() {
                switch (field, wire) {
                case (2, 2): if withProperties { tags = r.packed(limit: 65_536) } else { _ = r.skip(wire) }
                case (3, 0): type = Int(r.varint() ?? 0)
                case (4, 2): geometry = r.packed(limit: 4_000_000)
                default: if !r.skip(wire) { break }
                }
            }
            var properties: [(key: String, value: GeoValue)] = []
            var i = 0
            while i + 1 < tags.count {
                let k = Int(tags[i]), v = Int(tags[i + 1])
                if k < keys.count, v < values.count { properties.append((keys[k], values[v])) }
                i += 2
            }
            features.append(Feature(type: type, parts: decodeGeometry(geometry, type: type), properties: properties))
        }
        return Layer(name: name, extent: extent, features: features)
    }

    private static func decodeValue(_ data: Data) -> GeoValue {
        var r = ProtoReader(data: data)
        while let (field, wire) = r.key() {
            switch (field, wire) {
            case (1, 2): return .string(r.bytes().map { String(decoding: $0.prefix(32 * 1024), as: UTF8.self) } ?? "")
            case (2, 5): return r.fixed32().map { .number(Double(Float(bitPattern: $0))) } ?? .null
            case (3, 1): return r.fixed64().map { .number(Double(bitPattern: $0)) } ?? .null
            case (4, 0): return r.varint().map { .number(Double(Int64(bitPattern: $0))) } ?? .null
            case (5, 0): return r.varint().map { .number(Double($0)) } ?? .null
            case (6, 0): return r.varint().map { .number(Double(Int64(bitPattern: ($0 >> 1) ^ (0 &- ($0 & 1))))) } ?? .null
            case (7, 0): return r.varint().map { .bool($0 != 0) } ?? .null
            default: if !r.skip(wire) { return .null }
            }
        }
        return .null
    }

    private static func decodeGeometry(_ commands: [UInt32], type: Int) -> [[(Int32, Int32)]] {
        var parts: [[(Int32, Int32)]] = []
        var current: [(Int32, Int32)] = []
        var x: Int32 = 0, y: Int32 = 0
        var i = 0
        func zigzag(_ v: UInt32) -> Int32 { Int32(bitPattern: (v >> 1) ^ (0 &- (v & 1))) }
        while i < commands.count {
            let command = commands[i] & 0x7
            let count = Int(commands[i] >> 3)
            i += 1
            switch command {
            case 1, 2:
                guard count <= (commands.count - i) / 2 else { return parts }
                for _ in 0..<count {
                    x &+= zigzag(commands[i]); y &+= zigzag(commands[i + 1])
                    i += 2
                    if command == 1, type != 1 {
                        if !current.isEmpty { parts.append(current) }
                        current = []
                    }
                    current.append((x, y))
                }
            case 7:
                if let first = current.first { current.append(first) }
            default:
                return parts
            }
        }
        if !current.isEmpty { parts.append(current) }
        if type == 1 { return parts.flatMap { $0 }.map { [$0] } }
        return parts
    }
}

/// Minimal protocol buffer wire-format reader.
struct ProtoReader {
    let data: Data
    var pos = 0

    init(data: Data) { self.data = data.startIndex == 0 ? data : Data(data) }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < data.count, shift < 64 {
            let byte = data[pos]
            pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func key() -> (Int, Int)? {
        guard pos < data.count, let k = varint() else { return nil }
        return (Int(k >> 3), Int(k & 7))
    }

    mutating func bytes() -> Data? {
        guard let length = varint(), length <= UInt64(data.count - pos) else { pos = data.count; return nil }
        let start = pos
        pos += Int(length)
        return data.subdata(in: start..<pos)
    }

    mutating func fixed32() -> UInt32? {
        guard pos + 4 <= data.count else { return nil }
        defer { pos += 4 }
        return data.u32(pos)
    }

    mutating func fixed64() -> UInt64? {
        guard pos + 8 <= data.count else { return nil }
        defer { pos += 8 }
        return data.u64(pos)
    }

    mutating func packed(limit: Int) -> [UInt32] {
        guard let slice = bytes() else { return [] }
        var inner = ProtoReader(data: slice)
        var result: [UInt32] = []
        while inner.pos < inner.data.count, result.count < limit, let v = inner.varint() { result.append(UInt32(truncatingIfNeeded: v)) }
        return result
    }

    mutating func skip(_ wire: Int) -> Bool {
        switch wire {
        case 0: return varint() != nil
        case 1: guard pos + 8 <= data.count else { return false }; pos += 8; return true
        case 2: return bytes() != nil
        case 5: guard pos + 4 <= data.count else { return false }; pos += 4; return true
        default: return false
        }
    }
}
