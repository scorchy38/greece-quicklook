import Foundation
import simd

/// A glTF 2.0 asset (`.gltf` JSON or `.glb` container): its JSON, its embedded binary chunk, and
/// helpers to walk the scene graph. Used for facts in previews and geometry in thumbnails.
struct GLTFDocument {
    let json: [String: Any]
    let binaryChunk: Data?
    let directory: URL
    let accessors: [[String: Any]]
    let meshes: [[String: Any]]
    let nodes: [[String: Any]]

    static let jsonLimit = 64 * 1024 * 1024
    /// Scene graphs deeper or larger than this are hostile or broken: walking stops there.
    static let depthLimit = 64
    static let nodeVisitLimit = 200_000

    enum Failure: Error { case notGLTF, tooLarge }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data, directory: url.deletingLastPathComponent())
    }

    init(data: Data, directory: URL) throws {
        self.directory = directory
        var jsonData = data
        var binary: Data?
        if data.count >= 12, data.u32(0) == 0x46546C67 {   // "glTF"
            // GLB: a 12-byte header, then a JSON chunk and an optional BIN chunk.
            var offset = 12
            var found: Data?
            while offset + 8 <= data.count {
                let length = Int(data.u32(offset))
                let type = data.u32(offset + 4)
                let start = offset + 8
                guard length >= 0, start + length <= data.count else { break }
                if type == 0x4E4F534A, found == nil {
                    guard length <= Self.jsonLimit else { throw Failure.tooLarge }
                    found = data.subdata(in: start..<(start + length))
                } else if type == 0x004E4942, binary == nil {
                    binary = data[start..<(start + length)]
                }
                offset = start + ((length + 3) & ~3)
            }
            guard let found else { throw Failure.notGLTF }
            jsonData = found
        } else if data.count > Self.jsonLimit {
            throw Failure.tooLarge
        }
        guard let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              object["asset"] is [String: Any] || object["meshes"] != nil else { throw Failure.notGLTF }
        json = object
        binaryChunk = binary.map { Data($0) }
        accessors = object["accessors"] as? [[String: Any]] ?? []
        meshes = object["meshes"] as? [[String: Any]] ?? []
        nodes = object["nodes"] as? [[String: Any]] ?? []
    }

    // MARK: - Lookups

    func array(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }

    var extensionsUsed: [String] { json["extensionsUsed"] as? [String] ?? [] }
    var generator: String? { (json["asset"] as? [String: Any])?["generator"] as? String }
    var version: String? { (json["asset"] as? [String: Any])?["version"] as? String }

    func accessorCount(_ index: Any?) -> Int {
        guard let index = index as? Int, accessors.indices.contains(index) else { return 0 }
        return max(0, accessors[index]["count"] as? Int ?? 0)
    }

    /// The root nodes of the default scene (or every parentless node when there are no scenes).
    var rootNodes: [Int] {
        let scenes = array("scenes")
        if !scenes.isEmpty {
            let index = json["scene"] as? Int ?? 0
            let scene = scenes.indices.contains(index) ? scenes[index] : scenes[0]
            return (scene["nodes"] as? [Int] ?? []).filter { nodes.indices.contains($0) }
        }
        var children = Set<Int>()
        for node in nodes { (node["children"] as? [Int])?.forEach { children.insert($0) } }
        return nodes.indices.filter { !children.contains($0) }
    }

    /// Visits every node of the default scene with its world transform, depth-first.
    func walk(_ visit: (_ index: Int, _ node: [String: Any], _ world: simd_float4x4) -> Void) {
        var visits = 0
        func recurse(_ index: Int, _ parent: simd_float4x4, depth: Int) {
            guard depth < Self.depthLimit, visits < Self.nodeVisitLimit, nodes.indices.contains(index) else { return }
            visits += 1
            let node = nodes[index]
            let world = parent * Self.localMatrix(node)
            visit(index, node, world)
            for child in node["children"] as? [Int] ?? [] { recurse(child, world, depth: depth + 1) }
        }
        for root in rootNodes { recurse(root, matrix_identity_float4x4, depth: 0) }
    }

    static func localMatrix(_ node: [String: Any]) -> simd_float4x4 {
        if let m = (node["matrix"] as? [NSNumber])?.map({ $0.floatValue }), m.count == 16, m.allSatisfy(\.isFinite) {
            return simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                           SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
        }
        func vector(_ key: String, _ count: Int) -> [Float]? {
            guard let values = (node[key] as? [NSNumber])?.map({ $0.floatValue }), values.count == count, values.allSatisfy(\.isFinite) else { return nil }
            return values
        }
        var matrix = matrix_identity_float4x4
        if let t = vector("translation", 3) { matrix.columns.3 = SIMD4(t[0], t[1], t[2], 1) }
        if let r = vector("rotation", 4) {
            let q = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            if q.length > 0 { matrix = matrix * simd_float4x4(simd_normalize(q)) }
        }
        if let s = vector("scale", 3) { matrix = matrix * simd_float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1)) }
        return matrix
    }

    // MARK: - Facts

    struct Summary {
        var meshInstances = 0
        var triangles = 0
        var vertices = 0
        var points = 0
        var bounds = Bounds()
    }

    /// Triangles, vertices and world bounds of the default scene, from accessor metadata alone.
    func summarize() -> Summary {
        var summary = Summary()
        walk { _, node, world in
            guard let index = node["mesh"] as? Int, meshes.indices.contains(index) else { return }
            // EXT_mesh_gpu_instancing draws the mesh once per instance.
            var instances = 1
            if let instancing = (node["extensions"] as? [String: Any])?["EXT_mesh_gpu_instancing"] as? [String: Any],
               let attributes = instancing["attributes"] as? [String: Any] {
                instances = max(1, attributes.values.map { accessorCount($0) }.max() ?? 1)
            }
            summary.meshInstances += instances
            for primitive in meshes[index]["primitives"] as? [[String: Any]] ?? [] {
                let attributes = primitive["attributes"] as? [String: Any] ?? [:]
                let vertexCount = accessorCount(attributes["POSITION"])
                let drawn = primitive["indices"] != nil ? accessorCount(primitive["indices"]) : vertexCount
                let mode = primitive["mode"] as? Int ?? 4
                var triangles = 0
                switch mode {
                case 4: triangles = drawn / 3
                case 5, 6: triangles = max(0, drawn - 2)
                case 0: summary.points = summary.points.addingClamped(drawn.multipliedClamped(instances))
                default: break
                }
                summary.triangles = summary.triangles.addingClamped(triangles.multipliedClamped(instances))
                summary.vertices = summary.vertices.addingClamped(vertexCount.multipliedClamped(instances))
                if let box = positionBounds(attributes["POSITION"]) {
                    summary.bounds.formUnion(box.transformed(by: world))
                }
            }
        }
        return summary
    }

    /// POSITION accessors must carry min and max; normalized integers are stored un-normalized.
    func positionBounds(_ index: Any?) -> Bounds? {
        guard let index = index as? Int, accessors.indices.contains(index) else { return nil }
        let accessor = accessors[index]
        guard let minimum = (accessor["min"] as? [NSNumber])?.map({ $0.floatValue }),
              let maximum = (accessor["max"] as? [NSNumber])?.map({ $0.floatValue }),
              minimum.count >= 3, maximum.count >= 3 else { return nil }
        var scale: Float = 1
        if accessor["normalized"] as? Bool == true {
            switch accessor["componentType"] as? Int {
            case 5120: scale = 1 / 127
            case 5121: scale = 1 / 255
            case 5122: scale = 1 / 32767
            case 5123: scale = 1 / 65535
            default: break
            }
        }
        var box = Bounds()
        box.add(SIMD3(minimum[0], minimum[1], minimum[2]) * scale)
        box.add(SIMD3(maximum[0], maximum[1], maximum[2]) * scale)
        return box.isEmpty ? nil : box
    }
}

