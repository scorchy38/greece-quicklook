import Foundation
import CZstd

/// Decodes a Zstandard stream (any number of frames) from another source, in process.
final class ZstdSource: ByteSource {
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// Frames needing more than a 128 MB window are refused rather than allocated.
    static let windowLogMax: Int32 = 27

    private let input: ByteSource
    private let stream: OpaquePointer
    private var inputBuffer = Data()
    private var inputPosition = 0
    private var inputEnded = false
    private var finished = false

    init(_ input: ByteSource) throws {
        guard let stream = ZSTD_createDStream() else {
            throw ArchiveError.unsupported(String(localized: "The Zstandard decoder couldn’t start.", bundle: .greeceKit))
        }
        self.input = input
        self.stream = stream
        _ = ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, ZstdSource.windowLogMax)
    }

    deinit { ZSTD_freeDStream(stream) }

    func read(upTo count: Int) throws -> Data {
        guard !finished, count > 0 else { return Data() }
        var output = Data(count: count)
        var produced = 0
        while produced < count {
            if inputPosition >= inputBuffer.count && !inputEnded {
                inputBuffer = try input.read(upTo: 128 * 1024)
                inputPosition = 0
                if inputBuffer.isEmpty { inputEnded = true }
            }
            let before = (produced, inputPosition)
            var failure = false
            output.withUnsafeMutableBytes { out in
                inputBuffer.withUnsafeBytes { source in
                    var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: inputPosition)
                    var outBuffer = ZSTD_outBuffer(dst: out.baseAddress, size: count, pos: produced)
                    let result = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                    if ZSTD_isError(result) != 0 { failure = true }
                    inputPosition = inBuffer.pos
                    produced = outBuffer.pos
                }
            }
            if failure {
                // Anything already decoded is still good; a later read reports the damage.
                if produced > 0 { inputEnded = true; break }
                throw ArchiveError.corrupt(String(localized: "Zstandard data error", bundle: .greeceKit,
                                                  comment: "Why an archive is damaged, shown inside “This archive appears to be damaged (…)”; Zstandard is a compression format"))
            }
            if (produced, inputPosition) == before && inputEnded {
                finished = true
                break
            }
        }
        output.count = produced
        return output
    }
}

/// Reads a file from the start, forwards.
final class FileSource: ByteSource {
    private let handle: FileHandle
    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    func read(upTo count: Int) throws -> Data { try handle.read(upToCount: count) ?? Data() }
}
