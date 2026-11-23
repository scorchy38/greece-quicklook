import Foundation

/// A ".sparseimage": a 4 KB "sprs" header mapping stored bands to their place on the virtual disk.
///
/// Header (big-endian): "sprs", u32 version (3), u32 sectors per band, u32 flags, u32 sector count,
/// …, then from offset 64 an array of u32 band numbers (virtual band + 1, 0 when unused).
/// Band `i` of the file starts at 4096 + i × band size.
final class SparseImageDevice: DiskDevice {
    static let headerSize = 4096
    let size: UInt64
    let bandSize: UInt64
    let storedBands: Int
    private let data: Data
    /// Virtual band → index of the band stored in the file.
    private let map: [UInt64: Int]

    static func isSparseImage(_ probe: [UInt8]) -> Bool { probe.count >= 4 && probe[0..<4].elementsEqual(Array("sprs".utf8)) }

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        let r = BinaryReader(data, bigEndian: true)
        guard data.count >= SparseImageDevice.headerSize, r.bytes(at: 0, count: 4) == Data("sprs".utf8),
              let sectorsPerBand = r.u32(at: 8), (1...(1 << 20)).contains(sectorsPerBand),
              let sectors = r.u32(at: 16) else { throw DiskImageError.notADiskImage }
        bandSize = UInt64(sectorsPerBand) * 512
        size = UInt64(sectors) * 512
        var map: [UInt64: Int] = [:]
        let stored = (data.count - SparseImageDevice.headerSize) / Int(bandSize) + 1
        var count = 0
        for index in 0..<((SparseImageDevice.headerSize - 64) / 4) {
            guard let value = r.u32(at: 64 + index * 4), value != 0 else { continue }
            guard index < stored else { break }
            map[UInt64(value - 1)] = index
            count += 1
        }
        self.map = map
        storedBands = count
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let total = Int(min(UInt64(count), size - offset))
        var output = Data(count: total)
        var written = 0
        while written < total {
            let position = offset + UInt64(written)
            let band = position / bandSize
            let within = position % bandSize
            let length = Int(min(UInt64(total - written), bandSize - within))
            if let stored = map[band] {
                let start = UInt64(SparseImageDevice.headerSize) + UInt64(stored) * bandSize + within
                if start < UInt64(data.count) {
                    let available = min(length, data.count - Int(start))
                    output.replaceSubrange(written..<(written + available), with: data[Int(start)..<(Int(start) + available)])
                }
            }
            written += length
        }
        return output
    }
}

/// A ".sparsebundle": a folder with Info.plist and a "bands" folder of fixed-size band files named in hex.
final class SparseBundleDevice: DiskDevice {
    let size: UInt64
    let bandSize: UInt64
    let bandCount: Int
    let isEncrypted: Bool
    private let bands: URL
    private let cache = DiskChunkCache(capacity: 8, byteLimit: 64 << 20)

    init(url: URL) throws {
        let infoURL = url.appendingPathComponent("Info.plist")
        guard let info = try? Data(contentsOf: infoURL), info.count < 1 << 20,
              let plist = try? PropertyListSerialization.propertyList(from: info, options: [], format: nil) as? [String: Any],
              (plist["diskimage-bundle-type"] as? String)?.contains("sparsebundle") == true else { throw DiskImageError.notADiskImage }
        let band = (plist["band-size"] as? NSNumber)?.uint64Value ?? 0
        let total = (plist["size"] as? NSNumber)?.uint64Value ?? 0
        guard band >= 4096, band <= 1 << 30 else { throw DiskImageError.corrupt("band size") }
        bandSize = band
        size = total
        bands = url.appendingPathComponent("bands")
        bandCount = (try? FileManager.default.contentsOfDirectory(atPath: bands.path).count) ?? 0
        // Encrypted bundles carry their key material in "token" with an encrcdsa header.
        if let handle = try? FileHandle(forReadingFrom: url.appendingPathComponent("token")),
           let head = try? handle.read(upToCount: 8) {
            isEncrypted = head == Data("encrcdsa".utf8)
            try? handle.close()
        } else {
            isEncrypted = false
        }
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard !isEncrypted else { throw DiskImageError.encrypted }
        guard offset < size, count > 0 else { return Data() }
        let total = Int(min(UInt64(count), size - offset))
        var output = Data(count: total)
        var written = 0
        while written < total {
            let position = offset + UInt64(written)
            let band = position / bandSize
            let within = Int(position % bandSize)
            let length = min(total - written, Int(bandSize) - within)
            if let contents = bandData(Int(band)), within < contents.count {
                let available = min(length, contents.count - within)
                output.replaceSubrange(written..<(written + available), with: contents[within..<(within + available)])
            }
            written += length
        }
        return output
    }

