import Foundation

/// Read access to a bundle's files, wherever the bundle lives: a folder on disk or inside an .ipa.
/// Paths are relative to the bundle root and use "/".
protocol BundleSource: AnyObject {
    /// The bundle's own file name ("Murmur.app").
    var name: String { get }
    /// The bundle on disk, when it is one (enables Security framework checks and Finder icons).
    var url: URL? { get }
    func data(_ path: String, limit: Int) -> Data?
    func exists(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    /// Immediate children's names.
    func children(_ path: String) -> [String]
    /// Random access to a (usually executable) file.
    func bytes(_ path: String) -> RandomAccessBytes?
    /// Every regular file with its size, within limits.
    func files(limit: Int, deadline: Date) -> (files: [(path: String, size: UInt64)], complete: Bool)
}

extension BundleSource {
    func plist(_ path: String, limit: Int = 4 << 20) -> [String: Any]? {
        guard let data = data(path, limit: limit) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }
}

final class DirectoryBundle: BundleSource {
    let root: URL
    var name: String { root.lastPathComponent }
    var url: URL? { root }

    init(url: URL) { root = url }

    private func resolve(_ path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    func data(_ path: String, limit: Int) -> Data? {
        let file = resolve(path)
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit else { return nil }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: resolve(path).path) }

    func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: resolve(path).path, isDirectory: &directory) && directory.boolValue
    }

    func children(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: resolve(path).path)) ?? []).sorted().prefix(2000).map { $0 }
    }

    func bytes(_ path: String) -> RandomAccessBytes? { try? FileBytes(url: resolve(path)) }

    func files(limit: Int, deadline: Date) -> (files: [(path: String, size: UInt64)], complete: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return ([], false)
        }
        var result: [(String, UInt64)] = []
        let prefix = root.standardizedFileURL.path.count + 1
        var complete = true
        while let item = enumerator.nextObject() as? URL {
            if result.count >= limit || (result.count % 256 == 0 && Date() > deadline) { complete = false; break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = String(item.standardizedFileURL.path.dropFirst(prefix))
            result.append((path, UInt64(values.fileSize ?? 0)))
        }
        return (result, complete)
    }
}

/// A bundle inside a ZIP (an .ipa's Payload/X.app/). Executables are streamed, not extracted.
final class ZipBundle: BundleSource {
    let zip: ZIPArchive
    let prefix: String
    let name: String
    var url: URL? { nil }
    private var directories: [String: Set<String>] = [:]

    init(zip: ZIPArchive, prefix: String) {
        self.zip = zip
        self.prefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        name = String(self.prefix.dropLast().split(separator: "/").last ?? "App.app")
        for member in zip.members where member.path.hasPrefix(self.prefix) {
            let relative = String(member.path.dropFirst(self.prefix.count))
            var parent = ""
            for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
                directories[parent, default: []].insert(String(component))
                parent = parent.isEmpty ? String(component) : parent + "/" + component
            }
        }
    }

    func data(_ path: String, limit: Int) -> Data? { zip.contents(of: prefix + path, limit: limit) }

    func exists(_ path: String) -> Bool {
        zip.member(prefix + path) != nil || directories[path] != nil
    }

    func isDirectory(_ path: String) -> Bool { directories[path] != nil }

    func children(_ path: String) -> [String] { (directories[path] ?? []).sorted() }

    func bytes(_ path: String) -> RandomAccessBytes? {
        guard let member = zip.member(prefix + path) else { return nil }
        return ZipBundle.capture(member, in: zip)
    }

    func files(limit: Int, deadline: Date) -> (files: [(path: String, size: UInt64)], complete: Bool) {
        var result: [(String, UInt64)] = []
        for member in zip.members where member.path.hasPrefix(prefix) && !member.isDirectory {
            if result.count >= limit { return (result, false) }
            result.append((String(member.path.dropFirst(prefix.count)), member.size))
        }
        return (result, true)
    }

    /// Streams a compressed Mach-O once, keeping only what the parser asks for: headers, load
    /// commands, the code signature and an embedded Info.plist. Bounded by size and time.
    static func capture(_ member: ZIPMember, in zip: ZIPArchive, budget: TimeInterval = 2.5) -> SparseBytes? {
        let sparse = SparseBytes(size: member.size)
        let deadline = Date().addingTimeInterval(budget)
        var wanted = MachOFile.neededRanges(sparse)
        var position: UInt64 = 0
        do {
            try zip.stream(member, maximum: min(member.size, 1 << 30), chunkSize: 1 << 20) { chunk in
                let start = position
                let end = start + UInt64(chunk.count)
                position = end
                var capturedSomething = false
                for range in wanted where range.lowerBound < end && range.upperBound > start {
                    let from = max(range.lowerBound, start), to = min(range.upperBound, end)
                    sparse.store(chunk.subdata(in: Int(from - start)..<Int(to - start)), at: from)
                    capturedSomething = true
                }
                if capturedSomething {
                    // Merge pieces of a range that spanned chunks, then ask what's still missing.
                    sparse.coalesce()
                    wanted = MachOFile.neededRanges(sparse)
                }
                let pendingAhead = wanted.contains { $0.upperBound > end }
                return pendingAhead && Date() < deadline
            }
        } catch {
            if sparse.pieces.isEmpty { return nil }
        }
        return sparse
    }
}

extension SparseBytes {
    /// Joins adjacent pieces so a read spanning two chunks succeeds.
    func coalesce() {
        let sorted = pieces.sorted { $0.start < $1.start }
        var merged: [(start: UInt64, data: Data)] = []
        for piece in sorted {
            if var last = merged.last, last.start + UInt64(last.data.count) >= piece.start {
                let overlap = Int(last.start + UInt64(last.data.count) - piece.start)
                if overlap < piece.data.count { last.data.append(piece.data.subdata(in: (piece.data.startIndex + overlap)..<piece.data.endIndex)) }
                merged[merged.count - 1] = last
            } else {
                merged.append(piece)
            }
        }
        replace(merged)
    }
}
