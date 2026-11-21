import AppKit

/// Apple's Universal Disk Image Format: compressed chunks of sectors, described by a property list
/// ("blkx" tables) and a 512-byte "koly" trailer at the end of the file.
final class UDIFImage: DiskDevice {
    struct Trailer {
        var version: UInt32
        var flags: UInt32
        var dataForkOffset: UInt64
        var dataForkLength: UInt64
        var resourceForkOffset: UInt64
        var resourceForkLength: UInt64
        var segmentNumber: UInt32
        var segmentCount: UInt32
        var segmentID: UUID?
        var dataChecksum: Checksum?
        var xmlOffset: UInt64
        var xmlLength: UInt64
        var codeSignatureOffset: UInt64
        var codeSignatureLength: UInt64
        var masterChecksum: Checksum?
        var imageVariant: UInt32
        var sectorCount: UInt64
    }

    struct Checksum: Equatable {
        var type: UInt32
        var value: UInt32
        var name: String {
            switch type {
            case 1: return "CRC-32 (UDIF)"
            case 2: return "CRC-32"
            case 3: return "MD5"
            case 4: return "SHA-1"
            default: return "Type \(type)"
            }
        }
        /// "$A030D4BB", as hdiutil prints it.
        var text: String { String(format: "$%08X", value) }
    }

    struct Chunk {
        var type: UInt32
        var sector: UInt64
        var sectorCount: UInt64
        var fileOffset: UInt64
        var length: UInt64
    }

    /// One "blkx" entry: a partition (or the partition map) and its chunks.
    struct Block {
        var name: String
        var id: Int
        var firstSector: UInt64
        var sectorCount: UInt64
        var checksum: Checksum?
        var chunkTypes: Set<UInt32>
    }

    enum ChunkType {
        static let zero: UInt32 = 0x0000_0000
        static let raw: UInt32 = 0x0000_0001
        static let ignore: UInt32 = 0x0000_0002
        static let adc: UInt32 = 0x8000_0004
        static let zlib: UInt32 = 0x8000_0005
        static let bzip2: UInt32 = 0x8000_0006
        static let lzfse: UInt32 = 0x8000_0007
        static let lzma: UInt32 = 0x8000_0008
        static let comment: UInt32 = 0x7FFF_FFFE
        static let terminator: UInt32 = 0xFFFF_FFFF
    }

    static let sectorSize: UInt64 = 512
    static let maximumChunks = 2_000_000
    static let maximumChunkBytes: UInt64 = 64 << 20

    let url: URL
    let fileSize: UInt64
    let trailer: Trailer
    let blocks: [Block]
    /// Resources other than "blkx" (license agreements: LPic, TEXT, RTF , STR#).
    let resources: [String: [[String: Any]]]
    let size: UInt64
    private let data: Data
    private let chunks: [Chunk]
    private let cache = DiskChunkCache()

