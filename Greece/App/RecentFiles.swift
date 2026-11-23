import AppKit

/// Files worth a quick look: ones you previewed recently, and ones your coding agents just edited.
/// Agent edits come straight from Claude Code's and Codex's own session logs, so there's nothing
/// to set up and edits from before Greece was installed show up too.
@MainActor
final class RecentFiles: ObservableObject {

    enum Source: String, CaseIterable {
        case previewed, claude, codex

        var title: String {
            switch self {
            case .previewed: return String(localized: "Recently Previewed", comment: "Menu bar: files previewed in Quick Look")
            case .claude: return String(localized: "Edited by Claude Code", comment: "Menu bar: files the Claude Code agent changed")
            case .codex: return String(localized: "Edited by Codex", comment: "Menu bar: files the Codex agent changed")
            }
        }

        var symbol: String {
            switch self {
            case .previewed: return "eye"
            case .claude: return "sparkle"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    struct Item: Identifiable, Hashable {
        var id: String { source.rawValue + url.path }
        let url: URL
        let date: Date
        let source: Source
        /// The project (agent's working folder) or the containing folder.
        let context: String
    }

    @Published private(set) var items: [Source: [Item]] = [:]
    @Published private(set) var loading = false

    nonisolated private static let window: TimeInterval = 14 * 86_400
    nonisolated private static let perSource = 25
    /// Parsed edits per session log, keyed by path, reused while the log is unchanged.
    private var cache: [String: (modified: Date, edits: [Edit])] = [:]

    struct Edit: Sendable { let path: String; let date: Date; let project: String }

    func refresh() {
        // Previews are one small plist: show them at once, then fill in agent edits.
        items[.previewed] = Self.previewedFiles()
        guard !loading else { return }
        loading = true
        let previous = cache
        Task.detached(priority: .utility) {
            var cache = previous
            let claude = Self.scan(Self.logs(in: NSHomeDirectory() + "/.claude/projects", depth: 2), cache: &cache, parse: Self.claudeEdits)
            let codex = Self.scan(Self.logs(in: NSHomeDirectory() + "/.codex/sessions", depth: 4), cache: &cache, parse: Self.codexEdits)
            let found = (Self.items(from: claude, source: .claude), Self.items(from: codex, source: .codex))
            let updated = cache
            await MainActor.run {
                self.cache = updated
                self.items[.claude] = found.0
                self.items[.codex] = found.1
                self.loading = false
            }
        }
    }

    // MARK: - Previewed in Quick Look

    /// Each preview family keeps its own list (extensions can't share storage); merge them.
    nonisolated private static func previewedFiles() -> [Item] {
        let containers = NSHomeDirectory() + "/Library/Containers"
        let families = ((try? FileManager.default.contentsOfDirectory(atPath: containers)) ?? []).filter { $0.hasPrefix("com.scorchy.greece.quicklook") }
        let recents = families.flatMap { id -> [[String: Any]] in
            let plist = NSDictionary(contentsOfFile: "\(containers)/\(id)/Data/Library/Preferences/\(id).plist")
            return plist?["recent-files.v1"] as? [[String: Any]] ?? []
        }.sorted { ($0["date"] as? Double ?? 0) > ($1["date"] as? Double ?? 0) }
        return recents.compactMap { entry -> Item? in
            guard let path = entry["path"] as? String, let time = entry["date"] as? Double,
                  !["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"].contains(where: { path.hasPrefix($0) }),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            return Item(url: url, date: Date(timeIntervalSince1970: time), source: .previewed,
                        context: url.deletingLastPathComponent().lastPathComponent)
        }.prefix(perSource).map { $0 }
    }

    // MARK: - Agent session logs

    /// Session logs changed in the last two weeks, newest first.
    nonisolated private static func logs(in root: String, depth: Int) -> [(path: String, modified: Date)] {
        let cutoff = Date().addingTimeInterval(-window)
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var found: [(String, Date)] = []
        for case let url as URL in enumerator {
            if enumerator.level > depth { enumerator.skipDescendants(); continue }
            guard url.pathExtension == "jsonl",
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified > cutoff else { continue }
            found.append((url.path, modified))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(40).map { ($0.0, $0.1) }
    }

    nonisolated private static func scan(_ logs: [(path: String, modified: Date)], cache: inout [String: (modified: Date, edits: [Edit])],
                                         parse: (Data) -> [Edit]) -> [Edit] {
        var edits: [Edit] = []
        for log in logs {
            if let cached = cache[log.path], cached.modified == log.modified {
                edits += cached.edits
                continue
            }
            // Session logs grow to hundreds of megabytes; recent edits are at the end, so read only that.
            guard let data = tail(of: log.path, bytes: 16 * 1024 * 1024) else { continue }
            let parsed = parse(data)
            cache[log.path] = (log.modified, parsed)
            edits += parsed
        }
        return edits
    }

    /// The last `bytes` of a file, starting at a line boundary.
    nonisolated private static func tail(of path: String, bytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        return data
    }

    nonisolated private static func items(from edits: [Edit], source: Source) -> [Item] {
        var latest: [String: Edit] = [:]
        for edit in edits where (latest[edit.path]?.date ?? .distantPast) < edit.date { latest[edit.path] = edit }
        return latest.values
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.date > $1.date }
            .prefix(perSource)
            .map { Item(url: URL(fileURLWithPath: $0.path), date: $0.date, source: source, context: $0.project) }
    }

    nonisolated private static let timestamp = try! NSRegularExpression(pattern: #""timestamp":"([^"]+)""#)
    nonisolated private static let cwd = try! NSRegularExpression(pattern: #""cwd":"((?:[^"\\]|\\.)*)""#)
    nonisolated private static let codexEdit = try! NSRegularExpression(pattern: #"\*\*\* (?:Update|Add) File: (.+?)\\n"#)

    /// The lines of a log that contain any of `markers`, found by byte search (logs are huge, edits rare).
    nonisolated private static func lines(in data: Data, containing markers: [String]) -> [String] {
        var starts = Set<Int>()
        var result: [String] = []
        for marker in markers.map({ Data($0.utf8) }) {
            var searchFrom = data.startIndex
            while let hit = data.range(of: marker, in: searchFrom..<data.endIndex) {
                let lineStart = data[data.startIndex..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
                let lineEnd = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
                if starts.insert(lineStart).inserted { result.append(String(decoding: data[lineStart..<lineEnd], as: UTF8.self)) }
                searchFrom = lineEnd
            }
        }
        return result
    }

    nonisolated private static let claudeMarkers = ["Edit", "Write", "MultiEdit"].map { #""name":"\#($0)","input":{"file_path":""# }
        + [#""name":"NotebookEdit","input":{"notebook_path":""#]

    nonisolated static func claudeEdits(_ data: Data) -> [Edit] {
        var edits: [Edit] = []
        for line in lines(in: data, containing: claudeMarkers) {
            let date = first(timestamp, in: line).flatMap(parseDate) ?? .distantPast
            let project = first(cwd, in: line).map { (unescape($0) as NSString).lastPathComponent } ?? ""
            for marker in claudeMarkers {
                var rest = line[...]
                while let range = rest.range(of: marker) {
                    let tail = rest[range.upperBound...]
                    var path = "", escaped = false
                    for character in tail {
                        if escaped { path.append("\\"); path.append(character); escaped = false; continue }
                        if character == "\\" { escaped = true; continue }
                        if character == "\"" { break }
                        path.append(character)
                    }
                    let resolved = unescape(path)
                    if resolved.hasPrefix("/") { edits.append(Edit(path: resolved, date: date, project: project)) }
                    rest = tail
                }
            }
        }
        return edits
    }

    nonisolated static func codexEdits(_ data: Data) -> [Edit] {
        var edits: [Edit] = []
        // The session's working folder, for patches with relative paths.
        let meta = lines(in: data.prefix(256 * 1024), containing: [#""session_meta""#]).first
        let folder = meta.flatMap { first(cwd, in: $0) }.map(unescape) ?? ""
        for line in lines(in: data, containing: ["*** Update File: ", "*** Add File: "]) {
            let date = first(timestamp, in: line).flatMap(parseDate) ?? .distantPast
            for match in codexEdit.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let raw = Range(match.range(at: 1), in: line).map({ unescape(String(line[$0])) }) else { continue }
                let path = raw.hasPrefix("/") ? raw : (folder as NSString).appendingPathComponent(raw)
                edits.append(Edit(path: (path as NSString).standardizingPath, date: date, project: (folder as NSString).lastPathComponent))
            }
        }
        return edits
    }

    nonisolated private static func first(_ expression: NSRegularExpression, in line: String) -> String? {
        guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    /// JSON string escapes in a path ("\/", "\"", "é").
    nonisolated private static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        let json = "\"" + value + "\""
        return (try? JSONDecoder().decode(String.self, from: Data(json.utf8))) ?? value
    }

    nonisolated private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