/// An axis-aligned box that ignores non-finite points.
struct Bounds: Equatable {
    var min = SIMD3<Float>(repeating: .infinity)
    var max = SIMD3<Float>(repeating: -.infinity)

    var isEmpty: Bool { !(min.x <= max.x && min.y <= max.y && min.z <= max.z) }
    var size: SIMD3<Float> { isEmpty ? .zero : max - min }
    var center: SIMD3<Float> { isEmpty ? .zero : (min + max) / 2 }

    mutating func add(_ point: SIMD3<Float>) {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
        min = simd_min(min, point)
        max = simd_max(max, point)
    }

    mutating func formUnion(_ other: Bounds) {
        guard !other.isEmpty else { return }
        add(other.min)
        add(other.max)
    }

    func transformed(by matrix: simd_float4x4) -> Bounds {
        guard !isEmpty else { return self }
        var result = Bounds()
        for corner in 0..<8 {
            let point = SIMD3(corner & 1 == 0 ? min.x : max.x, corner & 2 == 0 ? min.y : max.y, corner & 4 == 0 ? min.z : max.z)
            let moved = matrix * SIMD4(point, 1)
            result.add(SIMD3(moved.x, moved.y, moved.z) / (moved.w == 0 ? 1 : moved.w))
        }
        return result
    }
}

extension Int {
    /// Sums that hostile counts can't overflow.
    func addingClamped(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? Int.max : sum
    }

    func multipliedClamped(_ other: Int) -> Int {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? Int.max : product
    }
}
