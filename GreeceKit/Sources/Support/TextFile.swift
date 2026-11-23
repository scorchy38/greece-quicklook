import Foundation

/// A text file decoded with care: BOMs, UTF-16, legacy encodings and a size cap.
public struct TextFile: Sendable {
    public let text: String
    public let encodingName: String
    public let byteCount: Int
    /// True when only the first `limit` bytes were decoded.
    public let truncated: Bool

    public static let defaultLimit = 8 * 1024 * 1024

    public init(url: URL, limit: Int = TextFile.defaultLimit) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = try handle.read(upToCount: limit) ?? Data()
        byteCount = max(size, data.count)
        truncated = size > limit

        if truncated {
            // Never cut a UTF-8 sequence or a line in half.
            if let newline = data.lastIndex(of: 0x0A), newline > data.count / 2 { data = data.prefix(upTo: newline + 1) }
        }

        let (decoded, name) = TextFile.decode(data)
        text = decoded
        encodingName = name
    }

    public init(text: String) {
        self.text = text
        encodingName = "UTF-8"
        byteCount = text.utf8.count
        truncated = false
    }

    static func decode(_ data: Data) -> (String, String) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), "UTF-8")
        }
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) {
            return (s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s, "UTF-16")
        }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) {
            return (s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s, "UTF-16")
        }
        if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8") }
        // A truncated multi-byte tail is still UTF-8.
        if data.count > 4, let s = String(data: data.dropLast(3), encoding: .utf8) { return (s, "UTF-8") }
        if let s = String(data: data, encoding: .windowsCP1252) { return (s, "Windows Latin 1") }
        if let s = String(data: data, encoding: .macOSRoman) { return (s, "Mac Roman") }
        return (String(decoding: data, as: UTF8.self), "UTF-8")
    }

    public var lineCount: Int {
        var count = 1
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        if text.hasSuffix("\n") { count -= 1 }
        return max(count, text.isEmpty ? 0 : 1)
    }
}
