import XCTest
@testable import GreeceKit

/// Archives: detection, listing every format, split sets, encryption, legacy names, extraction and limits.
final class ArchivesTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/archives")
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceArchivesTests-\(UUID().uuidString)")
        let project = directory.appendingPathComponent("Project/Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "hello\n".write(to: directory.appendingPathComponent("Project/README.md"), atomically: true, encoding: .utf8)
        try String(repeating: "let x = 1\n", count: 500).write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "Ελλάδα\n".write(to: directory.appendingPathComponent("Project/Νάξος.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String) -> URL { Self.fixtures.appendingPathComponent(name) }

    /// Incompressible bytes, so archives of them split into a predictable number of pieces.
    private func noise(_ count: Int) -> Data {
        var state: UInt32 = 0x9E37_79B9
        return Data((0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        })
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// bsdtar writes most formats Greece reads.
    private func make(_ name: String, _ flags: [String]) throws -> URL {
        try run("/usr/bin/tar", flags + ["-cf", name, "Project"])
        return directory.appendingPathComponent(name)
    }

    private func list(_ url: URL) throws -> ArchiveListing { try ArchiveSession(url: url).listAll() }

    private func files(_ listing: ArchiveListing) -> [String] { listing.entries.filter { !$0.isDirectory }.map(\.path).sorted() }

    private func text(_ session: ArchiveSession, _ listing: ArchiveListing, suffix: String, limit: UInt64 = 1 << 20) -> String? {
        guard let entry = listing.entries.first(where: { $0.path.hasSuffix(suffix) }), let data = session.data(entry, limit: limit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Detection

    func testMagicBytesIdentifyEveryFormat() {
        func format(_ bytes: [UInt8], _ ext: String = "") -> ArchiveFormat? { ArchiveSniffer.format(of: bytes + [UInt8](repeating: 0, count: 600), ext: ext) }
        XCTAssertEqual(format([0x50, 0x4B, 0x03, 0x04]), .zip)
        XCTAssertEqual(format([0x50, 0x4B, 0x07, 0x08]), .zip)
        XCTAssertEqual(format([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]), .sevenZip)
        XCTAssertEqual(format(Array("Rar!".utf8) + [0x1A, 0x07, 0x00]), .rar)
        XCTAssertEqual(format(Array("Rar!".utf8) + [0x1A, 0x07, 0x01, 0x00]), .rar)
        XCTAssertEqual(format([0x1F, 0x8B, 0x08]), .gzip)
        XCTAssertEqual(format(Array("BZh9".utf8)), .bzip2)
        XCTAssertEqual(format([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]), .xz)
        XCTAssertEqual(format([0x28, 0xB5, 0x2F, 0xFD]), .zstd)
        XCTAssertEqual(format(Array("LZIP".utf8)), .lzip)
        XCTAssertEqual(format([0x1F, 0x9D]), .compress)
        XCTAssertEqual(format(Array("MSCF".utf8) + [0, 0, 0, 0]), .cab)
        XCTAssertEqual(format(Array("xar!".utf8)), .xar)
        XCTAssertEqual(format([0xED, 0xAB, 0xEE, 0xDB]), .rpm)
        XCTAssertEqual(format(Array("!<arch>\n".utf8)), .ar)
        XCTAssertEqual(format(Array("070701".utf8)), .cpio)
        XCTAssertEqual(format(Array("Cr24".utf8)), .zip)
        XCTAssertNil(format(Array("BZh".utf8) + [0x00]))
        XCTAssertNil(format(Array("Hello, world".utf8)))
    }

    func testClaimsArchivesButLeavesDocumentsAndLibraries() throws {
        try run("/usr/bin/zip", ["-qr", "p.zip", "Project"])
        let zip = directory.appendingPathComponent("p.zip")
        XCTAssertEqual(FileKind.detect(zip), .module(ArchivesModule.id))
        for name in ["report.docx", "slides.key", "book.epub", "app.ipa"] {
            let copy = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: zip, to: copy)
            XCTAssertFalse(ArchivesModule.claims(FileInfo(url: copy)), name)
        }
        let library = directory.appendingPathComponent("libthing.a")
        try Data("!<arch>\n".utf8 + [UInt8](repeating: 0x20, count: 120)).write(to: library)
        XCTAssertFalse(ArchivesModule.claims(FileInfo(url: library)))
        let plain = directory.appendingPathComponent("notes.txt")
        try "just text".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertFalse(ArchivesModule.claims(FileInfo(url: plain)))
    }

    func testFlavoursComeFromExtensions() throws {
        try run("/usr/bin/zip", ["-qr", "p.zip", "Project"])
        for (name, flavor) in [("book.cbz", ArchiveIdentity.Flavor.comic), ("lib.jar", .package(.jar)), ("pkg.whl", .package(.wheel)),
                               ("app.apk", .package(.apk)), ("x.nupkg", .package(.nuget)), ("ext.vsix", .package(.vsix)), ("p.zip", .plain)] {
            let url = directory.appendingPathComponent(name)
            if name != "p.zip" { try FileManager.default.copyItem(at: directory.appendingPathComponent("p.zip"), to: url) }
            XCTAssertEqual(ArchiveSniffer.identify(FileInfo(url: url))?.flavor, flavor, name)
        }
    }

    // MARK: - Listing

    func testZipListsInstantlyWithCompressedSizes() throws {
        try run("/usr/bin/zip", ["-qr", "p.zip", "Project"])
        let listing = try list(directory.appendingPathComponent("p.zip"))
        XCTAssertEqual(listing.container, .zip)
        XCTAssertEqual(files(listing), ["Project/README.md", "Project/Sources/main.swift", "Project/Νάξος.txt"])
        let main = try XCTUnwrap(listing.entries.first { $0.path.hasSuffix("main.swift") })
        XCTAssertEqual(main.size, 5000)
        XCTAssertLessThan(main.compressedSize ?? .max, 5000)
        XCTAssertEqual(main.method, "Deflate")
        XCTAssertTrue(listing.hasCompressedSizes)
    }

    func testContainersLibarchiveReads() throws {
        let cases: [(String, [String], ArchiveFormat, String)] = [
            ("p.7z", ["--format", "7zip"], .sevenZip, "7-Zip Archive"),
            ("p.xar", ["--format", "xar"], .xar, "XAR Archive"),
            ("p.cpio", ["--format", "newc"], .cpio, "cpio Archive"),
            ("p.iso", ["--format", "iso9660"], .iso, "ISO Disk Image"),
            ("p.tar.lzma", ["--lzma"], .tar, "Tar Archive · LZMA"),
            ("p.tar.lz", ["--lzip"], .tar, "Tar Archive · lzip"),
            ("p.tar.Z", ["-Z"], .tar, "Tar Archive · compress"),
            ("p.tgz", ["-z"], .tar, "Tar Archive · gzip"),
            ("p.tbz2", ["-j"], .tar, "Tar Archive · bzip2"),
            ("p.txz", ["-J"], .tar, "Tar Archive · xz"),
        ]
        for (name, flags, format, title) in cases {
            let url = try make(name, flags)
            // ISO images open in the apps inspector (disk image details plus their files); the archive
            // reader still has to list them, for archives that contain ISOs.
            XCTAssertEqual(FileKind.detect(url), .module(name.hasSuffix(".iso") ? AppsModule.id : ArchivesModule.id), name)
            let session = try ArchiveSession(url: url)
            let listing = try session.listAll()
            XCTAssertEqual(listing.format, format, name)
            XCTAssertEqual(listing.title, title, name)
            let names = files(listing)
            XCTAssertTrue(names.contains { $0.hasSuffix("Project/Νάξος.txt") || $0.hasSuffix("PROJECT/ΝΆΞΟΣ.TXT") || $0.lowercased().hasSuffix("νάξος.txt") }, "\(name): \(names)")
            XCTAssertEqual(listing.entries.first { $0.path.lowercased().hasSuffix("main.swift") }?.size, 5000, name)
            XCTAssertEqual(text(session, listing, suffix: "README.md").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, "hello", name)
        }
    }

    func testRarFormats() throws {
        for name in ["rar4.rar", "rar5.rar", "rar5-solid.rar"] {
            let url = fixture("libarchive/" + name)
            // ISO images open in the apps inspector (disk image details plus their files); the archive
            // reader still has to list them, for archives that contain ISOs.
            XCTAssertEqual(FileKind.detect(url), .module(name.hasSuffix(".iso") ? AppsModule.id : ArchivesModule.id), name)
            let session = try ArchiveSession(url: url)
            let listing = try session.listAll()
            XCTAssertEqual(listing.format, .rar, name)
            XCTAssertGreaterThan(listing.fileCount, 1, name)
            XCTAssertNil(listing.damage, name)
            // The last file of a solid archive needs every earlier one decoded first.
            let last = try XCTUnwrap(listing.entries.last { !$0.isDirectory })
            XCTAssertEqual(session.data(last, limit: 1 << 24)?.count, Int(last.size), name)
        }
        let unicode = try list(fixture("libarchive/rar5-unicode.rar"))
        XCTAssertTrue(unicode.entries.contains { $0.path.unicodeScalars.contains { $0.value > 0x7F } }, "\(unicode.entries.map(\.path))")
        let rar4 = try list(fixture("libarchive/rar4-unicode.rar"))
        XCTAssertTrue(rar4.entries.contains { $0.path.unicodeScalars.contains { $0.value > 0x7F } }, "\(rar4.entries.map(\.path))")
    }

    func testCabinetLHAAndCpio() throws {
        for name in ["mszip.cab", "lzx.cab", "lh6.lzh"] {
            let session = try ArchiveSession(url: fixture("libarchive/" + name))
            let listing = try session.listAll()
            XCTAssertGreaterThan(listing.fileCount, 1, name)
            let file = try XCTUnwrap(listing.entries.first { !$0.isDirectory && $0.size > 0 }, name)
            XCTAssertEqual(session.data(file, limit: 1 << 24)?.count, Int(file.size), name)
        }
        XCTAssertEqual(try list(fixture("libarchive/mszip.cab")).title, "Cabinet Archive")
        XCTAssertEqual(try list(fixture("libarchive/lh6.lzh")).format, .lha)
    }

    func testZstandardTarAndSingleFile() throws {
        let tar = try ArchiveSession(url: fixture("libarchive/compat.tar.zst"))
        let listing = try tar.listAll()
        XCTAssertEqual(listing.container, .tar)
        XCTAssertEqual(listing.title, "Tar Archive · Zstandard")
        XCTAssertGreaterThan(listing.fileCount, 0)
        let file = try XCTUnwrap(listing.entries.first { !$0.isDirectory })
        XCTAssertEqual(tar.data(file, limit: 1 << 24)?.count, Int(file.size))

        let zipped = try ArchiveSession(url: fixture("libarchive/zstd.zipx"))
        let zipListing = try zipped.listAll()
        let entry = try XCTUnwrap(zipListing.entries.first { !$0.isDirectory })
        XCTAssertEqual(entry.method, "Zstandard")
        XCTAssertEqual(zipped.data(entry, limit: 1 << 24)?.count, Int(entry.size))
    }

    func testSingleCompressedFilesKeepTheirName() throws {
        try run("/usr/bin/gzip", ["-k", "Project/Sources/main.swift"])
        let gz = try list(directory.appendingPathComponent("Project/Sources/main.swift.gz"))
        XCTAssertEqual(gz.container, .compressedFile)
        XCTAssertEqual(gz.title, "gzip Compressed File")
        XCTAssertEqual(gz.entries.map(\.path), ["main.swift"])
        XCTAssertEqual(gz.entries.first?.size, 5000)
        XCTAssertEqual(gz.innerPrefix.map { String(decoding: $0.prefix(9), as: UTF8.self) }, "let x = 1")

        try run("/usr/bin/bzip2", ["-k", "Project/README.md"])
        let bz = try list(directory.appendingPathComponent("Project/README.md.bz2"))
        XCTAssertEqual(bz.container, .compressedFile)
        XCTAssertEqual(bz.entries.map(\.path), ["README.md"])
        XCTAssertEqual(bz.entries.first?.size, 6)
    }

    // MARK: - Split archives

    func testSplitSevenZipAndZipPieces() throws {
        try noise(300_000).write(to: directory.appendingPathComponent("Project/noise.bin"))
        for (name, flags) in [("p.7z", ["--format", "7zip"]), ("p.zip", ["--format", "zip"])] {
            let whole = try make(name, flags)
            // Cut into 70 KB pieces numbered from .001, as 7-Zip names them.
            let data = try Data(contentsOf: whole)
            for (number, start) in stride(from: 0, to: data.count, by: 70_000).enumerated() {
                try data.subdata(in: start..<min(start + 70_000, data.count))
                    .write(to: directory.appendingPathComponent(name + String(format: ".%03d", number + 1)))
            }
            try FileManager.default.removeItem(at: whole)

            let first = directory.appendingPathComponent(name + ".001")
            let volumes = ArchiveVolumes.discover(directory.appendingPathComponent(name + ".003"))
            XCTAssertEqual(volumes.kind, .pieces, name)
            XCTAssertEqual(volumes.count, 5, name)
            XCTAssertTrue(ArchivesModule.claims(FileInfo(url: first)), name)
            let session = try ArchiveSession(url: first)
            let listing = try session.listAll()
            XCTAssertEqual(listing.volumes, 5, name)
            let noise = try XCTUnwrap(listing.entries.first { $0.path.hasSuffix("noise.bin") }, name)
            XCTAssertEqual(session.data(noise, limit: 1 << 24)?.count, 300_000, name)
        }
    }

    func testSpannedZipFromAnyPart() throws {
        try noise(200_000).write(to: directory.appendingPathComponent("Project/noise.bin"))
        try run("/usr/bin/zip", ["-qr", "-s", "64k", "span.zip", "Project"])
        for part in ["span.z01", "span.z02", "span.zip"] {
            let url = directory.appendingPathComponent(part)
            XCTAssertTrue(ArchivesModule.claims(FileInfo(url: url)), part)
            let volumes = ArchiveVolumes.discover(url)
            XCTAssertEqual(volumes.kind, .spannedZIP, part)
            XCTAssertEqual(volumes.urls.last?.lastPathComponent, "span.zip", part)
            let session = try ArchiveSession(url: url)
            let listing = try session.listAll()
            let noise = try XCTUnwrap(listing.entries.first { $0.path.hasSuffix("noise.bin") }, part)
            XCTAssertEqual(session.data(noise, limit: 1 << 24)?.count, 200_000, part)
        }
    }

    func testRarVolumesFromAnyPart() throws {
        let third = fixture("libarchive/rar-volumes/volumes.part3.rar")
        let volumes = ArchiveVolumes.discover(third)
        XCTAssertEqual(volumes.kind, .rarVolumes)
        XCTAssertEqual(volumes.count, 6)
        XCTAssertEqual(volumes.first.lastPathComponent, "volumes.part1.rar")
        let session = try ArchiveSession(url: third)
        let listing = try session.listAll()
        XCTAssertEqual(listing.volumes, 6)
        XCTAssertNil(listing.damage)
        let last = try XCTUnwrap(listing.entries.last { !$0.isDirectory })
        XCTAssertEqual(session.data(last, limit: 1 << 24)?.count, Int(last.size))
    }

    func testOldStyleRarVolumes() throws {
        // The same six volumes named the old way: name.rar, name.r00, name.r01…
        let source = fixture("libarchive/rar-volumes")
        for part in 1...6 {
            let name = part == 1 ? "old.rar" : String(format: "old.r%02d", part - 2)
            try FileManager.default.copyItem(at: source.appendingPathComponent("volumes.part\(part).rar"), to: directory.appendingPathComponent(name))
        }
        let volumes = ArchiveVolumes.discover(directory.appendingPathComponent("old.r02"))
        XCTAssertEqual(volumes.kind, .rarVolumes)
        XCTAssertEqual(volumes.urls.map(\.lastPathComponent), ["old.rar", "old.r00", "old.r01", "old.r02", "old.r03", "old.r04"])
        let listing = try list(directory.appendingPathComponent("old.rar"))
        XCTAssertEqual(listing.volumes, 6)
        XCTAssertNil(listing.damage)
    }

    func testSplitDiscoveryIgnoresLookalikes() throws {
        for name in ["notes.2024", "report.001"] {
            try "plain".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(ArchiveVolumes.discover(directory.appendingPathComponent("notes.2024")).kind, .single)
        XCTAssertFalse(ArchivesModule.claims(FileInfo(url: directory.appendingPathComponent("report.001"))), "a .001 that isn't an archive")
    }

    // MARK: - Encryption

    func testEncryptionIsDetected() throws {
        try run("/usr/bin/zip", ["-qr", "-P", "secret", "locked.zip", "Project"])
        let zip = try ArchiveSession(url: directory.appendingPathComponent("locked.zip"))
        let zipListing = try zip.listAll()
        XCTAssertTrue(zipListing.isEncrypted)
        let entry = try XCTUnwrap(zipListing.entries.first { !$0.isDirectory })
        XCTAssertThrowsError(try zip.extract(entry, limit: 100) { _ in })

        XCTAssertTrue(try list(fixture("libarchive/aes256.zip")).isEncrypted)
        XCTAssertTrue(try list(fixture("libarchive/7z-encrypted-data.7z")).isEncrypted)
        XCTAssertTrue(try list(fixture("libarchive/rar4-encrypted-data.rar")).isEncrypted)
        for name in ["7z-encrypted-header.7z", "rar4-encrypted-header.rar"] {
            let listing = try list(fixture("libarchive/" + name))
            XCTAssertTrue(listing.headerEncrypted, name)
            XCTAssertTrue(listing.entries.isEmpty, name)
        }
    }

    // MARK: - Names

    func testLegacyFileNameEncodings() throws {
        let russian = try list(fixture("libarchive/cp866.zip"))
        XCTAssertEqual(russian.nameEncoding, "DOS Cyrillic")
        XCTAssertTrue(russian.entries.allSatisfy { $0.path.unicodeScalars.allSatisfy { $0.value < 0x80 || (0x0400...0x04FF).contains($0.value) } },
                      "\(russian.entries.map(\.path))")
        let japanese = try list(fixture("libarchive/cp932.zip"))
        XCTAssertEqual(japanese.nameEncoding, "Shift JIS")
        XCTAssertTrue(japanese.entries.contains { $0.path.contains("表") }, "\(japanese.entries.map(\.path))")
        let lha = try list(fixture("libarchive/cp932.lzh"))
        XCTAssertTrue(lha.entries.contains { $0.path.contains("表") }, "\(lha.entries.map(\.path))")
        let cpio = try list(fixture("libarchive/koi8r.cpio"))
        XCTAssertEqual(cpio.nameEncoding, "KOI8-R")
        XCTAssertTrue(cpio.entries.contains { $0.path.lowercased().contains("пример") || $0.path.contains("ПРИВЕТ") || $0.path.unicodeScalars.contains { (0x0430...0x044F).contains($0.value) } },
                      "\(cpio.entries.map(\.path))")
    }

    func testNamesSortLikeFinder() {
        let names = ["file 10.txt", "File 9.txt", "file 1.txt", "README", "_build", "2024 notes", "10 things", "9 lives", "Ábaco", "abacus", "zeta"]
        let fast = names.sorted { FileTreeView.finderOrder($0, $1) == .orderedAscending }
        XCTAssertEqual(Array(fast.prefix(4)), ["_build", "9 lives", "10 things", "2024 notes"])
        XCTAssertEqual(fast.filter { $0.lowercased().hasPrefix("file") }, ["file 1.txt", "File 9.txt", "file 10.txt"])
        XCTAssertEqual(fast.last, "zeta")
        XCTAssertEqual(FileTreeView.finderOrder("a", "a"), .orderedSame)
    }

    func testIncrementalTreeMatchesOneShot() {
        let entries = (0..<500).map { ArchiveEntry(path: "dir\($0 % 7)/sub\($0 % 3)/file\($0).txt", isDirectory: false, size: UInt64($0)) }
        let builder = ArchiveTreeBuilder(showHidden: false)
        for chunk in stride(from: 0, to: entries.count, by: 64) { builder.add(Array(entries[chunk..<min(chunk + 64, entries.count)])) }
        builder.finish()
        let whole = FileNode.tree(from: ArchiveListing(format: .zip, container: .zip, entries: entries, archiveSize: 1), showHidden: false)
        XCTAssertEqual(builder.root.fileCount, 500)
        XCTAssertEqual(builder.root.size, whole.size)
        XCTAssertEqual(builder.root.children?.count, 7)
    }

    func testListingStreamsInBatches() throws {
        for index in 0..<400 { try "x".write(to: directory.appendingPathComponent("Project/Sources/f\(index).txt"), atomically: false, encoding: .utf8) }
        let session = try ArchiveSession(url: try make("many.tgz", ["-z"]))
        let lister = session.makeLister()
        let first = try lister.step(until: CFAbsoluteTimeGetCurrent() - 1)   // already past: one batch only
        XCTAssertFalse(lister.isFinished)
        XCTAssertEqual(first.count, 64)
        var total = first.count
        while !lister.isFinished { total += try lister.step(until: .infinity).count }
        XCTAssertEqual(total, lister.listing.entries.count)
        XCTAssertGreaterThan(total, 400)
    }

    func testPlainLatinNamesStayLatin() {
        let names = ["Café.txt", "Résumé final.doc", "Naïve – Übersicht.pdf"].map { Array($0.data(using: .windowsCP1252)!) }
        XCTAssertEqual(NameDecoder.choose(names, fallback: nil).script, .latin)
        let dos = ["Café.txt", "Größe.txt"].map { Array($0.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))))!) }
        XCTAssertEqual(NameDecoder.choose(dos, fallback: nil).script, .latin)
    }

    // MARK: - Extraction limits and hostile input

    func testExtractionStopsAtTheLimit() throws {
        try Data(count: 5_000_000).write(to: directory.appendingPathComponent("Project/zeros.bin"))
        for (name, flags) in [("z.zip", ["--format", "zip"]), ("z.7z", ["--format", "7zip"]), ("z.tgz", ["-z"])] {
            let session = try ArchiveSession(url: try make(name, flags))
            let listing = try session.listAll()
            let zeros = try XCTUnwrap(listing.entries.first { $0.path.hasSuffix("zeros.bin") }, name)
            var received = 0
            let (count, complete) = try session.extract(zeros, limit: 100_000) { received += $0.count }
            XCTAssertEqual(count, 100_000, name)
            XCTAssertEqual(received, 100_000, name)
            XCTAssertFalse(complete, name)
            XCTAssertNil(session.data(zeros, limit: 4_999_999), name)
            XCTAssertEqual(session.data(zeros, limit: 5_000_000)?.count, 5_000_000, name)
        }
    }

    func testCancellationStopsExtraction() throws {
        try Data(count: 3_000_000).write(to: directory.appendingPathComponent("Project/zeros.bin"))
        let session = try ArchiveSession(url: try make("c.tgz", ["-z"]))
        let zeros = try XCTUnwrap(try session.listAll().entries.first { $0.path.hasSuffix("zeros.bin") })
        let token = CancelToken()
        token.cancel()
        XCTAssertThrowsError(try session.extract(zeros, limit: .max, cancel: token) { _ in })
    }

    func testTruncatedAndGarbageArchivesNeverCrash() throws {
        try run("/usr/bin/zip", ["-qr", "p.zip", "Project"])
        let formats: [(String, [String])] = [("p.7z", ["--format", "7zip"]), ("p.tgz", ["-z"]), ("p.cpio", ["--format", "newc"]), ("p.xar", ["--format", "xar"])]
        var originals = [directory.appendingPathComponent("p.zip")]
        for (name, flags) in formats { originals.append(try make(name, flags)) }
        originals += ["rar5.rar", "rar4.rar", "mszip.cab", "lh6.lzh", "compat.tar.zst"].map { fixture("libarchive/" + $0) }
        for original in originals {
            let data = try Data(contentsOf: original)
            for cut in [data.count / 3, data.count / 2, data.count - 7] where cut > 8 {
                let damaged = directory.appendingPathComponent("cut-\(cut)-" + original.lastPathComponent)
                try data.prefix(cut).write(to: damaged)
                if let session = try? ArchiveSession(url: damaged), let listing = try? session.listAll() {
                    for entry in listing.entries.prefix(5) where !entry.isDirectory { _ = session.data(entry, limit: 1 << 20) }
                }
            }
            // Flip bytes in the middle: decoders must fail cleanly.
            var flipped = data
            for index in stride(from: min(64, flipped.count - 1), to: flipped.count, by: max(1, flipped.count / 40)) { flipped[index] ^= 0xA5 }
            let garbled = directory.appendingPathComponent("flip-" + original.lastPathComponent)
            try flipped.write(to: garbled)
            if let session = try? ArchiveSession(url: garbled), let listing = try? session.listAll() {
                for entry in listing.entries.prefix(5) where !entry.isDirectory { _ = session.data(entry, limit: 1 << 20) }
            }
        }
    }

    func testZipDirectoryClaimsCannotEscapeTheFile() throws {
        // An end record pointing far outside the file, with a huge entry count.
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes += [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0]
        let url = directory.appendingPathComponent("evil.zip")
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(try list(url))
    }

    func testCompressedTextShowsWholeWithinLimit() throws {
        let text = String(repeating: "2026-11-21 INFO berth assigned\n", count: 10_000)
        try text.write(to: directory.appendingPathComponent("harbor.log"), atomically: true, encoding: .utf8)
        try run("/usr/bin/bzip2", ["harbor.log"])
        let listing = try list(directory.appendingPathComponent("harbor.log.bz2"))
        XCTAssertEqual(listing.innerPrefix?.count, text.utf8.count)
        XCTAssertEqual(listing.entries.first?.size, UInt64(text.utf8.count))
    }
}

/// Package metadata: every kind Greece reads, from fixtures built by Fixtures/archives/make-packages.py.
final class PackageTests: XCTestCase {
    private func inspect(_ name: String) throws -> PackageInfo {
        let url = ArchivesTests.fixtures.appendingPathComponent("packages/" + name)
        let identity = try XCTUnwrap(ArchiveSniffer.identify(FileInfo(url: url)), name)
        let document = try ArchiveDocument(url: url, identity: identity, showHidden: false)
        if document.package == nil, document.isLoading { _ = try document.session.listAll() }
        return try XCTUnwrap(document.package ?? document.inspectPackage(try document.session.listAll()), name)
    }

    func testPython() throws {
        let wheel = try inspect("harbourmaster-2.4.1-py3-none-any.whl")
        XCTAssertEqual(wheel.kind, .wheel)
        XCTAssertEqual(wheel.name, "harbourmaster")
        XCTAssertEqual(wheel.version, "2.4.1")
        XCTAssertEqual(wheel.summary, "Assigns berths to ferries arriving at Aegean harbours.")
        XCTAssertEqual(wheel.facts.first { $0.0 == "Requires Python" }?.1, "≥ 3.9")
        XCTAssertEqual(wheel.facts.first { $0.0 == "License" }?.1, "MIT")
        XCTAssertEqual(wheel.facts.first { $0.0 == "Author" }?.1, "Eleni Papadaki")
        XCTAssertEqual(wheel.facts.first { $0.0 == "Built for" }?.1, "py3-none-any")
        XCTAssertEqual(wheel.dependencies.count, 3, "extras are left out: \(wheel.dependencies)")
        let sdist = try inspect("harbourmaster-2.4.1.tar.gz")
        XCTAssertEqual(sdist.kind, .sdist)
        XCTAssertEqual(sdist.version, "2.4.1")
    }

    func testJavaAndDotNet() throws {
        let jar = try inspect("lighthouse-1.3.0.jar")
        XCTAssertEqual(jar.name, "Lighthouse")
        XCTAssertEqual(jar.version, "1.3.0")
        XCTAssertEqual(jar.facts.first { $0.0 == "Vendor" }?.1, "Aegean Light Company", "continuation lines join")
        XCTAssertEqual(jar.facts.first { $0.0 == "Main class" }?.1, "gr.aegean.lighthouse.Keeper")
        XCTAssertEqual(jar.facts.first { $0.0 == "Maven" }?.1, "gr.aegean:lighthouse")
        XCTAssertEqual(jar.facts.first { $0.0 == "Classes" }?.1, "3")
        let nuget = try inspect("Aegean.Ferries.3.1.0.nupkg")
        XCTAssertEqual(nuget.name, "Aegean Ferries")
        XCTAssertEqual(nuget.version, "3.1.0")
        XCTAssertEqual(nuget.facts.first { $0.0 == "License" }?.1, "Apache-2.0")
        XCTAssertEqual(nuget.facts.first { $0.0 == "Frameworks" }?.1, "net8.0, netstandard2.0")
        XCTAssertEqual(nuget.dependencies, ["System.Text.Json 8.0.4", "Microsoft.Bcl.AsyncInterfaces 8.0.0"])
        XCTAssertNotNil(nuget.icon.flatMap(NSImage.init(data:)))
    }

    func testEditorAndBrowserExtensions() throws {
        let vsix = try inspect("ferry-tracker-0.9.2.vsix")
        XCTAssertEqual(vsix.name, "Ferry Tracker")
        XCTAssertEqual(vsix.facts.first { $0.0 == "Identifier" }?.1, "aegean-labs.ferry-tracker")
        XCTAssertNotNil(vsix.icon)
        for name in ["tide-clock-1.2.xpi", "tide-clock-1.2.crx"] {
            let info = try inspect(name)
            XCTAssertEqual(info.name, "Tide Clock", "__MSG_ names resolve from the default locale")
            XCTAssertEqual(info.summary, "High and low tide for your harbour, in the toolbar.")
            XCTAssertNotNil(info.icon, name)
        }
        XCTAssertEqual(try inspect("tide-clock-1.2.xpi").kind, .xpi)
        XCTAssertEqual(try inspect("tide-clock-1.2.crx").kind, .crx)
    }

    func testAndroid() throws {
        for name in ["lighthouse-keeper.apk", "lighthouse-keeper.aab"] {
            let info = try inspect(name)
            XCTAssertEqual(info.name, "Lighthouse Keeper", name)
            XCTAssertEqual(info.summary, "gr.aegean.lighthouse", name)
            XCTAssertEqual(info.version, "3.2.0", name)
            XCTAssertEqual(info.facts.first { $0.0 == "Version code" }?.1, "42", name)
            XCTAssertEqual(info.facts.first { $0.0 == "Minimum Android" }?.1, "Android 8 (API 26)", name)
            XCTAssertEqual(info.dependencies, ["INTERNET", "ACCESS_FINE_LOCATION", "POST_NOTIFICATIONS"], name)
        }
        let apk = try inspect("lighthouse-keeper.apk")
        XCTAssertEqual(apk.facts.first { $0.0 == "Native code" }?.1, "arm64-v8a, x86_64")
        XCTAssertNotNil(apk.icon)
    }

    func testLinuxRubyAndNode() throws {
        let deb = try inspect("harbourmaster_2.4.1-1_arm64.deb")
        XCTAssertEqual(deb.name, "harbourmaster")
        XCTAssertEqual(deb.version, "2.4.1-1")
        XCTAssertEqual(deb.summary, "berths for Aegean ferries")
        XCTAssertEqual(deb.facts.first { $0.0 == "Architecture" }?.1, "arm64")
        XCTAssertEqual(deb.dependencies, ["libc6 (>= 2.34)", "python3 (>= 3.9)", "python3-attr"])
        let debListing = try ArchiveSession(url: ArchivesTests.fixtures.appendingPathComponent("packages/harbourmaster_2.4.1-1_arm64.deb")).listAll()
        XCTAssertEqual(debListing.title, "Debian Package")
        XCTAssertTrue(debListing.entries.contains { $0.path == "usr/bin/harbourmaster" }, "data.tar.zst decodes: \(debListing.entries.map(\.path))")

        let rpmURL = ArchivesTests.fixtures.appendingPathComponent("packages/harbourmaster-2.4.1-1.x86_64.rpm")
        let rpm = try inspect("harbourmaster-2.4.1-1.x86_64.rpm")
        XCTAssertEqual(rpm.name, "harbourmaster")
        XCTAssertEqual(rpm.version, "2.4.1-1")
        XCTAssertEqual(rpm.facts.first { $0.0 == "Architecture" }?.1, "x86_64")
        XCTAssertEqual(rpm.dependencies, ["python3", "python3-attrs"])
        let session = try ArchiveSession(url: rpmURL)
        let listing = try session.listAll()
        XCTAssertEqual(listing.compression, .zstd)
        let script = try XCTUnwrap(listing.entries.first { $0.path.hasSuffix("bin/harbourmaster") })
        XCTAssertEqual(session.data(script, limit: 1 << 20).map { String(decoding: $0, as: UTF8.self) }, "#!/bin/sh\necho 'Harbourmaster: berth A1 is free.'\n")

        let gem = try inspect("harbourmaster-2.4.1.gem")
        XCTAssertEqual(gem.name, "harbourmaster")
        XCTAssertEqual(gem.version, "2.4.1")
        XCTAssertEqual(gem.facts.first { $0.0 == "Ruby" }?.1, "≥ 3.1.0")
        XCTAssertEqual(gem.facts.first { $0.0 == "Authors" }?.1, "Eleni Papadaki, Nikos Georgiou")
        XCTAssertEqual(gem.dependencies, ["concurrent-ruby ~> 1.3"])

        let npm = try inspect("tide-clock-1.2.0.tgz")
        XCTAssertEqual(npm.kind, .npm)
        XCTAssertEqual(npm.name, "@aegean/tide-clock")
        XCTAssertEqual(npm.dependencies, ["date-fns ^4.1.0", "suncalc ^1.9.0"])
    }

    func testRPMSourceFixtureFromLibarchive() throws {
        let url = ArchivesTests.fixtures.appendingPathComponent("libarchive/gzip-payload.rpm")
        let session = try ArchiveSession(url: url)
        let listing = try session.listAll()
        XCTAssertFalse(listing.entries.isEmpty)
        let file = try XCTUnwrap(listing.entries.first { !$0.isDirectory && $0.size > 0 })
        XCTAssertEqual(session.data(file, limit: 1 << 20)?.count, Int(file.size))
    }

    func testHostileMetadataIsRefusedOrBounded() throws {
        // Deep JSON nesting, a truncated binary manifest and a protobuf length past the end.
        XCTAssertNil(PackageFormats.json(Data((String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)).utf8)))
        XCTAssertNil(AndroidManifest(binaryXML: Data([0x03, 0x00, 0x08, 0x00, 0xFF, 0xFF, 0xFF, 0x7F, 0x01, 0x00])))
        var budget = 1000
        XCTAssertTrue(Protobuf.fields(Data([0x0A, 0xFF, 0xFF, 0xFF, 0x0F, 0x01])[...], budget: &budget).isEmpty)
        let headers = PackageFormats.headers(String(repeating: "Key: value\n continued\n", count: 10_000))
        XCTAssertLessThanOrEqual(headers.count, 5000)
        XCTAssertNil(PackageFormats.XMLDigest(Data(repeating: 0x3C, count: PackageInspector.metadataLimit + 1)))
        // A gzip bomb stops at the limit.
        let zeros = try (Data(count: 4 * 1024 * 1024) as NSData).compressed(using: .zlib) as Data
        XCTAssertNil(PackageFormats.gunzip(Data([0x78, 0x9C]) + zeros, limit: 1024))
    }
}

