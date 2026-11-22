import XCTest
@testable import GreeceKit

/// The shared ZIP reader every ZIP-based format goes through: structure (ZIP64, data
/// descriptors, legacy names), lookups, and the limits that keep hostile archives harmless.
final class ZIPReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceZIPReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ data: Data, _ name: String = "test.zip") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The same bytes mapped from disk, read with pread, and in memory must agree.
    private func open(_ data: Data) throws -> [ZIPArchive] {
        let url = try write(data)
        return [try ZIPArchive(url: url), try ZIPArchive(source: RandomAccessFile(url)), try ZIPArchive(data: data)]
    }

    private let text = Data(String(repeating: "Ferries leave Piraeus at dawn. ", count: 400).utf8)

    // MARK: - Members

    func testStoredAndDeflatedMembers() throws {
        let photo = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let data = ZIPBuilder([.init("notes.txt", text, method: 8), .init("photo.raw", photo), .init("empty/", Data())]).build()
        for zip in try open(data) {
            XCTAssertEqual(zip.members.map(\.path), ["notes.txt", "photo.raw", "empty/"])
            let notes = try XCTUnwrap(zip.member("notes.txt"))
            XCTAssertEqual(notes.method, 8)
            XCTAssertLessThan(notes.compressedSize, notes.size)
            XCTAssertEqual(try zip.contents(of: notes, limit: 1 << 20), text)
            XCTAssertEqual(zip.contents(of: "photo.raw"), photo)
            XCTAssertTrue(try XCTUnwrap(zip.member("empty/")).isDirectory)
            XCTAssertEqual(zip.contents(of: "empty/"), Data())
            XCTAssertNil(zip.contents(of: "missing.txt"))
            XCTAssertEqual(zip.size, UInt64(data.count))

            // Streaming hands over chunks and stops when asked.
            var streamed = Data()
            try zip.stream(notes, chunkSize: 4096) { streamed.append($0); return true }
            XCTAssertEqual(streamed, text)
            var chunks = 0
            try zip.stream(notes, chunkSize: 4096) { _ in chunks += 1; return false }
            XCTAssertEqual(chunks, 1)
        }
    }

    func testZIP64() throws {
        // Saturated 32-bit fields with the real values in the ZIP64 extra field, and a ZIP64 end record.
        let data = ZIPBuilder([.init("first.txt", text, method: 8, zip64: true), .init("second.txt", Data("Naxos".utf8), zip64: true)],
                              zip64End: true).build()
        for zip in try open(data) {
            XCTAssertEqual(zip.members.count, 2)
            let first = try XCTUnwrap(zip.member("first.txt"))
            XCTAssertEqual(first.size, UInt64(text.count))
            XCTAssertNotEqual(first.compressedSize, 0xFFFF_FFFF)
            XCTAssertEqual(try zip.contents(of: first, limit: 1 << 20), text)
            let second = try XCTUnwrap(zip.member("second.txt"))
            XCTAssertNotEqual(second.localHeaderOffset, 0xFFFF_FFFF)
            XCTAssertEqual(try zip.contents(of: second, limit: 100), Data("Naxos".utf8))
        }
    }

    func testDataDescriptor() throws {
        // Sizes and CRC follow the data; the local header has zeros.
        let data = ZIPBuilder([.init("streamed.txt", text, method: 8, dataDescriptor: true), .init("after.txt", Data("Milos".utf8))]).build()
        for zip in try open(data) {
            let streamed = try XCTUnwrap(zip.member("streamed.txt"))
            XCTAssertTrue(streamed.hasDataDescriptor)
            XCTAssertEqual(try zip.contents(of: streamed, limit: 1 << 20), text)
            XCTAssertEqual(zip.contents(of: "after.txt"), Data("Milos".utf8))
        }
    }

    func testLegacyNamesAreDecoded() throws {
        // "Résumé Ölçü.txt" in CP437, without the UTF-8 flag (as old DOS and Windows tools wrote it).
        let cp437: [UInt8] = [0x52, 0x82, 0x73, 0x75, 0x6D, 0x82, 0x20, 0x99, 0x6C, 0x87, 0x81, 0x2E, 0x74, 0x78, 0x74]
        let data = ZIPBuilder([.init(bytes: cp437, Data("CV".utf8)), .init("Ελλάδα.txt", Data("Hellas".utf8), flags: 0x0800)]).build()
        let directory = try ZIPReader.directory(InMemoryFile(data), limit: 100)
        XCTAssertEqual(directory.members.map(\.path), ["Résumé Ölçü.txt", "Ελλάδα.txt"])
        XCTAssertEqual(directory.nameEncoding, "DOS Latin US")
        for zip in try open(data) {
            XCTAssertEqual(zip.contents(of: "Résumé Ölçü.txt"), Data("CV".utf8))
            XCTAssertEqual(zip.contents(named: "résumé ölçü.TXT"), Data("CV".utf8))
        }
    }

    func testEncryptedMembersAreFlaggedAndRefused() throws {
        // Traditional PKWARE encryption sets bit 0; WinZip AES uses method 99 and an 0x9901 extra field.
        let aesExtra = Data([0x01, 0x99, 0x07, 0x00, 0x02, 0x00, 0x41, 0x45, 0x03, 0x08, 0x00])
        let data = ZIPBuilder([.init("secret.txt", Data("ciphertext!!".utf8), flags: 0x0001),
                               .init("aes.txt", Data("ciphertext!!".utf8), flags: 0x0001, rawMethod: 99, extra: aesExtra),
                               .init("plain.txt", Data("open".utf8))]).build()
        for zip in try open(data) {
            XCTAssertEqual(zip.members.map(\.isEncrypted), [true, true, false])
            for name in ["secret.txt", "aes.txt"] {
                let member = try XCTUnwrap(zip.member(name))
                XCTAssertThrowsError(try zip.contents(of: member, limit: 1 << 20)) { XCTAssertEncrypted($0) }
                XCTAssertThrowsError(try zip.stream(member) { _ in true }) { XCTAssertEncrypted($0) }
                XCTAssertNil(zip.contents(of: name))
            }
            XCTAssertEqual(zip.contents(of: "plain.txt"), Data("open".utf8))
        }
        // The archive browser marks them the same way.
        let listing = try ZIPReader.read(RandomAccessFile(try write(data, "browser.zip")))
        XCTAssertEqual(listing.entries.map(\.isEncrypted), [true, true, false])
        XCTAssertEqual(listing.entries[1].method, "AES")
    }

    // MARK: - Lookups

    func testPathTraversalIsRejected() throws {
        let data = ZIPBuilder([.init("../../etc/passwd", Data("root".utf8)), .init("docs/../../escape.txt", Data("out".utf8)),
                               .init("docs/readme.txt", Data("hello".utf8))]).build()
        for zip in try open(data) {
            // Listed, so the file list shows what's there, but never found by name.
            XCTAssertEqual(zip.members.map(\.escapesRoot), [true, true, false])
            for name in ["../../etc/passwd", "docs/../../escape.txt", "docs/../docs/readme.txt", "..\\..\\etc\\passwd", ".."] {
                XCTAssertNil(zip.member(name), name)
                XCTAssertNil(zip.member(named: name), name)
                XCTAssertNil(zip.contents(of: name), name)
                XCTAssertNil(zip.contents(named: name), name)
            }
            XCTAssertEqual(zip.contents(named: "docs/readme.txt"), Data("hello".utf8))
        }
        XCTAssertTrue(ZIPArchive.hasParentComponent("a/../b"))
        XCTAssertTrue(ZIPArchive.hasParentComponent("a\\..\\b"))
        XCTAssertFalse(ZIPArchive.hasParentComponent("a/..b/c..d/..."))
    }

    func testLenientLookups() throws {
        let data = ZIPBuilder([.init("OEBPS/Text/Chapter.xhtml", Data("one".utf8)), .init("oebps/text/chapter.xhtml", Data("two".utf8)),
                               .init("/3D/model.model", Data("mesh".utf8)), .init("files\\icon.png", Data("png".utf8)),
                               .init("dup.txt", Data("first".utf8)), .init("dup.txt", Data("second".utf8))]).build()
        for zip in try open(data) {
            // Exact names win over case-insensitive matches; the first of duplicates wins.
            XCTAssertEqual(zip.contents(named: "oebps/text/chapter.xhtml"), Data("two".utf8))
            XCTAssertEqual(zip.contents(named: "OEBPS/TEXT/CHAPTER.XHTML"), Data("one".utf8))
            XCTAssertEqual(zip.contents(named: "dup.txt"), Data("first".utf8))
            XCTAssertEqual(zip.contents(of: "dup.txt"), Data("first".utf8))
            // Leading "/" and "./" and backslashes are forgiven by name; exact lookups take the name as stored.
            XCTAssertEqual(zip.contents(named: "3D/model.model"), Data("mesh".utf8))
            XCTAssertEqual(zip.contents(named: "./3d/MODEL.model"), Data("mesh".utf8))
            XCTAssertEqual(zip.contents(named: "files/icon.png"), Data("png".utf8))
            XCTAssertNil(zip.member("3D/model.model"))
            XCTAssertNotNil(zip.member("/3D/model.model"))
            XCTAssertNil(zip.member(named: ""))
            XCTAssertNil(zip.member(named: "/"))
        }
    }

    // MARK: - Limits

    func testDeflateBombStopsAtItsLimit() throws {
        // 16 MB of zeros deflates to about 16 KB.
        let zeros = Data(count: 16 << 20)
        let honest = ZIPBuilder([.init("bomb.bin", zeros, method: 8)]).build()
        XCTAssertLessThan(honest.count, 200_000)
        // A member that admits its size is refused before any inflating.
        let zip = try ZIPArchive(url: try write(honest, "honest.zip"))
        let bomb = try XCTUnwrap(zip.member("bomb.bin"))
        XCTAssertThrowsError(try zip.contents(of: bomb, limit: 1 << 20)) { XCTAssertTooLarge($0) }
        // Deflate at its best (about 1,000 to 1) is still allowed when the limit is generous.
        XCTAssertEqual(try zip.contents(of: bomb, limit: 16 << 20).count, zeros.count)

        // One that lies about its size is inflated only up to the limit, then refused.
        let lying = ZIPBuilder([.init("bomb.bin", zeros, method: 8, declaredSize: 100)]).build()
        for zip in try open(lying) {
            let member = try XCTUnwrap(zip.member("bomb.bin"))
            XCTAssertEqual(member.size, 100)
            XCTAssertThrowsError(try zip.contents(of: member, limit: 1 << 20)) { XCTAssertTooLarge($0) }
            var delivered = 0
            try zip.stream(member, maximum: 1 << 20, chunkSize: 64 << 10) { delivered += $0.count; return true }
            XCTAssertEqual(delivered, 1 << 20)
        }
        // The archive browser stops at the same place and says it didn't finish.
        let file = try RandomAccessFile(try write(lying, "browser.zip"))
        let listing = try ZIPReader.read(file)
        var delivered: UInt64 = 0
        let (count, complete) = try ZIPReader.extract(listing.entries[0], from: file, limit: 1 << 20) {
            delivered += UInt64($0.count)
        }
        XCTAssertEqual(count, 1 << 20)
        XCTAssertEqual(delivered, 1 << 20)
        XCTAssertFalse(complete)

        // A stored member that claims to be small but runs on is held to the limit too.
        let stored = ZIPBuilder([.init("long.txt", text, declaredSize: 10)]).build()
        let storedZip = try ZIPArchive(data: stored)
        XCTAssertThrowsError(try storedZip.contents(of: try XCTUnwrap(storedZip.member("long.txt")), limit: 1000)) { XCTAssertTooLarge($0) }
    }

    func testMemberLimit() throws {
        let data = ZIPBuilder((0..<5).map { .init("file\($0).txt", Data("\($0)".utf8)) }).build()
        let zip = try ZIPArchive(data: data, memberLimit: 3)
        XCTAssertEqual(zip.members.count, 3)
        XCTAssertTrue(zip.truncated)
        XCTAssertNil(zip.member("file4.txt"))
        let exact = try ZIPArchive(data: data, memberLimit: 5)
        XCTAssertEqual(exact.members.count, 5)
        XCTAssertFalse(exact.truncated)
    }

    // MARK: - Damage

    func testTruncatedArchivesFailCleanly() throws {
        let data = ZIPBuilder([.init("a.txt", text, method: 8), .init("b.txt", Data("Paros".utf8)), .init("c/", Data())]).build()
        // Every possible cut: without its end record the archive can't be opened; nothing traps.
        for length in 0..<data.count {
            let cut = data.prefix(length)
            XCTAssertThrowsError(try ZIPArchive(data: cut), "cut at \(length)") { error in
                guard case ArchiveError.corrupt = error else { return XCTFail("cut at \(length): \(error)") }
            }
        }
        XCTAssertThrowsError(try ZIPArchive(url: try write(data.prefix(data.count - 1), "cut.zip")))
        XCTAssertThrowsError(try ZIPArchive(data: Data()))

        // An intact directory whose first member claims more data than the file holds: reading it
        // whole is refused, streaming hands over what's there, and the others still read.
        var short = data
        let record = Int(try ZIPReader.directory(InMemoryFile(data), limit: 10).offset)
        short.replaceSubrange((record + 20)..<(record + 24), with: Data([0, 0, 0x10, 0]))   // compressed size: 1 MB
        let damaged = try ZIPArchive(data: short)
        let long = try XCTUnwrap(damaged.member("a.txt"))
        XCTAssertThrowsError(try damaged.contents(of: long, limit: 1 << 20)) { error in
            guard case ArchiveError.corrupt = error else { return XCTFail("\(error)") }
        }
        var streamed = Data()
        try damaged.stream(long) { streamed.append($0); return true }
        XCTAssertEqual(streamed, text)
        XCTAssertEqual(damaged.contents(of: "b.txt"), Data("Paros".utf8))

        // A directory that claims more members than it holds, or points outside the file.
        var lying = data
        lying[lying.count - 12] = 0x40   // total entries: 64
        let listing = try ZIPReader.read(InMemoryFile(lying))
        XCTAssertEqual(listing.entries.count, 3)
        XCTAssertEqual(listing.damage, "the file list ends early")
        var outside = data
        outside.replaceSubrange((outside.count - 6)..<(outside.count - 2), with: Data([0xFF, 0xFF, 0xFF, 0x7F]))
        outside.replaceSubrange((outside.count - 10)..<(outside.count - 6), with: Data([0x10, 0, 0, 0]))
        XCTAssertThrowsError(try ZIPArchive(data: outside))

        // An empty archive is just an end record.
        let empty = try ZIPArchive(data: ZIPBuilder([]).build())
        XCTAssertTrue(empty.members.isEmpty)
    }

    func testDamagedMembersAndFields() throws {
        // Deflate data that isn't Deflate.
        var data = ZIPBuilder([.init("a.txt", text, method: 8)]).build()
        let zip = try ZIPArchive(data: data)
        let member = try XCTUnwrap(zip.member("a.txt"))
        let start = Int(member.localHeaderOffset) + 30 + 5
        data.replaceSubrange(start..<(start + 16), with: Data(repeating: 0xFF, count: 16))
        let broken = try ZIPArchive(data: data)
        XCTAssertThrowsError(try broken.contents(of: try XCTUnwrap(broken.member("a.txt")), limit: 1 << 20))

        // A member's extra field that runs past the directory: the member is still listed.
        var extra = ZIPBuilder([.init("doc.kml", Data("<kml/>".utf8)), .init("files/marker.png", Data("png".utf8))]).build()
        let directory = try ZIPReader.directory(InMemoryFile(extra), limit: 10)
        let secondRecord = Int(directory.offset) + 46 + "doc.kml".utf8.count
        extra[secondRecord + 31] = 0xA3   // extra length high byte
        let tolerant = try ZIPArchive(data: extra)
        XCTAssertEqual(tolerant.members.map(\.path), ["doc.kml", "files/marker.png"])
        XCTAssertEqual(tolerant.contents(of: "files/marker.png"), Data("png".utf8))

        // A member with an unknown method is listed but refused.
        let odd = try ZIPArchive(data: ZIPBuilder([.init("x.bin", Data("abc".utf8), rawMethod: 14)]).build())
        XCTAssertThrowsError(try odd.contents(of: try XCTUnwrap(odd.member("x.bin")), limit: 100)) { error in
            guard case ArchiveError.unsupported = error else { return XCTFail("\(error)") }
        }

        // Random damage anywhere never traps.
        var generator = SeededGenerator(seed: 41)
        let valid = ZIPBuilder([.init("a.txt", text, method: 8), .init("b.txt", Data("x".utf8))]).build()
        for _ in 0..<300 {
            var copy = valid
            for _ in 0..<8 { copy[Int.random(in: 0..<copy.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator) }
            guard let zip = try? ZIPArchive(data: copy) else { continue }
            for member in zip.members {
                _ = try? zip.contents(of: member, limit: 1 << 20)
                try? zip.stream(member, maximum: 1 << 20) { _ in true }
            }
        }
    }

    func testAPKSigningBlockIsFoundBeforeTheDirectory() throws {
        // A minimal signing block: size, one ID-value pair, size, magic.
        var block = Data()
        let pair = Data([0x0C, 0, 0, 0, 0, 0, 0, 0]) + Data([0x1A, 0x87, 0x09, 0x71]) + Data("ABCDEFGH".utf8)
        let size = UInt64(pair.count + 24)
        withUnsafeBytes(of: size.littleEndian) { block.append(contentsOf: $0) }
        block.append(pair)
        withUnsafeBytes(of: size.littleEndian) { block.append(contentsOf: $0) }
        block.append(Data("APK Sig Block 42".utf8))
        let data = ZIPBuilder([.init("AndroidManifest.xml", Data("<manifest/>".utf8))], beforeDirectory: block).build()
        let zip = try ZIPArchive(data: data)
        let pairs = AndroidSigning.signingBlock(of: zip)
        XCTAssertEqual(pairs.map(\.0), [AndroidSigning.v2ID])
        XCTAssertEqual(pairs.first?.1, Data("ABCDEFGH".utf8))
        XCTAssertEqual(zip.contents(of: "AndroidManifest.xml"), Data("<manifest/>".utf8))
    }

    private func XCTAssertEncrypted(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case ArchiveError.encrypted = error else { return XCTFail("expected encrypted, got \(error)", file: file, line: line) }
    }

    private func XCTAssertTooLarge(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case ArchiveError.tooLarge = error else { return XCTFail("expected too large, got \(error)", file: file, line: line) }
    }
}

