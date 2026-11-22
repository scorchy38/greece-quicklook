import XCTest
import simd
@testable import GreeceKit

/// 3D models and point clouds: detection, facts, point sampling, readers, thumbnails and hostile input.
final class ModelsTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/models")

    private func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    private func temporary(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("greece-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    private func format(_ name: String) -> ModelFormat? { ModelFormat.detect(FileInfo(url: fixture(name))) }

    // MARK: - Detection

    func testFixturesAreDetected() {
        let expected: [(String, ModelFormat)] = [
            ("fox.glb", .glb), ("glass.glb", .glb), ("box-textured/BoxTextured.gltf", .gltf), ("milk-truck-draco/CesiumMilkTruck.gltf", .gltf),
            ("windmill.fbx", .fbx), ("windmill-binary.fbx", .fbx), ("bracket.3mf", .threeMF), ("lamp.dae", .collada),
            ("pawn/pawn.obj", .obj), ("gear.stl", .stl), ("ziggurat.stl", .stl), ("vase.ply", .ply), ("icosahedron.off", .off),
            ("table.3ds", .threeDS), ("primitives.wrl", .vrml), ("tree.vox", .vox), ("terrain.las", .las), ("hillside.laz", .laz),
            ("knot.pcd", .pcd),
        ]
        for (name, kind) in expected {
            XCTAssertEqual(format(name), kind, name)
            XCTAssertEqual(FileKind.detect(fixture(name)), .module(ModelsModule.id), name)
        }
    }

    func testOnlyClaimsWhatTheBytesConfirm() throws {
        // A Windows object file, a JSON file that isn't glTF, a text file posing as binary formats.
        XCTAssertNil(format("hostile/coff.obj"))
        XCTAssertNil(ModelFormat.detect(ext: "gltf", probe: Array("not json".utf8), fileSize: 8))
        XCTAssertNil(ModelFormat.detect(ext: "glb", probe: Array("{\"asset\":{}}".utf8), fileSize: 12))
        XCTAssertNil(ModelFormat.detect(ext: "fbx", probe: Array("hello world".utf8), fileSize: 11))
        XCTAssertNil(ModelFormat.detect(ext: "3mf", probe: Array("PK not really".utf8).dropFirst(2).map { $0 }, fileSize: 11))
        XCTAssertNil(ModelFormat.detect(ext: "ply", probe: Array("plyx".utf8), fileSize: 4))
        XCTAssertNil(ModelFormat.detect(ext: "las", probe: Array("LASF".utf8), fileSize: 4))
        XCTAssertNil(ModelFormat.detect(ext: "dae", probe: Array("<html></html>".utf8), fileSize: 13))
        XCTAssertNil(ModelFormat.detect(ext: "obj", probe: Array("hello there\nthis is prose\n".utf8), fileSize: 26))
        XCTAssertNil(ModelFormat.detect(ext: "vox", probe: Array("VOXX".utf8), fileSize: 4))
        // A binary STL whose triangle count doesn't match its size, and isn't ASCII either.
        XCTAssertNil(format("hostile/lying.stl"))
        // Formats that stay with macOS.
        for name in ["model.usdz", "scene.scn", "model.usda", "anim.abc"] {
            XCTAssertNil(ModelFormat.detect(ext: (name as NSString).pathExtension, probe: Array("#usda 1.0".utf8), fileSize: 9), name)
        }
        // Binary STL that starts with "solid" is still binary when its size adds up.
        var header = Array("solid but binary".utf8) + [UInt8](repeating: 0x20, count: 64)
        header += [1, 0, 0, 0] + [UInt8](repeating: 0, count: 50)
        XCTAssertEqual(ModelFormat.detect(ext: "stl", probe: header, fileSize: header.count), .stl)
        // LAS whose point format has LASzip's compression bit set is LAZ, whatever its extension.
        var las = [UInt8](repeating: 0, count: 227)
        las.replaceSubrange(0..<4, with: Array("LASF".utf8))
        las[104] = 0x83
        XCTAssertEqual(ModelFormat.detect(ext: "las", probe: las, fileSize: 227), .laz)
        _ = try temporary("x.bin", [0])
    }

    func testOBJHeuristic() {
        XCTAssertTrue(ModelFormat.looksLikeOBJ("# exported\nmtllib a.mtl\nv 0 0 0\nv 1 0 0\nf 1 2 3\n"))
        XCTAssertTrue(ModelFormat.looksLikeOBJ("\n\n   v 1 2 3"))
        XCTAssertFalse(ModelFormat.looksLikeOBJ("function main() {}\n"))
    }

    // MARK: - Facts

    func testGLTFFacts() throws {
        let fox = ModelFacts.read(.glb, url: fixture("fox.glb"))
        XCTAssertEqual(fox.triangles, 576)
        XCTAssertEqual(fox.animations, 3)
        XCTAssertEqual(fox.units, "m")
        XCTAssertEqual(fox.textures, 1)
        let box = ModelFacts.read(.gltf, url: fixture("box-textured/BoxTextured.gltf"))
        XCTAssertEqual(box.triangles, 12)
        XCTAssertEqual(box.size?.map { ($0 * 1000).rounded() / 1000 }, [1, 1, 1])
        let truck = ModelFacts.read(.gltf, url: fixture("milk-truck-draco/CesiumMilkTruck.gltf"))
        XCTAssertEqual(truck.compression, ["Draco"])
        XCTAssertEqual(truck.triangles, 3624)
        let meshopt = ModelFacts.read(.glb, url: fixture("fox-meshopt.glb"))
        XCTAssertTrue(meshopt.compression.contains("Meshopt"))
        XCTAssertEqual(meshopt.triangles, 576)
        // Quantised positions are scaled by their nodes: the fox keeps its size.
        for (packed, original) in zip(meshopt.size ?? [], fox.size ?? []) { XCTAssertEqual(packed, original, accuracy: 1) }
        XCTAssertEqual(meshopt.size?.count, 3)
    }

    func testMeshFacts() {
        let gear = ModelFacts.read(.stl, url: fixture("gear.stl"))
        XCTAssertEqual(gear.triangles, 1440)
        XCTAssertEqual(gear.size?.map { $0.rounded() }, [40, 40, 6])
        XCTAssertNil(gear.units)
        XCTAssertEqual(ModelFacts.read(.stl, url: fixture("ziggurat.stl")).triangles, 48)
        let bracket = ModelFacts.read(.threeMF, url: fixture("bracket.3mf"))
        XCTAssertEqual(bracket.units, "mm")
        XCTAssertEqual(bracket.size?.map { $0.rounded() }, [40, 20, 30])
        XCTAssertEqual(bracket.generator, "Greece fixture generator")
        let pawn = ModelFacts.read(.obj, url: fixture("pawn/pawn.obj"))
        XCTAssertEqual(pawn.materials, 2)
        XCTAssertEqual(pawn.meshes, 2)
        XCTAssertEqual(pawn.size?.map { $0.rounded() }, [14, 13, 14])
        let vase = ModelFacts.read(.ply, url: fixture("vase.ply"))
        XCTAssertEqual(vase.vertices, 3505)
        XCTAssertEqual(vase.faces, 3456)
        XCTAssertEqual(ModelFacts.read(.off, url: fixture("icosahedron.off")).faces, 20)
        XCTAssertEqual(ModelFacts.read(.collada, url: fixture("lamp.dae")).units, "cm")
        XCTAssertEqual(ModelFacts.read(.fbx, url: fixture("windmill-binary.fbx")).version, "7.4")
        XCTAssertEqual(ModelFacts.read(.fbx, url: fixture("windmill.fbx")).version, "7.4")
        let vox = ModelFacts.read(.vox, url: fixture("tree.vox"))
        XCTAssertEqual(vox.size, [16, 16, 16])
        XCTAssertGreaterThan(vox.voxels ?? 0, 256)
    }

    func testInfoBarDetails() {
        var facts = ModelFacts()
        facts.triangles = 12_480
        facts.materials = 3
        facts.animations = 1
        facts.size = [0.243, 0.091, 0.18]
        facts.units = "m"
        // glTF is Y-up: width × depth × height reorders y and z.
        XCTAssertEqual(facts.details(format: .glb), ["12,480 triangles", "3 materials", "1 animation", "24.3 × 18 × 9.1 cm"])
        XCTAssertEqual(ModelFacts.dimensions([1200, 30.25, 4], units: "mm"), "1,200 × 30 × 4 mm")
        XCTAssertEqual(ModelFacts.dimensions([0.004, 0.002, 0.001], units: "m"), "4 × 2 × 1 mm")
        XCTAssertNil(ModelFacts.dimensions([0, 0, 0], units: "m"))
        XCTAssertNil(ModelFacts.dimensions([.nan, 1, 1], units: nil))
        XCTAssertEqual(ModelFacts.unitSymbol(metres: 0.0254), "in")
        XCTAssertNil(ModelFacts.unitSymbol(metres: 0.5))
    }

    // MARK: - Point clouds

    func testLASHeaderAndUnits() throws {
        let las = try LASFile(url: fixture("terrain.las"))
        XCTAssertEqual(las.header.pointCount, 15_000)
        XCTAssertEqual(las.header.pointFormat, 2)
        XCTAssertTrue(las.header.hasRGB)
        XCTAssertFalse(las.header.isCompressed)
        XCTAssertEqual(las.units, LASFile.Units(horizontal: "m", geographic: false))
        let facts = ModelFacts.read(.las, url: fixture("terrain.las"))
        XCTAssertEqual(facts.points, 15_000)
        XCTAssertEqual(facts.size?.map { $0.rounded() }, [140, 140, 32])

        let laz = try LASFile(url: fixture("hillside.laz"))
        XCTAssertTrue(laz.header.isCompressed)
        XCTAssertEqual(laz.header.pointFormat, 7)
        XCTAssertEqual(laz.header.pointCount, 25_000)
        XCTAssertEqual(laz.header.versionMinor, 4)

        XCTAssertEqual(LASFile.wktUnits("PROJCS[\"NAD83 / foo\",UNIT[\"US survey foot\",0.3048006]]")?.horizontal, "US ft")
        XCTAssertEqual(LASFile.wktUnits("GEOGCS[\"WGS 84\"]")?.geographic, true)
    }

    func testLASSampleIsEvenAndBounded() throws {
        let data = try Data(contentsOf: fixture("terrain.las"))
        let las = try LASFile(data: data)
        let sample = las.sample(data, budget: 1_000)
        XCTAssertLessThanOrEqual(sample.count, 1_000)
        XCTAssertGreaterThan(sample.count, 900)
        XCTAssertEqual(sample.colors.count, sample.count * 3)
        XCTAssertEqual(sample.classes.count, sample.count)
        // Positions are relative to the centre, so they stay small and precise.
        XCTAssertTrue(sample.positions.allSatisfy { abs($0) < 100 })
        // 16-bit colours become 8-bit ones.
        XCTAssertTrue(Set(sample.colors).count > 10)
        // Every prefix of the bit-reversed order is spread over the whole cloud.
        let firstQuarter = sample.positions.prefix(sample.count / 4 * 3)
        let xs = stride(from: 0, to: firstQuarter.count, by: 3).map { firstQuarter[$0] }
        XCTAssertLessThan(xs.min() ?? 0, -50)
        XCTAssertGreaterThan(xs.max() ?? 0, 50)

        let encoded = sample.encoded()
        XCTAssertEqual(Array(encoded.prefix(4)), Array("GPC1".utf8))
        XCTAssertEqual(encoded.u32(4), UInt32(sample.count))
        XCTAssertEqual(encoded.u32(8), 7)
    }

    func testBlockReadsSampleExactlyLikeMemory() throws {
        let url = fixture("terrain.las")
        let data = try Data(contentsOf: url)
        let las = try LASFile(data: data)
        for budget in [1, 777, 15_000, 1_000_000] {
            let mapped = las.sample(data, budget: budget), read = las.sample(url: url, budget: budget)
            XCTAssertEqual(mapped.positions, read.positions, "budget \(budget)")
            XCTAssertEqual(mapped.colors, read.colors)
            XCTAssertEqual(mapped.classes, read.classes)
        }
        XCTAssertEqual(las.sample(url: fixture("hostile/short.las"), budget: 10).count, 0)
    }

    func testClusteringKeepsTheSurface() throws {
        let gear = try XCTUnwrap(STLReader.load(fixture("gear.stl"), budget: ModelBudget())?.meshes.first)
        let simplified = gear.clustered(resolution: 24)
        XCTAssertLessThan(simplified.triangleCount, gear.triangleCount)
        XCTAssertGreaterThan(simplified.triangleCount, 100)
        XCTAssertLessThan(simplified.positions.count, gear.positions.count)
        var before = Bounds(), after = Bounds()
        gear.positions.forEach { before.add($0) }
        simplified.positions.forEach { after.add($0) }
        XCTAssertEqual(after.size.x, before.size.x, accuracy: before.size.x * 0.1)
        XCTAssertEqual(after.size.z, before.size.z, accuracy: before.size.z * 0.2)
        XCTAssertTrue(simplified.indices.allSatisfy { Int($0) < simplified.positions.count })
    }

    func testProgressiveOrderIsAPermutation() {
        for count in [0, 1, 2, 3, 5, 64, 1000, 4097] {
            let order = LASFile.progressiveOrder(count)
            XCTAssertEqual(order.count, count)
            XCTAssertEqual(Set(order).count, count)
            XCTAssertTrue(order.allSatisfy { $0 >= 0 && $0 < count })
        }
        XCTAssertEqual(LASFile.progressiveOrder(8), [0, 4, 2, 6, 1, 5, 3, 7])
    }

    // MARK: - Pages

    func testPreviewDocuments() throws {
        guard case .web(let gltf, let summary, _) = try ModelsModule.prepare(FileInfo(url: fixture("fox.glb")), settings: PreviewSettings()) else {
            return XCTFail("glTF should preview in the web view")
        }
        XCTAssertEqual(summary.title, "glTF Binary Model")
        XCTAssertTrue(summary.details.contains("576 triangles"))
        XCTAssertEqual(gltf.readableDirectory?.standardizedFileURL.path, fixtures.standardizedFileURL.path)
        XCTAssertTrue(gltf.allowsWasm)
        let html = gltf.html(settings: PreviewSettings())
        XCTAssertTrue(html.contains("vendor/three/three-gltf.min.js"))
        XCTAssertTrue(html.contains("'wasm-unsafe-eval'"))
        XCTAssertFalse(html.contains("'unsafe-eval'"))
        XCTAssertTrue(html.contains("connect-src greece://asset greece://file;"))

        guard case .web(let stl, _, _) = try ModelsModule.prepare(FileInfo(url: fixture("gear.stl")), settings: PreviewSettings()) else {
            return XCTFail("STL should preview in the web view")
        }
        XCTAssertFalse(stl.allowsWasm)
        XCTAssertFalse(stl.html(settings: PreviewSettings()).contains("wasm-unsafe-eval"))

        guard case .web(let las, let lasSummary, _) = try ModelsModule.prepare(FileInfo(url: fixture("terrain.las")), settings: PreviewSettings()),
              let resources = las.resources else {
            return XCTFail("LAS should serve its points")
        }
        XCTAssertEqual(lasSummary.title, "LAS Point Cloud")
        XCTAssertEqual(resources("points").map { Array($0.data.prefix(4)) }, Array("GPC1".utf8))
        XCTAssertNil(resources("../etc/passwd"))
    }

    func testFileNamesCantBreakOutOfThePage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("greece-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("<img src=x onerror=alert(1)> \"quote' #?.stl")
        try FileManager.default.copyItem(at: fixture("gear.stl"), to: url)
        guard case .web(let document, _, _) = try ModelsModule.prepare(FileInfo(url: url), settings: PreviewSettings()) else { return XCTFail() }
        let html = document.html(settings: PreviewSettings())
        XCTAssertFalse(html.contains("<img src=x"))
        XCTAssertTrue(ModelsModule.fileURL(url).contains("%3Cimg"))
        XCTAssertTrue(ModelsModule.fileURL(url).contains("%23%3F.stl"))
    }

    // MARK: - Readers

    func testZipMembersAndXML() throws {
        let package = try ModelZipMembers(url: fixture("bracket.3mf"))
        XCTAssertEqual(ThreeMFPackage.rootModelPath(in: package), "/3D/3dmodel.model")
        let model = try XCTUnwrap(package.entry(named: "/3D/3dmodel.model").flatMap { package.contents(of: $0, limit: 1 << 20) })
        XCTAssertTrue(String(decoding: model, as: UTF8.self).contains("<model unit=\"millimeter\""))
        // The size limit holds even when the directory lies about sizes.
        XCTAssertNil(package.entry(named: "/3D/3dmodel.model").flatMap { package.contents(of: $0, limit: 100) })

        var tags: [(String, String?, Float?)] = []
        XMLTagScanner.scan("<?xml?><!-- <b x='1'/> --><a p:path='/x.model' v1=\"7\"/><b y = '2.5'></b><c broken=\"", { tag in
            tags.append((tag.name, tag.attribute("path"), tag.float("y")))
            return true
        })
        // The comment swallows the tag inside it; the unterminated last tag is ignored.
        XCTAssertEqual(tags.map(\.0), ["a", "b", "b"])
        XCTAssertEqual(tags[0].1, "/x.model")
        XCTAssertEqual(tags[1].2, 2.5)
    }

    func testThreeMFGeometryHonoursComponentsAndTransforms() throws {
        let scene = try XCTUnwrap(ThreeMFPackage.load(fixture("bracket.3mf"), budget: ModelBudget()))
        XCTAssertEqual(scene.meshes.count, 3)   // the bracket and two pegs placed by components
        XCTAssertEqual(scene.meshes.map(\.triangleCount).reduce(0, +), 20 + 128 * 2)
        let bounds = scene.bounds
        XCTAssertEqual(bounds.max.z, 30, accuracy: 0.01)
        XCTAssertTrue(scene.zUp)
    }

    func testGLTFReaderSkinsAndTextures() throws {
        let fox = try XCTUnwrap(GLTFSceneReader.load(url: fixture("fox.glb"), budget: ModelBudget()))
        XCTAssertEqual(fox.meshes.first?.triangleCount, 576)
        XCTAssertNotNil(fox.meshes.first?.material.texture)
        let box = try XCTUnwrap(GLTFSceneReader.load(url: fixture("box-textured/BoxTextured.gltf"), budget: ModelBudget()))
        XCTAssertEqual(box.meshes.first?.uvs.count, box.meshes.first?.positions.count)
        XCTAssertNotNil(box.meshes.first?.material.texture)
        // Draco needs a decoder Swift doesn't have: no geometry, no thumbnail, no crash.
        XCTAssertNil(GLTFSceneReader.load(url: fixture("milk-truck-draco/CesiumMilkTruck.gltf"), budget: ModelBudget()))
    }

    func testFBXReader() throws {
        let scene = try XCTUnwrap(FBXReader.load(fixture("windmill-binary.fbx"), budget: ModelBudget()))
        XCTAssertEqual(scene.meshes.count, 7)
        // The sails hang off the rotor, which sits 400 cm up: the model is taller than the tower.
        XCTAssertGreaterThan(scene.bounds.max.y, 600)
        XCTAssertNil(FBXReader.load(fixture("windmill.fbx"), budget: ModelBudget()))   // ASCII is left to the preview
        XCTAssertEqual(FBXReader.euler(SIMD3(0, 0, 90), order: 0).columns.0.y, 1, accuracy: 1e-5)
    }

    // MARK: - Thumbnails

    func testThumbnailsRender() throws {
        for name in ["fox.glb", "box-textured/BoxTextured.gltf", "gear.stl", "ziggurat.stl", "bracket.3mf", "icosahedron.off", "tree.vox",
                     "terrain.las", "windmill-binary.fbx", "lamp.dae", "pawn/pawn.obj", "vase.ply"] {
            let page = try XCTUnwrap(ModelsModule.thumbnail(FileInfo(url: fixture(name)), size: CGSize(width: 128, height: 128), settings: PreviewSettings()), name)
            XCTAssertEqual(page.size, CGSize(width: 128, height: 128))
            let image = try XCTUnwrap(ModelThumbnails.render(fixture(name), format: format(name)!, fileSize: 1, pixels: 64), name)
            XCTAssertGreaterThan(opaqueFraction(image), 0.02, "\(name) should draw something")
            XCTAssertLessThan(opaqueFraction(image), 0.9, "\(name) should keep a transparent background")
        }
    }

    func testFormatsWithoutSwiftReadersKeepTheirIcons() {
        for name in ["table.3ds", "primitives.wrl", "hillside.laz", "knot.pcd", "milk-truck-draco/CesiumMilkTruck.gltf", "fox-meshopt.glb"] {
            XCTAssertNil(ModelsModule.thumbnail(FileInfo(url: fixture(name)), size: CGSize(width: 128, height: 128), settings: PreviewSettings()), name)
        }
    }

    private func opaqueFraction(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var opaque = 0
        for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] > 200 { opaque += 1 }
        return Double(opaque) / Double(width * height)
    }

    // MARK: - Hostile input

    func testHostileFilesFailQuietly() throws {
        let budget = ModelBudget(deadline: Date().addingTimeInterval(5))
        // A cyclic node graph with absurd counts: walking stops, sums saturate.
        let cycle = ModelFacts.read(.gltf, url: fixture("hostile/cycle.gltf"))
        XCTAssertEqual(cycle.triangles, Int.max)
        XCTAssertNil(GLTFSceneReader.load(url: fixture("hostile/cycle.gltf"), budget: budget))
        // A GLB whose JSON chunk runs past the end of the file.
        XCTAssertThrowsError(try GLTFDocument(url: fixture("hostile/truncated.glb")))
        XCTAssertEqual(ModelFacts.read(.glb, url: fixture("hostile/truncated.glb")), ModelFacts())
        // A LAS header pointing past the end of the file: a header, but no points.
        let shortData = try Data(contentsOf: fixture("hostile/short.las"))
        let short = try LASFile(data: shortData)
        XCTAssertEqual(short.sample(shortData, budget: 1000).count, 0)
        XCTAssertNil(ModelThumbnails.lasPoints(fixture("hostile/short.las"), budget: budget))
        // A 3MF whose zip directory is garbage.
        XCTAssertThrowsError(try ModelZipMembers(url: fixture("hostile/broken.3mf")))
        XCTAssertNil(ThreeMFPackage.load(fixture("hostile/broken.3mf"), budget: budget))
        XCTAssertEqual(ModelFacts.read(.threeMF, url: fixture("hostile/broken.3mf")).triangles, nil)
    }

    func testTruncatedAndRandomBytesNeverCrashReaders() throws {
        var generator = SystemRandomNumberGenerator()
        for name in ["fox.glb", "windmill-binary.fbx", "bracket.3mf", "terrain.las", "tree.vox", "gear.stl", "icosahedron.off"] {
            let original = try Data(contentsOf: fixture(name))
            for cut in [0, 7, 30, original.count / 3, original.count - 1] {
                var bytes = [UInt8](original.prefix(cut))
                // Flip a handful of bytes as well as truncating.
                for _ in 0..<min(8, bytes.count) { bytes[Int.random(in: 0..<bytes.count, using: &generator)] ^= 0xA5 }
                let url = try temporary("mangled-\(cut)-" + (name as NSString).lastPathComponent, bytes)
                let info = FileInfo(url: url)
                if let kind = ModelFormat.detect(info) {
                    _ = ModelFacts.read(kind, url: url)
                    _ = ModelThumbnails.render(url, format: kind, fileSize: bytes.count, pixels: 32)
                    _ = try? ModelsModule.prepare(info, settings: PreviewSettings())
                }
                _ = GLTFSceneReader.load(url: url, budget: ModelBudget())
                _ = FBXReader.load(url, budget: ModelBudget())
                _ = ThreeMFPackage.load(url, budget: ModelBudget())
                _ = VOXReader.load(url, budget: ModelBudget())
                _ = STLReader.load(url, budget: ModelBudget())
                _ = OFFReader.load(url, budget: ModelBudget())
                if let data = try? Data(contentsOf: url), let las = try? LASFile(data: data) { _ = las.sample(data, budget: 100) }
            }
        }
    }

    func testFBXArraysRefuseImpossibleSizes() {
        // A compressed array claiming a billion doubles must not allocate them.
        XCTAssertNil(FBXReader.inflateZlib(Data([0x78, 0x9C, 0x03, 0x00]), expected: Int.max / 2))
        let property = FBXReader.Property.array(type: UInt8(ascii: "d"), count: 1_000_000_000, encoding: 0, range: 0..<4)
        XCTAssertNil(FBXReader.doubles(property, in: Data([0, 0, 0, 0])))
    }
}
