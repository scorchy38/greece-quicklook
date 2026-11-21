import AppKit
import CArchive

/// Decodes PNGs, including Apple's "CgBI" variant that Xcode writes into iOS apps: raw deflate
/// without a zlib header, BGRA byte order and premultiplied alpha. Image I/O rejects those.
enum CgBIImage {
    static let maxDimension = 4096

    static func image(from data: Data) -> NSImage? {
        if isCgBI(data), let image = decodeCgBI(data) { return image }
        return NSImage(data: data)
    }

    static func isCgBI(_ data: Data) -> Bool {
        data.count > 16 && data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            && data.subdata(in: (data.startIndex + 12)..<(data.startIndex + 16)) == Data("CgBI".utf8)
    }

    static func decodeCgBI(_ png: Data) -> NSImage? {
        let reader = BinaryReader(png, bigEndian: true)
        var offset = 8
        var width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0
        var compressed = Data()
        var chunks = 0
        while offset + 8 <= reader.count, chunks < 10_000 {
            chunks += 1
            guard let length = reader.u32(at: offset).map(Int.init), let type = reader.bytes(at: offset + 4, count: 4),
                  reader.has(length, at: offset + 8) else { return nil }
            let body = offset + 8
            switch String(decoding: type, as: UTF8.self) {
            case "IHDR":
                width = Int(reader.u32(at: body) ?? 0)
                height = Int(reader.u32(at: body + 4) ?? 0)
                bitDepth = Int(reader.u8(at: body + 8) ?? 0)
                colorType = Int(reader.u8(at: body + 9) ?? 0)
                interlace = Int(reader.u8(at: body + 12) ?? 0)
            case "IDAT":
                guard compressed.count + length < 64 << 20, let bytes = reader.bytes(at: body, count: length) else { return nil }
                compressed.append(bytes)
            case "IEND":
                offset = reader.count
                continue
            default:
                break
            }
            offset = body + length + 4
        }
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension, bitDepth == 8, interlace == 0,
              colorType == 6 || colorType == 2 else { return nil }
        let channels = colorType == 6 ? 4 : 3
        let stride = width * channels
        let expected = height * (stride + 1)
        guard let raw = inflateRaw(compressed, expected: expected), raw.count >= expected else { return nil }

        // Undo the per-row filters, then expand to 32-bit BGRA premultiplied (what CgBI stores).
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var previous = [UInt8](repeating: 0, count: stride)
        var current = [UInt8](repeating: 0, count: stride)
        raw.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let source = buffer.bindMemory(to: UInt8.self)
            for row in 0..<height {
                let base = row * (stride + 1)
                let filter = source[base]
                for index in 0..<stride {
                    let x = source[base + 1 + index]
                    let a = index >= channels ? current[index - channels] : 0
                    let b = previous[index]
                    let c = index >= channels ? previous[index - channels] : 0
                    switch filter {
                    case 1: current[index] = x &+ a
                    case 2: current[index] = x &+ b
                    case 3: current[index] = x &+ UInt8((Int(a) + Int(b)) / 2)
                    case 4:
                        let p = Int(a) + Int(b) - Int(c)
                        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
                        current[index] = x &+ (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)
                    default: current[index] = x
                    }
                }
                for column in 0..<width {
                    let target = (row * width + column) * 4
                    let pixel = column * channels
                    pixels[target] = current[pixel]          // B
                    pixels[target + 1] = current[pixel + 1]  // G
                    pixels[target + 2] = current[pixel + 2]  // R
                    pixels[target + 3] = channels == 4 ? current[pixel + 3] : 255
                }
                swap(&previous, &current)
            }
        }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    private static func inflateRaw(_ data: Data, expected: Int) -> Data? {
        guard !data.isEmpty, expected > 0, expected < 80 << 20 else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: expected)
        let status: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(expected)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || status == Z_OK || status == Z_BUF_ERROR else { return nil }
        output.count = expected - Int(stream.avail_out)
        return output
    }
}