    private func bandData(_ index: Int) -> Data? {
        if let cached = cache.get(index) { return cached }
        let url = bands.appendingPathComponent(String(index, radix: 16))
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        cache.put(index, data)
        return data
    }
}

/// Apple Sparse Image Format (".asif", macOS 26). Reverse-engineered layout (big-endian):
/// "shdw", u32 version, u32 header size, u32 flags, u64 directory offsets ×2, UUID, u64 sector count,
/// u64 maximum size, u32 chunk size, u16 sector size. Each directory starts with a generation number and
/// the chunk index of the mapping table; the table holds one u64 per virtual chunk (top bits flags,
/// low bits the file chunk), with an extra bitmap entry after every 2,048 chunks.
final class ASIFDevice: DiskDevice {
    let size: UInt64
    let chunkSize: UInt64
    let uuid: UUID?
    private let data: Data
    private let table: Int

    static func isASIF(_ probe: [UInt8]) -> Bool { probe.count >= 4 && probe[0..<4].elementsEqual(Array("shdw".utf8)) }

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        let r = BinaryReader(data, bigEndian: true)
        guard r.bytes(at: 0, count: 4) == Data("shdw".utf8), let sectors = r.u64(at: 48),
              let chunk = r.u32(at: 64), let sector = r.u16(at: 68), sector >= 512, sector <= 4096,
              chunk >= 64 * 1024, chunk <= 64 << 20, chunk % UInt32(sector) == 0 else { throw DiskImageError.notADiskImage }
        size = sectors.multipliedReportingOverflow(by: UInt64(sector)).overflow ? 0 : sectors * UInt64(sector)
        chunkSize = UInt64(chunk)
        uuid = r.bytes(at: 32, count: 16).map { bytes in bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) } }
        // Two directory copies: the newer generation wins.
        var best: (generation: UInt64, table: UInt64)?
        for at in [16, 24] {
            guard let directory = r.u64(at: at).flatMap({ Int(exactly: $0) }), let generation = r.u64(at: directory),
                  let tableChunk = r.u64(at: directory + 8) else { continue }
            if best == nil || generation > best!.generation { best = (generation, tableChunk) }
        }
        guard let best, let start = Int(exactly: best.table.multipliedReportingOverflow(by: chunkSize).partialValue),
              !best.table.multipliedReportingOverflow(by: chunkSize).overflow, start < data.count else {
            throw DiskImageError.corrupt("ASIF directory")
        }
        table = start
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let total = Int(min(UInt64(count), size - offset))
        var output = Data(count: total)
        let r = BinaryReader(data, bigEndian: true)
        var written = 0
        while written < total {
            let position = offset + UInt64(written)
            let chunk = position / chunkSize
            let within = position % chunkSize
            let length = Int(min(UInt64(total - written), chunkSize - within))
            let group = chunk / 2048
            let entryIndex = group * 2049 + chunk % 2048
            if entryIndex < UInt64(Int.max / 16), case let (at, overflow) = table.addingReportingOverflow(Int(entryIndex) * 8), !overflow,
               let entry = r.u64(at: at),
               entry & 0x4000_0000_0000_0000 != 0 {
                let stored = entry & 0x00FF_FFFF_FFFF_FFFF
                let (base, overflow) = stored.multipliedReportingOverflow(by: chunkSize)
                if !overflow, base < UInt64(data.count) {
                    let start = Int(base + within)
                    if start < data.count {
                        let available = min(length, data.count - start)
                        output.replaceSubrange(written..<(written + available), with: data[start..<(start + available)])
                    }
                }
            }
            written += length
        }
        return output
    }
}

/// The header of an encrypted image ("encrcdsa", version 2) or the trailer of a version 1 one ("cdsaencr").
struct DiskEncryption: Equatable {
    var version: Int
    var keyBits: Int?
    var blockSize: Int?
    var dataSize: UInt64?

    var algorithm: String { keyBits.map { "AES-\($0)" } ?? "AES" }

    init?(header: Data) {
        let r = BinaryReader(header, bigEndian: true)
        guard r.bytes(at: 0, count: 8) == Data("encrcdsa".utf8) else { return nil }
        version = Int(r.u32(at: 8) ?? 2)
        let bits = Int(r.u32(at: 24) ?? 0)
        keyBits = [128, 192, 256].contains(bits) ? bits : nil
        let block = Int(r.u32(at: 52) ?? 0)
        blockSize = block >= 512 && block <= 1 << 20 ? block : nil
        dataSize = r.u64(at: 56)
    }

    init?(trailer: Data) {
        guard trailer.count >= 8, trailer.suffix(8) == Data("cdsaencr".utf8) else { return nil }
        version = 1
        keyBits = nil
        blockSize = nil
        dataSize = nil
    }
}
