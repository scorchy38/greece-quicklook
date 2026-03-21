import Foundation

/// Pure Swift ZIP central directory parser.
/// Reads the End of Central Directory (EOCD) record to locate and parse the central directory entries.
enum ZIPParser {

    static func parse(url: URL) throws -> [ArchiveEntry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else {
            throw NSError(domain: "GreeceQL", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid ZIP file"])
        }

        // Find End of Central Directory signature (0x06054b50)
        guard let eocdOffset = findEOCD(data) else {
            throw NSError(domain: "GreeceQL", code: 11, userInfo: [NSLocalizedDescriptionKey: "Cannot find ZIP end of central directory"])
        }

        // Parse EOCD
        let totalEntries = data.readUInt16(at: eocdOffset + 10)
        let centralDirOffset = data.readUInt32(at: eocdOffset + 16)

        guard centralDirOffset < data.count else {
            throw NSError(domain: "GreeceQL", code: 12, userInfo: [NSLocalizedDescriptionKey: "Invalid central directory offset"])
        }

        var entries: [ArchiveEntry] = []
        var offset = Int(centralDirOffset)
        let maxEntries = min(Int(totalEntries), GreeceConstants.maxArchiveEntries)

        for _ in 0..<maxEntries {
            guard offset + 46 <= data.count else { break }

            // Verify central directory header signature (0x02014b50)
            let signature = data.readUInt32(at: offset)
            guard signature == 0x02014b50 else { break }

            let compressionMethod = data.readUInt16(at: offset + 10)
            let dosTime = data.readUInt16(at: offset + 12)
            let dosDate = data.readUInt16(at: offset + 14)
            let compressedSize = UInt64(data.readUInt32(at: offset + 20))
            let uncompressedSize = UInt64(data.readUInt32(at: offset + 24))
            let nameLength = Int(data.readUInt16(at: offset + 28))
            let extraLength = Int(data.readUInt16(at: offset + 30))
            let commentLength = Int(data.readUInt16(at: offset + 32))

            guard offset + 46 + nameLength <= data.count else { break }

            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let path = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .ascii) ?? "?"

            let isDirectory = path.hasSuffix("/")
            let modDate = dosDateTimeToDate(date: dosDate, time: dosTime)

            entries.append(ArchiveEntry(
                path: path,
                isDirectory: isDirectory,
                size: uncompressedSize,
                compressedSize: compressedSize,
                modificationDate: modDate
            ))

            offset += 46 + nameLength + extraLength + commentLength
        }

        return entries
    }

    // MARK: - Find EOCD

    private static func findEOCD(_ data: Data) -> Int? {
        // Search backwards from end for EOCD signature 0x06054b50
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let maxSearch = min(data.count, 65536 + 22)

        for i in stride(from: data.count - 22, through: max(0, data.count - maxSearch), by: -1) {
            if data[i] == signature[0] &&
               data[i + 1] == signature[1] &&
               data[i + 2] == signature[2] &&
               data[i + 3] == signature[3] {
                return i
            }
        }
        return nil
    }

    // MARK: - DOS Date/Time

    private static func dosDateTimeToDate(date: UInt16, time: UInt16) -> Date? {
        var components = DateComponents()
        components.year = Int((date >> 9) & 0x7F) + 1980
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int((time >> 11) & 0x1F)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int((time & 0x1F) * 2)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

// MARK: - Data Helpers

extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return self.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return self.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
}
