import Foundation
import simd

/// An ASPRS LAS point cloud (1.0–1.4): the header, units from its coordinate system, and an
/// evenly spaced sample of its points. LAZ files share the header; their points are decoded by the page.
struct LASFile {
    struct Header: Encodable, Equatable {
        var versionMajor: Int
        var versionMinor: Int
        var headerSize: Int
        var pointOffset: Int
        var vlrCount: Int
        var pointFormat: Int
        var recordLength: Int
        var pointCount: Int
        var scale: [Double]
        var offset: [Double]
        var minimum: [Double]
        var maximum: [Double]
        var software: String
        var isCompressed: Bool

        var hasRGB: Bool { [2, 3, 5, 7, 8, 10].contains(pointFormat) }
        /// Byte offset of red, green and blue within a record.
        var rgbOffset: Int? {
            switch pointFormat {
            case 2: return 20
            case 3, 5: return 28
            case 7, 8, 10: return 30
            default: return nil
            }
        }
        var isExtended: Bool { pointFormat >= 6 }
        /// The smallest record each point format allows; shorter records are corrupt.
        var minimumRecordLength: Int {
            [20, 28, 26, 34, 57, 63, 30, 36, 38, 59, 67][min(max(pointFormat, 0), 10)]
        }
    }

    struct Units: Encodable, Equatable {
        /// "m", "ft" or "US ft"; nil if unknown.
        var horizontal: String?
        /// True when x and y are longitude and latitude, where distances in x/y mean little.
        var geographic: Bool
    }

    let header: Header
    let units: Units

