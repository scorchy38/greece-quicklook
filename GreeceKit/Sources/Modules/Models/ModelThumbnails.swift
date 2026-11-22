import AppKit
import SceneKit
import ModelIO
import SceneKit.ModelIO
import simd

/// Finder thumbnails for models and point clouds: each format's geometry, rendered by `ModelRenderer`.
enum ModelThumbnails {
    /// Files larger than this keep their icon: reading them would take too long for a thumbnail.
    static let fileLimit = 400 * 1024 * 1024
    /// ModelIO parses in one call that can't be interrupted, so it gets a tighter limit.
    static let modelIOLimit = 120 * 1024 * 1024

    static func page(_ file: FileInfo, format: ModelFormat, size: CGSize) -> ThumbnailPage? {
        guard let fileSize = file.fileSize, fileSize > 0, fileSize <= fileLimit else { return nil }
        let side = max(16, min(size.width, size.height)).rounded()
        let pixels = Int(min(1024, side * 2))
        guard let image = render(file.url, format: format, fileSize: fileSize, pixels: pixels) else { return nil }
        return ThumbnailPage(size: CGSize(width: side, height: side), badge: format.badge) { rect in
            NSGraphicsContext.current?.cgContext.draw(image, in: rect)
        }
    }

    static func render(_ url: URL, format: ModelFormat, fileSize: Int, pixels: Int) -> CGImage? {
        let budget = ModelBudget()
        switch format {
        case .gltf, .glb:
            return GLTFSceneReader.load(url: url, budget: budget).flatMap { ModelRenderer.image(for: $0, pixels: pixels) }
        case .threeMF:
            return ThreeMFPackage.load(url, budget: budget).flatMap { ModelRenderer.image(for: $0, pixels: pixels) }
        case .stl:
            return STLReader.load(url, budget: budget).flatMap { ModelRenderer.image(for: $0, pixels: pixels) }
        case .off:
            return OFFReader.load(url, budget: budget).flatMap { ModelRenderer.image(for: $0, pixels: pixels) }
        case .vox:
            return VOXReader.load(url, budget: budget).flatMap { ModelRenderer.image(for: $0, pixels: pixels) }
        case .fbx:
            return FBXReader.load(url, budget: budget).flatMap { ModelRenderer.image(for: $0, pixels: pixels) }
        case .las:
            return lasPoints(url, budget: budget).flatMap { ModelRenderer.image(for: $0, pixels: pixels) }
        case .obj, .ply:
            guard fileSize <= modelIOLimit, let scene = modelIOScene(url) else { return nil }
            return ModelRenderer.image(for: scene, zUp: false, clayWhenPlain: true, pixels: pixels)
        case .collada:
            // SceneKit won't open COLLADA by path from here ("operation not permitted"), but reads it from memory.
            guard fileSize <= modelIOLimit, let data = try? Data(contentsOf: url) else { return nil }
            let options: [SCNSceneSource.LoadingOption: Any] = [.convertToYUp: true, .createNormalsIfAbsent: true,
                                                                 .assetDirectoryURLs: [url.deletingLastPathComponent()],
                                                                 .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay]
            guard let source = SCNSceneSource(data: data, options: options), let scene = try? source.scene(options: options) else { return nil }
            return ModelRenderer.image(for: scene, zUp: false, clayWhenPlain: true, pixels: pixels)
        case .threeDS, .vrml, .amf, .laz, .pcd:
            return nil
        }
    }

    /// OBJ (with its MTL and textures) and PLY (with vertex colours), read by ModelIO.
    static func modelIOScene(_ url: URL) -> SCNScene? {
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { return nil }
        asset.loadTextures()
        return SCNScene(mdlAsset: asset)
    }

    static func lasPoints(_ url: URL, budget: ModelBudget) -> ModelScene? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let las = try? LASFile(data: data), !las.header.isCompressed else { return nil }
        let sample = las.sample(data, budget: budget.points, deadline: budget.deadline)
        guard sample.count > 0 else { return nil }
        var points = ModelPoints()
        points.positions.reserveCapacity(sample.count)
        for i in 0..<sample.count {
            points.positions.append(SIMD3<Float>(sample.positions[i * 3], sample.positions[i * 3 + 1], sample.positions[i * 3 + 2]))
        }
        let hasColor = !sample.colors.isEmpty && Set(sample.colors.prefix(3000)).count > 1
        if hasColor {
            points.colors.reserveCapacity(sample.count)
            for i in 0..<sample.count {
                let rgb = SIMD3<Float>(Float(sample.colors[i * 3]), Float(sample.colors[i * 3 + 1]), Float(sample.colors[i * 3 + 2]))
                points.colors.append(rgb / 255)
            }
        } else {
            points.colors = ElevationRamp.colors(heights: points.positions.map(\.z))
        }
        return ModelScene(points: points, zUp: true)
    }
}

