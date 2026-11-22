import AppKit
import Compression
import CArchive

/// Reads an app icon out of a compiled asset catalog (Assets.car), which is where Xcode puts iOS
/// icons today. The catalog is a BOM store: FACETKEYS maps asset names to an identifier, KEYFORMAT
/// says where that identifier sits in each rendition key, and RENDITIONS holds the images (CSI
/// headers followed by LZFSE/zlib-compressed BGRA pixels, or embedded PNG/JPEG data).
enum AssetCatalog {
    static let maxSize = 96 << 20
    static let maxDimension = 2048
    private static let identifierAttribute: UInt16 = 17   // kCRThemeIdentifierName

    static func appIcon(in data: Data, named name: String?) -> NSImage? {
        guard data.count >= 32, data.count <= maxSize, data.prefix(8).elementsEqual(Array("BOMStore".utf8)) else { return nil }
        let store = BOMStore(data)
        guard let keyFormat = store.variable("KEYFORMAT").flatMap(store.block), let facets = store.variable("FACETKEYS"),
              let renditions = store.variable("RENDITIONS") else { return nil }

        // Where the identifier sits in a rendition key.
        let format = BinaryReader(data.subdata(in: keyFormat.start..<(keyFormat.start + keyFormat.length)))
        let attributeCount = Int(format.u32(at: 8) ?? 0)
        var identifierPosition: Int?
        for index in 0..<min(attributeCount, 64) where format.u32(at: 12 + index * 4) == UInt32(identifierAttribute) {
            identifierPosition = index
        }
        guard let identifierPosition else { return nil }

        // The facet's identifier: the named icon set, else anything called AppIcon.
        let wanted = Set([name, "AppIcon"].compactMap { $0 })
        var identifier: UInt16?
        store.walk(tree: facets, limit: 20_000) { key, value in
            let facet = String(decoding: key.prefix { $0 != 0 }, as: UTF8.self)
            guard wanted.contains(facet) else { return true }
            let token = BinaryReader(value)
            let count = Int(token.u16(at: 4) ?? 0)
            for index in 0..<min(count, 64) where token.u16(at: 6 + index * 4) == identifierAttribute {
                identifier = token.u16(at: 8 + index * 4)
            }
            return facet != (name ?? "AppIcon")
        }
        guard let identifier else { return nil }

        // Candidate renditions, largest first.
        var candidates: [(width: Int, csi: Data)] = []
        store.walk(tree: renditions, limit: 50_000) { key, value in
            let keyReader = BinaryReader(key)
            guard keyReader.u16(at: identifierPosition * 2) == identifier, value.count > 184 else { return true }
            let csi = BinaryReader(value)
            guard csi.bytes(at: 0, count: 4) == Data("ISTC".utf8), let width = csi.u32(at: 12).map(Int.init),
                  let height = csi.u32(at: 16).map(Int.init), width == height, width > 0, width <= maxDimension else { return true }
            candidates.append((width, value))
            return true
        }
        for candidate in candidates.sorted(by: { $0.width > $1.width }).prefix(6) {
            if let image = decode(csi: candidate.csi) { return image }
        }
        return nil
    }

    /// One rendition: a 184-byte CSI header, TLVs, then the image data.
    static func decode(csi data: Data) -> NSImage? {
        let reader = BinaryReader(data)
        guard let width = reader.u32(at: 12).map(Int.init), let height = reader.u32(at: 16).map(Int.init),
              let pixelFormat = reader.bytes(at: 24, count: 4), let tlvLength = reader.u32(at: 168).map(Int.init),
              let renditionLength = reader.u32(at: 180).map(Int.init),
              width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              let body = reader.bytes(at: 184 + tlvLength, count: renditionLength) else { return nil }
        let bodyReader = BinaryReader(body)
        let tag = bodyReader.bytes(at: 0, count: 4).map { String(decoding: $0, as: UTF8.self) }

        if tag == "DWAR" || tag == "RAWD", let length = bodyReader.u32(at: 8).map(Int.init), let raw = bodyReader.bytes(at: 12, count: length) {
            return NSImage(data: raw)
        }
        // Pixel data: "ARGB" is stored little-endian as "BGRA".
        guard pixelFormat == Data("BGRA".utf8) else { return nil }
        let expected = width * height * 4
        guard tag == "MLEC", let compression = bodyReader.u32(at: 8), let fourth = bodyReader.u32(at: 12).map(Int.init) else { return nil }
        var pixels = Data()
        if bodyReader.bytes(at: 16, count: 4) == Data("KCBC".utf8) {
            // Current catalogs: a chunk count, then bands of rows, each "KCBC", 0, 0, rows, length, data.
            var offset = 16
            for _ in 0..<min(fourth, 4096) {
                guard pixels.count < expected, bodyReader.bytes(at: offset, count: 4) == Data("KCBC".utf8),
                      let length = bodyReader.u32(at: offset + 16).map(Int.init),
                      let compressed = bodyReader.bytes(at: offset + 20, count: length),
                      let chunk = decode(compressed, compression: compression, capacity: expected - pixels.count) else { return nil }
                pixels.append(chunk)
                offset += 20 + length
            }
        } else {
            // Older catalogs: the fourth field is the length of one compressed block.
            guard let compressed = bodyReader.bytes(at: 16, count: fourth),
                  let chunk = decode(compressed, compression: compression, capacity: expected) else { return nil }
            pixels = chunk
        }
        guard pixels.count >= expected else { return nil }
        let rowBytes = pixels.count / height >= width * 4 ? pixels.count / height : width * 4
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    private static func decode(_ compressed: Data, compression: UInt32, capacity: Int) -> Data? {
        guard capacity > 0 else { return nil }
        switch compression {
        case 0: return compressed.prefix(capacity)
        case 3, 4: return decompress(compressed, algorithm: COMPRESSION_LZFSE, capacity: capacity)   // LZVN blocks are LZFSE-framed
        case 2: return inflate(compressed, capacity: capacity)
        default: return nil   // palette, ASTC, HEVC and "deepmap" renditions aren't decoded
        }
    }

    private static func decompress(_ data: Data, algorithm: compression_algorithm, capacity: Int) -> Data? {
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }

    private static func inflate(_ data: Data, capacity: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: capacity)
        let status: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return CArchive.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || status == Z_OK || status == Z_BUF_ERROR else { return nil }
        output.count = capacity - Int(stream.avail_out)
        return output
    }
}