/// Comic books: page order, ComicInfo, pages served on demand (random access and sequential).
final class ComicTests: XCTestCase {
    private func book(_ name: String) throws -> ComicBook {
        let url = ArchivesTests.fixtures.appendingPathComponent("comics/" + name)
        XCTAssertEqual(ArchiveSniffer.identify(FileInfo(url: url))?.flavor, .comic, name)
        let session = try ArchiveSession(url: url)
        return try XCTUnwrap(ComicBook(session: session, listing: try session.listAll(), scratch: ArchiveScratch()), name)
    }

    func testPagesComeInReadingOrderWithTheirDetails() throws {
        let book = try book("Aegean Tales 01.cbz")
        XCTAssertEqual(book.pages.count, 8)
        XCTAssertEqual(book.pages.map { ($0.path as NSString).lastPathComponent }.first, "page-01.jpg")
        XCTAssertEqual(book.info.series, "Aegean Tales")
        XCTAssertEqual(book.info.title, "The Crossing")
        let payload = book.payload(fileName: "Aegean Tales 01.cbz", format: "CBZ")
        XCTAssertEqual(payload.title, "Aegean Tales #1")
        XCTAssertEqual(payload.facts.first, "8 pages")
    }

    func testPagesAndThumbnailsAreServed() throws {
        for name in ["Aegean Tales 01.cbz", "Aegean Tales 01.cb7", "Aegean Tales 01.cbt"] {
            let book = try book(name)
            let page = try XCTUnwrap(book.resource("page/2"), name)
            XCTAssertEqual(page.mimeType, "image/jpeg", name)
            XCTAssertNotNil(NSImage(data: page.data), name)
            let thumb = try XCTUnwrap(book.resource("thumb/0?w=200"), name)
            let image = try XCTUnwrap(NSBitmapImageRep(data: thumb.data), name)
            XCTAssertLessThanOrEqual(max(image.pixelsWide, image.pixelsHigh), 300, name)
        }
    }