/// The page's elevation colours, low to high: deep blue, teal, green, sand, orange, red.
enum ElevationRamp {
    static let stops: [SIMD3<Float>] = {
        let bytes: [[Float]] = [[44, 90, 160], [42, 157, 143], [138, 201, 38], [244, 211, 94], [238, 150, 75], [209, 73, 91]]
        return bytes.map { SIMD3<Float>($0[0], $0[1], $0[2]) / 255 }
    }()

    static func colors(heights: [Float]) -> [SIMD3<Float>] {
        let sorted = heights.filter(\.isFinite).sorted()
        guard let first = sorted.first else { return [] }
        let low = sorted[Int(Float(sorted.count - 1) * 0.01)], high = sorted[Int(Float(sorted.count - 1) * 0.99)]
        let span = max(high - low, 1e-6)
        _ = first
        return heights.map { height in
            let t = min(1, max(0, (height - low) / span)) * Float(stops.count - 1)
            let k = min(stops.count - 2, Int(t))
            return simd_mix(stops[k], stops[k + 1], SIMD3(repeating: t - Float(k)))
        }
    }
}

// MARK: - STL

enum STLReader {
    static func load(_ url: URL, budget: ModelBudget) -> ModelScene? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        var mesh = ModelMesh()
        if data.count >= 84, 84 + Int(data.u32(80)) * 50 == data.count {
            let count = min(Int(data.u32(80)), budget.triangles)
            mesh.positions.reserveCapacity(count * 3)
            data.withUnsafeBytes { raw in
                for t in 0..<count {
                    let base = 84 + t * 50 + 12
                    for corner in 0..<3 {
                        let at = base + corner * 12
                        mesh.positions.append(SIMD3(Float(bitPattern: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian),
                                                    Float(bitPattern: raw.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self).littleEndian),
                                                    Float(bitPattern: raw.loadUnaligned(fromByteOffset: at + 8, as: UInt32.self).littleEndian)))
                    }
                }
            }
        } else {
            // ASCII: every "vertex x y z" line.
            var tokens = 0
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                tokens += 1
                if tokens & 0xFFFF == 0, budget.expired { break }
                let words = line.split(whereSeparator: \.isWhitespace)
                guard words.count == 4, words[0] == "vertex", let x = Float(words[1]), let y = Float(words[2]), let z = Float(words[3]) else { continue }
                mesh.positions.append(SIMD3(x, y, z))
                if mesh.positions.count >= budget.triangles * 3 { break }
            }
            mesh.positions.removeLast(mesh.positions.count % 3)
        }
        guard !mesh.positions.isEmpty else { return nil }
        mesh.positions = mesh.positions.map { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite ? $0 : .zero }
        mesh.indices = Array(0..<UInt32(mesh.positions.count))
        mesh.computeFlatNormals()
        mesh.material.baseColor = SIMD4(0.66, 0.68, 0.71, 1)
        mesh.material.roughness = 0.48
        return ModelScene(meshes: [mesh], zUp: true)
    }
}

extension ModelMesh {
    /// Faceted normals for unshared triangles (STL, OFF): each corner takes its face's normal.
    mutating func computeFlatNormals() {
        normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: positions.count)
        for t in Swift.stride(from: 0, to: indices.count - 2, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            let unit = simd_length(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 1, 0)
            normals[a] = unit; normals[b] = unit; normals[c] = unit
        }
    }
}

// MARK: - OFF

enum OFFReader {
    static func load(_ url: URL, budget: ModelBudget) -> ModelScene? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count <= 256 * 1024 * 1024 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
            .filter { !$0.isEmpty }
        guard var header = lines.first?.split(whereSeparator: \.isWhitespace).map(String.init), let keyword = header.first, keyword.hasSuffix("OFF") else { return nil }
        header.removeFirst()
        var cursor = 1
        var counts = header.compactMap { Int($0) }
        while counts.count < 2, cursor < lines.count {
            counts += lines[cursor].split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            cursor += 1
        }
        guard counts.count >= 2, counts[0] > 0, counts[0] <= 20_000_000, counts[1] >= 0 else { return nil }
        let vertexCount = counts[0], faceCount = counts[1]
        let skip = (keyword.contains("N") ? 3 : 0)
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(min(vertexCount, 1_000_000))
        while vertices.count < vertexCount, cursor < lines.count {
            let numbers = lines[cursor].split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
            cursor += 1
            guard numbers.count >= 3 else { continue }
            vertices.append(SIMD3(numbers[0], numbers[1], numbers[2]))
            _ = skip
        }
        var mesh = ModelMesh()
        var faces = 0
        var anyColor = false
        while faces < faceCount, cursor < lines.count, mesh.positions.count < budget.triangles * 3 {
            let words = lines[cursor].split(whereSeparator: \.isWhitespace)
            cursor += 1
            faces += 1
            guard let n = words.first.flatMap({ Int($0) }), n >= 3, n < 1000, words.count >= n + 1 else { continue }
            let ids = words[1...n].compactMap { Int($0) }
            guard ids.count == n, ids.allSatisfy({ $0 >= 0 && $0 < vertices.count }) else { continue }
            let extra = words.dropFirst(n + 1).compactMap { Float($0) }
            var color = SIMD4<Float>(0.66, 0.68, 0.71, 1)
            if extra.count >= 3 {
                let scale: Float = extra.prefix(3).contains { $0 > 1 } ? 1 / 255 : 1
                color = SIMD4(extra[0] * scale, extra[1] * scale, extra[2] * scale, 1)
                anyColor = true
            }
            for k in 1..<(n - 1) {
                for id in [ids[0], ids[k], ids[k + 1]] {
                    mesh.positions.append(vertices[id])
                    mesh.colors.append(color)
                }
            }
        }
        guard !mesh.positions.isEmpty else { return nil }
        if !anyColor { mesh.colors = []; mesh.material.baseColor = SIMD4(0.66, 0.68, 0.71, 1) }
        mesh.indices = Array(0..<UInt32(mesh.positions.count))
        mesh.computeFlatNormals()
        mesh.material.roughness = 0.5
        return ModelScene(meshes: [mesh])
    }
}

