import AppKit

/// An HTTP Archive: the requests a browser made, with their timings, headers and bodies.
struct HARCapture {
    struct Timings: Encodable {
        var blocked: Double?, dns: Double?, connect: Double?, ssl: Double?, send: Double?, wait: Double?, receive: Double?
    }
    struct Row: Encodable {
        var method: String
        var url: String
        var host: String
        var path: String
        var status: Int
        var statusText: String
        var mime: String
        var type: String
        var size: Int
        var time: Double
        var start: Double
        var timings: Timings
        var page: Int?
        var failed: Bool
    }
    struct Page: Encodable {
        var title: String
        var start: Double
        var contentLoad: Double?
        var load: Double?
    }
    struct Summary: Encodable {
        var creator: String
        var browser: String?
        var pages: [Page]
        var entries: [Row]
        var total: Int
        var bytes: Int
        var duration: Double
        var select: Int?
    }

    var summary: Summary
    /// The raw entries, for details on demand.
    let entries: [[String: Any]]

    static let readLimit = 96 * 1024 * 1024
    static let maxEntries = 20_000

    static func sniff(_ text: String) -> Bool {
        let head = text.prefix(4096).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        return head.contains("\"log\":{") && (head.contains("\"creator\"") || head.contains("\"entries\"") || head.contains("\"version\""))
    }