/// The generic parts of a BOM store: named variables and B-tree walks, bounded against cycles.
struct BOMStore {
    let data: Data
    private let reader: BinaryReader
    private let indexOffset: Int
    private let blockCount: Int
    private var variables: [String: UInt32] = [:]

    init(_ data: Data) {
        self.data = data.startIndex == 0 ? data : Data(data)
        reader = BinaryReader(self.data, bigEndian: true)
        indexOffset = Int(reader.u32(at: 16) ?? 0)
        let indexLength = Int(reader.u32(at: 20) ?? 0)
        blockCount = min(Int(reader.u32(at: indexOffset) ?? 0), max(0, (indexLength - 4) / 8))
        let varsOffset = Int(reader.u32(at: 24) ?? 0)
        if let count = reader.u32(at: varsOffset) {
            var position = varsOffset + 4
            for _ in 0..<min(Int(count), 128) {
                guard let number = reader.u32(at: position), let length = reader.u8(at: position + 4).map(Int.init),
                      let name = reader.bytes(at: position + 5, count: length) else { break }
                variables[String(decoding: name, as: UTF8.self)] = number
                position += 5 + length
            }
        }
    }

    func variable(_ name: String) -> UInt32? { variables[name] }

    func block(_ number: UInt32) -> (start: Int, length: Int)? {
        let index = Int(number)
        guard index > 0, index < blockCount,
              let address = reader.u32(at: indexOffset + 4 + index * 8).map(Int.init),
              let length = reader.u32(at: indexOffset + 8 + index * 8).map(Int.init),
              reader.has(length, at: address) else { return nil }
        return (address, length)
    }

    private func bytes(_ number: UInt32) -> Data? {
        block(number).map { data.subdata(in: $0.start..<($0.start + $0.length)) }
    }

    /// Visits every (key, value) in a tree, in order. Return false to stop.
    func walk(tree number: UInt32, limit: Int, _ visit: (Data, Data) -> Bool) {
        guard let tree = block(number), tree.length >= 12, reader.bytes(at: tree.start, count: 4) == Data("tree".utf8),
              var node = reader.u32(at: tree.start + 8) else { return }
        var seen = Set<UInt32>()
        // Down to the leftmost leaf.
        while true {
            guard seen.insert(node).inserted, seen.count < 64, let location = block(node), location.length >= 12,
                  let isLeaf = reader.u16(at: location.start) else { return }
            if isLeaf != 0 { break }
            guard let child = reader.u32(at: location.start + 12) else { return }
            node = child
        }
        var visited = 0
        var leaves = Set<UInt32>()
        var leaf = node
        while leaf != 0, leaves.insert(leaf).inserted, let location = block(leaf),
              let count = reader.u16(at: location.start + 2).map(Int.init), let forward = reader.u32(at: location.start + 4) {
            for index in 0..<count {
                let pair = location.start + 12 + index * 8
                guard pair + 8 <= location.start + location.length, let valueIndex = reader.u32(at: pair),
                      let keyIndex = reader.u32(at: pair + 4), let value = bytes(valueIndex), let key = bytes(keyIndex) else { continue }
                visited += 1
                if visited > limit || !visit(key, value) { return }
            }
            leaf = forward
        }
    }
}
