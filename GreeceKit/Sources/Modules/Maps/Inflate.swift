import Foundation
import CArchive

/// zlib inflate with a hard output cap, so a zip bomb or a hostile tile can't exhaust memory.
enum Inflate {
    enum Mode { case raw, gzipOrZlib }

    static func decompress(_ input: Data, mode: Mode, limit: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        var stream = z_stream()
        let bits: Int32 = mode == .raw ? -15 : 15 + 32
        guard inflateInit2_(&stream, bits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        let ok: Bool = input.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return false }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 {
                    guard output.count + produced <= limit else { return false }
                    output.append(contentsOf: buffer[0..<produced])
                }
                if status == Z_STREAM_END { return true }
                if status != Z_OK { return status == Z_BUF_ERROR && stream.avail_in == 0 && !output.isEmpty }
                if stream.avail_in == 0 && produced == 0 { return !output.isEmpty }
            }
        }
        return ok ? output : nil
    }

    static func isGzip(_ data: Data) -> Bool { data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B }
    static func isZlib(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let a = data[data.startIndex], b = data[data.startIndex + 1]
        return a & 0x0F == 8 && (UInt16(a) << 8 | UInt16(b)) % 31 == 0
    }
}