    /// Reads the trailer only: cheap enough for detection.
    static func trailer(of url: URL) -> Trailer? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end >= 512, (try? handle.seek(toOffset: end - 512)) != nil,
              let tail = try? handle.read(upToCount: 512), tail.count == 512 else { return nil }
        return parseTrailer(tail)
    }

    static func parseTrailer(_ tail: Data) -> Trailer? {
        let r = BinaryReader(tail, bigEndian: true)
        guard tail.count >= 512, r.bytes(at: 0, count: 4) == Data("koly".utf8), let headerSize = r.u32(at: 8), headerSize == 512 else { return nil }
        func checksum(_ at: Int) -> Checksum? {
            guard let type = r.u32(at: at), type != 0, let value = r.u32(at: at + 8) else { return nil }
            return Checksum(type: type, value: value)
        }
        var segmentID: UUID?
        if let bytes = r.bytes(at: 64, count: 16), bytes.contains(where: { $0 != 0 }) {
            segmentID = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        }
        return Trailer(version: r.u32(at: 4) ?? 0, flags: r.u32(at: 12) ?? 0,
                       dataForkOffset: r.u64(at: 24) ?? 0, dataForkLength: r.u64(at: 32) ?? 0,
                       resourceForkOffset: r.u64(at: 40) ?? 0, resourceForkLength: r.u64(at: 48) ?? 0,
                       segmentNumber: r.u32(at: 56) ?? 0, segmentCount: r.u32(at: 60) ?? 0, segmentID: segmentID,
                       dataChecksum: checksum(80), xmlOffset: r.u64(at: 216) ?? 0, xmlLength: r.u64(at: 224) ?? 0,
                       codeSignatureOffset: r.u64(at: 296) ?? 0, codeSignatureLength: r.u64(at: 304) ?? 0,
                       masterChecksum: checksum(352), imageVariant: r.u32(at: 488) ?? 0, sectorCount: r.u64(at: 492) ?? 0)
    }

    init(url: URL) throws {
        self.url = url
        data = try Data(contentsOf: url, options: .alwaysMapped)
        fileSize = UInt64(data.count)
        guard data.count >= 512, let trailer = UDIFImage.parseTrailer(data.subdata(in: (data.count - 512)..<data.count)) else {
            throw DiskImageError.notADiskImage
        }
        self.trailer = trailer

        // The block tables live in an XML property list (modern images) just before the trailer.
        guard trailer.xmlLength > 0, trailer.xmlLength <= 64 << 20, trailer.xmlOffset <= fileSize,
              trailer.xmlLength <= fileSize - trailer.xmlOffset else {
            throw DiskImageError.unsupported("This disk image keeps its partition tables in a legacy resource fork.")
        }
        let xml = data.subdata(in: Int(trailer.xmlOffset)..<Int(trailer.xmlOffset + trailer.xmlLength))
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any],
              let fork = plist["resource-fork"] as? [String: Any] else { throw DiskImageError.corrupt("property list") }

        var resources: [String: [[String: Any]]] = [:]
        for (key, value) in fork where key != "blkx" {
            if let list = value as? [[String: Any]] { resources[key] = Array(list.prefix(256)) }
        }
        self.resources = resources

        var blocks: [Block] = []
        var chunks: [Chunk] = []
        for entry in (fork["blkx"] as? [[String: Any]] ?? []).prefix(4096) {
            guard let mish = entry["Data"] as? Data else { continue }
            let name = (entry["Name"] as? String) ?? (entry["CFName"] as? String) ?? ""
            let id = (entry["ID"] as? String).flatMap { Int($0) } ?? (entry["ID"] as? Int) ?? 0
            guard let parsed = UDIFImage.parseBlockTable(mish, dataForkOffset: trailer.dataForkOffset, fileSize: fileSize,
                                                         budget: UDIFImage.maximumChunks - chunks.count) else { continue }
            blocks.append(Block(name: name, id: id, firstSector: parsed.first, sectorCount: parsed.count,
                                checksum: parsed.checksum, chunkTypes: Set(parsed.chunks.map(\.type))))
            chunks += parsed.chunks
            if chunks.count >= UDIFImage.maximumChunks { break }
        }
        guard !blocks.isEmpty else { throw DiskImageError.corrupt("no partition tables") }
        chunks.sort { $0.sector < $1.sector }
        self.blocks = blocks
        self.chunks = chunks
        let tableEnd = blocks.map { $0.firstSector &+ $0.sectorCount }.max() ?? 0
        let sectors = trailer.sectorCount > 0 ? trailer.sectorCount : tableEnd
        size = min(sectors, UInt64.max / UDIFImage.sectorSize) * UDIFImage.sectorSize
    }

    /// Parses a "mish" block table. Returns nil for anything malformed.
    static func parseBlockTable(_ mish: Data, dataForkOffset: UInt64, fileSize: UInt64, budget: Int)
        -> (first: UInt64, count: UInt64, checksum: Checksum?, chunks: [Chunk])? {
        let r = BinaryReader(mish, bigEndian: true)
        guard r.bytes(at: 0, count: 4) == Data("mish".utf8), let first = r.u64(at: 8), let count = r.u64(at: 16),
              let declared = r.u32(at: 200).map(Int.init) else { return nil }
        let checksumType = r.u32(at: 64) ?? 0
        let checksum = checksumType != 0 ? Checksum(type: checksumType, value: r.u32(at: 72) ?? 0) : nil
        let fits = max(0, (mish.count - 204) / 40)
        var chunks: [Chunk] = []
        for index in 0..<min(declared, fits, max(0, budget)) {
            let at = 204 + index * 40
            guard let type = r.u32(at: at), let sector = r.u64(at: at + 8), let sectors = r.u64(at: at + 16),
                  let offset = r.u64(at: at + 24), let length = r.u64(at: at + 32) else { break }
            if type == ChunkType.terminator { break }
            if type == ChunkType.comment || sectors == 0 { continue }
            let (absolute, overflow) = first.addingReportingOverflow(sector)
            let (end, overflow3) = absolute.addingReportingOverflow(sectors)
            // Data chunks are at most 64 MB once expanded; only zero runs may be longer.
            let isZero = type == ChunkType.zero || type == ChunkType.ignore
            guard !overflow, !overflow3, end <= UInt64.max / sectorSize,
                  isZero || sectors <= maximumChunkBytes / sectorSize else { continue }
            let (fileOffset, overflow2) = dataForkOffset.addingReportingOverflow(offset)
            guard !overflow2 else { continue }
            chunks.append(Chunk(type: type, sector: absolute, sectorCount: sectors, fileOffset: fileOffset, length: length))
        }
        return (first, count, checksum, chunks)
    }

    // MARK: Format

    var chunkTypes: Set<UInt32> { blocks.reduce(into: Set<UInt32>()) { $0.formUnion($1.chunkTypes) } }

    /// hdiutil's format code and a plain description.
    var format: (code: String, description: String, compression: String?) {
        let types = chunkTypes
        if types.contains(ChunkType.lzfse) { return ("ULFO", "Compressed (LZFSE)", "LZFSE") }
        if types.contains(ChunkType.lzma) { return ("ULMO", "Compressed (LZMA)", "LZMA") }
        if types.contains(ChunkType.bzip2) { return ("UDBZ", "Compressed (bzip2)", "bzip2") }
        if types.contains(ChunkType.zlib) { return ("UDZO", "Compressed (zlib)", "zlib") }
        if types.contains(ChunkType.adc) { return ("UDCO", "Compressed (ADC)", "ADC") }
        return ("UDRO", "Read-only", nil)
    }

    /// Bytes of chunk data actually stored.
    var storedBytes: UInt64 {
        chunks.reduce(0) { total, chunk in
            chunk.type == ChunkType.zero || chunk.type == ChunkType.ignore ? total : total.saturatingAdd(chunk.length)
        }
    }

    /// The software license agreement shown before mounting, as plain text.
    var licenseText: String? {
        // RTF first (it carries formatting hdiutil shows), then TEXT.
        let candidates: [(String, (Data) -> String?)] = [
            ("RTF ", { data in
                (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string
            }),
            ("TEXT", { data in
                String(data: data, encoding: .utf8) ?? String(data: data, encoding: .macOSRoman)
            }),
        ]
        for (key, decode) in candidates {
            guard let list = resources[key], !list.isEmpty else { continue }
            // Prefer the English (ID 5000) agreement, else the first.
            let entry = list.first { ($0["ID"] as? String) == "5000" } ?? list[0]
            guard let data = entry["Data"] as? Data, data.count < 4 << 20, let text = decode(data) else { continue }
            let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    var hasLicenseAgreement: Bool { resources["LPic"] != nil || resources["TEXT"] != nil || resources["RTF "] != nil }

    // MARK: Reading

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let total = Int(min(UInt64(count), size - offset))
        var output = Data(count: total)
        var position = offset
        var written = 0
        while written < total {
            let sector = position / UDIFImage.sectorSize
            let index = chunkIndex(containing: sector)
            if let index {
                let chunk = chunks[index]
                let chunkStart = chunk.sector * UDIFImage.sectorSize
                let within = position - chunkStart
                let chunkBytes = chunk.sectorCount * UDIFImage.sectorSize
                let length = Int(min(UInt64(total - written), chunkBytes - within))
                if chunk.type != ChunkType.zero && chunk.type != ChunkType.ignore {
                    let contents = try decompressed(index)
                    let start = Int(within)
                    if start < contents.count {
                        let available = min(length, contents.count - start)
                        output.replaceSubrange(written..<(written + available), with: contents[(contents.startIndex + start)..<(contents.startIndex + start + available)])
                    }
                }
                written += length
                position += UInt64(length)
            } else {
                // A gap between chunks: zeros up to the next chunk.
                let next = nextChunkStart(after: sector).map { min($0, UInt64.max / UDIFImage.sectorSize) * UDIFImage.sectorSize } ?? size
                let length = Int(min(UInt64(total - written), max(next, position + 1) - position))
                written += length
                position += UInt64(length)
            }
        }
        return output
    }

    private func chunkIndex(containing sector: UInt64) -> Int? {
        var low = 0, high = chunks.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let chunk = chunks[middle]
            if sector < chunk.sector { high = middle - 1 }
            else if sector >= chunk.sector &+ chunk.sectorCount { low = middle + 1 }
            else { return middle }
        }
        return nil
    }

    private func nextChunkStart(after sector: UInt64) -> UInt64? {
        var low = 0, high = chunks.count
        while low < high {
            let middle = (low + high) / 2
            if chunks[middle].sector <= sector { low = middle + 1 } else { high = middle }
        }
        return low < chunks.count ? chunks[low].sector : nil
    }

    private func decompressed(_ index: Int) throws -> Data {
        if let cached = cache.get(index) { return cached }
        let chunk = chunks[index]
        let expected = chunk.sectorCount * UDIFImage.sectorSize
        guard expected <= UDIFImage.maximumChunkBytes, chunk.length <= UDIFImage.maximumChunkBytes,
              chunk.fileOffset <= fileSize, chunk.length <= fileSize - chunk.fileOffset else {
            throw DiskImageError.corrupt("chunk out of range")
        }
        let input = data.subdata(in: Int(chunk.fileOffset)..<Int(chunk.fileOffset + chunk.length))
        let output: Data
        switch chunk.type {
        case ChunkType.raw: output = input
        case ChunkType.zlib: output = try DiskDecompress.zlib(input, expected: Int(expected))
        case ChunkType.bzip2: output = try DiskDecompress.bzip2(input, expected: Int(expected))
        case ChunkType.lzfse: output = try DiskDecompress.lzfse(input, expected: Int(expected))
        case ChunkType.lzma: output = try DiskDecompress.lzma(input, expected: Int(expected))
        case ChunkType.adc: output = try DiskDecompress.adc(input, expected: Int(expected))
        default: throw DiskImageError.unsupported(String(format: "chunk type 0x%08X", chunk.type))
        }
        cache.put(index, output)
        return output
    }
}