    func testResourceRequestsAreValidated() throws {
        let book = try book("Aegean Tales 01.cbz")
        for request in ["page/8", "page/-1", "thumb/99?w=200", "../page/1", "page/1/2", "page/one", "cover", "", "thumb/0?w=999999999999999999999"] {
            if request.hasPrefix("thumb/0") {
                XCTAssertNotNil(book.resource(request), "oversized widths are clamped")
            } else {
                XCTAssertNil(book.resource(request), request)
            }
        }
    }

    func testComicsPrepareAsAPageOfCovers() throws {
        let url = ArchivesTests.fixtures.appendingPathComponent("comics/Aegean Tales 01.cbz")
        let prepared = try ArchivesModule.prepare(FileInfo(url: url), settings: PreviewSettings())
        guard case .web(let document, let summary, _) = prepared else { return XCTFail("expected a web page") }
        XCTAssertEqual(document.kind, .init("comic"))
        XCTAssertNotNil(document.resources)
        XCTAssertEqual(summary.title, "Comic Book")
        XCTAssertEqual(summary.details.first, "8 pages")
    }
}

/// Phase timings for a big archive, for performance work. Skipped unless GREECE_PERF names a file.
final class ArchivePerformance: XCTestCase {
    @MainActor
    func testPhases() throws {
        guard let path = ProcessInfo.processInfo.environment["GREECE_PERF"] else { throw XCTSkip("Set GREECE_PERF to an archive") }
        let url = URL(fileURLWithPath: path)
        var clock = CFAbsoluteTimeGetCurrent()
        func lap(_ label: String) {
            let now = CFAbsoluteTimeGetCurrent()
            print(String(format: "PERF %@ %.0f ms", label, (now - clock) * 1000))
            clock = now
        }
        let identity = try XCTUnwrap(ArchiveSniffer.identify(FileInfo(url: url)))
        lap("identify")
        let session = try ArchiveSession(url: url, format: identity.format)
        let listing = try session.listAll()
        lap("list \(listing.entries.count)")
        let builder = ArchiveTreeBuilder(showHidden: false)
        builder.add(listing.entries)
        lap("tree")
        builder.finish()
        lap("totals")
        _ = PackageInspector.inspect(session, listing: listing, flavor: identity.flavor, members: [:])
        lap("package")
        let tree = FileTreeView(root: builder.root, settings: PreviewSettings(), showsKind: false, compressedSizes: true)
        lap("view")
        tree.reload()
        lap("reload")
    }
}