// MARK: - MagicaVoxel

enum VOXReader {
    static func load(_ url: URL, budget: ModelBudget) -> ModelScene? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 20, data.u32(0) == 0x2058_4F56 else { return nil }
        var size: (Int, Int, Int)?
        var voxels: [(x: Int, y: Int, z: Int, color: Int)] = []
        var palette = (0..<256).map { _ in SIMD4<Float>(0.7, 0.7, 0.7, 1) }
        var offset = 8
        var steps = 0
        while offset + 12 <= data.count, steps < 100_000 {
            steps += 1
            let id = data.u32(offset)
            let content = Int(data.u32(offset + 4)), children = Int(data.u32(offset + 8))
            let body = offset + 12
            if id == 0x4E49_414D { offset = body; continue }   // MAIN: its children follow
            guard content >= 0, children >= 0, body + content <= data.count else { break }
            switch id {
            case 0x455A_4953 where content >= 12 && size == nil:   // SIZE
                size = (Int(data.u32(body)), Int(data.u32(body + 4)), Int(data.u32(body + 8)))
            case 0x495A_5958 where voxels.isEmpty:   // XYZI (first model only)
                let count = min(Int(data.u32(body)), (content - 4) / 4, 4_000_000)
                for i in 0..<max(0, count) {
                    let at = body + 4 + i * 4
                    voxels.append((Int(data[at]), Int(data[at + 1]), Int(data[at + 2]), Int(data[at + 3])))
                }
            case 0x4142_4752 where content >= 1024:   // RGBA
                for i in 0..<255 {
                    let at = body + i * 4
                    palette[i + 1] = SIMD4(Float(data[at]), Float(data[at + 1]), Float(data[at + 2]), 255) / 255
                }
            default:
                break
            }
            offset = body + content + children
        }
        guard !voxels.isEmpty else { return nil }
        // Only faces between a voxel and empty space are visible.
        var occupied = Set<Int>()
        func key(_ x: Int, _ y: Int, _ z: Int) -> Int { (x & 0x3FF) | (y & 0x3FF) << 10 | (z & 0x3FF) << 20 }
        for v in voxels { occupied.insert(key(v.x, v.y, v.z)) }
        var mesh = ModelMesh()
        let directions: [(SIMD3<Int>, [SIMD3<Float>])] = [
            (SIMD3(1, 0, 0), [SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(1, 1, 1), SIMD3(1, 0, 1)]),
            (SIMD3(-1, 0, 0), [SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(0, 1, 0)]),
            (SIMD3(0, 1, 0), [SIMD3(0, 1, 0), SIMD3(0, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, 0)]),
            (SIMD3(0, -1, 0), [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1)]),
            (SIMD3(0, 0, 1), [SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]),
            (SIMD3(0, 0, -1), [SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(1, 0, 0)]),
        ]
        for v in voxels {
            if mesh.positions.count > budget.triangles * 2 { break }
            let color = palette[min(255, max(0, v.color))]
            for (normal, corners) in directions where !occupied.contains(key(v.x + normal.x, v.y + normal.y, v.z + normal.z)) {
                let base = UInt32(mesh.positions.count)
                for corner in corners {
                    mesh.positions.append(SIMD3(Float(v.x), Float(v.y), Float(v.z)) + corner)
                    mesh.normals.append(SIMD3(Float(normal.x), Float(normal.y), Float(normal.z)))
                    mesh.colors.append(color)
                }
                mesh.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }
        mesh.material.roughness = 0.7
        _ = size
        return ModelScene(meshes: [mesh], zUp: true)
    }
}
