import Foundation
import CoreGraphics
import ImageIO
import simd

/// glTF 2.0 geometry for thumbnails: meshes in world space with base colours, metal/roughness and
/// base-colour textures, skinned meshes in their rest pose. Draco- and Meshopt-compressed
/// primitives need decoders Swift doesn't have; they're skipped.
struct GLTFSceneReader {
    let document: GLTFDocument
    let budget: ModelBudget
    private var buffers: [Int: Data] = [:]
    private var images: [Int: CGImage?] = [:]
    private var materials: [Int: ModelMaterial] = [:]

    static let bufferLimit = 512 * 1024 * 1024
    static let textureSide = 512

    static func load(url: URL, budget: ModelBudget) -> ModelScene? {
        guard let document = try? GLTFDocument(url: url) else { return nil }
        var reader = GLTFSceneReader(document: document, budget: budget)
        return reader.scene()
    }

    init(document: GLTFDocument, budget: ModelBudget) {
        self.document = document
        self.budget = budget
    }

    mutating func scene() -> ModelScene? {
        // World matrices for every node first: skins need their joints' rest transforms.
        var worlds: [Int: simd_float4x4] = [:]
        var meshNodes: [(index: Int, world: simd_float4x4)] = []
        document.walk { index, node, world in
            worlds[index] = world
            if node["mesh"] is Int { meshNodes.append((index, world)) }
        }
        var scene = ModelScene()
        var triangles = 0
        let meshes = document.meshes
        for (index, world) in meshNodes {
            guard !budget.expired, triangles < budget.triangles else { break }
            let node = document.nodes[index]
            guard let meshIndex = node["mesh"] as? Int, meshes.indices.contains(meshIndex) else { continue }
            let skin = (node["skin"] as? Int).flatMap { skinMatrices($0, worlds: worlds) }
            for primitive in meshes[meshIndex]["primitives"] as? [[String: Any]] ?? [] {
                guard var mesh = self.mesh(primitive) else { continue }
                if let skin, let skinned = applySkin(primitive, mesh: mesh, joints: skin) {
                    mesh = skinned
                } else {
                    mesh.apply(world)
                }
                if mesh.normals.isEmpty { mesh.computeNormals() }
                triangles += mesh.triangleCount
                scene.meshes.append(mesh)
                if triangles >= budget.triangles { break }
            }
        }
        return scene.isEmpty ? nil : scene
    }

    // MARK: - Primitives

    private mutating func mesh(_ primitive: [String: Any]) -> ModelMesh? {
        let extensions = primitive["extensions"] as? [String: Any] ?? [:]
        guard extensions["KHR_draco_mesh_compression"] == nil else { return nil }
        let mode = primitive["mode"] as? Int ?? 4
        guard mode == 4 || mode == 5 || mode == 6 else { return nil }
        let attributes = primitive["attributes"] as? [String: Any] ?? [:]
        guard let positions = floats(attributes["POSITION"], components: 3), !positions.isEmpty else { return nil }
        var mesh = ModelMesh()
        mesh.positions = stride(from: 0, to: positions.count - 2, by: 3).map { SIMD3(positions[$0], positions[$0 + 1], positions[$0 + 2]) }
        if let normals = floats(attributes["NORMAL"], components: 3), normals.count == positions.count {
            mesh.normals = stride(from: 0, to: normals.count - 2, by: 3).map { SIMD3(normals[$0], normals[$0 + 1], normals[$0 + 2]) }
        }
        if let uvs = floats(attributes["TEXCOORD_0"], components: 2), uvs.count == mesh.positions.count * 2 {
            mesh.uvs = stride(from: 0, to: uvs.count - 1, by: 2).map { SIMD2(uvs[$0], uvs[$0 + 1]) }
        }
        if let colorIndex = attributes["COLOR_0"] as? Int, document.accessors.indices.contains(colorIndex) {
            let width = document.accessors[colorIndex]["type"] as? String == "VEC3" ? 3 : 4
            if let colors = floats(colorIndex, components: width), colors.count == mesh.positions.count * width {
                mesh.colorsAreLinear = true
                mesh.colors = stride(from: 0, to: colors.count - width + 1, by: width).map {
                    SIMD4(colors[$0], colors[$0 + 1], colors[$0 + 2], width == 4 ? colors[$0 + 3] : 1)
                }
            }
        }
        var indices = primitive["indices"] != nil ? (self.indices(primitive["indices"]) ?? []) : Array(0..<UInt32(mesh.positions.count))
        if mode == 5 {   // strip
            var triangles: [UInt32] = []
            for i in 0..<max(0, indices.count - 2) {
                triangles += i % 2 == 0 ? [indices[i], indices[i + 1], indices[i + 2]] : [indices[i + 1], indices[i], indices[i + 2]]
            }
            indices = triangles
        } else if mode == 6 {   // fan
            var triangles: [UInt32] = []
            for i in 1..<max(1, indices.count - 1) { triangles += [indices[0], indices[i], indices[i + 1]] }
            indices = triangles
        }
        mesh.indices = indices
        mesh.material = material(primitive["material"] as? Int)
        mesh.validate()
        return mesh.indices.isEmpty ? nil : mesh
    }

