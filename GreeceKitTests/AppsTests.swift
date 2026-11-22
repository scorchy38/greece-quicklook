import XCTest
import AppKit
import CryptoKit
@testable import GreeceKit

/// Apps, installers and binaries: detection, bundles, Mach-O, code signatures, profiles, iOS apps, torrents.
final class AppsCoreTests: XCTestCase {

    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repository.appendingPathComponent("Fixtures/apps")

    private func fixture(_ path: String) -> URL { Self.fixtures.appendingPathComponent(path) }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceApps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func kind(_ url: URL) -> AppsModule.Kind? { AppsModule.kind(of: FileInfo(url: url)) }

    // MARK: - Detection

    func testBundledSamplesNeverRouteToTheAppsModule() throws {
        let samples = Self.repository.appendingPathComponent("GreeceKit/Resources/Samples")
        let files = try FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertNotEqual(FileKind.detect(file), .module(AppsModule.id), file.lastPathComponent)
            XCTAssertNil(kind(file), file.lastPathComponent)
        }
    }

    func testEverydayFilesAreLeftToTheCore() throws {
        let cases: [(String, Data)] = [
            ("data.json", Data(#"{"a": [1, 2]}"#.utf8)),
            ("settings.plist", Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8)),
            ("notes.md", Data("# Notes".utf8)),
            ("run.sh", Data("#!/bin/sh\necho hi\n".utf8)),
            ("Main.class", Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41] + [UInt8](repeating: 0, count: 64))),
            ("Thing.java", Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34] + [UInt8](repeating: 0, count: 64))),
            ("fake.ipa", Data("not a zip".utf8)),
            ("fake.torrent", Data("hello".utf8)),
            ("fake.mobileprovision", Data("<plist/>".utf8)),
            ("fake.mobileconfig", Data("just text".utf8)),
            ("archive.zip", Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 60))),
        ]
        for (name, data) in cases {
            let url = try write(name, data)
            XCTAssertNil(kind(url), name)
        }
    }

    func testDetection() throws {
        XCTAssertEqual(kind(fixture("bundles/Tiny.app")), .bundle)
        XCTAssertEqual(kind(fixture("bundles/Tiny.app/Contents/PlugIns/TinyPreview.appex")), .bundle)
        XCTAssertEqual(kind(fixture("bundles/Tiny.xcarchive")), .xcarchive)
        XCTAssertEqual(kind(fixture("bundles/Tiny.app.dSYM")), .dsym)
        XCTAssertEqual(kind(fixture("macho/greece-tool")), .machO)
        XCTAssertEqual(kind(fixture("macho/intel-tool")), .machO)
        XCTAssertEqual(kind(fixture("macho/libgreece.dylib")), .machO)
        XCTAssertEqual(kind(fixture("macho/lib.o")), .machO)
        XCTAssertEqual(kind(fixture("ios/Tiny.ipa")), .ipa)
        XCTAssertEqual(kind(fixture("profiles/Tiny_Development.mobileprovision")), .provisioningProfile)
        XCTAssertEqual(kind(fixture("profiles/Greece.mobileconfig")), .configurationProfile)
        XCTAssertEqual(kind(fixture("profiles/Greece-Signed.mobileconfig")), .configurationProfile)
        XCTAssertEqual(kind(fixture("torrent/Aegean Photos.torrent")), .torrent)
        XCTAssertEqual(FileKind.detect(fixture("macho/greece-tool")), .module(AppsModule.id))
        // A plain folder is still a folder.
        XCTAssertEqual(FileKind.detect(directory), .folder)
    }

    // MARK: - Mach-O

    func testUniversalToolWithEmbeddedInfoAndSignature() throws {
        let bytes = try FileBytes(url: fixture("macho/greece-tool"))
        let file = try MachOFile.parse(bytes)
        XCTAssertTrue(file.isFat)
        XCTAssertEqual(Set(file.architectures), ["arm64", "x86_64"])
        XCTAssertEqual(ArchitectureSupport(file.slices), .universal)
        let slice = try XCTUnwrap(file.preferredSlice)
        XCTAssertEqual(slice.architecture, "arm64")
        XCTAssertEqual(slice.fileType, 2)
        XCTAssertEqual(slice.builds.first?.platform, .macOS)
        XCTAssertEqual(slice.builds.first?.minimum, "12.0")
        XCTAssertNotNil(slice.uuid)
        XCTAssertTrue(slice.libraries.contains { $0.path == "/usr/lib/libSystem.B.dylib" && $0.isSystem })
        XCTAssertFalse(slice.truncated)
        let info = try XCTUnwrap(MachOPage.infoPlist(in: slice, source: bytes))
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.scorchy.greece.fixture.tool")

        let signature = try XCTUnwrap(CodeSignature.read(from: bytes, macho: file))
        XCTAssertTrue(signature.isAdHoc)
        XCTAssertTrue(signature.hasHardenedRuntime)
        // codesign names a tool after its embedded Info.plist's bundle identifier.
        XCTAssertEqual(signature.identifier, "com.scorchy.greece.fixture.tool")
        XCTAssertEqual(signature.entitlements["com.apple.security.cs.allow-jit"] as? Bool, true)
        XCTAssertEqual(signature.cdhash?.count, 20)
        XCTAssertEqual(signature.signer, .adHoc)

        let page = try MachOPage.page(for: fixture("macho/greece-tool"), modified: nil)
        XCTAssertEqual(page.header.subtitle, "Command-Line Tool · Version 1.4 (14)")
        XCTAssertTrue(page.badges.contains { $0.id == "architecture" && $0.title == "Universal" })
        XCTAssertTrue(page.badges.contains { $0.id == "runtime" })
        XCTAssertNotNil(page.section("capabilities"))
        XCTAssertNotNil(page.section("libraries"))
        XCTAssertEqual(page.section("architectures")?.rows.count, 2)
    }

    func testIntelOnlyIsFlagged() throws {
        let file = try MachOFile.parse(try FileBytes(url: fixture("macho/intel-tool")))
        XCTAssertEqual(ArchitectureSupport(file.slices), .intel)
        XCTAssertEqual(ArchitectureSupport(file.slices).badge.title, "Intel Only")
        XCTAssertEqual(ArchitectureSupport(file.slices).badge.tone, .caution)
    }

    func testDylibAndObjectFile() throws {
        let dylib = try MachOFile.parse(try FileBytes(url: fixture("macho/libgreece.dylib")))
        XCTAssertEqual(dylib.fileTypeName, "Dynamic Library")
        XCTAssertEqual(dylib.slices.first?.installName, "@rpath/libgreece.dylib")
        XCTAssertEqual(dylib.slices.first?.installVersion, "1.2.3")
        let object = try MachOFile.parse(try FileBytes(url: fixture("macho/lib.o")))
        XCTAssertEqual(object.fileTypeName, "Object File")
        XCTAssertNoThrow(try MachOPage.page(for: fixture("macho/lib.o"), modified: nil))
    }

    func testLibraryNames() {
        func name(_ path: String) -> String { MachOFile.Library(path: path, kind: .normal, currentVersion: "1.0", compatibilityVersion: "1.0").name }
        XCTAssertEqual(name("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"), "AppKit")
        XCTAssertEqual(name("@rpath/Sparkle.framework/Versions/B/Sparkle"), "Sparkle")
        XCTAssertEqual(name("/usr/lib/libobjc.A.dylib"), "libobjc")
        XCTAssertEqual(name("/usr/lib/swift/libswiftCore.dylib"), "libswiftCore")
    }

    func testHostileMachOHeaders() throws {
        // A fat header claiming 20 slices that all point past the end.
        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x14])
        for _ in 0..<20 {
            fat.append(contentsOf: [0x01, 0x00, 0x00, 0x0C, 0, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 14])
        }
        XCTAssertThrowsError(try MachOFile.parse(DataBytes(fat)))

        // A thin header claiming a million load commands of zero size.
        var thin = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0x02, 0, 0, 0])
        thin.append(contentsOf: [0x40, 0x42, 0x0F, 0x00, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0, 0, 0, 0, 0])
        thin.append(Data(count: 64))
        let parsed = try MachOFile.parse(DataBytes(thin))
        XCTAssertTrue(parsed.slices[0].truncated)

        // A load command whose string offset points outside it.
        var command = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0x06, 0, 0, 0, 0x01, 0, 0, 0, 0x18, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        command.append(contentsOf: [0x0C, 0, 0, 0, 0x18, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let library = try MachOFile.parse(DataBytes(command))
        XCTAssertTrue(library.slices[0].libraries.isEmpty)

        XCTAssertThrowsError(try MachOFile.parse(DataBytes(Data([0xCF, 0xFA]))))
        XCTAssertNil(MachOFile.magic(of: [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0x34]))   // a Java class file
    }

    func testMutatedMachODoesNotCrash() throws {
        let original = try Data(contentsOf: fixture("macho/greece-tool"))
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<300 {
            var data = original
            for _ in 0..<12 {
                let index = Int.random(in: 0..<min(data.count, 8192), using: &generator)
                data[index] = UInt8.random(in: 0...255, using: &generator)
            }
            if Bool.random(using: &generator) { data = data.prefix(Int.random(in: 0..<data.count, using: &generator)) }
            if let file = try? MachOFile.parse(DataBytes(data)) {
                _ = CodeSignature.read(from: DataBytes(data), macho: file)
            }
        }
    }

    // MARK: - Code signatures and tickets

    func testHostileSuperblobs() {
        XCTAssertNil(CodeSignature(data: Data([0xFA, 0xDE, 0x0C, 0xC0])))
        // A superblob claiming 2^32-1 entries, each pointing nowhere.
        var blob = Data([0xFA, 0xDE, 0x0C, 0xC0, 0x00, 0x00, 0x00, 0x40, 0xFF, 0xFF, 0xFF, 0xFF])
        for _ in 0..<6 { blob.append(contentsOf: [0, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF]) }
        let signature = CodeSignature(data: blob)
        XCTAssertNotNil(signature)
        XCTAssertNil(signature?.identifier)
        // A CMS blob full of garbage.
        var cms = Data([0xFA, 0xDE, 0x0C, 0xC0, 0x00, 0x00, 0x00, 0x34, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14])
        cms.append(contentsOf: [0xFA, 0xDE, 0x0B, 0x01, 0x00, 0x00, 0x00, 0x20])
        cms.append(Data(repeating: 0x30, count: 24))
        XCTAssertEqual(CodeSignature(data: cms)?.certificates.count, 0)
    }

    static func ticket(hashes: [Data], seconds: UInt64) -> Data {
        var body = Data("g8tk".utf8)
        body.append(contentsOf: [0x02, 0x00, 0x14, 0x00])
        var count = UInt32(hashes.count).littleEndian
        body.append(Data(bytes: &count, count: 4))
        body.append(Data(count: 4))
        var time = seconds.littleEndian
        body.append(Data(bytes: &time, count: 8))
        for hash in hashes { body.append(0x02); body.append(hash.prefix(20)) }
        var ticket = Data("s8ch".utf8)
        var fields: [UInt32] = [1, 0, UInt32(body.count)]
        for index in fields.indices { ticket.append(Data(bytes: &fields[index], count: 4)) }
        ticket.append(body)
        ticket.append(Data(repeating: 0x30, count: 70))
        return ticket
    }

    func testNotarizationTicket() throws {
        let hash = Data((0..<32).map { UInt8($0) })
        let other = Data(repeating: 0xEE, count: 32)
        let data = Self.ticket(hashes: [other, hash], seconds: 1_794_836_320)
        let ticket = try XCTUnwrap(NotarizationTicket(data: data))
        XCTAssertEqual(ticket.entries.count, 2)
        XCTAssertTrue(ticket.covers(hash))
        XCTAssertTrue(ticket.covers(hash.prefix(20)))
        XCTAssertFalse(ticket.covers(Data(repeating: 1, count: 20)))
        XCTAssertEqual(ticket.notarizedAt, Date(timeIntervalSince1970: 1_794_836_320))
        XCTAssertNotNil(NotarizationTicket(searching: Data(repeating: 0, count: 100) + data))

        // Lies about its count and length.
        var lying = data
        lying.replaceSubrange(24..<28, with: [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertLessThanOrEqual(NotarizationTicket(data: lying)?.entries.count ?? 0, 2)
        var short = data
        short.replaceSubrange(12..<16, with: [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertNil(NotarizationTicket(data: short))
        XCTAssertNil(NotarizationTicket(data: data.prefix(20)))
    }

    // MARK: - Bundles

    func testBundleFacts() throws {
        let facts = try XCTUnwrap(BundleFacts(source: DirectoryBundle(url: fixture("bundles/Tiny.app"))))
        XCTAssertEqual(facts.layout, .macOS)
        XCTAssertEqual(facts.name, "Tiny")
        XCTAssertEqual(facts.identifier, "com.scorchy.greece.fixture.tiny")
        XCTAssertEqual(Format.version(facts.shortVersion, build: facts.buildVersion), "Version 2.1 (214)")
        XCTAssertEqual(facts.executablePath, "Contents/MacOS/Tiny")
        XCTAssertTrue(facts.isSandboxed)
        XCTAssertFalse(facts.isIOS)
        XCTAssertEqual(facts.localizations, ["de", "en", "fr"])
        XCTAssertNotNil(facts.privacyManifest)
        XCTAssertTrue(facts.nested.contains { $0.role == .appExtension && $0.extensionPoint == "com.apple.quicklook.preview" && $0.name == "Tiny Preview" })
        XCTAssertTrue(facts.nested.contains { $0.role == .loginItem && $0.name == "TinyHelper" })

        let page = BundlePage.page(for: facts, icon: .file(fixture("bundles/Tiny.app")), subject: .bundle, modified: nil)
        for id in ["signature", "capabilities", "privacy", "privacyManifest", "extensions", "background", "documents", "urls", "libraries", "size", "info"] {
            XCTAssertNotNil(page.section(id), id)
        }
        XCTAssertEqual(page.badges.first?.title, "Universal")
        XCTAssertTrue(page.badges.contains { $0.id == "sandbox" })
        XCTAssertTrue(page.badges.contains { $0.id == "signer" && $0.title == "Ad Hoc" })
        let privacy = try XCTUnwrap(page.section("privacy")).rows.compactMap(\.item)
        XCTAssertTrue(privacy.contains { $0.title == "Camera" && $0.subtitle == "“Tiny uses the camera to scan documents.”" && $0.help == "NSCameraUsageDescription" })
        let capabilities = try XCTUnwrap(page.section("capabilities")).rows.compactMap(\.item)
        XCTAssertTrue(capabilities.contains { $0.title == "Outgoing network connections" && $0.help == "com.apple.security.network.client" })
        XCTAssertEqual(capabilities.first?.tone, .caution)   // "Controls other apps" sorts first
        XCTAssertTrue(page.checks.contains { $0.id == "integrity" })
        let info = try XCTUnwrap(page.section("info")).rows.compactMap(\.item)
        XCTAssertTrue(info.contains { $0.title == "Built With" && $0.value == "macOS 26.5 SDK, Xcode 26.6 (17F42)" })
        XCTAssertTrue(info.contains { $0.title == "Network Security" && $0.tone == .caution })
    }

    func testSignatureIntegrityChecks() throws {
        let intact = SigningSection.integrityCheck(url: fixture("bundles/Tiny.app"), subject: .bundle, skipResources: false)
        XCTAssertTrue(intact.badges.isEmpty)
        XCTAssertEqual(intact.rows.first?.item?.value, "Unmodified since signing")

        let tampered = SigningSection.integrityCheck(url: fixture("bundles/Tampered.app"), subject: .bundle, skipResources: false)
        XCTAssertTrue(tampered.badges.contains { $0.id == "modified" && $0.tone == .critical })
        let row = try XCTUnwrap(tampered.rows.first?.item)
        XCTAssertEqual(row.value, "Modified after signing")
        XCTAssertTrue(row.details.contains { $0.title.contains("fr.lproj/InfoPlist.strings") })
    }

    func testInspectorChecksReplacePendingRows() async throws {
        let facts = try XCTUnwrap(BundleFacts(source: DirectoryBundle(url: fixture("bundles/Tampered.app"))))
        let page = BundlePage.page(for: facts, icon: .file(fixture("bundles/Tampered.app")), subject: .bundle, modified: nil)
        let model = await InspectorModel(page: page, settings: PreviewSettings())
        let check = try XCTUnwrap(page.checks.first { $0.id == "integrity" })
        let result = check.run()
        await model.apply(result, to: check.id)
        let updated = await model.page
        XCTAssertTrue(updated.badges.contains { $0.id == "modified" })
        XCTAssertFalse(updated.allRows.contains { if case .pending(let id, _) = $0 { return id == "integrity" } else { return false } })
    }

    func testXcodeArchiveAndSymbols() throws {
        let archive = try ArchivePage.xcarchive(fixture("bundles/Tiny.xcarchive"), modified: nil)
        XCTAssertEqual(archive.header.title, "Tiny")
        XCTAssertEqual(archive.summary.title, "Xcode Archive")
        XCTAssertEqual(archive.sections.first?.id, "archive")
        XCTAssertNotNil(archive.section("dsyms"))

        let symbols = try ArchivePage.dsym(fixture("bundles/Tiny.app.dSYM"), modified: nil)
        let uuids = try XCTUnwrap(symbols.section("uuids")).rows.compactMap(\.item)
        XCTAssertEqual(Set(uuids.map(\.title)), ["arm64", "x86_64"])
        XCTAssertTrue(uuids.allSatisfy { UUID(uuidString: $0.value ?? "") != nil })
    }

    // MARK: - Disk images

    func testDiskImageSignature() throws {
        let signed = fixture("diskimages/Signed-adhoc.dmg")
        XCTAssertEqual(kind(signed), .diskImage)
        let page = try AppsModule.makePage(FileInfo(url: signed))
        let section = try XCTUnwrap(page.section("signature"))
        XCTAssertTrue(section.rows.contains { $0.item?.value == "com.scorchy.greece.fixture.disk" })
        XCTAssertTrue(page.badges.contains { $0.id == "signer" && $0.title == "Ad Hoc" })
        let integrity = try XCTUnwrap(page.checks.first { $0.id == "integrity" })
        XCTAssertEqual(integrity.run().rows.first?.item?.value, "Unmodified since signing")

        // Unsigned images are normal: no alarming badge.
        let unsigned = try AppsModule.makePage(FileInfo(url: fixture("diskimages/Sample-HFS-zlib.dmg")))
        XCTAssertEqual(unsigned.section("signature")?.rows.first?.item?.value, "Not signed")
        XCTAssertFalse(unsigned.badges.contains { $0.id == "signer" })
        XCTAssertEqual(unsigned.sections.first?.id, "apps")
    }

    // MARK: - iOS

    func testIPA() throws {
        let page = try IPAPage.page(for: fixture("ios/Tiny.ipa"), modified: nil)
        XCTAssertEqual(page.header.title, "Tiny")
        XCTAssertEqual(page.summary.title, "iOS App")
        guard case .image(let image, let shape) = page.header.icon else { return XCTFail("expected the app icon") }
        XCTAssertEqual(shape, .iOS)
        XCTAssertEqual(image.size, NSSize(width: 120, height: 120))
        XCTAssertNotNil(page.section("embeddedProfile"))
        XCTAssertNotNil(page.section("privacy"))
        XCTAssertTrue(page.section("signature")?.rows.contains { $0.item?.title == "Hardened Runtime" } == false)
        XCTAssertNotNil(IPAPage.icon(for: fixture("ios/Tiny.ipa")))
        XCTAssertNotNil(AppsModule.thumbnail(FileInfo(url: fixture("ios/Tiny.ipa")), size: CGSize(width: 256, height: 256), settings: PreviewSettings()))
    }

    func testIconFromCompiledAssetCatalog() throws {
        // Current Xcode ships iOS icons only inside Assets.car.
        let icon = try XCTUnwrap(IPAPage.icon(for: fixture("ios/Catalog.ipa")))
        XCTAssertEqual(icon.size, NSSize(width: 1024, height: 1024))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(icon.tiffRepresentation)))
        let centre = try XCTUnwrap(bitmap.colorAt(x: 512, y: 512)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(centre.greenComponent, 0.95)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 40, y: 40)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(corner.blueComponent, corner.redComponent + 0.3)

        // Hostile catalogs: truncated, corrupted, or not a BOM at all.
        let zip = try ZipFile(url: fixture("ios/Catalog.ipa"))
        let catalog = try XCTUnwrap(zip.contents(of: "Payload/Catalog.app/Assets.car"))
        XCTAssertNil(AssetCatalog.appIcon(in: catalog.prefix(600), named: "AppIcon"))
        XCTAssertNil(AssetCatalog.appIcon(in: Data("BOMStore".utf8) + Data(repeating: 0xFF, count: 200), named: nil))
        var generator = SeededGenerator(seed: 3)
        for _ in 0..<200 {
            var data = catalog
            for _ in 0..<16 { data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator) }
            _ = AssetCatalog.appIcon(in: data, named: "AppIcon")
        }
    }

    func testCgBIDecoding() throws {
        let zip = try ZipFile(url: fixture("ios/Tiny.ipa"))
        let data = try XCTUnwrap(zip.contents(of: "Payload/Tiny.app/AppIcon60x60@2x.png"))
        XCTAssertTrue(CgBIImage.isCgBI(data))
        let image = try XCTUnwrap(CgBIImage.decodeCgBI(data))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        // The fixture's centre is a white disc on a blue gradient.
        let centre = try XCTUnwrap(bitmap.colorAt(x: 60, y: 60)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(centre.redComponent, 0.95)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(corner.blueComponent, corner.redComponent + 0.3)

        // Truncated, oversized and corrupt variants fail cleanly.
        XCTAssertNil(CgBIImage.decodeCgBI(data.prefix(40)))
        var huge = data
        let ihdr = try XCTUnwrap(huge.firstRange(of: Array("IHDR".utf8)))
        huge.replaceSubrange((ihdr + 4)..<(ihdr + 12), with: [0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
        XCTAssertNil(CgBIImage.decodeCgBI(huge))
        var garbage = data
        if let idat = garbage.firstRange(of: Array("IDAT".utf8)) {
            for index in (idat + 4)..<min(garbage.count, idat + 200) { garbage[index] = 0xFF }
        }
        _ = CgBIImage.decodeCgBI(garbage)
    }

    // MARK: - Profiles

    func testProvisioningProfiles() throws {
        let data = try Data(contentsOf: fixture("profiles/Tiny_Development.mobileprovision"))
        let profile = try XCTUnwrap(ProvisioningProfile(data: data))
        XCTAssertEqual(profile.kind, .development)
        XCTAssertEqual(profile.devices.count, 3)
        XCTAssertEqual(profile.teamName, "Greece Fixtures")
        XCTAssertEqual(profile.teamIDs, ["FIXTURE01"])
        XCTAssertEqual(profile.certificates.first?.commonName, "Apple Development: Greece Fixture (FIXTURE01)")
        XCTAssertEqual(profile.signatureIntact, true)
        XCTAssertEqual(profile.platformNames, "iOS and visionOS")

        let expired = try XCTUnwrap(ProvisioningProfile(data: try Data(contentsOf: fixture("profiles/Expired_AdHoc.mobileprovision"))))
        XCTAssertEqual(expired.kind, .adHoc)
        XCTAssertEqual(Format.expiry(try XCTUnwrap(expired.expires)).tone, .critical)
        let page = try ProfilePage.provisioningPage(for: fixture("profiles/Expired_AdHoc.mobileprovision"), modified: nil)
        XCTAssertTrue(page.badges.contains { $0.id == "expiry" && $0.title == "Expired" })

        // Tampered contents break the signature check.
        var tampered = data
        if let position = tampered.firstRange(of: Array("Greece Fixtures".utf8)) { tampered[position] = UInt8(ascii: "X") }
        XCTAssertEqual(ProvisioningProfile(data: tampered)?.signatureIntact, false)
        XCTAssertNil(ProvisioningProfile(data: Data(repeating: 0x30, count: 64)))
        XCTAssertNil(ProvisioningProfile(data: data.prefix(100)))
    }

    func testConfigurationProfiles() throws {
        for name in ["Greece.mobileconfig", "Greece-Signed.mobileconfig"] {
            let page = try ProfilePage.configurationPage(for: fixture("profiles/" + name), modified: nil)
            XCTAssertEqual(page.header.title, "Greece Office")
            XCTAssertEqual(page.section("payloads")?.rows.count, 4)
            XCTAssertTrue(page.badges.contains { $0.id == "root" })
            XCTAssertEqual(page.badges.contains { $0.id == "signed" && $0.title == "Signed" }, name.contains("Signed"))
            let wifi = page.section("payloads")?.rows.compactMap(\.item).first { $0.help == "com.apple.wifi.managed" }
            XCTAssertEqual(wifi?.subtitle, "Wi-Fi · Network “Greece-Office”")
        }
        let junk = try write("junk.mobileconfig", Data([0x30, 0x82, 0x01, 0x00] + [UInt8](repeating: 0xAB, count: 300)))
        XCTAssertThrowsError(try ProfilePage.configurationPage(for: junk, modified: nil))
    }

    // MARK: - Torrents

    func testTorrents() throws {
        let data = try Data(contentsOf: fixture("torrent/Aegean Photos.torrent"))
        let torrent = try Torrent(data: data)
        XCTAssertEqual(torrent.name, "Aegean Photos")
        XCTAssertEqual(torrent.files.count, 4)
        XCTAssertEqual(torrent.totalSize, 568_200)
        XCTAssertTrue(torrent.isPrivate)
        XCTAssertEqual(torrent.trackers.count, 2)
        XCTAssertEqual(torrent.trackers.joined().count, 3)
        XCTAssertEqual(torrent.webSeeds, ["https://mirror.example.com/files/"])
        XCTAssertEqual(torrent.pieceCount, 3)
        XCTAssertEqual(torrent.source, "GRC")
        // The SHA-1 of the bencoded info dictionary, computed independently with Python's hashlib.
        let expected = "9c59d5d3523335f3e144a3fb22a40024dc44032a"
        XCTAssertEqual(torrent.infoHashV1, expected)
        XCTAssertTrue(torrent.magnetLink?.hasPrefix("magnet:?xt=urn:btih:" + expected) == true)

        let single = try Torrent(data: try Data(contentsOf: fixture("torrent/Single File.torrent")))
        XCTAssertEqual(single.files, [Torrent.File(path: "ubuntu-like.iso", size: 4_700_000_000)])
        let hybrid = try Torrent(data: try Data(contentsOf: fixture("torrent/Hybrid Set.torrent")))
        XCTAssertEqual(hybrid.version, 2)
        XCTAssertEqual(hybrid.infoHashV2?.count, 64)
        XCTAssertNotNil(hybrid.infoHashV1)

        let page = try TorrentPage.page(for: fixture("torrent/Aegean Photos.torrent"), modified: nil)
        XCTAssertTrue(page.badges.contains { $0.id == "private" })
        XCTAssertNotNil(page.contents)
        XCTAssertNotNil(AppThumbnails.torrentCard(for: fixture("torrent/Aegean Photos.torrent"), size: CGSize(width: 256, height: 256)))
    }

    func testHostileBencode() {
        XCTAssertThrowsError(try Bencode.parse(Data(String(repeating: "l", count: 100_000).utf8)))
        XCTAssertThrowsError(try Bencode.parse(Data("99999999999999999999:abc".utf8)))
        XCTAssertThrowsError(try Bencode.parse(Data("i99999999999999999999999e".utf8)))
        XCTAssertThrowsError(try Bencode.parse(Data("d4:infod4:name".utf8)))
        XCTAssertThrowsError(try Bencode.parse(Data("di1ei2ee".utf8)))
        XCTAssertThrowsError(try Bencode.parse(Data()))
        XCTAssertThrowsError(try Torrent(data: Data("d4:infoi3ee".utf8)))
        // Wide but legal structures stay within the node budget.
        let wide = "l" + String(repeating: "i1e", count: 50_000) + "e"
        XCTAssertNoThrow(try Bencode.parse(Data(wide.utf8)))
        var generator = SeededGenerator(seed: 11)
        let original = (try? Data(contentsOf: Self.fixtures.appendingPathComponent("torrent/Aegean Photos.torrent"))) ?? Data()
        for _ in 0..<300 {
            var data = original
            for _ in 0..<6 where !data.isEmpty {
                data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = try? Torrent(data: data)
        }
    }

    // MARK: - ZIP members

    func testZipMembersAndLimits() throws {
        let zip = try ZipFile(url: fixture("ios/Tiny.ipa"))
        XCTAssertNotNil(zip.member("Payload/Tiny.app/Info.plist"))
        XCTAssertThrowsError(try zip.contents(of: try XCTUnwrap(zip.member("Payload/Tiny.app/Tiny")), limit: 16))
        XCTAssertThrowsError(try ZipFile(url: try write("random.zip", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }))))

        // An end record pointing far outside the file.
        var bogus = Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 26))
        bogus.append(contentsOf: [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0])
        XCTAssertThrowsError(try ZipFile(url: try write("bogus.ipa", bogus)))

        // A member whose header claims 4 GB: streaming stops at the maximum.
        let data = try Data(contentsOf: fixture("ios/Tiny.ipa"))
        let mapped = try ZipFile(url: try write("copy.ipa", data))
        let member = try XCTUnwrap(mapped.member("Payload/Tiny.app/Tiny"))
        var total = 0
        try mapped.stream(member, maximum: 1000) { total += $0.count; return true }
        XCTAssertEqual(total, 1000)
    }

    func testStreamedExecutableKeepsOnlyWhatItNeeds() throws {
        let zip = try ZipFile(url: fixture("ios/Tiny.ipa"))
        let member = try XCTUnwrap(zip.member("Payload/Tiny.app/Tiny"))
        let sparse = try XCTUnwrap(ZipBundle.capture(member, in: zip))
        let file = try MachOFile.parse(sparse)
        XCTAssertEqual(file.slices.first?.builds.first?.platform, .iOS)
        let signature = try XCTUnwrap(CodeSignature.read(from: sparse, macho: file))
        XCTAssertEqual(signature.entitlements["get-task-allow"] as? Bool, true)
    }

    // MARK: - Copy and catalogs

    func testEveryCatalogSymbolExists() {
        var symbols: [(String, String)] = []
        for (key, entry) in EntitlementCatalog.entries { symbols.append((key, entry.symbol)) }
        for (key, entry) in PrivacyCatalog.entries { symbols.append((key, entry.symbol)) }
        for (key, entry) in ExtensionPointCatalog.entries { symbols.append((key, entry.symbol)) }
        for (key, entry) in PayloadCatalog.entries { symbols.append((key, entry.symbol)) }
        for (key, symbol) in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(key): \(symbol)")
        }
    }

    func testFormatting() {
        XCTAssertEqual(Format.version("2.1", build: "214"), "Version 2.1 (214)")
        XCTAssertEqual(Format.version("3.0", build: "3.0"), "Version 3.0")
        XCTAssertNil(Format.version(" ", build: nil))
        XCTAssertEqual(Format.count(1, "file"), "1 file")
        XCTAssertEqual(Format.count(1204, "library", "libraries"), "1,204 libraries")
        XCTAssertEqual(Format.clean("a\u{0}b\u{7}c" + String(repeating: "x", count: 400), limit: 10), "abcxxxxxxx…")
        XCTAssertEqual(BundlePage.sdkName("macosx15.2", xcode: "1620", build: nil), "macOS 15.2 SDK, Xcode 16.2")
        XCTAssertEqual(BundlePage.humanize("NSPrivacyCollectedDataTypeEmailAddress", prefix: "NSPrivacyCollectedDataType"), "Email address")
        XCTAssertEqual(PrivacyCatalog.describe("NSFooBarUsageDescription")?.title, "Foo Bar")
    }
}

