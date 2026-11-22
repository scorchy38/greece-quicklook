import Foundation
import CoreGraphics
import simd

/// Geometry Greece's Swift readers produce for thumbnails: triangle meshes with simple PBR
/// materials, or coloured points, already in world space.
struct ModelMaterial {
    var baseColor = SIMD4<Float>(0.8, 0.8, 0.8, 1)
    var metallic: Float = 0
    var roughness: Float = 0.6
    var emissive = SIMD3<Float>(0, 0, 0)
    var texture: CGImage?
    var doubleSided = false
}

struct ModelMesh {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var colors: [SIMD4<Float>] = []
    var indices: [UInt32] = []
    var material = ModelMaterial()

    var triangleCount: Int { indices.count / 3 }

    /// Moves the mesh into world space (normals with the inverse transpose).
    mutating func apply(_ matrix: simd_float4x4) {
        guard matrix != matrix_identity_float4x4 else { return }
        for index in positions.indices {
            let p = matrix * SIMD4(positions[index], 1)
            positions[index] = SIMD3(p.x, p.y, p.z)
        }
        if !normals.isEmpty {
            let upper = simd_float3x3(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                                      SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                                      SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
            let normalMatrix = upper.determinant == 0 ? upper : upper.inverse.transpose
            for index in normals.indices {
                let n = normalMatrix * normals[index]
                let length = simd_length(n)
                normals[index] = length > 0 ? n / length : n
            }
        }
        // Mirroring transforms flip the winding.
        if simd_determinant(matrix) < 0 {
            for triangle in Swift.stride(from: 0, to: indices.count - 2, by: 3) { indices.swapAt(triangle + 1, triangle + 2) }
        }
    }

    /// Smooth vertex normals from face normals, for formats that don't store any.
    mutating func computeNormals() {
        var sums = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for triangle in Swift.stride(from: 0, to: indices.count - 2, by: 3) {
            let a = Int(indices[triangle]), b = Int(indices[triangle + 1]), c = Int(indices[triangle + 2])
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            sums[a] += face; sums[b] += face; sums[c] += face
        }
        normals = sums.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    /// Drops triangles that point outside the vertex arrays.
    mutating func validate() {
        let count = UInt32(positions.count)
        if indices.contains(where: { $0 >= count }) {
            var kept: [UInt32] = []
            kept.reserveCapacity(indices.count)
            for triangle in Swift.stride(from: 0, to: indices.count - 2, by: 3)
            where indices[triangle] < count && indices[triangle + 1] < count && indices[triangle + 2] < count {
                kept.append(contentsOf: indices[triangle..<(triangle + 3)])
            }
            indices = kept
        }
        indices.removeLast(indices.count % 3)
        if !normals.isEmpty && normals.count != positions.count { normals = [] }
        if !uvs.isEmpty && uvs.count != positions.count { uvs = [] }
        if !colors.isEmpty && colors.count != positions.count { colors = [] }
    }
}

struct ModelPoints {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD3<Float>] = []
}

/// Everything a thumbnail draws.
struct ModelScene {
    var meshes: [ModelMesh] = []
    var points: ModelPoints?
    /// True for Z-up sources (CAD, printing, surveying): the renderer stands them upright.
    var zUp = false

    var bounds: Bounds {
        var box = Bounds()
        for mesh in meshes { for p in mesh.positions { box.add(p) } }
        if let points { for p in points.positions { box.add(p) } }
        return box
    }

    var isEmpty: Bool { meshes.allSatisfy { $0.indices.isEmpty } && (points?.positions.isEmpty ?? true) }
}

/// Limits every Swift reader honours so hostile files can't exhaust memory or time.
struct ModelBudget {
    var triangles = 2_000_000
    var points = 400_000
    var fileBytes = 512 * 1024 * 1024
    var deadline = Date().addingTimeInterval(4)

    var expired: Bool { Date() > deadline }
}
