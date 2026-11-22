import Foundation
import CArchive
import simd

/// Binary FBX (7.x) geometry for thumbnails: meshes placed by their models' transforms and coloured
/// by their materials' diffuse colours. ASCII FBX is left to the preview.
enum FBXReader {

    /// A node of the FBX tree. Array properties stay compressed until something asks for them.
    final class Node {
        let name: String
        var properties: [Property] = []
        var children: [Node] = []
        init(name: String) { self.name = name }

        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        func children(_ name: String) -> [Node] { children.filter { $0.name == name } }
    }

    enum Property {
        case integer(Int64)
        case number(Double)
        case string(String)
        case array(type: UInt8, count: Int, encoding: UInt32, range: Range<Int>)
        case other

        var integer: Int64? {
            switch self {
            case .integer(let v): return v
            case .number(let v): return v.isFinite && abs(v) < 9e18 ? Int64(v) : nil
            default: return nil
            }
        }
        var number: Double? {
            switch self {
            case .integer(let v): return Double(v)
            case .number(let v): return v
            default: return nil
            }
        }
        var string: String? { if case .string(let v) = self { return v } else { return nil } }
    }

    struct Limits {
        static let nodes = 2_000_000
        static let depth = 64
        static let arrayElements = 60_000_000
    }

    // MARK: - Parsing

    struct Parser {
        let data: Data
        let wide: Bool
        var nodeCount = 0

        /// The document's top-level nodes, or nil if this isn't a binary FBX.
        static func parse(_ data: Data) -> [Node]? {
            guard data.count > 27, data.prefix(18) == Data("Kaydara FBX Binary".utf8) else { return nil }
            let version = Int(data.u32(23))
            guard version >= 6100, version < 10000 else { return nil }
            var parser = Parser(data: data, wide: version >= 7500)
            var offset = 27
            var nodes: [Node] = []
            while offset < data.count - 13 {
                guard let (node, next) = parser.node(at: offset, depth: 0) else { break }
                guard let node else { break }   // the null record ends the top level
                nodes.append(node)
                offset = next
            }
            return nodes.isEmpty ? nil : nodes
        }

        /// One node record and the offset after it; (nil, offset) for a null record; nil when corrupt.
        mutating func node(at start: Int, depth: Int) -> (Node?, Int)? {
            guard depth < Limits.depth, nodeCount < Limits.nodes else { return nil }
            let headerSize = wide ? 25 : 13
            guard start + headerSize <= data.count else { return nil }
            let end = wide ? Int(clamping: data.u64(start)) : Int(data.u32(start))
            let propertyCount = wide ? Int(clamping: data.u64(start + 8)) : Int(data.u32(start + 4))
            let nameLength = Int(data[data.startIndex + start + headerSize - 1])
            if end == 0 { return (nil, start + headerSize) }
            guard end > start, end <= data.count, start + headerSize + nameLength <= end, propertyCount < 1_000_000 else { return nil }
            nodeCount += 1
            let nameStart = data.startIndex + start + headerSize
            let node = Node(name: String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self))
            var offset = start + headerSize + nameLength
            for _ in 0..<propertyCount {
                guard let (property, next) = property(at: offset, limit: end) else { return nil }
                node.properties.append(property)
                offset = next
            }
            while offset < end {
                guard let (child, next) = self.node(at: offset, depth: depth + 1) else { return nil }
                if let child { node.children.append(child) }
                guard next > offset else { return nil }
                offset = next
            }
            return (node, end)
        }

