import Foundation
import Compression

/// Pure Swift TAR parser supporting plain tar, gzipped (.tar.gz/.tgz), and bzip2 (.tar.bz2/.tbz2).
enum TARParser {

    // MARK: - Parse plain TAR

    static func parse(url: URL) throws -> [ArchiveEntry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return parseTarData(data)
    }

    // MARK: - Parse gzipped TAR

    static func parseGzipped(url: URL) throws -> [ArchiveEntry] {
        let compressedData = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let decompressed = decompress(compressedData, algorithm: COMPRESSION_ZLIB) else {
            throw NSError(domain: "GreeceQL", code: 20, userInfo: [NSLocalizedDescriptionKey: "Cannot decompress gzip data"])
        }
        return parseTarData(decompressed)
    }

    // MARK: - Parse bz2 TAR

    static func parseBz2(url: URL) throws -> [ArchiveEntry] {
        let compressedData = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let decompressed = decompress(compressedData, algorithm: COMPRESSION_LZMA) else {
            // Try with shell fallback
            throw NSError(domain: "GreeceQL", code: 21, userInfo: [NSLocalizedDescriptionKey: "Cannot decompress bz2 data"])
        }
        return parseTarData(decompressed)
    }

    // MARK: - TAR Data Parser

    private static func parseTarData(_ data: Data) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var offset = 0
        let blockSize = 512

        while offset + blockSize <= data.count && entries.count < GreeceConstants.maxArchiveEntries {
            let headerBlock = data.subdata(in: offset..<(offset + blockSize))

            // Check for empty block (two consecutive zero blocks = end of archive)
            if headerBlock.allSatisfy({ $0 == 0 }) {
                break
            }

            // Parse header
            let name = readString(from: headerBlock, offset: 0, length: 100)
            let sizeOctal = readString(from: headerBlock, offset: 124, length: 12)
            let mtimeOctal = readString(from: headerBlock, offset: 136, length: 12)
            let typeFlag = headerBlock.count > 156 ? headerBlock[156] : 0
            let prefix = readString(from: headerBlock, offset: 345, length: 155)

            // Full path
            let fullPath: String
            if !prefix.isEmpty {
                fullPath = prefix + "/" + name
            } else {
                fullPath = name
            }

            guard !fullPath.isEmpty else {
                offset += blockSize
                continue
            }

            // Size
            let size = parseOctal(sizeOctal)

            // Modification time
            let mtime = parseOctal(mtimeOctal)
            let modDate = mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil

            // Type
            let isDirectory = typeFlag == 0x35 /* '5' */ || fullPath.hasSuffix("/")

            entries.append(ArchiveEntry(
                path: fullPath,
                isDirectory: isDirectory,
                size: UInt64(size),
                compressedSize: UInt64(size), // TAR doesn't compress
                modificationDate: modDate
            ))

            // Advance past header + file data (rounded up to block boundary)
            let dataBlocks = (size + blockSize - 1) / blockSize
            offset += blockSize + dataBlocks * blockSize
        }

        return entries
    }

    // MARK: - Helpers

    private static func readString(from data: Data, offset: Int, length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        let slice = data.subdata(in: offset..<(offset + length))
        // Find null terminator
        let nullIndex = slice.firstIndex(of: 0) ?? slice.endIndex
        let trimmed = slice[slice.startIndex..<nullIndex]
        return String(data: trimmed, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func parseOctal(_ string: String) -> Int {
        let cleaned = string.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        return Int(cleaned, radix: 8) ?? 0
    }

    // MARK: - Decompression

    private static func decompress(_ data: Data, algorithm: compression_algorithm) -> Data? {
        // Skip gzip header if present
        var sourceData = data
        if data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B {
            // It's gzip, skip the header
            sourceData = skipGzipHeader(data) ?? data
        }

        let destinationBufferSize = data.count * 10 // Estimate 10x expansion
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = sourceData.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Int in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                destinationBufferSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                sourceData.count,
                nil,
                algorithm == COMPRESSION_ZLIB ? COMPRESSION_ZLIB : algorithm
            )
        }

        guard decompressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }

    private static func skipGzipHeader(_ data: Data) -> Data? {
        guard data.count >= 10 else { return nil }
        var offset = 10
        let flags = data[3]

        // FEXTRA
        if flags & 0x04 != 0 {
            guard offset + 2 <= data.count else { return nil }
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
        }

        // FNAME
        if flags & 0x08 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }

        // FCOMMENT
        if flags & 0x10 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }

        // FHCRC
        if flags & 0x02 != 0 { offset += 2 }

        guard offset < data.count else { return nil }
        return data.subdata(in: offset..<data.count)
    }
}