    // MARK: - Skins

    private mutating func skinMatrices(_ skinIndex: Int, worlds: [Int: simd_float4x4]) -> [simd_float4x4]? {
        let skins = document.array("skins")
        guard skins.indices.contains(skinIndex), let joints = skins[skinIndex]["joints"] as? [Int], !joints.isEmpty, joints.count <= 1024 else { return nil }
        let inverse = (skins[skinIndex]["inverseBindMatrices"] as? Int).flatMap { floats($0, components: 16) }
        return joints.enumerated().map { offset, joint in
            let world = worlds[joint] ?? matrix_identity_float4x4
            guard let inverse, inverse.count >= (offset + 1) * 16 else { return world }
            let m = Array(inverse[(offset * 16)..<(offset * 16 + 16)])
            let bind = simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                               SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
            return world * bind
        }
    }

    /// Linear blend skinning at rest: what animation-less viewers show.
    private mutating func applySkin(_ primitive: [String: Any], mesh: ModelMesh, joints: [simd_float4x4]) -> ModelMesh? {
        let attributes = primitive["attributes"] as? [String: Any] ?? [:]
        guard let indices = floats(attributes["JOINTS_0"], components: 4, normalize: false),
              let weights = floats(attributes["WEIGHTS_0"], components: 4),
              indices.count == mesh.positions.count * 4, weights.count == indices.count else { return nil }
        var result = mesh
        for v in mesh.positions.indices {
            var matrix = simd_float4x4()
            var total: Float = 0
            for k in 0..<4 {
                let weight = weights[v * 4 + k]
                let joint = Int(indices[v * 4 + k])
                guard weight > 0, joints.indices.contains(joint) else { continue }
                matrix += joints[joint] * weight
                total += weight
            }
            guard total > 0 else { continue }
            if total != 1 { matrix = matrix * (1 / total) }
            let p = matrix * SIMD4(mesh.positions[v], 1)
            result.positions[v] = SIMD3(p.x, p.y, p.z)
            if !mesh.normals.isEmpty {
                let n = matrix * SIMD4(mesh.normals[v], 0)
                let length = simd_length(SIMD3(n.x, n.y, n.z))
                result.normals[v] = length > 0 ? SIMD3(n.x, n.y, n.z) / length : mesh.normals[v]
            }
        }
        return result
    }

    // MARK: - Materials

    private mutating func material(_ index: Int?) -> ModelMaterial {
        guard let index else { return ModelMaterial() }
        if let cached = materials[index] { return cached }
        let all = document.array("materials")
        var material = ModelMaterial()
        guard all.indices.contains(index) else { return material }
        let json = all[index]
        let pbr = json["pbrMetallicRoughness"] as? [String: Any] ?? [:]
        if let factor = (pbr["baseColorFactor"] as? [NSNumber])?.map(\.floatValue), factor.count == 4, factor.allSatisfy(\.isFinite) {
            material.baseColor = SIMD4(factor[0], factor[1], factor[2], factor[3])
        } else {
            material.baseColor = SIMD4(1, 1, 1, 1)
        }
        material.metallic = (pbr["metallicFactor"] as? NSNumber)?.floatValue ?? 1
        material.roughness = (pbr["roughnessFactor"] as? NSNumber)?.floatValue ?? 1
        if let emissive = (json["emissiveFactor"] as? [NSNumber])?.map(\.floatValue), emissive.count == 3 {
            material.emissive = SIMD3(emissive[0], emissive[1], emissive[2])
        }
        material.doubleSided = json["doubleSided"] as? Bool ?? false
        if json["alphaMode"] as? String != "BLEND" { material.baseColor.w = 1 }
        if let texture = (pbr["baseColorTexture"] as? [String: Any])?["index"] as? Int {
            material.texture = image(forTexture: texture)
        }
        materials[index] = material
        return material
    }