        func property(at start: Int, limit: Int) -> (Property, Int)? {
            guard start < limit else { return nil }
            let type = data[data.startIndex + start]
            let body = start + 1
            func need(_ count: Int) -> Bool { count >= 0 && body + count <= limit }
            switch type {
            case UInt8(ascii: "Y"): guard need(2) else { return nil }; return (.integer(Int64(Int16(bitPattern: data.u16(body)))), body + 2)
            case UInt8(ascii: "C"): guard need(1) else { return nil }; return (.integer(Int64(data[data.startIndex + body])), body + 1)
            case UInt8(ascii: "I"): guard need(4) else { return nil }; return (.integer(Int64(Int32(bitPattern: data.u32(body)))), body + 4)
            case UInt8(ascii: "F"): guard need(4) else { return nil }; return (.number(Double(Float(bitPattern: data.u32(body)))), body + 4)
            case UInt8(ascii: "D"): guard need(8) else { return nil }; return (.number(Double(bitPattern: data.u64(body))), body + 8)
            case UInt8(ascii: "L"): guard need(8) else { return nil }; return (.integer(Int64(bitPattern: data.u64(body))), body + 8)
            case UInt8(ascii: "S"), UInt8(ascii: "R"):
                guard need(4) else { return nil }
                let length = Int(data.u32(body))
                guard need(4 + length) else { return nil }
                if type == UInt8(ascii: "R") { return (.other, body + 4 + length) }
                let from = data.startIndex + body + 4
                return (.string(String(decoding: data[from..<(from + length)], as: UTF8.self)), body + 4 + length)
            case UInt8(ascii: "f"), UInt8(ascii: "d"), UInt8(ascii: "l"), UInt8(ascii: "i"), UInt8(ascii: "b"):
                guard need(12) else { return nil }
                let count = Int(data.u32(body))
                let encoding = data.u32(body + 4)
                let length = Int(data.u32(body + 8))
                guard need(12 + length) else { return nil }
                return (.array(type: type, count: count, encoding: encoding, range: (body + 12)..<(body + 12 + length)), body + 12 + length)
            default:
                return nil
            }
        }
    }

    /// An array property as doubles (inflating zlib-compressed arrays), or nil if it is corrupt.
    static func doubles(_ property: Property?, in data: Data) -> [Double]? {
        guard case .array(let type, let count, let encoding, let range)? = property, count >= 0, count <= Limits.arrayElements else { return nil }
        let size: Int
        switch type {
        case UInt8(ascii: "d"), UInt8(ascii: "l"): size = 8
        case UInt8(ascii: "f"), UInt8(ascii: "i"): size = 4
        default: size = 1
        }
        let raw = data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
        var bytes: Data
        if encoding == 1 {
            guard let inflated = inflateZlib(raw, expected: count * size), inflated.count >= count * size else { return nil }
            bytes = inflated
        } else {
            guard raw.count >= count * size else { return nil }
            bytes = raw
        }
        var result = [Double](repeating: 0, count: count)
        bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let at = i * size
                switch type {
                case UInt8(ascii: "d"): result[i] = Double(bitPattern: buffer.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian)
                case UInt8(ascii: "f"): result[i] = Double(Float(bitPattern: buffer.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian))
                case UInt8(ascii: "l"): result[i] = Double(Int64(bitPattern: buffer.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian))
                case UInt8(ascii: "i"): result[i] = Double(Int32(bitPattern: buffer.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian))
                default: result[i] = Double(buffer[at])
                }
            }
        }
        return result
    }

    /// zlib-wrapped DEFLATE, stopping at `expected` bytes.
    static func inflateZlib(_ input: Data, expected: Int) -> Data? {
        guard expected > 0, expected <= Limits.arrayElements * 8 else { return expected == 0 ? Data() : nil }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: expected)
        var input = input
        let status: Int32 = input.withUnsafeMutableBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                guard let inBase = inPtr.baseAddress, let outBase = outPtr.baseAddress else { return Z_DATA_ERROR }
                stream.next_in = inBase.assumingMemoryBound(to: Bytef.self)
                stream.avail_in = uInt(inPtr.count)
                stream.next_out = outBase.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(outPtr.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || (status == Z_BUF_ERROR && stream.avail_out == 0) else { return nil }
        return output
    }

    // MARK: - Scene

    static func load(_ url: URL, budget: ModelBudget) -> ModelScene? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let root = Parser.parse(data) else { return nil }
        guard let objects = root.first(where: { $0.name == "Objects" }) else { return nil }
        let connections = root.first { $0.name == "Connections" }?.children("C") ?? []

        var byID: [Int64: Node] = [:]
        for object in objects.children { if let id = object.properties.first?.integer { byID[id] = object } }
        var parentModel: [Int64: Int64] = [:]
        var geometryModels: [Int64: [Int64]] = [:]
        var modelMaterials: [Int64: [Int64]] = [:]
        for connection in connections where connection.properties.first?.string == "OO" {
            guard connection.properties.count >= 3, let child = connection.properties[1].integer, let parent = connection.properties[2].integer,
                  let childNode = byID[child] else { continue }
            switch childNode.name {
            case "Model" where parent == 0 || byID[parent]?.name == "Model": parentModel[child] = parent
            case "Geometry" where byID[parent]?.name == "Model": geometryModels[child, default: []].append(parent)
            case "Material" where byID[parent]?.name == "Model": modelMaterials[parent, default: []].append(child)
            default: break
            }
        }

        var worlds: [Int64: simd_float4x4] = [:]
        func world(_ model: Int64, depth: Int = 0) -> simd_float4x4 {
            if let cached = worlds[model] { return cached }
            guard depth < Limits.depth, let node = byID[model] else { return matrix_identity_float4x4 }
            let parent = parentModel[model].flatMap { $0 == 0 ? nil : $0 }
            let result = (parent.map { world($0, depth: depth + 1) } ?? matrix_identity_float4x4) * localMatrix(node)
            worlds[model] = result
            return result
        }

        var scene = ModelScene()
        var triangles = 0
        for (geometryID, models) in geometryModels.sorted(by: { $0.key < $1.key }) {
            guard !budget.expired, triangles < budget.triangles, let geometry = byID[geometryID],
                  geometry.properties.count > 2, geometry.properties[2].string == "Mesh" else { continue }
            guard let vertices = doubles(geometry.child("Vertices")?.properties.first, in: data),
                  let polygons = doubles(geometry.child("PolygonVertexIndex")?.properties.first, in: data) else { continue }
            let materialIndices = geometry.child("LayerElementMaterial").flatMap { layer -> [Double]? in
                guard layer.child("MappingInformationType")?.properties.first?.string == "ByPolygon" else { return nil }
                return doubles(layer.child("Materials")?.properties.first, in: data)
            }
            for model in models.prefix(64) {
                guard let modelNode = byID[model] else { continue }
                let colors = (modelMaterials[model] ?? []).map { diffuse(byID[$0]) }
                var mesh = triangulate(vertices: vertices, polygons: polygons, materialIndices: materialIndices, colors: colors,
                                       limit: budget.triangles - triangles)
                guard !mesh.indices.isEmpty else { continue }
                mesh.apply(world(model) * geometricMatrix(modelNode))
                mesh.computeNormals()
                triangles += mesh.triangleCount
                scene.meshes.append(mesh)
            }
        }
        let settings = root.first { $0.name == "GlobalSettings" }.flatMap { properties70($0) } ?? [:]
        scene.zUp = settings["UpAxis"]?.first.map { Int($0) } == 2
        return scene.isEmpty ? nil : scene
    }

    /// Polygons (negative indices close them) as a fan of triangles, unshared, with optional per-polygon colours.
    static func triangulate(vertices: [Double], polygons: [Double], materialIndices: [Double]?, colors: [SIMD4<Float>], limit: Int) -> ModelMesh {
        var mesh = ModelMesh()
        let vertexCount = vertices.count / 3
        let single = colors.first ?? SIMD4<Float>(0.66, 0.68, 0.71, 1)
        let perPolygon = (materialIndices?.count ?? 0) > 1 && colors.count > 1
        var polygon: [Int] = []
        var polygonIndex = 0
        func position(_ i: Int) -> SIMD3<Float> {
            let p = SIMD3(Float(vertices[i * 3]), Float(vertices[i * 3 + 1]), Float(vertices[i * 3 + 2]))
            return p.x.isFinite && p.y.isFinite && p.z.isFinite ? p : .zero
        }
        for raw in polygons {
            guard raw.isFinite, abs(raw) < 2_000_000_000 else { break }
            let value = Int(raw)
            let index = value < 0 ? ~value : value
            guard index >= 0, index < vertexCount else { polygon.removeAll(); if value < 0 { polygonIndex += 1 }; continue }
            polygon.append(index)
            guard value < 0 else { continue }
            if polygon.count >= 3, mesh.indices.count / 3 < limit {
                var color = single
                if perPolygon, let materialIndices, polygonIndex < materialIndices.count {
                    let m = Int(materialIndices[polygonIndex])
                    if colors.indices.contains(m) { color = colors[m] }
                }
                for k in 1..<(polygon.count - 1) {
                    for i in [polygon[0], polygon[k], polygon[k + 1]] {
                        mesh.indices.append(UInt32(mesh.positions.count))
                        mesh.positions.append(position(i))
                        if perPolygon { mesh.colors.append(color) }
                    }
                }
            }
            polygon.removeAll(keepingCapacity: true)
            polygonIndex += 1
        }
        if !perPolygon {
            mesh.material.baseColor = single
        }
        mesh.material.roughness = 0.55
        return mesh
    }

    // MARK: - Properties

    /// `Properties70` entries: name → numeric values.
    static func properties70(_ node: Node) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        for entry in node.child("Properties70")?.children("P") ?? [] {
            guard let name = entry.properties.first?.string else { continue }
            result[name] = entry.properties.dropFirst(4).compactMap(\.number)
        }
        return result
    }

    static func diffuse(_ material: Node?) -> SIMD4<Float> {
        guard let material else { return SIMD4(0.66, 0.68, 0.71, 1) }
        let properties = properties70(material)
        let color = properties["DiffuseColor"] ?? properties["Diffuse"] ?? properties["BaseColor"]
        guard let color, color.count >= 3 else { return SIMD4(0.8, 0.8, 0.8, 1) }
        let factor = properties["DiffuseFactor"]?.first.map(Float.init) ?? 1
        let opacity = properties["Opacity"]?.first.map(Float.init) ?? 1
        let rgb = SIMD3(Float(color[0]), Float(color[1]), Float(color[2])) * (factor > 0 ? factor : 1)
        return SIMD4(simd_clamp(rgb, .zero, SIMD3(repeating: 1)), max(0, min(1, opacity)))
    }

    /// Lcl Translation × PreRotation × Lcl Rotation × PostRotation⁻¹ × Lcl Scaling (pivots ignored).
    static func localMatrix(_ model: Node) -> simd_float4x4 {
        let p = properties70(model)
        let order = Int(p["RotationOrder"]?.first ?? 0)
        func vector(_ name: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            guard let v = p[name], v.count >= 3 else { return fallback }
            let result = SIMD3(Float(v[0]), Float(v[1]), Float(v[2]))
            return result.x.isFinite && result.y.isFinite && result.z.isFinite ? result : fallback
        }
        let translation = translationMatrix(vector("Lcl Translation", .zero))
        let rotation = euler(vector("Lcl Rotation", .zero), order: order)
        let pre = euler(vector("PreRotation", .zero), order: 0)
        let post = euler(vector("PostRotation", .zero), order: 0)
        let scale = vector("Lcl Scaling", SIMD3(repeating: 1))
        return translation * pre * rotation * post.inverse * simd_float4x4(diagonal: SIMD4(scale, 1))
    }

    static func geometricMatrix(_ model: Node) -> simd_float4x4 {
        let p = properties70(model)
        func vector(_ name: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            guard let v = p[name], v.count >= 3 else { return fallback }
            return SIMD3(Float(v[0]), Float(v[1]), Float(v[2]))
        }
        return translationMatrix(vector("GeometricTranslation", .zero)) * euler(vector("GeometricRotation", .zero), order: 0)
            * simd_float4x4(diagonal: SIMD4(vector("GeometricScaling", SIMD3(repeating: 1)), 1))
    }

    static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// Euler angles in degrees; order 0 (XYZ) rotates about X first.
    static func euler(_ degrees: SIMD3<Float>, order: Int) -> simd_float4x4 {
        let r = degrees * .pi / 180
        let x = simd_float4x4(simd_quatf(angle: r.x, axis: SIMD3(1, 0, 0)))
        let y = simd_float4x4(simd_quatf(angle: r.y, axis: SIMD3(0, 1, 0)))
        let z = simd_float4x4(simd_quatf(angle: r.z, axis: SIMD3(0, 0, 1)))
        switch order {
        case 1: return y * z * x   // XZY
        case 2: return x * z * y   // YZX
        case 3: return z * x * y   // YXZ
        case 4: return x * y * z   // ZXY
        case 5: return y * x * z   // ZYX
        default: return z * y * x  // XYZ
        }
    }
}