/// Reproducible randomness for mutation tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - WindowsTests

final class WindowsTests: XCTestCase {

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/apps/windows/\(name)")
    }

    private func bytes(_ name: String) throws -> Data { try Data(contentsOf: fixture(name)) }

    private func patch32(_ data: inout Data, at offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    private func patch16(_ data: inout Data, at offset: Int, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<(offset + 2), with: $0) }
    }

    /// A minimal PE32+ image: `sections` sections of 4 KB each, contiguous in memory and on disk,
    /// so RVA r lives at file offset `headers + r - 0x1000`.
    private func syntheticPE(sections: Int, directories: [Int: (UInt32, UInt32)] = [:]) -> (data: Data, headers: Int) {
        let optional = 0x58
        let table = optional + 240
        let headers = (table + 40 * sections + 0x1FF) & ~0x1FF
        var data = Data(count: headers + sections * 0x1000)
        patch16(&data, at: 0, 0x5A4D)
        patch32(&data, at: 0x3C, 0x40)
        patch32(&data, at: 0x40, 0x4550)
        patch16(&data, at: 0x44, 0x8664)
        patch16(&data, at: 0x46, UInt16(sections))
        patch16(&data, at: 0x54, 240)
        patch16(&data, at: 0x56, 0x22)
        patch16(&data, at: optional, 0x20B)
        patch32(&data, at: optional + 56, UInt32(0x1000 * (sections + 1)))
        patch32(&data, at: optional + 60, UInt32(headers))
        patch16(&data, at: optional + 68, 3)
        patch32(&data, at: optional + 108, 16)
        for (index, directory) in directories {
            patch32(&data, at: optional + 112 + index * 8, directory.0)
            patch32(&data, at: optional + 112 + index * 8 + 4, directory.1)
        }
        for index in 0..<sections {
            let header = table + index * 40
            let name = Array(".s\(index)".utf8.prefix(8))
            data.replaceSubrange(header..<(header + name.count), with: name)
            patch32(&data, at: header + 8, 0x1000)
            patch32(&data, at: header + 12, UInt32(0x1000 * (index + 1)))
            patch32(&data, at: header + 16, 0x1000)
            patch32(&data, at: header + 20, UInt32(headers + index * 0x1000))
            patch32(&data, at: header + 36, 0x4000_0040)
        }
        return (data, headers)
    }

    // MARK: Detection

    func testSniffing() throws {
        let exe = [UInt8](try bytes("hello.exe").prefix(8192))
        XCTAssertTrue(WindowsPage.sniff(probe: exe))
        XCTAssertTrue(WindowsPage.sniff(probe: [UInt8](try bytes("greece.dll").prefix(8192))))
        XCTAssertFalse(WindowsPage.sniff(probe: []))
        XCTAssertFalse(WindowsPage.sniff(probe: Array("MZ".utf8)))
        var outOfRange = exe
        outOfRange[0x3C] = 0xFF; outOfRange[0x3D] = 0xFF; outOfRange[0x3E] = 0xFF; outOfRange[0x3F] = 0x7F
        XCTAssertFalse(WindowsPage.sniff(probe: outOfRange))
        // A DOS program without a PE header, and a Mach-O.
        var dos = [UInt8](repeating: 0, count: 256)
        dos[0] = 0x4D; dos[1] = 0x5A; dos[0x3C] = 0x80
        XCTAssertFalse(WindowsPage.sniff(probe: dos))
        XCTAssertFalse(WindowsPage.sniff(probe: [0xCF, 0xFA, 0xED, 0xFE] + [UInt8](repeating: 0, count: 100)))
    }

    // MARK: Parsing

    func testHeaders() throws {
        let file = try PEFile(url: fixture("hello.exe"))
        XCTAssertEqual(file.machine, 0x8664)
        XCTAssertTrue(file.is64Bit)
        XCTAssertFalse(file.isDLL)
        XCTAssertEqual(file.subsystem, 2)
        XCTAssertEqual(file.subsystemVersion.major, 6)
        XCTAssertEqual(file.subsystemVersion.minor, 1)
        XCTAssertNotEqual(file.dllCharacteristics & 0x40, 0)    // ASLR
        XCTAssertNotEqual(file.dllCharacteristics & 0x100, 0)   // DEP
        XCTAssertNotEqual(file.dllCharacteristics & 0x20, 0)    // high-entropy ASLR
        XCTAssertTrue(file.debug.isReproducible)
        XCTAssertEqual(file.debug.pdbPath, "hello.pdb")
        XCTAssertNotNil(file.debug.pdbGUID)
        XCTAssertEqual(file.sections.map(\.name).first, ".text")
        XCTAssertTrue(file.sections.contains { $0.name == ".rsrc" })
        XCTAssertNil(file.certificateTable)
        XCTAssertEqual(WindowsPage.architecture(file).badge, "x64")
        XCTAssertEqual(WindowsPage.minimumWindows(file.subsystemVersion), "Windows 7")
    }

    func testImportsIncludingDelayLoads() throws {
        let file = try PEFile(url: fixture("hello.exe"))
        let kernel = try XCTUnwrap(file.imports.first { $0.name.lowercased() == "kernel32.dll" })
        XCTAssertFalse(kernel.isDelayLoaded)
        XCTAssertEqual(kernel.functionCount, 2)
        XCTAssertEqual(Set(kernel.functions), ["ExitProcess", "GetTickCount"])
        let user = try XCTUnwrap(file.imports.first { $0.name.lowercased() == "user32.dll" })
        XCTAssertTrue(user.isDelayLoaded)
        XCTAssertEqual(user.functions, ["MessageBoxW"])
        XCTAssertEqual(WindowsPage.libraryDescription("KERNEL32.dll").isSystem, true)
        XCTAssertEqual(WindowsPage.libraryDescription("api-ms-win-crt-runtime-l1-1-0.dll").description, "C runtime")
        XCTAssertEqual(WindowsPage.libraryDescription("UnityPlayer.dll").isSystem, false)
    }

    func testExportsOfAnARM64Library() throws {
        let file = try PEFile(url: fixture("greece.dll"))
        XCTAssertEqual(file.machine, 0xAA64)
        XCTAssertTrue(file.isDLL)
        XCTAssertEqual(WindowsPage.architecture(file).badge, "ARM64")
        let exports = try XCTUnwrap(file.exports)
        XCTAssertEqual(exports.libraryName, "greece.dll")
        XCTAssertEqual(exports.functionCount, 3)
        XCTAssertEqual(exports.nameCount, 2)
        XCTAssertEqual(Set(exports.names), ["greece_add", "greece_answer"])
    }

    func testVersionInfoAndManifest() throws {
        let file = try PEFile(url: fixture("hello.exe"))
        let version = try XCTUnwrap(file.resources?.versionInfo(in: file))
        XCTAssertEqual(version["ProductName"], "Hello Greece")
        XCTAssertEqual(version["CompanyName"], "Greece Fixtures")
        XCTAssertEqual(version["OriginalFilename"], "hello.exe")
        XCTAssertEqual(version.fileVersion, "1.2.3.4")
        XCTAssertEqual(version.productVersion, "1.2.0.0")
        XCTAssertTrue(version.isPrerelease)
        XCTAssertFalse(version.isDebugBuild)
        XCTAssertEqual(version.languages, [0x0409])

        let manifest = try XCTUnwrap(file.resources?.manifest(in: file))
        XCTAssertTrue(manifest.requiresAdministrator)
        XCTAssertFalse(manifest.uiAccess)
        XCTAssertEqual(manifest.supportedOS, ["Windows 10 and 11", "Windows 7"])
        XCTAssertEqual(manifest.dpiAware, "true/pm")
        XCTAssertTrue(manifest.longPathAware)
        XCTAssertEqual(manifest.assemblyName, "Greece.Fixtures.Hello")
    }

    func testIconIsRebuiltAsAnICOFile() throws {
        let file = try PEFile(url: fixture("hello.exe"))
        let ico = try XCTUnwrap(file.resources?.iconFile(in: file))
        XCTAssertEqual([UInt8](ico.prefix(6)), [0, 0, 1, 0, 2, 0])
        let image = try XCTUnwrap(NSImage(data: ico))
        XCTAssertEqual(Set(image.representations.map(\.pixelsWide)), [16, 32])   // a BMP entry and a PNG entry
        let best = try XCTUnwrap(WindowsPage.icon(for: fixture("hello.exe")))
        XCTAssertEqual(best.size, NSSize(width: 32, height: 32))
        XCTAssertNil(WindowsPage.icon(for: fixture("greece.dll")))
    }

    // MARK: Authenticode

    func testSignatureAndIntegrity() throws {
        let file = try PEFile(url: fixture("hello-signed.exe"))
        let signature = try XCTUnwrap(AuthenticodeSignature(file: file))
        XCTAssertEqual(signature.signer?.commonName, "Greece Test Signer")
        XCTAssertEqual(signature.signer?.organization, "Greece Fixtures")
        XCTAssertEqual(signature.digestAlgorithm, .sha256)
        XCTAssertEqual(signature.digest?.count, 32)
        XCTAssertNotNil(signature.signingTime)
        XCTAssertEqual(signature.integrity(of: file), .matches)

        // One changed byte of code: the digest no longer matches.
        var tampered = try bytes("hello-signed.exe")
        let text = try XCTUnwrap(file.sections.first { $0.name == ".text" })
        tampered[Int(text.rawOffset) + 4] ^= 0xFF
        let modified = try PEFile(data: tampered)
        XCTAssertEqual(try XCTUnwrap(AuthenticodeSignature(file: modified)).integrity(of: modified), .modified)

        // Changing the checksum is allowed: Authenticode skips it.
        var rechecked = try bytes("hello-signed.exe")
        patch32(&rechecked, at: file.checksumOffset, 0x1234_5678)
        let checksummed = try PEFile(data: rechecked)
        XCTAssertEqual(try XCTUnwrap(AuthenticodeSignature(file: checksummed)).integrity(of: checksummed), .matches)

        XCTAssertNil(AuthenticodeSignature(file: try PEFile(url: fixture("hello.exe"))))
    }

    func testPage() throws {
        let page = try WindowsPage.page(for: fixture("hello-signed.exe"), settings: PreviewSettings())
        XCTAssertEqual(page.header.title, "Hello Greece")
        XCTAssertEqual(page.header.identifier, "hello.exe")
        XCTAssertEqual(page.header.subtitle, "Version 1.2 · Greece Fixtures")
        guard case .image = page.header.icon else { return XCTFail("expected the program's icon") }
        let badges = page.badges.map(\.title)
        XCTAssertTrue(badges.contains("x64"))
        XCTAssertTrue(badges.contains("Signed"))
        XCTAssertTrue(badges.contains("Requires Administrator"))
        XCTAssertEqual(page.sections.map(\.id), ["signature", "security", "imports", "manifest", "version", "sections", "info"])
        XCTAssertEqual(page.summary.title, "Windows App")
        let check = try XCTUnwrap(page.checks.first)
        XCTAssertEqual(check.id, "windows.integrity")
        XCTAssertEqual(check.run().rows.first?.item?.tone, .positive)

        let library = try WindowsPage.page(for: fixture("greece.dll"), settings: PreviewSettings())
        XCTAssertEqual(library.summary.title, "Windows Library")
        XCTAssertTrue(library.badges.contains { $0.title == "Unsigned" })
        XCTAssertNotNil(library.section("exports"))
        XCTAssertTrue(library.checks.isEmpty)
    }

    func testInstallerAndArchiveMarkers() throws {
        let base = try bytes("hello.exe")
        func insights(appending overlay: [UInt8]) throws -> PEInsights {
            let file = try PEFile(data: base + Data(overlay))
            return PEInsights(file: file, version: nil, manifest: nil)
        }
        let nsis = try insights(appending: [0, 0, 0, 0, 0xEF, 0xBE, 0xAD, 0xDE] + Array("NullsoftInst".utf8) + [UInt8](repeating: 0, count: 64))
        XCTAssertEqual(nsis.installer, "NSIS")
        let sevenZip = try insights(appending: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C] + [UInt8](repeating: 1, count: 64))
        XCTAssertEqual(sevenZip.selfExtractingArchive, "7-Zip")
        let msi = try insights(appending: [UInt8](repeating: 0, count: 16) + [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        XCTAssertTrue(msi.containsMSI)
        let plain = try insights(appending: [])
        XCTAssertNil(plain.installer)
        XCTAssertNil(plain.selfExtractingArchive)
        XCTAssertEqual(PEInsights.prettyFramework(".NETCoreApp,Version=v8.0"), ".NET 8.0")
        XCTAssertEqual(PEInsights.prettyFramework(".NETFramework,Version=v4.7.2"), ".NET Framework 4.7.2")
    }

    // MARK: Hostile input

    func testRejectsMalformedHeaders() {
        XCTAssertThrowsError(try PEFile(data: Data()))
        XCTAssertThrowsError(try PEFile(data: Data("MZ".utf8)))
        XCTAssertThrowsError(try PEFile(data: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })))
        var lfanew = Data(count: 512)
        lfanew[0] = 0x4D; lfanew[1] = 0x5A
        patch32(&lfanew, at: 0x3C, 0xFFFF_FFF0)
        XCTAssertThrowsError(try PEFile(data: lfanew))
        // A PE signature with no optional header behind it.
        var truncated = Data(count: 0x48)
        truncated[0] = 0x4D; truncated[1] = 0x5A
        patch32(&truncated, at: 0x3C, 0x40)
        patch32(&truncated, at: 0x40, 0x4550)
        XCTAssertThrowsError(try PEFile(data: truncated))
    }

    func testSectionTableOverflow() throws {
        var data = try bytes("hello.exe")
        let file = try PEFile(data: data)
        patch16(&data, at: file.peOffset + 6, 0xFFFF)   // NumberOfSections
        let damaged = try PEFile(data: data)
        XCTAssertLessThanOrEqual(damaged.sections.count, PEFile.maxSections)
        _ = WindowsPage.page(for: damaged, url: fixture("hello.exe"))
    }

    func testImportDescriptorsCannotLoopForever() throws {
        // 256 sections; 4,096 import descriptors that all share one never-ending thunk array of ordinals.
        var (data, headers) = syntheticPE(sections: 256, directories: [1: (0x1000, 4096 * 20)])
        let descriptors = headers
        for index in 0..<200 {
            let at = descriptors + index * 20
            patch32(&data, at: at, 0x2000)          // lookup table
            patch32(&data, at: at + 12, 0x1F00)     // name
            patch32(&data, at: at + 16, 0x2000)
        }
        data.replaceSubrange((headers + 0xF00)..<(headers + 0xF08), with: Array("a.dll\0\0\0".utf8))
        var thunk = (UInt64(1) << 63 | 5).littleEndian
        let ordinal = Data(bytes: &thunk, count: 8)
        for offset in stride(from: headers + 0x1000, to: data.count, by: 8) { data.replaceSubrange(offset..<(offset + 8), with: ordinal) }
        let started = Date()
        let file = try PEFile(data: data)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(file.sections.count, 256)
        XCTAssertLessThanOrEqual(file.imports.reduce(0) { $0 + $1.functionCount }, PEFile.maxThunksTotal)
        XCTAssertTrue(file.imports.allSatisfy { $0.functions.count <= PEFile.maxNamesKept })
    }

    func testResourceDirectoryCycleAndAbsurdSizes() throws {
        var data = try bytes("hello.exe")
        let file = try PEFile(data: data)
        let resources = try XCTUnwrap(file.directory(2))
        let root = try XCTUnwrap(file.offset(ofRVA: resources.rva, length: 24))
        // The first type entry points back at the root directory.
        patch32(&data, at: root + 16 + 4, 0x8000_0000)
        // The export directory claims four billion names; the certificate table runs past the end.
        patch32(&data, at: file.directoriesOffset + 4 * 8, UInt32(data.count - 4))
        patch32(&data, at: file.directoriesOffset + 4 * 8 + 4, 0xFFFF_FFFF)
        let started = Date()
        let damaged = try PEFile(data: data)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNil(damaged.certificateTable)
        XCTAssertNil(AuthenticodeSignature(file: damaged))
        _ = WindowsPage.page(for: damaged, url: fixture("hello.exe"))

        var exports = try bytes("greece.dll")
        let library = try PEFile(data: exports)
        let directory = try XCTUnwrap(library.directory(0))
        let base = try XCTUnwrap(library.offset(ofRVA: directory.rva, length: 40))
        patch32(&exports, at: base + 20, 0xFFFF_FFFF)
        patch32(&exports, at: base + 24, 0xFFFF_FFFF)
        let inflated = try PEFile(data: exports)
        XCTAssertLessThanOrEqual(inflated.exports?.nameCount ?? 0, PEFile.maxExportNames)
        XCTAssertLessThanOrEqual(inflated.exports?.functionCount ?? 0, exports.count)
    }

    func testHostileVersionBlocksAndSignatures() {
        XCTAssertNil(PEVersionInfo(data: Data()))
        XCTAssertNil(PEVersionInfo(data: Data(repeating: 0xFF, count: 64)))
        // A block whose length is zero must not loop.
        XCTAssertNil(PEVersionInfo(data: Data([6, 0, 0, 0, 1, 0] + [UInt8](repeating: 0, count: 64))))
        XCTAssertNil(AuthenticodeSignature(pkcs7: Data()))
        XCTAssertNil(AuthenticodeSignature(pkcs7: Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF, 0x06])))
        XCTAssertNil(AuthenticodeSignature.DER.indirectDataDigest(inSignedData: Data([0x30, 0x03, 0x06, 0x01, 0x00])))
        XCTAssertNil(PEManifest(data: Data("no markup here".utf8)))
        // No closing brackets anywhere: the manifest patterns stay fast.
        let endless = Data(String(repeating: "<requestedExecutionLevel level", count: 2000).utf8)
        let started = Date()
        _ = PEManifest(data: endless)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testMutatedImagesNeverCrash() throws {
        /// Deterministic, so a failure can be replayed.
        struct SplitMix: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }
        let original = try bytes("hello-signed.exe")
        var generator = SplitMix(state: 0x6772_6565_6365)
        let started = Date()
        for _ in 0..<300 {
            var data = original
            for _ in 0..<12 {
                let position = Int.random(in: 0..<min(data.count, 2048), using: &generator)
                data[position] = UInt8.random(in: 0...255, using: &generator)
            }
            guard let file = try? PEFile(data: data) else { continue }
            _ = WindowsPage.page(for: file, url: fixture("hello-signed.exe"))
            _ = WindowsPage.icon(of: file)
            if let signature = AuthenticodeSignature(file: file) { _ = signature.integrity(of: file) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }
}

