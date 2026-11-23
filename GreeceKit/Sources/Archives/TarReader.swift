import Foundation

/// Tar header checks used for detection. Listing and extraction go through libarchive.
enum TarReader {

    /// A 512-byte block whose checksum matches: the start of a tar archive (any dialect).
    static func isValidHeader(_ block: ArraySlice<UInt8>) -> Bool {
        guard block.count >= 512 else { return false }
        let base = block.startIndex
        if block[base..<(base + 512)].allSatisfy({ $0 == 0 }) { return false }
        let stored = parseNumber(block[(base + 148)..<(base + 156)])
        var unsigned = 0
        for offset in 0..<512 {
            unsigned += (offset >= 148 && offset < 156) ? 32 : Int(block[base + offset])
        }
        return stored == UInt64(unsigned)
    }

    static func isValidHeader(_ block: Data) -> Bool { isValidHeader([UInt8](block)[...]) }

    static func parseNumber(_ field: ArraySlice<UInt8>) -> UInt64 {
        guard let first = field.first else { return 0 }
        if first & 0x80 != 0 {
            // GNU base-256 for values that do not fit in octal.
            var value: UInt64 = UInt64(first & 0x7F)
            for byte in field.dropFirst() {
                guard value >> 56 == 0 else { return .max }
                value = (value << 8) | UInt64(byte)
            }
            return value
        }
        var value: UInt64 = 0
        for byte in field {
            if byte == 0 || byte == 0x20 { if value > 0 { break } else { continue } }
            guard byte >= 0x30 && byte <= 0x37, value >> 60 == 0 else { break }
            value = value * 8 + UInt64(byte - 0x30)
        }
        return value
    }
}
