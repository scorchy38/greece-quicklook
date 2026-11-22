import Foundation

/// The 3D model and point-cloud formats Greece previews, identified by extension and bytes.
///
/// USDZ, USD, Reality, SceneKit and Alembic files stay with macOS: its own viewers already render
/// them well. See `docs/MODULES.md` and the models section of the README for the reasoning.
enum ModelFormat: String, CaseIterable, Sendable {
    case gltf, glb, fbx, threeMF = "3mf", collada = "dae", obj, stl, ply, off, threeDS = "3ds", vrml, amf, vox
    case las, laz, pcd

    var isPointCloud: Bool { self == .las || self == .laz || self == .pcd }

    /// What the info bar calls the file.
    var title: String {
        switch self {
        case .gltf: return "glTF Model"
        case .glb: return "glTF Binary Model"
        case .fbx: return "FBX Model"
        case .threeMF: return "3MF Model"
        case .collada: return "COLLADA Model"
        case .obj: return "OBJ Model"
        case .stl: return "STL Model"
        case .ply: return "PLY Model"
        case .off: return "OFF Model"
        case .threeDS: return "3DS Model"
        case .vrml: return "VRML World"
        case .amf: return "AMF Model"
        case .vox: return "MagicaVoxel Model"
        case .las: return "LAS Point Cloud"
        case .laz: return "LAZ Point Cloud"
        case .pcd: return "PCD Point Cloud"
        }
    }

    var symbol: String { isPointCloud ? "circle.dotted.circle" : "cube" }

    /// The Finder thumbnail badge.
    var badge: String {
        switch self {
        case .collada: return "DAE"
        case .vrml: return "WRL"
        default: return rawValue.uppercased()
        }
    }

    /// The bundled three.js loader script the page needs (LAS needs none: Swift samples its points).
    var loaderScript: String? {
        switch self {
        case .gltf, .glb: return "gltf"
        case .fbx: return "fbx"
        case .threeMF: return "3mf"
        case .collada: return "collada"
        case .obj: return "obj"
        case .stl: return "stl"
        case .ply: return "ply"
        case .threeDS: return "3ds"
        case .vrml: return "vrml"
        case .amf: return "amf"
        case .vox: return "vox"
        case .pcd: return "pcd"
        case .off, .las, .laz: return nil
        }
    }

    /// Formats whose decoders are WebAssembly (Draco, Meshopt, Basis for glTF; LASzip for LAZ).
    var needsWasm: Bool { self == .gltf || self == .glb || self == .laz }

    /// Formats that are Z-up by convention (CAD, 3D printing, surveying); the page turns them upright.
    var isZUp: Bool {
        switch self {
        case .stl, .threeMF, .amf, .threeDS, .vox, .las, .laz, .pcd: return true
        default: return false
        }
    }

    // MARK: - Detection

    /// The format of a file, or nil. Cheap: extension plus the first 8 KB.
    static func detect(_ file: FileInfo) -> ModelFormat? {
        guard !file.isDirectory else { return nil }
        return detect(ext: file.ext, probe: file.probe.bytes, fileSize: file.fileSize)
    }

    static func detect(ext: String, probe bytes: [UInt8], fileSize: Int?) -> ModelFormat? {
        func starts(_ prefix: String) -> Bool { starts(Array(prefix.utf8)) }
        func starts(_ prefix: [UInt8]) -> Bool { bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix }
        let isText = FileProbe(bytes: bytes).isText
        lazy var text = String(decoding: bytes, as: UTF8.self)
        lazy var trimmed = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

        switch ext {
        case "glb", "vrm":
            return starts("glTF") ? .glb : nil
        case "gltf":
            if starts("glTF") { return .glb }
            return isText && trimmed.hasPrefix("{") ? .gltf : nil
        case "fbx":
            if starts("Kaydara FBX Binary") { return .fbx }
            return isText && (text.contains("FBXHeaderExtension") || text.contains("FBXVersion") || trimmed.hasPrefix("; FBX")) ? .fbx : nil
        case "3mf":
            return starts(zip) ? .threeMF : nil
        case "dae":
            return isText && text.contains("<COLLADA") ? .collada : nil
        case "obj":
            return isText && looksLikeOBJ(text) ? .obj : nil
        case "stl":
            return looksLikeSTL(bytes, fileSize: fileSize) ? .stl : nil
        case "ply":
            return starts("ply\n") || starts("ply\r\n") ? .ply : nil
        case "off":
            guard isText, let first = trimmed.split(whereSeparator: \.isNewline).first else { return nil }
            let keyword = first.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            return ["OFF", "COFF", "NOFF", "CNOFF", "STOFF", "STCOFF", "NCOFF"].contains(keyword) ? .off : nil
        case "3ds":
            // The main chunk (0x4D4D) whose length is plausible for the file.
            guard bytes.count >= 16, bytes[0] == 0x4D, bytes[1] == 0x4D else { return nil }
            let length = Int(bytes[2]) | Int(bytes[3]) << 8 | Int(bytes[4]) << 16 | Int(bytes[5]) << 24
            return length >= 6 && (fileSize.map { length <= $0 + 1024 } ?? true) ? .threeDS : nil
        case "wrl", "vrml":
            return starts("#VRML V2.0") ? .vrml : nil
        case "amf":
            if starts(zip) { return .amf }
            return isText && text.contains("<amf") ? .amf : nil
        case "vox":
            return starts("VOX ") ? .vox : nil
        case "las", "laz":
            guard starts("LASF"), bytes.count > 104 else { return nil }
            // LASzip marks compressed files by setting the top bits of the point format.
            let compressed = bytes[104] & 0xC0 != 0
            return compressed || ext == "laz" ? .laz : .las
        case "pcd":
            guard isText || text.contains("DATA binary") else { return nil }
            return text.contains("FIELDS") && text.contains("POINTS") ? .pcd : nil
        default:
            return nil
        }
    }

    /// Wavefront OBJ is plain text made of short keyword lines (`v`, `vn`, `f`, `o`…).
    static func looksLikeOBJ(_ text: String) -> Bool {
        var statements = 0
        for line in text.split(whereSeparator: \.isNewline).prefix(400) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let keyword = trimmed.prefix { $0 != " " && $0 != "\t" }
            if ["v", "vt", "vn", "vp", "f", "l", "p", "o", "g", "s", "usemtl", "mtllib"].contains(String(keyword)) {
                statements += 1
                if statements >= 3 { return true }
            } else {
                return false
            }
        }
        return statements > 0
    }

    /// Binary STL has an 80-byte header, a triangle count and 50 bytes per triangle; ASCII STL starts with `solid`.
    static func looksLikeSTL(_ bytes: [UInt8], fileSize: Int?) -> Bool {
        if bytes.count >= 84, let fileSize {
            let count = Int(bytes[80]) | Int(bytes[81]) << 8 | Int(bytes[82]) << 16 | Int(bytes[83]) << 24
            if 84 + count * 50 == fileSize { return true }
        }
        let text = String(decoding: bytes.prefix(512), as: UTF8.self).drop { $0.isWhitespace }
        return FileProbe(bytes: bytes).isText && text.hasPrefix("solid") && (text.contains("facet") || bytes.count < 512)
    }
}
