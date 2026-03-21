import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Detects file category from extension, UTI, or content inspection.
struct FileTypeDetector {

    /// Determine the Greece file category for a given URL.
    static func detect(url: URL) -> GreeceConstants.FileCategory {
        // Check if it's a directory first
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            // Check for textbundle
            if GreeceConstants.textBundleExtensions.contains(url.pathExtension.lowercased()) {
                return .textBundle
            }
            return .folder
        }

        let ext = url.pathExtension.lowercased()

        // Markdown
        if GreeceConstants.markdownExtensions.contains(ext) {
            return .markdown
        }

        // TextBundle (packaged)
        if GreeceConstants.textBundleExtensions.contains(ext) {
            return .textBundle
        }

        // CSV / TSV
        if GreeceConstants.csvExtensions.contains(ext) {
            return .csv
        }

        // SQLite
        if GreeceConstants.sqliteExtensions.contains(ext) {
            return .sqlite
        }

        // Diff / Patch
        if GreeceConstants.diffExtensions.contains(ext) {
            return .diff
        }

        // Archives
        if GreeceConstants.archiveExtensions.contains(ext) {
            return .archive
        }

        // Compound archive extensions
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") {
            return .archive
        }

        // Source code — check if extension is in our known set
        if GreeceConstants.sourceCodeExtensions.contains(ext) {
            return .sourceCode
        }

        // Fallback: try to detect from content (shebang, etc.)
        if let category = detectFromContent(url: url) {
            return category
        }

        return .unknown
    }

    /// Inspect first bytes of a file for shebang or magic bytes.
    private static func detectFromContent(url: URL) -> GreeceConstants.FileCategory? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }

        let headerData = handle.readData(ofLength: 512)
        guard !headerData.isEmpty else { return nil }

        // Check for SQLite magic bytes
        if headerData.count >= 16 {
            let sqliteMagic = "SQLite format 3\0"
            if let headerString = String(data: headerData.prefix(16), encoding: .utf8),
               headerString == sqliteMagic {
                return .sqlite
            }
        }

        // Check for ZIP magic bytes (PK\x03\x04)
        if headerData.count >= 4 {
            let bytes = [UInt8](headerData.prefix(4))
            if bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03, bytes[3] == 0x04 {
                return .archive
            }
        }

        // Check for gzip magic bytes
        if headerData.count >= 2 {
            let bytes = [UInt8](headerData.prefix(2))
            if bytes[0] == 0x1F, bytes[1] == 0x8B {
                return .archive
            }
        }

        // Check for shebang (source code)
        if let headerString = String(data: headerData.prefix(256), encoding: .utf8) {
            if headerString.hasPrefix("#!") {
                return .sourceCode
            }
            // Check if content looks like text (source code fallback)
            if isLikelyText(headerString) {
                return .sourceCode
            }
        }

        return nil
    }

    /// Heuristic: check if a string looks like text content.
    private static func isLikelyText(_ string: String) -> Bool {
        let controlCharCount = string.unicodeScalars.filter {
            $0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13
        }.count
        return Double(controlCharCount) / Double(max(string.count, 1)) < 0.05
    }
}