// MARK: - InstallerPackageTests

/// Flat installer packages: xar, Distribution and PackageInfo, scripts, Bom payloads, signatures and tickets.
final class InstallerPackageTests: XCTestCase {

    private static var fixtures: URL {
        if let override = ProcessInfo.processInfo.environment["GREECE_FIXTURES"] { return URL(fileURLWithPath: override) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/apps/packages")
    }

    private func fixture(_ name: String) -> URL { Self.fixtures.appendingPathComponent(name) }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreecePackages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: Detection

    func testSniffsFlatAndBundlePackages() throws {
        let head = [UInt8](try Data(contentsOf: fixture("Sample.pkg")).prefix(64))
        XCTAssertTrue(InstallerPackagePage.sniff(probe: head, ext: "pkg"))
        XCTAssertTrue(InstallerPackagePage.sniff(probe: head, ext: "mpkg"))
        XCTAssertFalse(InstallerPackagePage.sniff(probe: head, ext: "safariextz"), "other xar archives aren't installers")
        XCTAssertFalse(InstallerPackagePage.sniff(probe: Array("PK\u{3}\u{4}".utf8), ext: "pkg"))
        XCTAssertTrue(InstallerPackagePage.sniff(probe: [], ext: "pkg", isDirectory: true))
        XCTAssertFalse(InstallerPackagePage.sniff(probe: [], ext: "app", isDirectory: true))
    }

    // MARK: Parsing

    func testComponentPackage() throws {
        let package = try InstallerPackage.read(fixture("Sample.pkg"))
        XCTAssertEqual(package.kind, .component)
        XCTAssertNil(package.signature)
        XCTAssertEqual(package.components.count, 1)
        let component = try XCTUnwrap(package.components.first)
        XCTAssertEqual(component.identifier, "com.example.sample")
        XCTAssertEqual(component.version, "1.2.3")
        XCTAssertEqual(component.installLocation, "/")
        XCTAssertTrue(component.installsAsRoot)
        XCTAssertEqual(component.bundles.map(\.identifier), ["com.example.sample"])

        let scripts = component.scripts
        XCTAssertEqual(scripts.map(\.name), ["preinstall", "postinstall", "defaults.plist"])
        XCTAssertEqual(scripts.map(\.role), [.hook, .hook, .support])
        XCTAssertEqual(scripts[1].grammar, "bash")
        XCTAssertTrue(scripts[1].text?.contains("launchctl bootstrap system") == true)
        XCTAssertEqual(scripts[2].grammar, "xml")

        let payload = try XCTUnwrap(component.payload)
        let paths = Set(payload.map(\.path))
        XCTAssertTrue(paths.contains("Applications/Sample.app/Contents/Info.plist"))
        XCTAssertTrue(paths.contains("Library/LaunchDaemons/com.example.sample.helper.plist"))
        let executable = try XCTUnwrap(payload.first { $0.path == "Applications/Sample.app/Contents/MacOS/Sample" })
        XCTAssertEqual(executable.kind, .file)
        XCTAssertEqual(executable.mode & 0o777, 0o755)
        XCTAssertEqual(package.installedFiles, 3)
        XCTAssertNotNil(package.tocChecksum)
    }

    func testProductArchive() throws {
        let package = try InstallerPackage.read(fixture("SampleSuite.pkg"))
        XCTAssertEqual(package.kind, .product)
        let distribution = try XCTUnwrap(package.distribution)
        XCTAssertEqual(distribution.title, "Sample Suite")
        XCTAssertEqual(distribution.productID, "com.example.suite")
        XCTAssertEqual(distribution.productVersion, "2.0")
        XCTAssertEqual(distribution.hostArchitectures, ["arm64", "x86_64"])
        XCTAssertEqual(distribution.minimumOS, "13.0")
        XCTAssertEqual(distribution.choices.map(\.title), ["Sample App", "Extras"])
        XCTAssertEqual(distribution.mustClose, ["com.example.sample"])
        XCTAssertTrue(distribution.requiresRestart)
        XCTAssertTrue(distribution.javaScript?.contains("checkMac") == true)
        XCTAssertEqual(distribution.installationCheck, "checkMac()")
        XCTAssertEqual(package.components.map(\.identifier), ["com.example.sample", "com.example.sample.extras"])
        XCTAssertEqual(package.components[1].installLocation, "/Library/Application Support")
        XCTAssertEqual(package.components[1].installedPath("Sample/Read Me.txt"), "Library/Application Support/Sample/Read Me.txt")
        XCTAssertTrue(package.license?.contains("Sample License") == true)
    }

    func testPageSummarisesWhatMatters() throws {
        let page = try InstallerPackagePage.page(for: fixture("SampleSuite.pkg"), settings: PreviewSettings())
        XCTAssertEqual(page.header.title, "Sample Suite")
        XCTAssertEqual(page.header.subtitle, "Version 2.0")
        XCTAssertEqual(page.header.identifier, "com.example.suite")
        let badges = page.badges.map(\.title)
        XCTAssertEqual(badges.first, "Unsigned")
        XCTAssertTrue(badges.contains("Universal"))
        XCTAssertTrue(badges.contains("Runs Scripts"))
        XCTAssertTrue(badges.contains("Requires Restart"))
        let ids = page.sections.map(\.id)
        for id in ["signature", "installs", "install-details", "background", "script-findings", "scripts", "choices", "requirements", "packages", "license", "info"] {
            XCTAssertTrue(ids.contains(id), "missing \(id)")
        }
        let installs = page.section("installs")?.rows.compactMap(\.item).map(\.title) ?? []
        XCTAssertTrue(installs.contains("/Applications/Sample.app"))
        XCTAssertTrue(installs.contains("/Library/Application Support/Sample"))
        let findings = page.section("script-findings")?.rows.compactMap(\.item).map(\.title) ?? []
        XCTAssertTrue(findings.contains("Downloads files"))
        XCTAssertTrue(findings.contains("Sets up a launch daemon"))
        let background = page.section("background")?.rows.compactMap(\.item) ?? []
        XCTAssertEqual(background.map(\.subtitle), ["com.example.sample.helper"])
        guard case .tree(let root, let title, let count, _)? = page.contents else { return XCTFail("no payload tab") }
        XCTAssertEqual(title, "Payload")
        XCTAssertEqual(count, 4)
        XCTAssertEqual(Set(root.children?.map(\.name) ?? []), ["Applications", "Library"])
        XCTAssertEqual(page.summary.title, "Installer Package")
    }

    func testScriptFindingsQuoteTheLine() {
        let script = InstallerPackage.script(named: "postinstall", owner: nil,
                                             contents: Data("#!/bin/sh\necho hi\n/usr/bin/security add-trusted-cert -d -r trustRoot evil.cer\n".utf8), size: 60)
        let findings = InstallerPackagePage.scriptFindings([script])
        let certificate = findings.first { $0.title == "Adds certificates" }
        XCTAssertEqual(certificate?.tone, .critical)
        XCTAssertEqual(certificate?.help?.hasPrefix("postinstall, line 3:"), true)
        // Support files never count.
        var support = script
        support.role = .support
        XCTAssertTrue(InstallerPackagePage.scriptFindings([support]).isEmpty)
    }

    func testBundleStylePackage() throws {
        let bundle = directory.appendingPathComponent("Legacy.pkg")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.legacy", "CFBundleShortVersionString": "3.1",
                                   "IFPkgFlagDefaultLocation": "/Applications", "IFPkgFlagAuthorizationAction": "RootAuthorization"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: resources.appendingPathComponent("postflight"))
        XCTAssertTrue(InstallerPackagePage.sniff(probe: [], ext: "pkg", isDirectory: true))
        let package = try InstallerPackage.read(bundle)
        XCTAssertEqual(package.kind, .bundle)
        XCTAssertEqual(package.components.first?.identifier, "com.example.legacy")
        XCTAssertEqual(package.components.first?.installLocation, "/Applications")
        XCTAssertEqual(package.components.first?.scripts.map(\.name), ["postflight"])
        _ = InstallerPackagePage.page(for: package)
    }