    static func load(_ url: URL) throws -> HARCapture {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= readLimit else {
            throw ArchiveError.unsupported(String(localized: "This capture is too large to preview.", bundle: .greeceKit, comment: "Error shown for a huge HTTP Archive (.har) file"))
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> HARCapture {
        guard let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let log = root["log"] as? [String: Any] else {
            throw ArchiveError.unsupported(String(localized: "Not an HTTP Archive.", bundle: .greeceKit, comment: "Error shown for a .har file that isn’t a network capture"))
        }
        let all = (log["entries"] as? [[String: Any]]) ?? []
        let raw = Array(all.prefix(maxEntries))
        let creator = log["creator"] as? [String: Any]
        let browser = log["browser"] as? [String: Any]
        let pagesRaw = (log["pages"] as? [[String: Any]]) ?? []
        let pageIDs = pagesRaw.compactMap { $0["id"] as? String }

        let dates = raw.compactMap { ($0["startedDateTime"] as? String).flatMap(parseDate) }
        let origin = (dates.min() ?? 0)
        var rows: [Row] = []
        var bytes = 0
        var end = 0.0
        for entry in raw {
            let request = entry["request"] as? [String: Any] ?? [:]
            let response = entry["response"] as? [String: Any] ?? [:]
            let content = response["content"] as? [String: Any] ?? [:]
            let urlString = String((request["url"] as? String ?? "").prefix(4096))
            let components = URLComponents(string: urlString)
            let host = components?.host ?? ""
            var path = components?.percentEncodedPath ?? urlString
            if let query = components?.percentEncodedQuery { path += "?" + query }
            if path.isEmpty { path = "/" }
            let mime = (content["mimeType"] as? String ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            let started = (entry["startedDateTime"] as? String).flatMap(parseDate) ?? origin
            let time = max(0, number(entry["time"]) ?? 0)
            let t = entry["timings"] as? [String: Any] ?? [:]
            func phase(_ key: String) -> Double? { number(t[key]).flatMap { $0 >= 0 ? $0 : nil } }
            let size = Int(max(number(response["_transferSize"]) ?? -1, number(response["bodySize"]) ?? -1, number(content["size"]) ?? -1, 0))
            let status = Int(number(response["status"]) ?? 0)
            let start = (started - origin) * 1000
            bytes += size
            end = max(end, start + time)
            let pageref = entry["pageref"] as? String
            rows.append(Row(method: String((request["method"] as? String ?? "GET").prefix(16)), url: urlString, host: host, path: String(path.prefix(2048)),
                            status: status, statusText: String((response["statusText"] as? String ?? "").prefix(80)), mime: String(mime.prefix(80)),
                            type: category(entry["_resourceType"] as? String, mime: mime, url: urlString), size: size, time: time, start: start,
                            timings: Timings(blocked: phase("blocked"), dns: phase("dns"), connect: phase("connect"), ssl: phase("ssl"),
                                             send: phase("send"), wait: phase("wait"), receive: phase("receive")),
                            page: pageref.flatMap { pageIDs.firstIndex(of: $0) },
                            failed: status == 0 || entry["_error"] != nil))
        }
        let pages = pagesRaw.prefix(200).map { page -> Page in
            let start = ((page["startedDateTime"] as? String).flatMap(parseDate) ?? origin) - origin
            let timings = page["pageTimings"] as? [String: Any] ?? [:]
            func timing(_ key: String) -> Double? { number(timings[key]).flatMap { $0 >= 0 ? start * 1000 + $0 : nil } }
            return Page(title: String((page["title"] as? String ?? "").prefix(300)), start: start * 1000, contentLoad: timing("onContentLoad"), load: timing("onLoad"))
        }
        for page in pages { end = max(end, page.load ?? 0, page.contentLoad ?? 0) }
        let creatorName = [creator?["name"] as? String, creator?["version"] as? String].compactMap { $0 }.joined(separator: " ")
        let browserName = [browser?["name"] as? String, browser?["version"] as? String].compactMap { $0 }.joined(separator: " ")
        let summary = Summary(creator: creatorName, browser: browserName.isEmpty ? nil : browserName, pages: pages, entries: rows,
                              total: all.count, bytes: bytes, duration: end)
        return HARCapture(summary: summary, entries: raw)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole = ISO8601DateFormatter()

    static func parseDate(_ text: String) -> Double? {
        if let date = fractional.date(from: text) { return date.timeIntervalSince1970 }
        return whole.date(from: text)?.timeIntervalSince1970 ?? DataValueParser.date(text)
    }

    /// The kind of request, as browsers group them.
    static func category(_ resourceType: String?, mime: String, url: String) -> String {
        if let resourceType, !resourceType.isEmpty {
            switch resourceType.lowercased() {
            case "document": return "document"
            case "script": return "script"
            case "stylesheet": return "stylesheet"
            case "image": return "image"
            case "font": return "font"
            case "xhr", "fetch": return "fetch"
            case "media": return "media"
            case "websocket": return "websocket"
            default: break
            }
        }
        if mime.contains("html") { return "document" }
        if mime.contains("javascript") || mime.contains("ecmascript") { return "script" }
        if mime == "text/css" { return "stylesheet" }
        if mime.hasPrefix("image/") { return "image" }
        if mime.hasPrefix("font/") || mime.contains("font") || url.hasSuffix(".woff2") || url.hasSuffix(".woff") { return "font" }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return "media" }
        if mime.contains("json") || mime.contains("xml") || mime.hasPrefix("text/plain") { return "fetch" }
        return "other"
    }

    // MARK: - Details on demand

    /// One entry's request and response, trimmed to sizes a page can show.
    func detail(_ index: Int) -> Data? {
        guard index >= 0, index < entries.count else { return nil }
        let entry = entries[index]
        func pairs(_ value: Any?) -> [[String: String]] {
            ((value as? [[String: Any]]) ?? []).prefix(500).map { item in
                ["name": String((item["name"] as? String ?? "").prefix(500)), "value": String(stringValue(item["value"]).prefix(8192))]
            }
        }
        func cut(_ text: String?, _ limit: Int) -> String? { text.map { String($0.prefix(limit)) } }
        let request = entry["request"] as? [String: Any] ?? [:]
        let response = entry["response"] as? [String: Any] ?? [:]
        let content = response["content"] as? [String: Any] ?? [:]
        let post = request["postData"] as? [String: Any]
        var result: [String: Any] = [
            "method": request["method"] as? String ?? "",
            "url": cut(request["url"] as? String, 8192) ?? "",
            "httpVersion": request["httpVersion"] as? String ?? "",
            "status": response["status"] ?? 0,
            "statusText": response["statusText"] as? String ?? "",
            "responseVersion": response["httpVersion"] as? String ?? "",
            "requestHeaders": pairs(request["headers"]),
            "responseHeaders": pairs(response["headers"]),
            "query": pairs(request["queryString"]),
            "requestCookies": pairs(request["cookies"]),
            "responseCookies": pairs(response["cookies"]),
            "server": entry["serverIPAddress"] as? String ?? "",
            "connection": stringValue(entry["connection"]),
            "redirect": response["redirectURL"] as? String ?? "",
            "timings": entry["timings"] ?? [:],
            "time": entry["time"] ?? 0,
            "mime": content["mimeType"] as? String ?? "",
            "size": content["size"] ?? 0,
            "encoding": content["encoding"] as? String ?? "",
        ]
        if let text = content["text"] as? String {
            result["body"] = cut(text, 3 * 1024 * 1024)
            result["bodyTruncated"] = text.utf8.count > 3 * 1024 * 1024
        }
        if let post {
            result["postMime"] = post["mimeType"] as? String ?? ""
            result["postText"] = cut(post["text"] as? String, 1024 * 1024) ?? ""
            result["postParams"] = pairs(post["params"])
        }
        if let error = entry["_error"] { result["error"] = stringValue(error) }
        return try? JSONSerialization.data(withJSONObject: result)
    }

    private func stringValue(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }
}

enum HARPage {
    static func prepare(_ file: FileInfo, modified: String?) throws -> PreparedPreview {
        var capture = try HARCapture.load(file.url)
        let summary = capture.summary
        let requests = summary.total
        var details = [String(localized: "\(requests) requests", bundle: .greeceKit, comment: "Info bar detail: network requests in an HTTP Archive"),
                       ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file),
                       duration(summary.duration)]
        if summary.pages.count > 1 {
            let pages = summary.pages.count
            details.insert(String(localized: "\(pages) pages", bundle: .greeceKit, comment: "Info bar detail: web pages loaded in an HTTP Archive"), at: 0)
        }
        if summary.total > summary.entries.count { details.append(DataModule.showingFirst(summary.entries.count)) }
        #if DEBUG
        if let state = ProcessInfo.processInfo.environment["GREECE_STATE"], state.hasPrefix("entry:") { capture.summary.select = Int(state.dropFirst(6)) }
        #endif
        let entries = capture
        var document = WebDocument(module: .init("har"), data: entries.summary, scripts: ["modules/data.js"], styles: ["modules/data.css"])
        document.resources = { path in
            guard path.hasPrefix("entry/"), let index = Int(path.dropFirst(6)), let data = entries.detail(index) else { return nil }
            return (data, "application/json")
        }
        let title = String(localized: "HTTP Archive", bundle: .greeceKit, comment: "Info bar title: a .har network capture")
        return .web(document, FileSummary(symbol: "network", title: title, details: details, trailing: modified), NSSize(width: 1100, height: 760))
    }

    /// "340 ms", "2.45 s".
    static func duration(_ ms: Double) -> String {
        if ms >= 1000 {
            let seconds = (ms / 1000).formatted(.number.precision(.fractionLength(2)))
            return String(localized: "\(seconds) s", bundle: .greeceKit, comment: "A duration in seconds, abbreviated, such as “2.45 s”")
        }
        let milliseconds = Int(ms.rounded())
        return String(localized: "\(milliseconds) ms", bundle: .greeceKit, comment: "A duration in milliseconds, abbreviated, such as “340 ms”")
    }
}
