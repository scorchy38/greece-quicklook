import AppKit
import SceneKit
import Metal
import CoreImage
import simd

/// Renders models offscreen with SceneKit for Finder thumbnails: a three-quarter view from slightly
/// above, studio lighting from a generated environment, and a soft contact shadow, on transparent
/// background so the model reads as the file's icon.
enum ModelRenderer {

    /// The neutral "clay" for files without materials (STL, OFF…), matching the preview.
    static let clay = NSColor(srgbRed: 0.66, green: 0.68, blue: 0.71, alpha: 1)

    // MARK: - Scenes from Greece's readers

    static func image(for model: ModelScene, pixels: Int) -> CGImage? {
        let content = SCNNode()
        for mesh in model.meshes where !mesh.indices.isEmpty {
            content.addChildNode(SCNNode(geometry: geometry(for: mesh)))
        }
        var isCloud = false
        if let points = model.points, !points.positions.isEmpty {
            content.addChildNode(SCNNode(geometry: geometry(for: points)))
            isCloud = model.meshes.isEmpty
        }
        return render(content, zUp: model.zUp, isCloud: isCloud, pixels: pixels)
    }

    static func geometry(for mesh: ModelMesh) -> SCNGeometry {
        var sources = [SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })]
        if !mesh.normals.isEmpty { sources.append(SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) })) }
        if !mesh.uvs.isEmpty, mesh.material.texture != nil {
            sources.append(SCNGeometrySource(textureCoordinates: mesh.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }))
        }
        if !mesh.colors.isEmpty {
            let data = mesh.colors.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: mesh.colors.count, usesFloatComponents: true,
                                             componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0,
                                             dataStride: MemoryLayout<SIMD4<Float>>.stride))
        }
        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: mesh.indices.count / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [material(for: mesh.material, vertexColors: !mesh.colors.isEmpty)]
        return geometry
    }

    static func material(for source: ModelMaterial, vertexColors: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        let color = source.baseColor
        if let texture = source.texture {
            material.diffuse.contents = NSImage(cgImage: texture, size: NSSize(width: texture.width, height: texture.height))
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            material.multiply.contents = NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        } else if vertexColors {
            material.diffuse.contents = NSColor.white
        } else {
            material.diffuse.contents = NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        }
        material.metalness.contents = NSNumber(value: source.metallic)
        material.roughness.contents = NSNumber(value: max(0.08, source.roughness))
        if source.emissive != .zero {
            material.emission.contents = NSColor(srgbRed: CGFloat(source.emissive.x), green: CGFloat(source.emissive.y), blue: CGFloat(source.emissive.z), alpha: 1)
        }
        if color.w < 0.999 {
            material.transparency = CGFloat(max(0.15, color.w))
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
        }
        material.isDoubleSided = true
        return material
    }

    static func geometry(for points: ModelPoints) -> SCNGeometry {
        let vertices = SCNGeometrySource(vertices: points.positions.map { SCNVector3($0.x, $0.y, $0.z) })
        let colors = points.colors.count == points.positions.count ? points.colors : points.positions.map { _ in SIMD3<Float>(0.6, 0.62, 0.66) }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                            componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                                            dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let indices = (0..<UInt32(points.positions.count)).map { $0 }
        let element = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .point,
                                         primitiveCount: indices.count, bytesPerIndex: 4)
        // Points as wide as the typical spacing between them, so sparse clouds still read as surfaces.
        var bounds = Bounds()
        for p in points.positions { bounds.add(p) }
        let extents = [bounds.size.x, bounds.size.y, bounds.size.z].sorted(by: >)
        let spacing = sqrt(max(extents[0] * extents[1], 1e-12) / Float(max(points.positions.count, 1)))
        element.pointSize = CGFloat(spacing * 1.3)
        element.minimumPointScreenSpaceRadius = 0.7
        element.maximumPointScreenSpaceRadius = 3
        let geometry = SCNGeometry(sources: [vertices, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        geometry.materials = [material]
        return geometry
    }

    // MARK: - Scenes SceneKit or ModelIO loaded

    /// Brings a loaded scene into the studio: lights and cameras go, plain materials become physically based.
    static func image(for loaded: SCNScene, zUp: Bool, clayWhenPlain: Bool, pixels: Int) -> CGImage? {
        let content = SCNNode()
        for child in loaded.rootNode.childNodes { content.addChildNode(child) }
        var triangles = 0
        content.enumerateHierarchy { node, _ in
            node.light = nil
            node.camera = nil
            guard let geometry = node.geometry else { return }
            for element in geometry.elements where element.primitiveType == .triangles { triangles += element.primitiveCount }
            geometry.materials = geometry.materials.map { studioMaterial(from: $0, geometry: geometry, clayWhenPlain: clayWhenPlain) }
            if geometry.materials.isEmpty { geometry.materials = [studioMaterial(from: SCNMaterial(), geometry: geometry, clayWhenPlain: true)] }
        }
        guard triangles > 0 else { return nil }
        return render(content, zUp: zUp, isCloud: false, pixels: pixels)
    }

    private static func studioMaterial(from original: SCNMaterial, geometry: SCNGeometry, clayWhenPlain: Bool) -> SCNMaterial {
        let material = original.copy() as? SCNMaterial ?? SCNMaterial()
        let hasColors = !geometry.sources(for: .color).isEmpty
        let contents = material.diffuse.contents
        let isPlain = contents == nil || ((contents as? NSColor).map { isDefaultWhite($0) } ?? false)
        if material.lightingModel != .physicallyBased {
            material.lightingModel = .physicallyBased
            material.metalness.contents = NSNumber(value: 0)
            material.roughness.contents = NSNumber(value: 0.55)
        }
        if isPlain && !hasColors && clayWhenPlain {
            material.diffuse.contents = clay
            material.roughness.contents = NSNumber(value: 0.48)
        }
        material.isDoubleSided = true
        return material
    }

    private static func isDefaultWhite(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent > 0.97 && rgb.greenComponent > 0.97 && rgb.blueComponent > 0.97
    }

    // MARK: - Studio

    static func render(_ content: SCNNode, zUp: Bool, isCloud: Bool, pixels: Int) -> CGImage? {
        guard pixels > 0, let device = MTLCreateSystemDefaultDevice() else { return nil }
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let pivot = SCNNode()
        if zUp { content.eulerAngles.x = -.pi / 2 }
        pivot.addChildNode(content)
        scene.rootNode.addChildNode(pivot)

        // Stand the model on the ground, centred.
        let (low, high) = pivot.boundingBox
        let size = SIMD3<Float>(Float(high.x - low.x), Float(high.y - low.y), Float(high.z - low.z))
        guard size.x.isFinite, size.y.isFinite, size.z.isFinite, max(size.x, size.y, size.z) > 0 else { return nil }
        let center = SIMD3<Float>(Float(low.x + high.x) / 2, Float(low.y + high.y) / 2, Float(low.z + high.z) / 2)
        pivot.position = SCNVector3(-center.x, isCloud ? -center.y : -Float(low.y), -center.z)
        let bounds = (min: SIMD3<Float>(-size.x / 2, isCloud ? -size.y / 2 : 0, -size.z / 2),
                      max: SIMD3<Float>(size.x / 2, isCloud ? size.y / 2 : size.y, size.z / 2))
        let radius = simd_length(size) / 2

        // Studio light: a soft environment, a key from upper left, and a contact shadow straight down.
        scene.lightingEnvironment.contents = studioEnvironment
        scene.lightingEnvironment.intensity = 1.25
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.eulerAngles = SCNVector3(-0.95, -0.55, 0)
        scene.rootNode.addChildNode(key)

        if !isCloud, let shadow = contactShadow(of: pivot, size: size, device: device) {
            scene.rootNode.addChildNode(shadow)
        }

        // Camera: three-quarter view, fitted tightly to the box.
        let camera = SCNCamera()
        camera.fieldOfView = 30
        let azimuth: Float = isCloud ? 0.45 : 0.56
        let elevation: Float = isCloud ? 0.62 : 0.36
        let direction = SIMD3<Float>(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
        let distance = fitDistance(min: bounds.min, max: bounds.max, direction: direction, fov: 30 * .pi / 180, aspect: 1, fill: isCloud ? 0.9 : 0.84)
        let target = (bounds.min + bounds.max) / 2
        let eye = target + direction * distance
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(eye.x, eye.y, eye.z)
        cameraNode.look(at: SCNVector3(target.x, target.y, target.z), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        camera.zNear = Double(max(distance - radius * 2, distance * 0.01))
        camera.zFar = Double(distance + radius * 3)
        camera.wantsHDR = false
        scene.rootNode.addChildNode(cameraNode)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// A soft shadow under the model: its base seen from below in black, blurred, laid on the ground
    /// (the same technique as the preview's contact shadow).
    static func contactShadow(of pivot: SCNNode, size: SIMD3<Float>, device: MTLDevice) -> SCNNode? {
        let extent = CGFloat(max(size.x, size.z) * 1.6 + size.y * 0.2)
        guard extent > 0, extent.isFinite else { return nil }
        let silhouette = SCNScene()
        silhouette.background.contents = NSColor.clear
        let black = SCNMaterial()
        black.lightingModel = .constant
        black.diffuse.contents = NSColor.black
        black.isDoubleSided = true
        let clone = pivot.clone()
        clone.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry?.copy() as? SCNGeometry else { return }
            geometry.materials = [black]
            node.geometry = geometry
        }
        silhouette.rootNode.addChildNode(clone)

        // Only the bottom of the model touches the ground, so only it casts the contact shadow.
        let reach = CGFloat(max(size.y * 0.3, Float(extent) * 0.03))
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(extent / 2)
        camera.zNear = Double(extent * 0.0005)
        camera.zFar = Double(extent * 0.001 + reach)
        let eye = SCNNode()
        eye.camera = camera
        eye.position = SCNVector3(0, -extent * 0.001, 0)
        eye.look(at: SCNVector3(0, 1, 0), up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        silhouette.rootNode.addChildNode(eye)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = silhouette
        renderer.pointOfView = eye
        let side = 192
        guard let raw = renderer.snapshot(atTime: 0, with: CGSize(width: side, height: side), antialiasingMode: .multisampling4X)
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // Seen from below, the image is mirrored left to right relative to the ground.
        let input = CIImage(cgImage: raw).oriented(.upMirrored)
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: Double(side) * 0.045]),
              let output = blur.outputImage?.cropped(to: input.extent),
              let blurred = CIContext(mtlDevice: device).createCGImage(output, from: input.extent) else { return nil }

        let plane = SCNPlane(width: extent, height: extent)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSImage(cgImage: blurred, size: NSSize(width: side, height: side))
        material.transparency = 0.5
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position.y = extent * 0.0002
        node.renderingOrder = -1
        node.castsShadow = false
        return node
    }

    /// The camera distance at which every corner of the box fits, filling `fill` of the frame.
    static func fitDistance(min low: SIMD3<Float>, max high: SIMD3<Float>, direction: SIMD3<Float>, fov: Float, aspect: Float, fill: Float) -> Float {
        let forward = simd_normalize(direction)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        let up = simd_cross(forward, right)
        let center = (low + high) / 2
        let tanV = tan(fov / 2) * fill
        let tanH = tanV * aspect
        var distance: Float = 0
        for i in 0..<8 {
            let corner = SIMD3<Float>(i & 1 == 0 ? low.x : high.x, i & 2 == 0 ? low.y : high.y, i & 4 == 0 ? low.z : high.z) - center
            let x = simd_dot(corner, right), y = simd_dot(corner, up), z = simd_dot(corner, forward)
            distance = Swift.max(distance, z + abs(x) / tanH, z + abs(y) / tanV)
        }
        return Swift.max(distance, simd_length(high - low) * 0.25)
    }

    /// An equirectangular studio: a bright ceiling, two soft boxes, a darker floor.
    static let studioEnvironment: CGImage? = {
        let width = 512, height = 256
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let sky = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1), CGColor(srgbRed: 0.82, green: 0.83, blue: 0.85, alpha: 1),
            CGColor(srgbRed: 0.55, green: 0.56, blue: 0.58, alpha: 1), CGColor(srgbRed: 0.3, green: 0.3, blue: 0.32, alpha: 1),
        ] as CFArray, locations: [0, 0.42, 0.55, 1])!
        // CoreGraphics' origin is bottom-left: the top of the image is the zenith.
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        func softBox(_ rect: CGRect, _ brightness: CGFloat) {
            let glow = CGGradient(colorsSpace: space, colors: [CGColor(gray: brightness, alpha: 1), CGColor(gray: brightness, alpha: 0)] as CFArray, locations: [0.35, 1])!
            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: rect.width / rect.height, y: 1)
            context.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rect.height / 2, options: [])
            context.restoreGState()
        }
        softBox(CGRect(x: 60, y: 160, width: 150, height: 60), 1)
        softBox(CGRect(x: 330, y: 150, width: 110, height: 50), 0.9)
        softBox(CGRect(x: 220, y: 215, width: 140, height: 40), 1)
        return context.makeImage()
    }()
}