    // MARK: Signatures and tickets

    func testSelfSignedSignatureVerifies() throws {
        let package = try InstallerPackage.read(fixture("SignedSample.pkg"))
        let signature = try XCTUnwrap(package.signature)
        XCTAssertEqual(signature.verdict, .valid)
        XCTAssertEqual(signature.checksumMatches, true)
        XCTAssertFalse(signature.chainsToApple)
        XCTAssertEqual(signature.certificates.first?.commonName, "Greece Test Installer")
        let page = InstallerPackagePage.page(for: package)
        XCTAssertEqual(page.badges.first?.title, "Untrusted Certificate")
        let rows = page.section("signature")?.rows.compactMap(\.item) ?? []
        XCTAssertEqual(rows.first { $0.title == "Signature" }?.value, "Valid")
        XCTAssertEqual(rows.first { $0.title == "Certificate" }?.value, "Self-signed")
    }

    func testTamperedSignatureIsCaught() throws {
        let original = try Data(contentsOf: fixture("SignedSample.pkg"))
        let xar = try XarArchive(url: fixture("SignedSample.pkg"))
        let signature = try XCTUnwrap(xar.signature)
        // Flip one byte of the RSA signature.
        var forged = original
        let position = xar.heapStart + Int(signature.offset) + 17
        forged[position] ^= 0xFF
        let forgedPackage = try InstallerPackage.read(try write("forged.pkg", forged))
        XCTAssertEqual(forgedPackage.signature?.verdict, .invalid)
        XCTAssertTrue(InstallerPackagePage.page(for: forgedPackage).badges.contains { $0.title == "Signature Invalid" })

        // Change the stored checksum: it no longer matches the table of contents.
        var altered = original
        altered[xar.heapStart + 3] ^= 0x01
        let alteredPackage = try InstallerPackage.read(try write("altered.pkg", altered))
        XCTAssertEqual(alteredPackage.signature?.checksumMatches, false)
        let rows = InstallerPackagePage.page(for: alteredPackage).section("signature")?.rows.compactMap(\.item) ?? []
        XCTAssertEqual(rows.first { $0.title == "Signature" }?.tone, .critical)
    }

