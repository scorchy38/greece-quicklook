import Foundation
import CArchive

/// Just enough decompression for media files: gzip (SVGZ) and zlib, always with a ceiling on
/// what comes out. ZIP containers (dotLottie, Procreate swatches) go through `ZIPArchive`.
enum MediaInflate {
    /// windowBits: 15 + 32 detects gzip or zlib headers; -15 is a raw deflate stream (ZIP).
    static func inflate(_ input: Data, windowBits: Int32, limit: Int) -> Data? {
        guard !input.isEmpty else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunk = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var finishedMembers = 0
        var failed = false
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(raw.count)
            while true {
                var produced = 0
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    let result = CArchive.inflate(&stream, Z_NO_FLUSH)
                    produced = chunk - Int(stream.avail_out)
                    output.append(out.baseAddress!, count: produced)
                    return result
                }
                if output.count > limit { failed = true; break }
                if status == Z_STREAM_END {
                    finishedMembers += 1
                    // Concatenated gzip members; anything else after the end is padding.
                    guard windowBits > 0, stream.avail_in > 0, inflateReset(&stream) == Z_OK else { break }
                    continue
                }
                if status != Z_OK {
                    // Junk after a complete member is tolerated; a broken first member is not.
                    if finishedMembers == 0 && status != Z_BUF_ERROR { failed = true }
                    break
                }
                if stream.avail_in == 0 && produced < chunk { break }
            }
            stream.next_in = nil
            stream.next_out = nil
        }
        guard !failed, !output.isEmpty else { return nil }
        return output
    }
}

extension ZIPArchive {
    /// A media container's ZIP (dotLottie, Procreate swatches): at most 4,096 members, and at least one.
    static func media(_ data: Data) -> ZIPArchive? {
        guard let zip = try? ZIPArchive(data: data, memberLimit: 4096), !zip.members.isEmpty else { return nil }
        return zip
    }
}