    enum Failure: Error { case notLAS, unsupported(String) }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data)
    }

    init(data: Data) throws {
        guard data.count >= 227, data.u32(0) == 0x4653414C else { throw Failure.notLAS }   // "LASF"
        let major = Int(data[24]), minor = Int(data[25])
        let headerSize = Int(data.u16(94))
        let pointOffset = Int(data.u32(96))
        let vlrCount = Int(data.u32(100))
        let rawFormat = Int(data[104])
        let recordLength = Int(data.u16(105))
        var count = Int(data.u32(107))
        if major == 1, minor >= 4, data.count >= 255, headerSize >= 375 {
            let extended = data.u64(247)
            if extended > 0, extended < UInt64(Int.max) { count = Int(extended) }
        }
        func f64(_ at: Int) -> Double { Double(bitPattern: data.u64(at)) }
        let software = String(decoding: data.subdata(in: 58..<90).prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let header = Header(versionMajor: major, versionMinor: minor, headerSize: headerSize, pointOffset: pointOffset,
                            vlrCount: vlrCount, pointFormat: rawFormat & 0x3F, recordLength: recordLength, pointCount: count,
                            scale: [f64(131), f64(139), f64(147)], offset: [f64(155), f64(163), f64(171)],
                            minimum: [f64(187), f64(203), f64(219)], maximum: [f64(179), f64(195), f64(211)],
                            software: software, isCompressed: rawFormat & 0xC0 != 0)
        guard header.pointFormat <= 10 else { throw Failure.unsupported("point format \(header.pointFormat)") }
        guard header.recordLength >= header.minimumRecordLength || header.isCompressed else { throw Failure.unsupported("short records") }
        guard header.scale.allSatisfy({ $0.isFinite && $0 != 0 }), header.offset.allSatisfy(\.isFinite) else { throw Failure.unsupported("scale") }
        self.header = header
        self.units = Self.readUnits(data, header: header)
    }

    // MARK: - Units

    /// Reads the coordinate system's linear unit from the GeoTIFF keys or WKT records.
    static func readUnits(_ data: Data, header: Header) -> Units {
        var units = Units(horizontal: nil, geographic: false)
        var offset = header.headerSize
        for _ in 0..<min(header.vlrCount, 512) {
            guard offset + 54 <= data.count, offset < header.pointOffset else { break }
            let user = String(decoding: data.subdata(in: (offset + 2)..<(offset + 18)).prefix { $0 != 0 }, as: UTF8.self)
            let record = Int(data.u16(offset + 18))
            let length = Int(data.u16(offset + 20))
            let body = offset + 54
            guard body + length <= data.count else { break }
            if user == "LASF_Projection" {
                if record == 34735, length >= 8 {
                    // GeoKeyDirectory: a header of four shorts, then (id, location, count, value) per key.
                    let keys = Int(data.u16(body + 6))
                    var projected = false, geographic = false
                    for k in 0..<min(keys, (length - 8) / 8) {
                        let at = body + 8 + k * 8
                        let id = data.u16(at), location = data.u16(at + 2), value = data.u16(at + 6)
                        guard location == 0 else { continue }
                        switch id {
                        case 1024: projected = value == 1; geographic = value == 2
                        case 3072: projected = true
                        case 2048: geographic = true
                        case 3076: units.horizontal = linearUnit(epsg: Int(value)) ?? units.horizontal
                        default: break
                        }
                    }
                    if geographic && !projected { units.geographic = true }
                } else if record == 2112 || record == 2111 {
                    let wkt = String(decoding: data.subdata(in: body..<(body + length)), as: UTF8.self)
                    if let parsed = wktUnits(wkt) { units = parsed }
                }
            }
            offset = body + length
        }
        return units
    }

    static func linearUnit(epsg: Int) -> String? {
        switch epsg {
        case 9001: return "m"
        case 9002: return "ft"
        case 9003: return "US ft"
        default: return nil
        }
    }

    static func wktUnits(_ wkt: String) -> Units? {
        let text = wkt.uppercased()
        let trimmed = text.drop { $0.isWhitespace }
        if trimmed.hasPrefix("GEOGCS") || trimmed.hasPrefix("GEOGCRS") || trimmed.hasPrefix("GEODCRS") {
            return Units(horizontal: nil, geographic: true)
        }
        guard trimmed.hasPrefix("PROJCS") || trimmed.hasPrefix("PROJCRS") || trimmed.hasPrefix("COMPD") else { return nil }
        // The projected system's own unit is the last UNIT before its AXIS/AUTHORITY tail; any foot wins over metre.
        if text.contains("US SURVEY FOOT") || text.contains("FOOT_US") || text.contains("US FOOT") { return Units(horizontal: "US ft", geographic: false) }
        if text.contains("UNIT[\"FOOT") || text.contains("LENGTHUNIT[\"FOOT") || text.contains("INTERNATIONAL FOOT") { return Units(horizontal: "ft", geographic: false) }
        if text.contains("METRE") || text.contains("METER") { return Units(horizontal: "m", geographic: false) }
        return nil
    }

    // MARK: - Sampling

    /// A compact, renderable sample: positions relative to the centre, plus whatever colours exist.
    struct Sample {
        var center: SIMD3<Double>
        var positions: [Float] = []       // x, y, z
        var colors: [UInt8] = []          // r, g, b (8-bit)
        var intensity: [UInt16] = []
        var classes: [UInt8] = []
        var count: Int { positions.count / 3 }
    }

    /// Up to `budget` points, evenly spaced through the file, ordered so that any prefix is itself
    /// an even sample (the page draws fewer points while the view moves). Stops at `deadline`.
    func sample(_ data: Data, budget: Int, deadline: Date = .distantFuture) -> Sample {
        guard var gatherer = Gatherer(header: header, available: max(0, data.count - header.pointOffset), budget: budget),
              header.pointOffset < data.count else { return Sample(center: Gatherer.center(header)) }
        data.withUnsafeBytes { raw in
            _ = gatherer.gather(UnsafeRawBufferPointer(rebasing: raw[header.pointOffset...]), deadline: deadline)
        }
        return gatherer.finish()
    }

    /// The same sample, read from disk in large sequential blocks: far faster than faulting in
    /// a memory map record by record when the file is hundreds of megabytes.
    func sample(url: URL, budget: Int, deadline: Date = .distantFuture) -> Sample {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard var gatherer = Gatherer(header: header, available: max(0, size - header.pointOffset), budget: budget),
              let handle = try? FileHandle(forReadingFrom: url) else { return Sample(center: Gatherer.center(header)) }
        defer { try? handle.close() }
        // Whole multiples of the stride per block keep every block aligned to the sample.
        let perBlock = max(1, (16 << 20) / (header.recordLength * gatherer.stride)) * gatherer.stride
        do {
            try handle.seek(toOffset: UInt64(header.pointOffset))
            var remaining = gatherer.total
            while remaining > 0 {
                let records = min(perBlock, remaining)
                guard let block = try handle.read(upToCount: records * header.recordLength), block.count >= header.recordLength else { break }
                let more = block.withUnsafeBytes { gatherer.gather($0, deadline: deadline) }
                remaining -= block.count / header.recordLength
                if !more || block.count < records * header.recordLength { break }
            }
        } catch {}
        return gatherer.finish()
    }

    /// Collects every `stride`-th record into flat arrays, then orders them progressively.
    private struct Gatherer {
        let header: Header
        let total: Int
        let stride: Int
        let wanted: Int
        let center: SIMD3<Double>
        private let rgbOffset: Int?
        private var positions: [Float]
        private var colors: [UInt16]
        private var intensity: [UInt16]
        private var classes: [UInt8]
        private var taken = 0
        private var maxColor: UInt16 = 0

        static func center(_ h: Header) -> SIMD3<Double> {
            let c = SIMD3((h.minimum[0] + h.maximum[0]) / 2, (h.minimum[1] + h.maximum[1]) / 2, (h.minimum[2] + h.maximum[2]) / 2)
            return c.x.isFinite && c.y.isFinite && c.z.isFinite ? c : .zero
        }

        init?(header h: Header, available bytes: Int, budget: Int) {
            guard !h.isCompressed, h.recordLength > 0, h.pointOffset > 0, budget > 0 else { return nil }
            let available = bytes / h.recordLength
            total = min(h.pointCount > 0 ? h.pointCount : available, available)
            guard total > 0 else { return nil }
            header = h
            stride = max(1, Int((Double(total) / Double(budget)).rounded(.up)))
            wanted = (total + stride - 1) / stride
            center = Self.center(h)
            rgbOffset = h.rgbOffset.flatMap { $0 + 6 <= h.recordLength ? $0 : nil }
            positions = [Float](repeating: 0, count: wanted * 3)
            colors = [UInt16](repeating: 0, count: rgbOffset == nil ? 0 : wanted * 3)
            intensity = [UInt16](repeating: 0, count: wanted)
            classes = [UInt8](repeating: 0, count: wanted)
        }

        /// Gathers from a run of whole records that starts on a sampled one. False once full or out of time.
        mutating func gather(_ raw: UnsafeRawBufferPointer, deadline: Date) -> Bool {
            let h = header
            let scale = SIMD3(h.scale[0], h.scale[1], h.scale[2])
            let shift = SIMD3(h.offset[0], h.offset[1], h.offset[2]) - center
            let classOffset = h.isExtended ? 16 : 15
            let classMask: UInt8 = h.isExtended ? 0xFF : 0x1F
            let recordLength = h.recordLength, stride = self.stride, wanted = self.wanted, rgbOffset = self.rgbOffset
            var taken = self.taken, maxColor = self.maxColor
            var expired = false
            // Unsafe buffers keep the per-point loop free of copy-on-write and bounds checks.
            positions.withUnsafeMutableBufferPointer { pos in
                intensity.withUnsafeMutableBufferPointer { inten in
                    classes.withUnsafeMutableBufferPointer { cls in
                        colors.withUnsafeMutableBufferPointer { col in
                            var at = 0
                            while at + recordLength <= raw.count, taken < wanted {
                                if taken & 0xFFFF == 0, taken > 0, Date() > deadline { expired = true; break }
                                let x = Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: Int32.self)))
                                let y = Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: at + 4, as: Int32.self)))
                                let z = Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: at + 8, as: Int32.self)))
                                let point = SIMD3(x, y, z) * scale + shift
                                pos[taken * 3] = Float(point.x)
                                pos[taken * 3 + 1] = Float(point.y)
                                pos[taken * 3 + 2] = Float(point.z)
                                inten[taken] = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at + 12, as: UInt16.self))
                                cls[taken] = raw[at + classOffset] & classMask
                                if let rgbOffset {
                                    for channel in 0..<3 {
                                        let value = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at + rgbOffset + channel * 2, as: UInt16.self))
                                        col[taken * 3 + channel] = value
                                        maxColor = Swift.max(maxColor, value)
                                    }
                                }
                                taken += 1
                                at += stride * recordLength
                            }
                        }
                    }
                }
            }
            self.taken = taken
            self.maxColor = maxColor
            return !expired && taken < wanted
        }

        /// Bit-reversed order: every prefix of the output is spread evenly over the whole cloud.
        /// Many writers store 8-bit colour in the 16-bit fields.
        func finish() -> Sample {
            var result = Sample(center: center)
            let taken = self.taken
            let colorShift: UInt16 = maxColor > 255 ? 8 : 0
            let hasColor = !colors.isEmpty
            result.positions = [Float](repeating: 0, count: taken * 3)
            result.intensity = [UInt16](repeating: 0, count: taken)
            result.classes = [UInt8](repeating: 0, count: taken)
            result.colors = [UInt8](repeating: 0, count: hasColor ? taken * 3 : 0)
            positions.withUnsafeBufferPointer { pos in
            intensity.withUnsafeBufferPointer { inten in
            classes.withUnsafeBufferPointer { cls in
            colors.withUnsafeBufferPointer { col in
            result.positions.withUnsafeMutableBufferPointer { outPos in
            result.intensity.withUnsafeMutableBufferPointer { outInten in
            result.classes.withUnsafeMutableBufferPointer { outCls in
            result.colors.withUnsafeMutableBufferPointer { outCol in
                var j = 0
                LASFile.forEachProgressive(taken) { source in
                    outPos[j * 3] = pos[source * 3]
                    outPos[j * 3 + 1] = pos[source * 3 + 1]
                    outPos[j * 3 + 2] = pos[source * 3 + 2]
                    outInten[j] = inten[source]
                    outCls[j] = cls[source]
                    if hasColor {
                        for channel in 0..<3 { outCol[j * 3 + channel] = UInt8(truncatingIfNeeded: col[source * 3 + channel] >> colorShift) }
                    }
                    j += 1
                }
            }}}}}}}}
            return result
        }
    }

    private static let byteReversal: [UInt32] = (0..<256).map { value in
        var reversed: UInt32 = 0, v = UInt32(value)
        for _ in 0..<8 { reversed = (reversed << 1) | (v & 1); v >>= 1 }
        return reversed
    }

    /// Calls `body` with 0..<count in bit-reversed order.
    @inline(__always)
    static func forEachProgressive(_ count: Int, _ body: (Int) -> Void) {
        guard count > 0 else { return }
        var bits = 0
        while (1 << bits) < count { bits += 1 }
        byteReversal.withUnsafeBufferPointer { table in
            for value in 0..<(1 << bits) {
                let v = UInt32(truncatingIfNeeded: value)
                let reversed = table[Int(v & 0xFF)] << 24 | table[Int((v >> 8) & 0xFF)] << 16 | table[Int((v >> 16) & 0xFF)] << 8 | table[Int(v >> 24)]
                let source = bits == 0 ? 0 : Int(reversed >> UInt32(32 - bits))
                if source < count { body(source) }
            }
        }
    }

    /// 0..<count in bit-reversed order.
    static func progressiveOrder(_ count: Int) -> [Int] {
        var order: [Int] = []
        order.reserveCapacity(count)
        forEachProgressive(count) { order.append($0) }
        return order
    }
}

extension LASFile.Sample {
    /// The page's binary layout: "GPC1", count, flags, centre (3 × f64), then positions (f32),
    /// colours (u8 × 3), intensity (u16) and classes (u8), each block padded to 4 bytes.
    func encoded() -> Data {
        var data = Data()
        data.append(contentsOf: Array("GPC1".utf8))
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        func pad() { while data.count % 4 != 0 { data.append(0) } }
        let flags: UInt32 = (colors.isEmpty ? 0 : 1) | (intensity.isEmpty ? 0 : 2) | (classes.isEmpty ? 0 : 4)
        append(UInt32(count).littleEndian)
        append(flags.littleEndian)
        append(UInt32(0))
        append(center.x.bitPattern.littleEndian)
        append(center.y.bitPattern.littleEndian)
        append(center.z.bitPattern.littleEndian)
        positions.withUnsafeBytes { data.append(contentsOf: $0) }
        if !colors.isEmpty { data.append(contentsOf: colors); pad() }
        if !intensity.isEmpty { intensity.withUnsafeBytes { data.append(contentsOf: $0) }; pad() }
        if !classes.isEmpty { data.append(contentsOf: classes); pad() }
        return data
    }
}