    func testAppleSignedPackage() throws {
        let url = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Resources/Packages/MobileDevice.pkg")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Xcode's MobileDevice.pkg isn't installed") }
        let started = Date()
        let package = try InstallerPackage.read(url)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let signature = try XCTUnwrap(package.signature)
        XCTAssertEqual(signature.verdict, .valid)
        XCTAssertTrue(signature.chainsToApple)
        XCTAssertEqual(InstallerPackagePage.signerKind(signature), .apple)
        XCTAssertGreaterThan(package.installedFiles, 10)
    }

    func testOfflineChainCheckNeedsRealSignatures() throws {
        // The self-signed fixture: its signatures are fine, but it isn't Apple's root.
        let fixtureChain = try XCTUnwrap(try XarArchive(url: fixture("SignedSample.pkg")).signature?.certificates)
        XCTAssertTrue(CertificateChain.verify(fixtureChain[0], signedBy: fixtureChain[0]))
        XCTAssertFalse(CertificateChain.signaturesChainToAppleRoot(fixtureChain))

        let url = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Resources/Packages/MobileDevice.pkg")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Xcode's MobileDevice.pkg isn't installed") }
        let apple = try XCTUnwrap(try XarArchive(url: url).signature?.certificates)
        XCTAssertEqual(apple.count, 3)
        XCTAssertTrue(CertificateChain.signaturesChainToAppleRoot(apple))
        // A leaf that Apple didn't issue, presented with Apple's real intermediate and root.
        XCTAssertFalse(CertificateChain.signaturesChainToAppleRoot([fixtureChain[0]] + apple.dropFirst()))
        // One flipped byte inside the leaf's signed part.
        var damaged = apple[0]
        damaged[damaged.count / 3] ^= 0x01
        XCTAssertFalse(CertificateChain.signaturesChainToAppleRoot([damaged] + apple.dropFirst()))
        XCTAssertNil(CertificateChain.split(Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])))
    }

    /// A ticket in the format `stapler` writes, listing the given hashes.
    private func ticket(hashes: [Data], date: UInt64 = 1_800_000_000) -> Data {
        var body = Data("g8tk".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { body.append(contentsOf: $0) } }
        append(UInt16(2)); append(UInt16(20)); append(UInt32(hashes.count)); append(UInt32(0)); append(date)
        for hash in hashes { body.append(1); body.append(hash.prefix(20)) }
        var ticket = Data("s8ch".utf8)
        func header<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { ticket.append(contentsOf: $0) } }
        header(UInt32(1)); header(UInt32(0)); header(UInt32(body.count))
        return ticket + body + Data(repeating: 0x30, count: 72)
    }

    func testStapledTicketMustListThePackage() throws {
        let original = try Data(contentsOf: fixture("Sample.pkg"))
        let checksum = try XCTUnwrap(try XarArchive(url: fixture("Sample.pkg")).storedChecksum)

        let stapled = try InstallerPackage.read(try write("stapled.pkg", original + ticket(hashes: [Data(repeating: 7, count: 20), checksum])))
        XCTAssertTrue(stapled.ticketMatches)
        XCTAssertEqual(stapled.ticket?.notarizedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(InstallerPackagePage.page(for: stapled).badges.contains { $0.title == "Notarized" && $0.tone == .positive })

        let foreign = try InstallerPackage.read(try write("foreign.pkg", original + ticket(hashes: [Data(repeating: 9, count: 20)])))
        XCTAssertNotNil(foreign.ticket)
        XCTAssertFalse(foreign.ticketMatches)
        XCTAssertFalse(InstallerPackagePage.page(for: foreign).badges.contains { $0.title == "Notarized" })
    }

    // MARK: Hostile input

    private func xarHeader(compressed: UInt64, uncompressed: UInt64, headerSize: UInt16 = 28) -> Data {
        var data = Data("xar!".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        append(headerSize); append(UInt16(1)); append(compressed); append(uncompressed); append(UInt32(1))
        return data
    }

    /// A zlib stream ("78 01", raw deflate, Adler-32) without linking zlib into the tests.
    private func zlibWrapped(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        var result = Data([0x78, 0x01]) + deflated
        withUnsafeBytes(of: ((b << 16) | a).bigEndian) { result.append(contentsOf: $0) }
        return result
    }

    func testHostileXarHeaders() throws {
        XCTAssertThrowsError(try XarArchive(url: try write("random.pkg", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }))))
        // A TOC larger than any real package: refused before reading.
        XCTAssertThrowsError(try XarArchive(url: try write("huge.pkg", xarHeader(compressed: 1 << 40, uncompressed: 1 << 41) + Data(count: 64)))) { error in
            XCTAssertEqual(error as? XarArchive.Failure, .tooLarge)
        }
        // A TOC that runs past the end of the file.
        XCTAssertThrowsError(try XarArchive(url: try write("short.pkg", xarHeader(compressed: 4096, uncompressed: 8192) + Data(count: 100))))
        // Header sizes that point nowhere sensible.
        XCTAssertThrowsError(try XarArchive(url: try write("header.pkg", xarHeader(compressed: 10, uncompressed: 10, headerSize: 3) + Data(count: 64))))
        // Not zlib at all.
        XCTAssertThrowsError(try XarArchive(url: try write("garbage.pkg", xarHeader(compressed: 64, uncompressed: 64) + Data(repeating: 0xAB, count: 64))))
        // Entity declarations are refused outright (billion laughs and friends).
        let laughs = "<?xml version=\"1.0\"?><!DOCTYPE xar [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;\">]><xar><toc><file id=\"1\"><name>&b;</name></file></toc></xar>"
        let compressed = try zlibWrapped(Data(laughs.utf8))
        let entities = xarHeader(compressed: UInt64(compressed.count), uncompressed: UInt64(laughs.utf8.count)) + compressed + Data(count: 20)
        XCTAssertThrowsError(try XarArchive(url: try write("entities.pkg", entities)))
    }

    func testHostileHeapOffsetsAreIgnored() throws {
        let toc = """
        <?xml version="1.0"?><xar><toc><checksum style="sha1"><offset>18446744073709551615</offset><size>20</size></checksum>
        <signature style="RSA"><offset>99999999999</offset><size>256</size></signature>
        <file id="1"><name>PackageInfo</name><type>file</type><data><offset>18446744073709551000</offset><length>4096</length>
        <size>4096</size><encoding style="application/x-gzip"/></data></file></toc></xar>
        """
        let compressed = try zlibWrapped(Data(toc.utf8))
        let url = try write("offsets.pkg", xarHeader(compressed: UInt64(compressed.count), uncompressed: UInt64(toc.utf8.count)) + compressed + Data(count: 64))
        let xar = try XarArchive(url: url)
        XCTAssertNil(xar.storedChecksum)
        XCTAssertNil(xar.contents(of: "PackageInfo", limit: 1 << 20))
        XCTAssertEqual(xar.verifyRSASignature(), .unknown)
        XCTAssertNoThrow(try InstallerPackage.read(url))
    }

    func testDecompressionIsBounded() throws {
        let bomb = try zlibWrapped(Data(count: 8 << 20))
        XCTAssertLessThan(bomb.count, 64 * 1024)
        let output = try XCTUnwrap(PackageDecompression.zlib(bomb, limit: 1 << 20))
        XCTAssertTrue(output.truncated)
        XCTAssertEqual(output.data.count, 1 << 20)
        XCTAssertNil(PackageDecompression.zlib(Data(repeating: 0x55, count: 100), limit: 1024))
        XCTAssertNil(PackageDecompression.unpbzx(Data("pbzx".utf8) + Data(count: 8) + Data(repeating: 0xFF, count: 16), limit: 1024))
    }

    private func odc(_ name: String, mode: UInt32, size: UInt64, body: Data) -> Data {
        func octal(_ value: UInt64, _ width: Int) -> String {
            let text = String(value, radix: 8)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let header = "070707" + octal(0, 6) + octal(1, 6) + octal(UInt64(mode), 6) + octal(0, 6) + octal(0, 6) + octal(1, 6)
            + octal(0, 6) + octal(0, 11) + octal(UInt64(name.utf8.count + 1), 6) + octal(size, 11)
        return Data(header.utf8) + Data(name.utf8) + Data([0]) + body
    }

    func testCpioFormatsAndLies() {
        let archive = odc("./postinstall", mode: 0o100755, size: 10, body: Data("#!/bin/sh\n".utf8))
            + odc("TRAILER!!!", mode: 0, size: 0, body: Data())
        let listing = Cpio.read(archive, keepContentsUpTo: 1024)
        XCTAssertEqual(listing.entries.map(\.path), ["postinstall"])
        XCTAssertEqual(listing.entries.first?.contents, Data("#!/bin/sh\n".utf8))
        XCTAssertFalse(listing.truncated)

        // A member that claims to be enormous: listed, not read, and the walk stops.
        let liar = odc("big", mode: 0o100644, size: 0o77777777777, body: Data("tiny".utf8))
        let lied = Cpio.read(liar, keepContentsUpTo: 1 << 30)
        XCTAssertEqual(lied.entries.count, 1)
        XCTAssertNil(lied.entries.first?.contents)
        XCTAssertTrue(lied.truncated)

        // newc, 4-byte aligned, hex fields.
        func hex(_ value: Int) -> String { let text = String(value, radix: 16); return String(repeating: "0", count: 8 - text.count) + text }
        var newc = Data(("070701" + hex(1) + hex(0o100644) + hex(0) + hex(0) + hex(1) + hex(0) + hex(3) + hex(0) + hex(0) + hex(0) + hex(0)
                         + hex(2) + hex(0)).utf8) + Data("a\0".utf8)
        while newc.count % 4 != 0 { newc.append(0) }
        newc += Data("abc".utf8)
        XCTAssertEqual(Cpio.read(newc, keepContentsUpTo: 16).entries.first?.contents, Data("abc".utf8))
        XCTAssertTrue(Cpio.read(Data("070707garbage".utf8)).entries.isEmpty)
    }

    /// Builds a BOMStore with the given blocks (block 0 is reserved) and variables.
    private func bom(blocks: [Data], variables: [(String, UInt32)]) -> Data {
        var body = Data()
        var pointers: [(UInt32, UInt32)] = [(0, 0)]
        let start = 512
        for block in blocks {
            pointers.append((UInt32(start + body.count), UInt32(block.count)))
            body.append(block)
        }
        var index = Data()
        func be<T: FixedWidthInteger>(_ value: T, into data: inout Data) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        be(UInt32(pointers.count), into: &index)
        for (address, length) in pointers { be(address, into: &index); be(length, into: &index) }
        var vars = Data()
        be(UInt32(variables.count), into: &vars)
        for (name, number) in variables { be(number, into: &vars); vars.append(UInt8(name.utf8.count)); vars.append(Data(name.utf8)) }
        var header = Data("BOMStore".utf8)
        be(UInt32(1), into: &header); be(UInt32(pointers.count), into: &header)
        let indexOffset = start + body.count
        be(UInt32(indexOffset), into: &header); be(UInt32(index.count), into: &header)
        be(UInt32(indexOffset + index.count), into: &header); be(UInt32(vars.count), into: &header)
        header.append(Data(count: start - header.count))
        return header + body + index + vars
    }

    private func be32(_ values: UInt32...) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func tree(root: UInt32) -> Data { Data("tree".utf8) + be32(1, root, 4096, 1) + Data([0]) }

    private func node(leaf: Bool, forward: UInt32 = 0, pairs: [(UInt32, UInt32)]) -> Data {
        var data = Data([0, leaf ? 1 : 0, UInt8(pairs.count >> 8), UInt8(pairs.count & 0xFF)]) + be32(forward, 0)
        for (value, key) in pairs { data += be32(value, key) }
        return data
    }

    private func pathInfo(type: UInt8, size: UInt32) -> Data {
        Data([type, 1, 0, 0, 0x81, 0xA4]) + be32(0, 0, 0, size) + Data([0]) + be32(0, 0)
    }

    func testBomListsPaths() throws {
        // Blocks: 1 tree, 2 leaf, 3/4 PathInfo1, 5/6 keys, 7/8 PathInfo2.
        let blocks = [tree(root: 2), node(leaf: true, pairs: [(3, 5), (4, 6)]),
                      be32(1, 7), be32(2, 8),
                      be32(0) + Data(".\0".utf8), be32(1) + Data("tool\0".utf8),
                      pathInfo(type: 2, size: 0), pathInfo(type: 1, size: 1234)]
        let listing = try Bom.read(bom(blocks: blocks, variables: [("Paths", 1)]))
        XCTAssertEqual(listing.entries.map(\.path), ["tool"])
        XCTAssertEqual(listing.entries.first?.size, 1234)
        XCTAssertEqual(listing.entries.first?.kind, .file)
    }

    func testBomRefusesCyclesAndBadPointers() throws {
        // A branch whose first child is itself.
        let cyclic = bom(blocks: [tree(root: 2), node(leaf: false, pairs: [(2, 0)])], variables: [("Paths", 1)])
        XCTAssertThrowsError(try Bom.read(cyclic))
        // A leaf that links forward to itself, pointing at blocks that don't exist.
        let looping = bom(blocks: [tree(root: 2), node(leaf: true, forward: 2, pairs: [(900, 901), (3, 4)]), be32(1, 99), be32(1) + Data("x\0".utf8)],
                          variables: [("Paths", 1)])
        _ = try? Bom.read(looping)
        // Parents that point at each other never resolve to a path.
        let parents = bom(blocks: [tree(root: 2), node(leaf: true, pairs: [(3, 5), (4, 6)]), be32(1, 7), be32(2, 7),
                                   be32(2) + Data("a\0".utf8), be32(1) + Data("b\0".utf8), pathInfo(type: 1, size: 1)],
                          variables: [("Paths", 1)])
        let listing = try? Bom.read(parents)
        XCTAssertTrue(listing?.entries.isEmpty ?? true)
        // No Paths variable, a truncated header, the wrong magic.
        XCTAssertThrowsError(try Bom.read(bom(blocks: [tree(root: 2)], variables: [("BomInfo", 1)])))
        XCTAssertThrowsError(try Bom.read(Data("BOMStore".utf8) + Data(count: 8)))
        XCTAssertThrowsError(try Bom.read(Data(count: 1024)))
    }

    func testRandomBytesNeverCrash() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        func noise(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }) }
        let sample = try Data(contentsOf: fixture("Sample.pkg"))
        for round in 0..<60 {
            _ = try? Bom.read(Data("BOMStore".utf8) + noise(512 + Int(next() % 4096)))
            _ = Cpio.read(Data("070707".utf8) + noise(Int(next() % 512)))
            _ = PackageDecompression.decode(noise(Int(next() % 2048)), limit: 1 << 16)
            // Flip bytes across a real package, header and TOC included.
            var damaged = sample
            for _ in 0..<(1 + round % 8) {
                let position = Int(next() % UInt64(damaged.count))
                damaged[position] = UInt8(truncatingIfNeeded: next())
            }
            let url = try write("damaged-\(round).pkg", damaged)
            if let package = try? InstallerPackage.read(url) { _ = InstallerPackagePage.page(for: package) }
        }
    }
}

// MARK: - AndroidTests

