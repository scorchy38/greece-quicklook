import AppKit
import CryptoKit

/// A .torrent file's metadata: what it downloads, from where, and its identity.
struct Torrent {
    struct File: Equatable {
        var path: String
        var size: UInt64
        var isPadding = false
    }

    var name: String
    var files: [File]
    var filesTruncated = false
    var pieceLength: UInt64?
    var pieceCount: Int?
    var isPrivate: Bool
    var trackers: [[String]]
    var webSeeds: [String]
    var createdBy: String?
    var created: Date?
    var comment: String?
    var source: String?
    var version: Int
    var infoHashV1: String?
    var infoHashV2: String?
    var dhtNodes: Int

    var totalSize: UInt64 { files.filter { !$0.isPadding }.reduce(0) { $0.saturatingAdd($1.size) } }
    var realFiles: [File] { files.filter { !$0.isPadding } }

    static let maxSize = 64 << 20
    static let maxFiles = 100_000

    init(data: Data) throws {
        var infoRange: Range<Int>?
        let root = try Bencode.parse(data, infoRange: &infoRange)
        guard let info = root["info"], case .dictionary = info else { throw Bencode.Failure.malformed }

        name = Format.clean((info["name.utf-8"] ?? info["name"])?.string ?? "Untitled", limit: 300)
        isPrivate = info["private"]?.integer == 1
        source = info["source"]?.string.map { Format.clean($0, limit: 100) }
        pieceLength = info["piece length"]?.integer.flatMap { $0 > 0 ? UInt64($0) : nil }
        if let pieces = info["pieces"]?.data { pieceCount = pieces.count / 20 }
        version = Int(info["meta version"]?.integer ?? 1)

        var files: [File] = []
        var truncated = false
        if let list = info["files"]?.list {
            for entry in list {
                if files.count >= Self.maxFiles { truncated = true; break }
                let components = ((entry["path.utf-8"] ?? entry["path"])?.list ?? []).compactMap(\.string)
                let length = UInt64(max(0, entry["length"]?.integer ?? 0))
                let attributes = entry["attr"]?.string ?? ""
                let path = components.map { Format.clean($0, limit: 255) }.joined(separator: "/")
                files.append(File(path: path.isEmpty ? "Untitled" : path, size: length,
                                  isPadding: attributes.contains("p") || components.first?.hasPrefix(".pad") == true))
            }
        } else if let length = info["length"]?.integer {
            files.append(File(path: name, size: UInt64(max(0, length))))
        } else if let tree = info["file tree"] {
            Torrent.walk(tree, path: [], depth: 0, into: &files, truncated: &truncated)
        }
        self.files = files
        filesTruncated = truncated

        var tiers: [[String]] = []
        for tier in (root["announce-list"]?.list ?? []).prefix(100) {
            let urls = (tier.list ?? []).compactMap(\.string).map { Format.clean($0, limit: 300) }
            if !urls.isEmpty { tiers.append(Array(urls.prefix(100))) }
        }
        if let announce = root["announce"]?.string, !tiers.joined().contains(announce) { tiers.insert([Format.clean(announce, limit: 300)], at: 0) }
        trackers = tiers
        if let list = root["url-list"]?.list {
            webSeeds = list.compactMap(\.string).prefix(50).map { Format.clean($0, limit: 300) }
        } else {
            webSeeds = root["url-list"]?.string.map { [Format.clean($0, limit: 300)] } ?? []
        }
        createdBy = root["created by"]?.string.map { Format.clean($0, limit: 100) }
        created = root["creation date"]?.integer.flatMap { $0 > 0 && $0 < 8_000_000_000 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        comment = root["comment"]?.string.map { Format.clean($0, limit: 600) }
        dhtNodes = root["nodes"]?.list?.count ?? 0

        if let infoRange, infoRange.upperBound <= data.count {
            let bytes = data.subdata(in: (data.startIndex + infoRange.lowerBound)..<(data.startIndex + infoRange.upperBound))
            if info["pieces"] != nil || version == 1 { infoHashV1 = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
            if version >= 2 { infoHashV2 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        }
    }

    /// v2 file trees: nested dictionaries whose leaves are keyed by "".
    private static func walk(_ node: Bencode, path: [String], depth: Int, into files: inout [File], truncated: inout Bool) {
        guard depth < 48, case .dictionary(let entries) = node else { return }
        for entry in entries {
            if files.count >= maxFiles { truncated = true; return }
            let key = String(decoding: entry.key, as: UTF8.self)
            if key.isEmpty {
                let length = UInt64(max(0, entry.value["length"]?.integer ?? 0))
                files.append(File(path: path.joined(separator: "/"), size: length))
            } else {
                walk(entry.value, path: path + [Format.clean(key, limit: 255)], depth: depth + 1, into: &files, truncated: &truncated)
            }
        }
    }

    var magnetLink: String? {
        var items: [String] = []
        if let v1 = infoHashV1 { items.append("xt=urn:btih:" + v1) }
        if let v2 = infoHashV2 { items.append("xt=urn:btmh:1220" + v2) }
        guard !items.isEmpty else { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
        items.append("dn=" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
        for tracker in trackers.joined().prefix(3) {
            items.append("tr=" + (tracker.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
        }
        return "magnet:?" + items.joined(separator: "&")
    }
}

enum TorrentPage {
    static func page(for url: URL, modified: String?) throws -> InspectorPage {
        let data = try ProfilePage.readLimited(url, limit: Torrent.maxSize)
        let torrent = try Torrent(data: data)
        let files = torrent.realFiles
        let fileText = Format.count(files.count, "file")
        var page = InspectorPage(
            header: InspectorHeader(icon: .symbol("arrow.down.circle.fill", .teal), title: torrent.name,
                                    subtitle: Format.joined([Format.bytes(torrent.totalSize), fileText]),
                                    identifier: torrent.infoHashV1 ?? torrent.infoHashV2),
            summary: FileSummary(symbol: "arrow.down.circle", title: "Torrent",
                                 details: [fileText, Format.bytes(torrent.totalSize), Format.count(torrent.trackers.joined().count, "tracker")], trailing: modified))

        if torrent.isPrivate {
            page.badges.append(InspectorBadge("private", symbol: "lock.fill", title: "Private", tone: .neutral,
                                              help: "Peers come only from its trackers: no DHT or peer exchange."))
        }
        if torrent.version >= 2 {
            page.badges.append(InspectorBadge("version", symbol: "2.circle", title: torrent.infoHashV1 != nil ? "Hybrid v1 + v2" : "BitTorrent v2", tone: .accent))
        }
        if !torrent.webSeeds.isEmpty {
            page.badges.append(InspectorBadge("webseeds", symbol: "globe", title: "Web Seeds", tone: .neutral, help: "Can also download over HTTP."))
        }
        if torrent.trackers.isEmpty && torrent.dhtNodes == 0 {
            page.badges.append(InspectorBadge("trackerless", symbol: "point.3.connected.trianglepath.dotted", title: "Trackerless", tone: .neutral,
                                              help: "Finds peers through the DHT only."))
        }

        var overview: [InspectorItem] = [.field("Size", Format.bytes(torrent.totalSize)), .field("Files", files.count.formatted())]
        if let length = torrent.pieceLength, let count = torrent.pieceCount {
            overview.append(.field("Pieces", "\(count.formatted()) × \(Format.bytes(length))"))
        }
        if let createdBy = torrent.createdBy { overview.append(.field("Created By", createdBy)) }
        if let created = torrent.created { overview.append(.field("Created", Format.dateTime(created))) }
        if let source = torrent.source { overview.append(.field("Source", source)) }
        if let comment = torrent.comment { overview.append(InspectorItem(title: "Comment", subtitle: comment)) }
        page.sections.append(InspectorSection("torrent", title: "Torrent", rows: overview.map(InspectorRow.item)))

        var largest = files.sorted { $0.size > $1.size }
        if largest.count > 1 {
            largest = Array(largest.prefix(200))
            let rows = largest.map { file -> InspectorRow in
                let name = (file.path as NSString).lastPathComponent
                let folder = (file.path as NSString).deletingLastPathComponent
                return .item(InspectorItem(symbol: FileSymbol.symbol(for: name), title: name, subtitle: folder.nilIfEmpty, value: Format.bytes(file.size), help: file.path))
            }
            let footer = torrent.filesTruncated ? "Showing the first \(Torrent.maxFiles.formatted()) files." : nil
            page.sections.append(InspectorSection("files", title: "Largest Files", footer: footer, rows: rows, visibleLimit: 8))
        }

        if !torrent.trackers.isEmpty {
            var rows: [InspectorRow] = []
            for (tierIndex, tier) in torrent.trackers.enumerated() {
                for tracker in tier {
                    let parsed = URL(string: tracker)
                    let scheme = parsed?.scheme?.lowercased() ?? ""
                    let protocolName = scheme == "udp" ? "UDP" : scheme == "https" ? "HTTPS" : scheme == "http" ? "HTTP" : scheme == "wss" ? "WebSocket" : scheme.uppercased()
                    rows.append(.item(InspectorItem(symbol: scheme == "http" ? "lock.open" : "antenna.radiowaves.left.and.right",
                                                    title: parsed?.host ?? tracker, subtitle: torrent.trackers.count > 1 ? "Tier \(tierIndex + 1)" : nil,
                                                    value: protocolName.nilIfEmpty, help: tracker)))
                }
            }
            page.sections.append(InspectorSection("trackers", title: "Trackers", rows: rows, visibleLimit: 8))
        }
        if !torrent.webSeeds.isEmpty {
            page.sections.append(InspectorSection("webseeds", title: "Web Seeds",
                                                  rows: torrent.webSeeds.map { .item(InspectorItem(symbol: "globe", title: URL(string: $0)?.host ?? $0, help: $0)) },
                                                  visibleLimit: 5))
        }
        var identity: [InspectorItem] = []
        if let v1 = torrent.infoHashV1 { identity.append(.field("Info Hash", v1, mono: true, help: "SHA-1 of the info dictionary (BitTorrent v1).")) }
        if let v2 = torrent.infoHashV2 { identity.append(.field("Info Hash v2", v2, mono: true, help: "SHA-256 of the info dictionary (BitTorrent v2).")) }
        if let magnet = torrent.magnetLink { identity.append(InspectorItem(title: "Magnet Link", subtitle: magnet, help: "Select to copy.")) }
        if !identity.isEmpty { page.sections.append(InspectorSection("identity", title: "Identity", rows: identity.map(InspectorRow.item))) }

        if files.count > 1 {
            let entries = files.map { ArchiveEntry(path: torrent.name + "/" + $0.path, isDirectory: false, size: $0.size) }
            let listing = ArchiveListing(format: .zip, container: .zip, entries: entries, archiveSize: UInt64(data.count), truncated: torrent.filesTruncated)
            page.contents = .tree(FileNode.tree(from: listing, showHidden: true), title: "Files", count: files.count)
        }
        return page
    }
}

/// A plausible SF Symbol for a file name, for lists of files we can't hand to Finder.
enum FileSymbol {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mkv", "mp4", "mov", "avi", "m4v", "webm", "ts", "wmv": return "film"
        case "mp3", "flac", "wav", "aac", "m4a", "ogg", "opus", "alac": return "music.note"
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp": return "photo"
        case "srt", "ass", "vtt", "sub", "idx": return "captions.bubble"
        case "txt", "nfo", "md", "rtf": return "doc.text"
        case "pdf", "epub", "mobi", "azw3", "cbz", "cbr": return "book"
        case "zip", "rar", "7z", "gz", "tar", "xz", "bz2": return "doc.zipper"
        case "iso", "img", "dmg": return "opticaldiscdrive"
        case "exe", "msi", "app", "pkg", "deb", "rpm", "apk": return "app.dashed"
        default: return "doc"
        }
    }
}