/// Writes ZIP archives byte by byte, including the parts most tools never produce on demand:
/// ZIP64 fields on small files, data descriptors, legacy names, encryption flags and lying sizes.
struct ZIPBuilder {
    struct Entry {
        var name: [UInt8]
        var data: Data
        var method: UInt16
        var flags: UInt16
        var zip64: Bool
        var dataDescriptor: Bool
        /// Overrides the uncompressed size the headers state.
        var declaredSize: UInt32?
        /// A method code written as is, with the data stored (for methods Greece doesn't decode).
        var rawMethod: UInt16?
        var extra: Data

        init(_ name: String, _ data: Data, method: UInt16 = 0, flags: UInt16 = 0, zip64: Bool = false, dataDescriptor: Bool = false,
             declaredSize: UInt32? = nil, rawMethod: UInt16? = nil, extra: Data = Data()) {
            self.init(bytes: Array(name.utf8), data, method: method, flags: flags, zip64: zip64, dataDescriptor: dataDescriptor,
                      declaredSize: declaredSize, rawMethod: rawMethod, extra: extra)
        }

        init(bytes: [UInt8], _ data: Data, method: UInt16 = 0, flags: UInt16 = 0, zip64: Bool = false, dataDescriptor: Bool = false,
             declaredSize: UInt32? = nil, rawMethod: UInt16? = nil, extra: Data = Data()) {
            name = bytes
            self.data = data
            self.method = method
            self.flags = flags | (dataDescriptor ? 0x0008 : 0)
            self.zip64 = zip64
            self.dataDescriptor = dataDescriptor
            self.declaredSize = declaredSize
            self.rawMethod = rawMethod
            self.extra = extra
        }
    }