final class AndroidTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/apps/android")

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AndroidTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String) -> URL { Self.fixtures.appendingPathComponent(name) }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Deterministic pseudo-random bytes, so failures reproduce.
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func bytes(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }) }
    }

    private func pixel(_ image: NSImage, _ fx: CGFloat, _ fy: CGFloat) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let x = min(rep.pixelsWide - 1, Int(CGFloat(rep.pixelsWide) * fx))
        let y = min(rep.pixelsHigh - 1, Int(CGFloat(rep.pixelsHigh) * fy))
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    // MARK: Detection

    func testSniffsAndroidPackagesByZipMagicAndExtension() {
        let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]
        XCTAssertTrue(AndroidPage.sniff(probe: zip, ext: "apk"))
        XCTAssertTrue(AndroidPage.sniff(probe: zip, ext: "aab"))
        XCTAssertFalse(AndroidPage.sniff(probe: zip, ext: "zip"))
        XCTAssertFalse(AndroidPage.sniff(probe: Array("not a zip".utf8), ext: "apk"))
        XCTAssertFalse(AndroidPage.sniff(probe: [], ext: "apk"))
    }

    // MARK: APK

    func testReadsBinaryManifestAndResourceTable() throws {
        let package = try AndroidPackageReader.read(fixture("sample.apk"))
        XCTAssertEqual(package.kind, .apk)
        XCTAssertEqual(package.package, "com.greece.sample")
        XCTAssertEqual(package.versionName, "1.2.3")
        XCTAssertEqual(package.versionCode, "42")
        XCTAssertEqual(package.minSdk, 26)
        XCTAssertEqual(package.targetSdk, 34)
        XCTAssertEqual(package.label, "Greece Sample")
        XCTAssertEqual(package.locales, 1)
        XCTAssertTrue(package.permissions.contains("android.permission.CAMERA"))
        XCTAssertTrue(package.permissions.contains("android.permission.READ_SMS"))
        XCTAssertEqual(package.definedPermissions, ["com.greece.sample.INTERNAL"])
        XCTAssertEqual(package.launcherActivity, "com.greece.sample.MainActivity")
        XCTAssertEqual(package.activities.count, 1)
        XCTAssertEqual(package.services.first?.permission, "android.permission.BIND_ACCESSIBILITY_SERVICE")
        XCTAssertEqual(package.receivers.first?.exported, true)
        XCTAssertEqual(package.providers.first?.exported, false)
        XCTAssertTrue(package.links.contains(.init(scheme: "https", host: "greece.example", path: nil, verified: true)))
        XCTAssertTrue(package.links.contains(.init(scheme: "greece", host: nil, path: nil, verified: false)))
        XCTAssertEqual(package.abis.map(\.name), ["arm64-v8a"])
        XCTAssertTrue(package.frameworks.contains("Flutter"))
        XCTAssertEqual(package.dexCount, 1)
        XCTAssertTrue(package.debuggable)
        XCTAssertEqual(package.allowBackup, false)
        XCTAssertEqual(package.usesCleartextTraffic, true)
        XCTAssertEqual(package.features, [.init(name: "android.hardware.camera", required: false)])
    }

    func testReadsSignatureSchemesAndCertificate() throws {
        let package = try AndroidPackageReader.read(fixture("sample.apk"))
        XCTAssertEqual(package.signature.schemes, ["v1 (JAR)", "v2", "v3"])
        XCTAssertFalse(package.signature.isDebugCertificate)
        let leaf = try XCTUnwrap(package.signature.certificates.first.flatMap { CertificateSummary(der: $0) })
        XCTAssertEqual(leaf.commonName, "Greece Test")
        XCTAssertEqual(leaf.organization, "Greece")
    }

    func testSigningBlockListsSchemesInOrder() throws {
        let zip = try ZipFile(url: fixture("sample.apk"))
        let ids = AndroidSigning.signingBlock(zip.data, centralDirectory: zip.centralDirectoryOffset).map(\.0)
        XCTAssertTrue(ids.contains(AndroidSigning.v2ID))
        XCTAssertTrue(ids.contains(AndroidSigning.v3ID))
    }

    func testIconComesFromTheSharpestBitmap() throws {
        let icon = try XCTUnwrap(AndroidPage.icon(for: fixture("sample.apk")))
        XCTAssertEqual(icon.size.width, 192)
        let center = try XCTUnwrap(pixel(icon, 0.5, 0.5))
        let corner = try XCTUnwrap(pixel(icon, 0.05, 0.05))
        XCTAssertGreaterThan(center.greenComponent, 0.95)
        XCTAssertGreaterThan(center.redComponent, 0.95)
        XCTAssertLessThan(corner.redComponent, 0.4)
        XCTAssertGreaterThan(corner.greenComponent, 0.5)
    }

    func testAdaptiveVectorIconIsCompositedAndMasked() throws {
        let icon = try XCTUnwrap(AndroidPage.icon(for: fixture("adaptive-unsigned.apk")))
        let center = try XCTUnwrap(pixel(icon, 0.5, 0.5))          // the yellow dot of the vector foreground
        XCTAssertGreaterThan(center.redComponent, 0.9)
        XCTAssertLessThan(center.blueComponent, 0.3)
        let background = try XCTUnwrap(pixel(icon, 0.12, 0.5))     // the colour layer
        XCTAssertGreaterThan(background.blueComponent, 0.8)
        let corner = try XCTUnwrap(pixel(icon, 0.02, 0.02))        // outside the circular mask
        XCTAssertLessThan(corner.alphaComponent, 0.1)
    }

    func testUnsignedPackageIsFlagged() throws {
        let page = try AndroidPage.page(for: fixture("adaptive-unsigned.apk"), settings: PreviewSettings())
        XCTAssertEqual(page.badges.first { $0.id == "signer" }?.title, "Unsigned")
        XCTAssertEqual(page.badges.first { $0.id == "signer" }?.tone, .critical)
        XCTAssertEqual(page.badges.first { $0.id == "architectures" }?.title, "Any Architecture")
    }

    func testPageGroupsWhatMatters() throws {
        let page = try AndroidPage.page(for: fixture("sample.apk"), settings: PreviewSettings())
        XCTAssertEqual(page.header.title, "Greece Sample")
        XCTAssertEqual(page.header.subtitle, "Version 1.2.3 (42)")
        XCTAssertEqual(page.header.identifier, "com.greece.sample")
        XCTAssertEqual(page.summary.title, "Android App")
        XCTAssertEqual(page.sections.map(\.id),
                       ["permissions", "integrations", "links", "signature", "components", "architectures", "builtWith", "size", "info"])
        XCTAssertTrue(page.badges.contains { $0.id == "debuggable" && $0.tone == .caution })
        let permissions = page.section("permissions")?.rows.compactMap(\.item) ?? []
        // Sensitive and special permissions first; the app's own internal permission is hidden.
        XCTAssertEqual(permissions.first?.help, "android.permission.SYSTEM_ALERT_WINDOW")
        let sms = try XCTUnwrap(permissions.first { $0.help == "android.permission.READ_SMS" })
        XCTAssertEqual(sms.tone, .caution)
        XCTAssertEqual(sms.value, "Asks first")
        XCTAssertFalse(permissions.contains { $0.help == "com.greece.sample.INTERNAL" })
        XCTAssertTrue(permissions.contains { $0.title == "Custom permissions" && $0.details.first?.title == "com.example.other.permission.CUSTOM" })
        let integrations = page.section("integrations")?.rows.compactMap(\.item).map(\.title) ?? []
        XCTAssertEqual(integrations, ["Accessibility service", "Home screen widget"])
        guard case .tree(_, _, let count, _)? = page.contents else { return XCTFail("contents") }
        XCTAssertEqual(count, 9)
    }

    // MARK: App Bundles

    func testReadsAppBundleProtobufManifestAndResources() throws {
        let package = try AndroidPackageReader.read(fixture("sample.aab"))
        XCTAssertEqual(package.kind, .bundle)
        XCTAssertEqual(package.package, "com.greece.sample")
        XCTAssertEqual(package.versionCode, "42")
        XCTAssertEqual(package.minSdk, 26)
        XCTAssertEqual(package.label, "Greece Sample")
        XCTAssertNotNil(package.icon)
        XCTAssertEqual(package.bundletoolVersion, "1.15.6")
        XCTAssertEqual(package.signature.schemes, ["v1 (JAR)"])
        XCTAssertEqual(package.abis.map(\.name), ["arm64-v8a"])
        XCTAssertEqual(package.dexCount, 1)
        XCTAssertEqual(package.launcherActivity, "com.greece.sample.MainActivity")
        let page = AndroidPage.page(for: package, url: fixture("sample.aab"), settings: PreviewSettings())
        XCTAssertEqual(page.summary.title, "Android App Bundle")
    }

    // MARK: Catalogs

    func testPermissionsReadPlainly() {
        let camera = AndroidPermission.describe("android.permission.CAMERA")
        XCTAssertEqual(camera.title, "Camera")
        XCTAssertEqual(camera.level, .runtime)
        XCTAssertTrue(AndroidPermission.describe("android.permission.SEND_SMS").sensitive)
        XCTAssertEqual(AndroidPermission.describe("android.permission.SYSTEM_ALERT_WINDOW").level, .special)
        XCTAssertEqual(AndroidPermission.describe("android.permission.FOREGROUND_SERVICE_CAMERA").title, "Foreground service (camera)")
        XCTAssertEqual(AndroidPermission.describe("com.example.permission.DO_THING").title, "Do thing")
        XCTAssertEqual(AndroidIntegration.forBindPermission("android.permission.BIND_VPN_SERVICE")?.title, "VPN")
        XCTAssertNil(AndroidIntegration.forBindPermission("android.permission.BIND_JOB_SERVICE"))
    }

    func testAndroidVersionNames() {
        XCTAssertEqual(AndroidVersions.describe(26), "Android 8.0 (API 26)")
        XCTAssertEqual(AndroidVersions.describe(34), "Android 14 (API 34)")
        XCTAssertEqual(AndroidVersions.describe(99), "API 99")
        XCTAssertEqual(AndroidVersions.short(21), "Android 5.0+")
    }

    // MARK: Hostile input

    func testBinaryXMLRejectsGarbage() {
        XCTAssertThrowsError(try AndroidBinaryXML.parse(Data()))
        XCTAssertThrowsError(try AndroidBinaryXML.parse(Data([0x03, 0x00, 0x08, 0x00, 0x08, 0, 0, 0])))
        var generator = Generator(state: 1)
        for _ in 0..<50 {
            XCTAssertThrowsError(try AndroidBinaryXML.parse(generator.bytes(512)))
        }
    }

    func testBinaryXMLSurvivesTruncationAndCorruption() throws {
        let zip = try ZipFile(url: fixture("sample.apk"))
        let manifest = try XCTUnwrap(zip.contents(of: "AndroidManifest.xml"))
        for length in stride(from: 0, to: manifest.count, by: 37) {
            _ = try? AndroidBinaryXML.parse(manifest.prefix(length))
        }
        var generator = Generator(state: 7)
        for _ in 0..<300 {
            var corrupted = manifest
            for _ in 0..<8 {
                let index = Int(generator.next() % UInt64(corrupted.count))
                corrupted[index] = UInt8(truncatingIfNeeded: generator.next())
            }
            if let root = try? AndroidBinaryXML.parse(corrupted) {
                var package = AndroidPackage(kind: .apk)
                AndroidPackageReader.apply(root, to: &package, resources: nil)
            }
        }
    }

    func testHostileStringPoolIsRejectedCheaply() {
        // An XML chunk whose string pool claims two billion strings.
        var data = Data()
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        u16(0x0003); u16(8); u32(8 + 28)
        u16(0x0001); u16(28); u32(28); u32(0x7FFF_FFFF); u32(0); u32(0); u32(28); u32(0)
        let started = Date()
        XCTAssertThrowsError(try AndroidBinaryXML.parse(data))
        XCTAssertNil(AndroidStringPool(data: data, chunk: 8))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testDeeplyNestedBinaryXMLIsBounded() throws {
        // 20,000 nested <a> elements: depth and element limits keep this flat and fast.
        var data = Data()
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        u16(0x0003); u16(8); u32(0)
        // String pool with one UTF-8 string "a".
        u16(0x0001); u16(28); u32(36); u32(1); u32(0); u32(0x100); u32(32); u32(0); u32(0); data.append(contentsOf: [1, 1, 0x61, 0])
        for _ in 0..<20_000 {
            u16(0x0102); u16(16); u32(36); u32(1); u32(0xFFFF_FFFF)
            u32(0xFFFF_FFFF); u32(0); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0)
        }
        let started = Date()
        let root = try? AndroidBinaryXML.parse(data, deadline: Date().addingTimeInterval(2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        var depth = 0
        var node = root
        while let current = node { depth += 1; node = current.children.first }
        XCTAssertLessThanOrEqual(depth, AndroidXMLLimits.maxDepth)
    }

    func testProtobufXMLRejectsGarbageAndBoundsNesting() {
        XCTAssertThrowsError(try AndroidProtoXML.parse(Data()))
        var generator = Generator(state: 3)
        for _ in 0..<50 { _ = try? AndroidProtoXML.parse(generator.bytes(256)) }
        // XmlNode { element { child { element { child … } } } } nested 2,000 deep.
        func varint(_ value: Int) -> Data {
            var value = UInt64(value), bytes = Data()
            repeat { var byte = UInt8(value & 0x7F); value >>= 7; if value != 0 { byte |= 0x80 }; bytes.append(byte) } while value != 0
            return bytes
        }
        var element = Data([0x1A, 0x01, 0x61])   // name = "a"
        for _ in 0..<2_000 {
            let node = Data([0x0A]) + varint(element.count) + element          // XmlNode.element
            element = Data([0x1A, 0x01, 0x61, 0x2A]) + varint(node.count) + node // XmlElement { name, child }
        }
        let document = Data([0x0A]) + varint(element.count) + element
        let root = try? AndroidProtoXML.parse(document)
        var depth = 0
        var node = root
        while let current = node { depth += 1; node = current.children.first }
        XCTAssertLessThanOrEqual(depth, AndroidXMLLimits.maxDepth)
    }

    func testResourceTablesSurviveTruncation() throws {
        let zip = try ZipFile(url: fixture("sample.apk"))
        let table = try XCTUnwrap(zip.contents(of: "resources.arsc"))
        for length in stride(from: 0, to: table.count, by: 13) {
            if let resources = try? AndroidBinaryResources(data: table.prefix(length)) {
                _ = resources.string(for: 0x7f01_0000)
                _ = resources.files(for: 0x7f02_0000)
            }
        }
        var generator = Generator(state: 11)
        for _ in 0..<200 {
            var corrupted = table
            for _ in 0..<6 {
                corrupted[Int(generator.next() % UInt64(corrupted.count))] = UInt8(truncatingIfNeeded: generator.next())
            }
            if let resources = try? AndroidBinaryResources(data: corrupted) {
                for id: UInt32 in [0x7f01_0000, 0x7f02_0000, 0x7f03_0000, 0xFFFF_FFFF] { _ = resources.values(for: id) }
            }
        }
        let bundle = try ZipFile(url: fixture("sample.aab"))
        let proto = try XCTUnwrap(bundle.contents(of: "base/resources.pb"))
        for length in stride(from: 0, to: proto.count, by: 29) { _ = try? AndroidProtoResources(data: proto.prefix(length)) }
    }

    func testSigningBlockRejectsLies() {
        var data = Data(count: 64)
        data.append(Data("APK Sig Block 42".utf8))
        // A block size larger than the file before it.
        var lie = data
        lie.replaceSubrange(56..<64, with: withUnsafeBytes(of: UInt64(1 << 40).littleEndian) { Data($0) })
        XCTAssertTrue(AndroidSigning.signingBlock(lie, centralDirectory: lie.count).isEmpty)
        XCTAssertTrue(AndroidSigning.signingBlock(data, centralDirectory: 12).isEmpty)
        XCTAssertTrue(AndroidSigning.signingBlock(data, centralDirectory: data.count + 100).isEmpty)
        var generator = Generator(state: 5)
        for _ in 0..<100 {
            _ = AndroidSigning.parseSigners(generator.bytes(300), isV3: true)
            _ = AndroidSigning.certificates(inPKCS7: generator.bytes(200))
        }
    }

    func testZipThatLiesAboutTheManifestSize() throws {
        var data = try Data(contentsOf: fixture("sample.apk"))
        // Find the central directory record for AndroidManifest.xml and claim it's 4 GB.
        let name = Data("AndroidManifest.xml".utf8)
        var patched = false
        var offset = 0
        while let found = data.firstRange(of: [0x50, 0x4B, 0x01, 0x02], from: offset) {
            if data.subdata(in: (found + 46)..<(found + 46 + name.count)) == name {
                data.replaceSubrange((found + 24)..<(found + 28), with: [0xF0, 0xFF, 0xFF, 0xFF])
                patched = true
                break
            }
            offset = found + 4
        }
        XCTAssertTrue(patched)
        let url = try write("liar.apk", data)
        XCTAssertThrowsError(try AndroidPackageReader.read(url))
    }

    func testRandomBytesAreNotAnAndroidPackage() throws {
        var generator = Generator(state: 9)
        let url = try write("noise.apk", generator.bytes(4096))
        XCTAssertThrowsError(try AndroidPage.page(for: url, settings: PreviewSettings()))
        XCTAssertNil(AndroidPage.icon(for: url))
    }

    func testFuzzedPackagesNeverCrash() throws {
        let original = try Data(contentsOf: fixture("sample.apk"))
        var generator = Generator(state: 13)
        let started = Date()
        for round in 0..<60 {
            var data = original
            for _ in 0..<(1 + round % 12) {
                data[Int(generator.next() % UInt64(data.count))] = UInt8(truncatingIfNeeded: generator.next())
            }
            let url = try write("fuzz-\(round).apk", data)
            _ = try? AndroidPage.page(for: url, settings: PreviewSettings())
            _ = AndroidPage.icon(for: url)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testIconDecodingRefusesGiantDimensions() {
        // A PNG header claiming 100,000 × 100,000 pixels must never be decoded.
        func chunk(_ kind: String, _ body: [UInt8]) -> [UInt8] {
            let type = Array(kind.utf8)
            var crc = UInt32(0xFFFF_FFFF)
            for byte in type + body {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            crc ^= 0xFFFF_FFFF
            let length = UInt32(body.count)
            return [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + type + body
                + [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
        }
        let side: [UInt8] = [0x00, 0x01, 0x86, 0xA0]   // 100,000
        let header = chunk("IHDR", side + side + [8, 6, 0, 0, 0])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + header + chunk("IEND", []))
        XCTAssertNil(AndroidIcon.decode(png))
        XCTAssertNil(AndroidIcon.decode(Data("not an image".utf8)))
    }

    func testOpenGLRequirementIsNamed() throws {
        // <uses-feature android:glEsVersion="0x00030000"/> has no name attribute.
        let manifest = AndroidXMLElement(name: "manifest", attributes: [])
        manifest.children = [AndroidXMLElement(name: "uses-feature", attributes: [
            AndroidXMLAttribute(namespace: nil, name: "glEsVersion", resourceID: 0x0101_0281, value: .int(0x0003_0000)),
        ])]
        var package = AndroidPackage(kind: .apk)
        AndroidPackageReader.apply(manifest, to: &package, resources: nil)
        XCTAssertEqual(package.features, [.init(name: "OpenGL ES 3.0", required: true)])
    }

    func testSVGPathData() {
        XCTAssertNotNil(SVGPath.parse("M0,0 L10,10 Z"))
        XCTAssertNotNil(SVGPath.parse("m1 1h2v2h-2z M5,5 c1,1 2,2 3,3 s1,1 2,2 q1,1 2,2 t1,1 a2,2 0 1,1 4,0"))
        XCTAssertNotNil(SVGPath.parse("M0,0a0,0 0 0,1 5,5"))       // zero radius becomes a line
        XCTAssertNotNil(SVGPath.parse("M1e2,-.5.5L3,4"))           // exponents and packed decimals
        XCTAssertNil(SVGPath.parse(""))
        XCTAssertNil(SVGPath.parse("hello"))
        let started = Date()
        _ = SVGPath.parse("M0,0" + String(repeating: "z1", count: 200_000))
        _ = SVGPath.parse(String(repeating: "L", count: 300_000))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}

// MARK: - DiskImageTests

final class DiskImageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceDiskImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/apps/diskimages/\(name)")
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func entry(_ contents: DiskImage.Contents, _ path: String) -> VolumeEntry? {
        contents.entries.first { $0.path == path }
    }

    // MARK: Detection

    func testDetection() throws {
        XCTAssertTrue(DiskImage.sniff(probe: [], ext: "dmg", isDirectory: false))
        XCTAssertTrue(DiskImage.sniff(probe: Array("encrcdsa".utf8) + [0, 0, 0, 2], ext: "bin", isDirectory: false))
        XCTAssertTrue(DiskImage.sniff(probe: Array("sprs".utf8) + [0, 0, 0, 3], ext: "sparseimage", isDirectory: false))
        XCTAssertTrue(DiskImage.sniff(probe: Array("shdw".utf8) + [0, 0, 0, 1, 0, 0, 2, 0], ext: "asif", isDirectory: false))
        XCTAssertTrue(DiskImage.sniff(probe: [], ext: "iso", isDirectory: false))
        XCTAssertTrue(DiskImage.sniff(probe: [], ext: "sparsebundle", isDirectory: true))
        XCTAssertFalse(DiskImage.sniff(probe: [], ext: "app", isDirectory: true))
        // CorelDRAW drawings share .cdr with Apple's DVD/CD masters.
        XCTAssertFalse(DiskImage.sniff(probe: Array("RIFF".utf8) + [0, 0, 0, 0], ext: "cdr", isDirectory: false))
        // .img needs a partition map (or a UDIF trailer) to be claimed.
        var mbr = [UInt8](repeating: 0, count: 512)
        mbr[510] = 0x55; mbr[511] = 0xAA
        XCTAssertTrue(DiskImage.sniff(probe: mbr, ext: "img", isDirectory: false))
        XCTAssertFalse(DiskImage.sniff(probe: [UInt8](repeating: 7, count: 600), ext: "img", isDirectory: false))
        XCTAssertFalse(DiskImage.sniff(probe: Array("shdw".utf8), ext: "txt", isDirectory: false))
        XCTAssertFalse(DiskImage.sniff(probe: [], ext: "txt", isDirectory: false))
        // A UDIF .img is recognised from its trailer.
        let udifAsImg = try write("copy.img", try Data(contentsOf: fixture("Sample-HFS-zlib.dmg")))
        XCTAssertTrue(DiskImage.sniff(udifAsImg, probe: [], ext: "img", isDirectory: false))
    }

    // MARK: Fixtures

    func testHFSZlibImageWithLicense() throws {
        let image = try DiskImage(url: fixture("Sample-HFS-zlib.dmg"))
        XCTAssertEqual(image.container, .udif)
        XCTAssertEqual(image.format.code, "UDZO")
        XCTAssertEqual(image.format.compression, "zlib")
        XCTAssertEqual(image.virtualSize, 3842 * 512)
        XCTAssertEqual(image.udif?.trailer.masterChecksum?.text, "$A030D4BB")
        XCTAssertEqual(image.partitionMap.scheme, .guid)
        XCTAssertEqual(image.partitionMap.readable.first?.fileSystem, .hfsPlus)
        XCTAssertNil(image.codeSignatureRange)
        XCTAssertTrue(image.udif?.licenseText?.hasPrefix("Sample License Agreement") ?? false)

        let contents = try XCTUnwrap(image.contents())
        XCTAssertEqual(contents.volumeName, "Sample HFS")
        XCTAssertEqual(contents.fileSystem, .hfsPlus)
        XCTAssertFalse(contents.truncated)
        XCTAssertEqual(contents.fileCount, 8)
        XCTAssertEqual(entry(contents, "Docs/Nested/Deeper/readme.txt")?.size, 19)
        XCTAssertEqual(entry(contents, "Docs/Nested/Deeper")?.isDirectory, true)
        XCTAssertEqual(entry(contents, "notes-link")?.isSymlink, true)
        XCTAssertTrue(contents.applicationsLink)
        XCTAssertEqual(contents.backgroundImage, ".background/background.png")

        let app = try XCTUnwrap(contents.apps.first)
        XCTAssertEqual(contents.apps.count, 1)
        XCTAssertEqual(app.name, "Sample App")
        XCTAssertEqual(app.version, "1.2.3")
        XCTAssertEqual(app.build, "45")
        XCTAssertEqual(app.bundleID, "com.example.sample")
        XCTAssertEqual(app.minimumSystem, "13.0")
        XCTAssertNotNil(app.icon)

        let volume = try XCTUnwrap(image.openVolume())
        XCTAssertEqual(try volume.readFile("Docs/Nested/Deeper/readme.txt", limit: 1024), Data("Deep file contents\n".utf8))
        XCTAssertEqual(try volume.linkTarget("notes-link"), "Docs/notes.txt")
        XCTAssertEqual(try volume.linkTarget("Applications"), "/Applications")
        XCTAssertThrowsError(try volume.readFile("Docs/Nested/Deeper/readme.txt", limit: 4))
        XCTAssertThrowsError(try volume.readFile("Docs/missing.txt", limit: 1024))
    }

    func testFilesInsideAnImagePreview() throws {
        // The Files tab reads members through the image without mounting it, for the preview pane.
        let page = try AppsModule.makePage(FileInfo(url: fixture("Sample-HFS-zlib.dmg")))
        guard case .tree(let root, _, _, let members)? = page.contents, let members else { return XCTFail("no previewable file tab") }
        func node(_ path: String, in parent: FileNode) -> FileNode? {
            if parent.path == path { return parent }
            for child in parent.children ?? [] { if let found = node(path, in: child) { return found } }
            return nil
        }
        let readme = try XCTUnwrap(node("Docs/Nested/Deeper/readme.txt", in: root))
        let scratch = ArchiveScratch()
        let file = try members.extract(readme, to: scratch, cancel: CancelToken())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Deep file contents\n")
        XCTAssertEqual(file.lastPathComponent, "readme.txt", "named as inside, so its kind is recognised")
        let folder = try XCTUnwrap(node("Docs/Nested", in: root))
        XCTAssertThrowsError(try members.extract(folder, to: scratch, cancel: CancelToken()))
    }

    func testAPFSLZFSEImage() throws {
        let image = try DiskImage(url: fixture("Sample-APFS-lzfse.dmg"))
        XCTAssertEqual(image.format.code, "ULFO")
        XCTAssertEqual(image.partitionMap.readable.first?.fileSystem, .apfs)
        let contents = try XCTUnwrap(image.contents())
        XCTAssertEqual(contents.volumeName, "Sample APFS")
        XCTAssertEqual(contents.fileSystem, .apfs)
        XCTAssertEqual(contents.fileCount, 8)
        XCTAssertEqual(contents.folderCount, 8)
        XCTAssertEqual(entry(contents, "Docs/Nested/Deeper/readme.txt")?.size, 19)
        XCTAssertEqual(entry(contents, "notes-link")?.isSymlink, true)
        XCTAssertEqual(contents.apps.first?.bundleID, "com.example.sample")
        XCTAssertNotNil(contents.apps.first?.icon)
        let volume = try XCTUnwrap(image.openVolume())
        XCTAssertEqual(try volume.readFile("Docs/notes.txt", limit: 1024), Data("hello\n".utf8))
        XCTAssertEqual(try volume.linkTarget("notes-link"), "Docs/notes.txt")
    }

    func testOtherCompressions() throws {
        for (name, code) in [("Sample-HFS-bzip2.dmg", "UDBZ"), ("Sample-HFS-lzma.dmg", "ULMO"), ("Sample-HFS-adc.dmg", "UDCO")] {
            let image = try DiskImage(url: fixture(name))
            XCTAssertEqual(image.format.code, code, name)
            let volume = try XCTUnwrap(image.openVolume(), name)
            XCTAssertEqual(try volume.readFile("Docs/Nested/Deeper/readme.txt", limit: 1024), Data("Deep file contents\n".utf8), name)
            XCTAssertEqual(image.contents()?.fileCount, 8, name)
        }
    }

    func testISO() throws {
        let image = try DiskImage(url: fixture("Sample.iso"))
        XCTAssertEqual(image.container, .raw)
        XCTAssertEqual(image.format.code, "ISO")
        let contents = try XCTUnwrap(image.contents())
        XCTAssertEqual(contents.fileSystem, .iso9660)
        XCTAssertEqual(contents.volumeName, "SAMPLEISO")
        // Joliet keeps long names with spaces and case.
        XCTAssertEqual(entry(contents, "Read Me First.txt")?.size, 6)
        XCTAssertEqual(entry(contents, "Docs/Nested/readme.txt")?.size, 19)
        XCTAssertEqual(try image.openVolume()?.readFile("Docs/Nested/readme.txt", limit: 1024), Data("Deep file contents\n".utf8))
    }

    func testSparseImage() throws {
        let image = try DiskImage(url: fixture("Sample.sparseimage"))
        XCTAssertEqual(image.container, .sparseImage)
        XCTAssertEqual(image.format.code, "UDSP")
        let contents = try XCTUnwrap(image.contents())
        XCTAssertEqual(contents.fileSystem, .hfsX)
        XCTAssertEqual(contents.volumeName, "Sparse")
        XCTAssertEqual(contents.fileCount, 2)
        XCTAssertEqual(try image.openVolume()?.readFile("Folder/inner.txt", limit: 64), Data("nested\n".utf8))
        XCTAssertEqual(try image.openVolume()?.readFile("hello.txt", limit: 64), Data("Sparse fixture\n".utf8))
    }

    func testEncryptedImage() throws {
        let image = try DiskImage(url: fixture("Encrypted-header.dmg"))
        XCTAssertEqual(image.container, .encrypted)
        XCTAssertEqual(image.encryption?.keyBits, 256)
        XCTAssertEqual(image.encryption?.algorithm, "AES-256")
        XCTAssertEqual(image.virtualSize, 1 << 20)
        XCTAssertNil(image.contents())
        let page = DiskImagePage.page(for: image, settings: PreviewSettings())
        XCTAssertTrue(page.badges.contains { $0.id == "encrypted" })
        XCTAssertNil(page.contents)
    }

    func testPage() throws {
        let page = try DiskImagePage.page(for: fixture("Sample-HFS-zlib.dmg"), settings: PreviewSettings())
        XCTAssertEqual(page.header.title, "Sample App")
        XCTAssertEqual(page.header.subtitle, "Version 1.2.3 (45)")
        XCTAssertEqual(page.header.identifier, "com.example.sample")
        XCTAssertEqual(page.badges.map(\.id), ["format", "license"])
        XCTAssertEqual(page.sections.map(\.id), ["apps", "image", "volume", "license"])
        XCTAssertEqual(page.summary.title, "Disk Image")
        guard case .tree(_, let title, let count, _)? = page.contents else { return XCTFail("no file listing") }
        XCTAssertEqual(title, "Files")
        XCTAssertEqual(count, 8)
    }

    // MARK: Synthetic containers

    /// Wraps a raw disk in an ASIF file with 64 KB chunks: header, two directories, table, then data.
    private func asif(wrapping disk: Data, skipZeroChunks: Bool = true) -> Data {
        let chunk = 65_536
        let chunks = (disk.count + chunk - 1) / chunk
        var file = Data(count: chunk * 2)
        func put64(_ value: UInt64, at offset: Int) { withUnsafeBytes(of: value.bigEndian) { file.replaceSubrange(offset..<(offset + 8), with: $0) } }
        func put32(_ value: UInt32, at offset: Int) { withUnsafeBytes(of: value.bigEndian) { file.replaceSubrange(offset..<(offset + 4), with: $0) } }
        file.replaceSubrange(0..<4, with: Data("shdw".utf8))
        put32(1, at: 4); put32(512, at: 8)
        put64(512, at: 16); put64(1024, at: 24)
        put64(UInt64(disk.count / 512), at: 48)
        put32(UInt32(chunk), at: 64)
        file.replaceSubrange(68..<70, with: [0x02, 0x00])
        // The older directory points at a bogus table; the newer one (generation 5) wins.
        put64(1, at: 512); put64(999, at: 520)
        put64(5, at: 1024); put64(1, at: 1032)
        var stored = 2
        var data = Data()
        for index in 0..<chunks {
            let slice = disk.subdata(in: (index * chunk)..<min(disk.count, (index + 1) * chunk))
            if skipZeroChunks && !slice.contains(where: { $0 != 0 }) {
                put64(0x8000_0000_0000_0000, at: chunk + index * 8)
                continue
            }
            put64(0xC000_0000_0000_0000 | UInt64(stored), at: chunk + index * 8)
            var padded = slice
            padded.count = chunk
            data.append(padded)
            stored += 1
        }
        return file + data
    }

    func testSyntheticASIF() throws {
        let disk = try Data(contentsOf: fixture("Sample.iso"))
        let url = try write("Synthetic.asif", asif(wrapping: disk))
        XCTAssertTrue(DiskImage.sniff(probe: [UInt8](try Data(contentsOf: url).prefix(8192)), ext: "asif", isDirectory: false))
        let image = try DiskImage(url: url)
        XCTAssertEqual(image.container, .asif)
        XCTAssertEqual(image.virtualSize, UInt64(disk.count))
        XCTAssertEqual(try image.device?.read(at: 0, count: disk.count), disk)
        let contents = try XCTUnwrap(image.contents())
        XCTAssertEqual(entry(contents, "Docs/Nested/readme.txt")?.size, 19)
    }

    func testSyntheticSparseBundle() throws {
        let disk = try Data(contentsOf: fixture("Sample.iso"))
        let bundle = directory.appendingPathComponent("Synthetic.sparsebundle")
        let bands = bundle.appendingPathComponent("bands")
        try FileManager.default.createDirectory(at: bands, withIntermediateDirectories: true)
        let plist: [String: Any] = ["diskimage-bundle-type": "com.apple.diskimage.sparsebundle", "band-size": 8192,
                                    "size": disk.count, "bundle-backingstore-version": 1, "CFBundleInfoDictionaryVersion": "6.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        for index in 0..<((disk.count + 8191) / 8192) {
            // The last band may be short; missing bands read as zeros.
            let band = disk.subdata(in: (index * 8192)..<min(disk.count, (index + 1) * 8192))
            if band.contains(where: { $0 != 0 }) { try band.write(to: bands.appendingPathComponent(String(index, radix: 16))) }
        }
        XCTAssertTrue(DiskImage.sniff(probe: [], ext: "sparsebundle", isDirectory: true))
        let image = try DiskImage(url: bundle)
        XCTAssertEqual(image.container, .sparseBundle)
        XCTAssertEqual(try image.device?.read(at: 0, count: disk.count), disk)
        XCTAssertEqual(image.contents()?.volumeName, "SAMPLEISO")
    }

    // MARK: Hostile input

    func testTruncatedTrailerFallsBackToRaw() throws {
        let data = try Data(contentsOf: fixture("Sample-HFS-zlib.dmg"))
        let url = try write("cut.dmg", data.prefix(data.count - 100))
        let image = try DiskImage(url: url)
        XCTAssertEqual(image.container, .raw)
        XCTAssertNil(image.contents())
        _ = DiskImagePage.page(for: image, settings: PreviewSettings())
    }

    /// A trailer whose property list declares impossible chunk tables.
    private func hostileUDIF(mish: Data, xmlOffset: UInt64? = nil, xmlLength: UInt64? = nil) throws -> URL {
        let plist: [String: Any] = ["resource-fork": ["blkx": [["Name": "hostile", "ID": "0", "Data": mish]]]]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var file = Data(count: 4096)
        let offset = UInt64(file.count)
        file.append(xml)
        var koly = Data(count: 512)
        func put(_ value: UInt64, at at: Int) { withUnsafeBytes(of: value.bigEndian) { koly.replaceSubrange(at..<(at + 8), with: $0) } }
        koly.replaceSubrange(0..<4, with: Data("koly".utf8))
        koly.replaceSubrange(8..<12, with: [0, 0, 2, 0])
        put(xmlOffset ?? offset, at: 216)
        put(xmlLength ?? UInt64(xml.count), at: 224)
        put(UInt64.max / 2, at: 492)                  // absurd sector count
        put(UInt64.max, at: 296); put(UInt64.max, at: 304)   // absurd signature range
        file.append(koly)
        return try write("hostile-\(UUID().uuidString).dmg", file)
    }

    private func mish(chunks: [(type: UInt32, sector: UInt64, count: UInt64, offset: UInt64, length: UInt64)], declared: UInt32? = nil) -> Data {
        var data = Data(count: 204)
        data.replaceSubrange(0..<4, with: Data("mish".utf8))
        withUnsafeBytes(of: (declared ?? UInt32(chunks.count)).bigEndian) { data.replaceSubrange(200..<204, with: $0) }
        for chunk in chunks {
            var entry = Data(count: 40)
            withUnsafeBytes(of: chunk.type.bigEndian) { entry.replaceSubrange(0..<4, with: $0) }
            withUnsafeBytes(of: chunk.sector.bigEndian) { entry.replaceSubrange(8..<16, with: $0) }
            withUnsafeBytes(of: chunk.count.bigEndian) { entry.replaceSubrange(16..<24, with: $0) }
            withUnsafeBytes(of: chunk.offset.bigEndian) { entry.replaceSubrange(24..<32, with: $0) }
            withUnsafeBytes(of: chunk.length.bigEndian) { entry.replaceSubrange(32..<40, with: $0) }
            data.append(entry)
        }
        return data
    }

    func testHostileChunkTables() throws {
        let url = try hostileUDIF(mish: mish(chunks: [
            (0x8000_0005, 0, 1 << 40, 0, 100),                    // a "1 TB" zlib chunk
            (0x8000_0005, UInt64.max - 2, 10, 0, 100),             // wraps around
            (0x0000_0001, 5, 4, UInt64.max - 10, 4096),            // data beyond the file
            (0x8000_0007, 9, 2048, 0, 1 << 40),                    // compressed length beyond the file
            (0x0000_0000, 20, UInt64.max / 1024, 0, 0),            // a huge zero run
        ], declared: 0xFFFF_FFFF))
        let image = try DiskImage(url: url)
        XCTAssertEqual(image.container, .udif)
        XCTAssertNil(image.codeSignatureRange)
        let device = try XCTUnwrap(image.device)
        // Reads either fail cleanly or return zeros; nothing traps or allocates terabytes.
        _ = try? device.read(at: 0, count: 4096)
        _ = try? device.read(at: 5 * 512, count: 4096)
        _ = try? device.read(at: 9 * 512, count: 4096)
        _ = try? device.read(at: UInt64.max - 10, count: 4096)
        XCTAssertEqual(image.partitionMap.scheme, .none)
        XCTAssertNil(image.contents())
        _ = DiskImagePage.page(for: image, settings: PreviewSettings())
    }

    func testHostileTrailerOffsets() throws {
        let url = try hostileUDIF(mish: mish(chunks: []), xmlOffset: UInt64.max - 4, xmlLength: 1 << 40)
        XCTAssertThrowsError(try UDIFImage(url: url))
        // DiskImage still identifies it as UDIF and reports the failure instead of crashing.
        XCTAssertThrowsError(try DiskImage(url: url))
    }

    func testRandomBytes() throws {
        var generator = SystemRandomNumberGenerator()
        for ext in ["dmg", "iso", "img", "sparseimage", "asif", "cdr"] {
            var bytes = (0..<65_536).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if ext == "sparseimage" { bytes.replaceSubrange(0..<4, with: Array("sprs".utf8)) }
            if ext == "asif" { bytes.replaceSubrange(0..<4, with: Array("shdw".utf8)) }
            let url = try write("random.\(ext)", Data(bytes))
            if let image = try? DiskImage(url: url) {
                _ = image.partitionMap
                _ = image.contents()
                _ = DiskImagePage.page(for: image, settings: PreviewSettings())
            }
        }
    }

    /// The raw disk inside the HFS+ fixture, for surgery on its structures.
    private func rawDisk(_ name: String) throws -> Data {
        let image = try DiskImage(url: fixture(name))
        let device = try XCTUnwrap(image.device)
        return try device.read(at: 0, count: Int(device.size))
    }

    func testHFSLeafChainLoopTerminates() throws {
        var disk = try rawDisk("Sample-HFS-zlib.dmg")
        let partition = 40 * 512
        let header = BinaryReader(disk.subdata(in: (partition + 1024)..<(partition + 1536)), bigEndian: true)
        let blockSize = Int(header.u32(at: 40) ?? 0)
        let catalogStart = partition + Int(header.u32(at: 272 + 16) ?? 0) * blockSize
        let node0 = BinaryReader(disk.subdata(in: catalogStart..<(catalogStart + 512)), bigEndian: true)
        let nodeSize = Int(node0.u16(at: 32) ?? 0)
        let firstLeaf = Int(node0.u32(at: 24) ?? 0)
        XCTAssertGreaterThan(nodeSize, 0)
        // Point the first leaf's forward link at itself.
        let leaf = catalogStart + firstLeaf * nodeSize
        withUnsafeBytes(of: UInt32(firstLeaf).bigEndian) { disk.replaceSubrange(leaf..<(leaf + 4), with: $0) }
        let url = try write("loop.dmg", disk)
        let started = Date()
        let contents = try XCTUnwrap(DiskImage(url: url).contents())
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertLessThanOrEqual(contents.entries.count, 16)
    }

    func testAPFSHostileCheckpointAddress() throws {
        // Regression: a checkpoint area near UInt64.max used to overflow when turned into an offset.
        var disk = try rawDisk("Sample-APFS-lzfse.dmg")
        let container = 40 * 512
        withUnsafeBytes(of: (UInt64.max - 3).littleEndian) { disk.replaceSubrange((container + 112)..<(container + 120), with: $0) }
        withUnsafeBytes(of: UInt32(64).littleEndian) { disk.replaceSubrange((container + 104)..<(container + 108), with: $0) }
        let url = try write("apfs.dmg", disk)
        let image = try DiskImage(url: url)
        // Block 0 is still a valid superblock, so the volume lists.
        XCTAssertEqual(image.contents()?.volumeName, "Sample APFS")
    }

    func testISODirectoryLoopTerminates() throws {
        // A hand-built ISO whose subdirectory points back at the root.
        var disk = Data(count: 2048 * 24)
        func record(name: [UInt8], extent: UInt32, length: UInt32, directory: Bool) -> Data {
            var r = Data(count: 33 + name.count + (name.count % 2 == 0 ? 1 : 0))
            r[0] = UInt8(r.count)
            withUnsafeBytes(of: extent.littleEndian) { r.replaceSubrange(2..<6, with: $0) }
            withUnsafeBytes(of: extent.bigEndian) { r.replaceSubrange(6..<10, with: $0) }
            withUnsafeBytes(of: length.littleEndian) { r.replaceSubrange(10..<14, with: $0) }
            withUnsafeBytes(of: length.bigEndian) { r.replaceSubrange(14..<18, with: $0) }
            r[25] = directory ? 0x02 : 0
            r[32] = UInt8(name.count)
            r.replaceSubrange(33..<(33 + name.count), with: name)
            return r
        }
        var pvd = Data(count: 2048)
        pvd[0] = 1
        pvd.replaceSubrange(1..<6, with: Data("CD001".utf8))
        pvd[6] = 1
        pvd.replaceSubrange(40..<44, with: Data("LOOP".utf8))
        withUnsafeBytes(of: UInt32(24).littleEndian) { pvd.replaceSubrange(80..<84, with: $0) }
        withUnsafeBytes(of: UInt16(2048).littleEndian) { pvd.replaceSubrange(128..<130, with: $0) }
        pvd.replaceSubrange(156..<190, with: record(name: [0], extent: 20, length: 2048, directory: true))
        disk.replaceSubrange((16 * 2048)..<(17 * 2048), with: pvd)
        disk[17 * 2048] = 255
        disk.replaceSubrange((17 * 2048 + 1)..<(17 * 2048 + 6), with: Data("CD001".utf8))
        var root = record(name: [0], extent: 20, length: 2048, directory: true) + record(name: [1], extent: 20, length: 2048, directory: true)
        root += record(name: Array("SUB".utf8), extent: 21, length: 2048, directory: true)
        root += record(name: Array("SELF".utf8), extent: 20, length: 2048, directory: true)
        disk.replaceSubrange((20 * 2048)..<(20 * 2048 + root.count), with: root)
        let sub = record(name: [0], extent: 21, length: 2048, directory: true) + record(name: Array("BACK".utf8), extent: 20, length: 2048, directory: true)
        disk.replaceSubrange((21 * 2048)..<(21 * 2048 + sub.count), with: sub)
        let url = try write("loop.iso", disk)
        let contents = try XCTUnwrap(DiskImage(url: url).contents())
        XCTAssertEqual(contents.volumeName, "LOOP")
        XCTAssertEqual(Set(contents.entries.map(\.path)), ["SUB", "SELF", "SUB/BACK"])
    }

    func testDecompressorsRejectGarbage() {
        let garbage = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919) })
        XCTAssertThrowsError(try DiskDecompress.zlib(garbage, expected: 65_536))
        XCTAssertThrowsError(try DiskDecompress.bzip2(garbage, expected: 65_536))
        XCTAssertThrowsError(try DiskDecompress.zlib(garbage, expected: 1 << 40))
        _ = try? DiskDecompress.lzfse(garbage, expected: 65_536)
        _ = try? DiskDecompress.lzvn(garbage, expected: 65_536)
        _ = try? DiskDecompress.adc(garbage, expected: 65_536)
        // An ADC back-reference before the start of the output is corrupt, not a crash.
        XCTAssertThrowsError(try DiskDecompress.adc(Data([0x40, 0xFF, 0xFF]), expected: 64))
    }
}