    private mutating func image(forTexture index: Int) -> CGImage? {
        let textures = document.array("textures")
        guard textures.indices.contains(index) else { return nil }
        let texture = textures[index]
        let extensions = texture["extensions"] as? [String: Any] ?? [:]
        // WebP (EXT_texture_webp) decodes with ImageIO; KTX2 (KHR_texture_basisu) doesn't.
        let source = (extensions["EXT_texture_webp"] as? [String: Any])?["source"] as? Int ?? texture["source"] as? Int
        guard let source else { return nil }
        if let cached = images[source] { return cached }
        let all = document.array("images")
        var result: CGImage?
        if all.indices.contains(source) {
            let json = all[source]
            var data: Data?
            if let view = json["bufferView"] as? Int { data = bufferView(view)?.data }
            else if let uri = json["uri"] as? String { data = load(uri: uri, limit: 64 * 1024 * 1024) }
            if let data, let imageSource = CGImageSourceCreateWithData(data as CFData, nil) {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceThumbnailMaxPixelSize: Self.textureSide,
                                                kCGImageSourceShouldCacheImmediately: true]
                result = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
            }
        }
        images[source] = result
        return result
    }

    // MARK: - Buffers and accessors

    /// External files must sit beside the model (or below it): `../` and absolute paths are refused.
    private func load(uri: String, limit: Int) -> Data? {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"), uri.count < limit * 4 / 3 + 1024 else { return nil }
            return Data(base64Encoded: String(uri[uri.index(after: comma)...]), options: .ignoreUnknownCharacters)
        }
        guard !uri.contains("://"), let decoded = uri.removingPercentEncoding, !decoded.hasPrefix("/") else { return nil }
        let url = document.directory.appendingPathComponent(decoded).standardizedFileURL
        guard url.path.hasPrefix(document.directory.standardizedFileURL.path + "/"),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit else { return nil }
        return try? Data(contentsOf: url, options: .alwaysMapped)
    }

    private mutating func buffer(_ index: Int) -> Data? {
        if let cached = buffers[index] { return cached }
        let all = document.array("buffers")
        guard all.indices.contains(index) else { return nil }
        let json = all[index]
        var data: Data?
        if let uri = json["uri"] as? String { data = load(uri: uri, limit: Self.bufferLimit) }
        else if index == 0 { data = document.binaryChunk }
        if let data { buffers[index] = data }
        return data
    }

    private mutating func bufferView(_ index: Int) -> (data: Data, stride: Int?)? {
        let views = document.array("bufferViews")
        guard views.indices.contains(index) else { return nil }
        let view = views[index]
        guard let bufferIndex = view["buffer"] as? Int, let buffer = buffer(bufferIndex) else { return nil }
        let offset = view["byteOffset"] as? Int ?? 0
        let length = view["byteLength"] as? Int ?? 0
        guard offset >= 0, length >= 0, offset <= buffer.count, length <= buffer.count - offset else { return nil }
        let start = buffer.startIndex + offset
        return (buffer[start..<(start + length)], view["byteStride"] as? Int)
    }

    /// An accessor as floats, normalising integer types as glTF specifies.
    private mutating func floats(_ index: Any?, components: Int, normalize: Bool = true) -> [Float]? {
        guard let index = index as? Int, document.accessors.indices.contains(index) else { return nil }
        let accessor = document.accessors[index]
        let count = accessor["count"] as? Int ?? 0
        let type = accessor["componentType"] as? Int ?? 5126
        let normalized = normalize && (accessor["normalized"] as? Bool ?? false)
        let componentSize = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][type] ?? 0
        guard count > 0, count <= 50_000_000, componentSize > 0 else { return nil }
        // Accessors without data are all zeros (sparse ones aren't read); don't let one allocate much.
        guard let viewIndex = accessor["bufferView"] as? Int else {
            return count <= 1_000_000 ? [Float](repeating: 0, count: count * components) : nil
        }
        guard let (view, declaredStride) = bufferView(viewIndex) else { return nil }
        let offset = accessor["byteOffset"] as? Int ?? 0
        let elementSize = componentSize * components
        let stride = declaredStride ?? elementSize
        guard offset >= 0, stride >= elementSize, offset + stride * (count - 1) + elementSize <= view.count else { return nil }
        var result = [Float](repeating: 0, count: count * components)
        view.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for element in 0..<count {
                let base = offset + element * stride
                for c in 0..<components {
                    let at = base + c * componentSize
                    let value: Float
                    switch type {
                    case 5126: value = Float(bitPattern: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian)
                    case 5120: let v = Float(raw.load(fromByteOffset: at, as: Int8.self)); value = normalized ? max(v / 127, -1) : v
                    case 5121: let v = Float(raw[at]); value = normalized ? v / 255 : v
                    case 5122: let v = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: Int16.self))); value = normalized ? max(v / 32767, -1) : v
                    case 5123: let v = Float(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt16.self))); value = normalized ? v / 65535 : v
                    default: value = Float(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                    }
                    result[element * components + c] = value.isFinite ? value : 0
                }
            }
        }
        return result
    }

    private mutating func indices(_ index: Any?) -> [UInt32]? {
        guard let index = index as? Int, document.accessors.indices.contains(index) else { return nil }
        let accessor = document.accessors[index]
        let count = accessor["count"] as? Int ?? 0
        let type = accessor["componentType"] as? Int ?? 5125
        let size = [5121: 1, 5123: 2, 5125: 4][type] ?? 0
        guard count > 0, count <= 150_000_000, size > 0, let viewIndex = accessor["bufferView"] as? Int,
              let (view, _) = bufferView(viewIndex) else { return nil }
        let offset = accessor["byteOffset"] as? Int ?? 0
        guard offset >= 0, offset + count * size <= view.count else { return nil }
        var result = [UInt32](repeating: 0, count: count)
        view.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let at = offset + i * size
                switch size {
                case 1: result[i] = UInt32(raw[at])
                case 2: result[i] = UInt32(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)))
                default: result[i] = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                }
            }
        }
        return result
    }
}