    var entries: [Entry]
    var zip64End = false
    /// Bytes between the last member and the central directory (an APK Signing Block).
    var beforeDirectory = Data()

    init(_ entries: [Entry], zip64End: Bool = false, beforeDirectory: Data = Data()) {
        self.entries = entries
        self.zip64End = zip64End
        self.beforeDirectory = beforeDirectory
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] }
        }
        return ~crc
    }

    func build() -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: UInt16, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        for entry in entries {
            let payload = entry.method == 8 ? (try! (entry.data as NSData).compressed(using: .zlib) as Data) : entry.data
            let method = entry.rawMethod ?? entry.method
            let crc = Self.crc32(entry.data)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            let offset = UInt64(out.count)
            // Local header.
            var localExtra = Data()
            if entry.zip64 { u16(1, &localExtra); u16(16, &localExtra); u64(UInt64(size), &localExtra); u64(UInt64(payload.count), &localExtra) }
            u32(0x04034B50, &out); u16(entry.zip64 ? 45 : 20, &out); u16(entry.flags, &out); u16(method, &out)
            u16(0, &out); u16(0x21, &out)
            if entry.dataDescriptor { u32(0, &out); u32(0, &out); u32(0, &out) } else if entry.zip64 {
                u32(crc, &out); u32(0xFFFF_FFFF, &out); u32(0xFFFF_FFFF, &out)
            } else {
                u32(crc, &out); u32(UInt32(payload.count), &out); u32(size, &out)
            }
            u16(UInt16(entry.name.count), &out); u16(UInt16(localExtra.count), &out)
            out.append(contentsOf: entry.name); out.append(localExtra); out.append(payload)
            if entry.dataDescriptor { u32(0x08074B50, &out); u32(crc, &out); u32(UInt32(payload.count), &out); u32(size, &out) }

            // Central directory record.
            var extra = Data()
            if entry.zip64 { u16(1, &extra); u16(24, &extra); u64(UInt64(size), &extra); u64(UInt64(payload.count), &extra); u64(offset, &extra) }
            extra.append(entry.extra)
            u32(0x02014B50, &central); u16(0x031E, &central); u16(entry.zip64 ? 45 : 20, &central); u16(entry.flags, &central); u16(method, &central)
            u16(0, &central); u16(0x21, &central); u32(crc, &central)
            u32(entry.zip64 ? 0xFFFF_FFFF : UInt32(payload.count), &central); u32(entry.zip64 ? 0xFFFF_FFFF : size, &central)
            u16(UInt16(entry.name.count), &central); u16(UInt16(extra.count), &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(entry.name.last == UInt8(ascii: "/") ? 0o040755 << 16 : 0o100644 << 16, &central)
            u32(entry.zip64 ? 0xFFFF_FFFF : UInt32(offset), &central)
            central.append(contentsOf: entry.name); central.append(extra)
        }
        out.append(beforeDirectory)
        let start = UInt64(out.count)
        out.append(central)
        if zip64End {
            let record = UInt64(out.count)
            u32(0x06064B50, &out); u64(44, &out); u16(45, &out); u16(45, &out); u32(0, &out); u32(0, &out)
            u64(UInt64(entries.count), &out); u64(UInt64(entries.count), &out); u64(UInt64(central.count), &out); u64(start, &out)
            u32(0x07064B50, &out); u32(0, &out); u64(record, &out); u32(1, &out)
            u32(0x06054B50, &out); u16(0, &out); u16(0, &out); u16(0xFFFF, &out); u16(0xFFFF, &out)
            u32(0xFFFF_FFFF, &out); u32(0xFFFF_FFFF, &out); u16(0, &out)
        } else {
            u32(0x06054B50, &out); u16(0, &out); u16(0, &out); u16(UInt16(entries.count), &out); u16(UInt16(entries.count), &out)
            u32(UInt32(central.count), &out); u32(UInt32(start), &out); u16(0, &out)
        }
        return out
    }
}
