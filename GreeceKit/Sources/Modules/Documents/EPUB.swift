import AppKit
import CArchive

/// Reads members of a ZIP file (stored or deflated) with hard size limits.
final class EPUBZipMembers {
    struct Member {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localHeader: Int
        var encrypted: Bool
    }

    let data: Data
    private(set) var members: [String: Member] = [:]
    private(set) var order: [String] = []
    static let memberLimit = 20_000

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 22 else { throw ArchiveError.corrupt("too small") }
        var eocd: Int?
        var index = data.count - 22
        let lowest = max(0, data.count - 65_557)
        while index >= lowest { if data.u32(index) == 0x06054B50 { eocd = index; break }; index -= 1 }
        guard let end = eocd else { throw ArchiveError.corrupt("no central directory") }
        var offset = Int(data.u32(end + 16))
        let size = Int(data.u32(end + 12))
        if offset >= data.count || data.u32(offset) != 0x02014B50, size <= end, data.u32(end - size) == 0x02014B50 { offset = end - size }
        while offset + 46 <= data.count, data.u32(offset) == 0x02014B50, members.count < Self.memberLimit {
            let flags = data.u16(offset + 8)
            let method = data.u16(offset + 10)
            let compressed = Int(data.u32(offset + 20))
            let uncompressed = Int(data.u32(offset + 24))
            let nameLength = Int(data.u16(offset + 28))
            let extraLength = Int(data.u16(offset + 30))
            let commentLength = Int(data.u16(offset + 32))
            let local = Int(data.u32(offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(decoding: data.subdata(in: nameStart..<(nameStart + nameLength)), as: UTF8.self)
            let member = Member(name: name, method: method, compressedSize: compressed, size: uncompressed, localHeader: local, encrypted: flags & 1 != 0)
            if members[name] == nil { order.append(name) }
            members[name] = member
            offset = nameStart + nameLength + extraLength + commentLength
        }
        guard !members.isEmpty else { throw ArchiveError.corrupt("empty") }
    }

    func member(_ name: String) -> Member? {
        if let m = members[name] { return m }
        // Some books get case or percent-encoding wrong.
        let lower = name.lowercased()
        return members.values.first { $0.name.lowercased() == lower }
    }

    /// A member's bytes, or nil if it's missing, encrypted, or bigger than `limit` when inflated.
    func read(_ name: String, limit: Int = 32 * 1024 * 1024) -> Data? {
        guard let m = member(name), !m.encrypted, m.size <= limit, m.compressedSize <= data.count else { return nil }
        let header = m.localHeader
        guard header + 30 <= data.count, data.u32(header) == 0x04034B50 else { return nil }
        let start = header + 30 + Int(data.u16(header + 26)) + Int(data.u16(header + 28))
        guard start >= 0, start + m.compressedSize <= data.count else { return nil }
        let compressed = data.subdata(in: start..<(start + m.compressedSize))
        switch m.method {
        case 0: return compressed.count <= limit ? compressed : nil
        case 8: return Self.inflate(compressed, expected: m.size, limit: limit)
        default: return nil
        }
    }

    static func inflate(_ input: Data, expected: Int, limit: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(1024, min(expected, limit)))
        var produced = 0
        var status: Int32 = Z_OK
        var source = input
        let result: Bool = source.withUnsafeMutableBytes { inPtr -> Bool in
            guard let base = inPtr.baseAddress else { return false }
            stream.next_in = base.assumingMemoryBound(to: Bytef.self)
            stream.avail_in = uInt(inPtr.count)
            while status == Z_OK {
                if produced == output.count {
                    guard output.count < limit else { return false }
                    output.count = min(limit, output.count * 2)
                }
                status = output.withUnsafeMutableBytes { outPtr -> Int32 in
                    stream.next_out = outPtr.baseAddress!.assumingMemoryBound(to: Bytef.self).advanced(by: produced)
                    stream.avail_out = uInt(outPtr.count - produced)
                    let before = stream.avail_out
                    let r = zlib_inflate_call(&stream)
                    produced += Int(before - stream.avail_out)
                    return r
                }
                if status == Z_BUF_ERROR && stream.avail_in == 0 { break }
            }
            return status == Z_STREAM_END || (status == Z_BUF_ERROR && produced > 0)
        }
        guard result else { return nil }
        output.count = produced
        return output
    }
}

@inline(__always) private func zlib_inflate_call(_ stream: inout z_stream) -> Int32 { inflate(&stream, Z_NO_FLUSH) }

/// An EPUB 2 or 3 book: metadata, cover, table of contents and chapters.
final class EPUBBook {
    struct Item { var id: String; var href: String; var mediaType: String; var properties: String }
    struct TOCEntry: Encodable { var title: String; var href: String; var chapter: Int?; var anchor: String?; var children: [TOCEntry] }
    struct Person: Encodable { var name: String; var role: String?; var fileAs: String? }

    let archive: EPUBZipMembers
    var opfPath = ""
    var title = ""
    var subtitle: String?
    var creators: [Person] = []
    var contributors: [Person] = []
    var publisher: String?
    var date: String?
    var modified: String?
    var identifiers: [(value: String, scheme: String?)] = []
    var language: String?
    var description: String?
    var subjects: [String] = []
    var rights: String?
    var series: String?
    var seriesIndex: String?
    var version = "3.0"
    var manifest: [String: Item] = [:]
    var spine: [(idref: String, linear: Bool)] = []
    var coverPath: String?
    var navPath: String?
    var ncxPath: String?
    var toc: [TOCEntry] = []
    var encrypted = false

    static let fileLimit = 512 * 1024 * 1024

    init(url: URL) throws {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > Self.fileLimit { throw PreviewError.unsupported }
        archive = try EPUBZipMembers(url: url)
        guard let container = archive.read("META-INF/container.xml", limit: 1 << 20).map({ String(decoding: $0, as: UTF8.self) }) else { throw PreviewError.unsupported }
        for token in Markup.tokens(container) {
            if case .start(let name, let attributes, _) = token, name == "rootfile",
               let path = attributes.first(where: { $0.0 == "full-path" })?.1 {
                let type = attributes.first(where: { $0.0 == "media-type" })?.1 ?? "application/oebps-package+xml"
                if type.contains("oebps") { opfPath = path; break }
            }
        }
        guard !opfPath.isEmpty, let opf = archive.read(opfPath, limit: 8 << 20).map({ TextFile.decode($0).0 }) else { throw PreviewError.unsupported }
        encrypted = archive.member("META-INF/encryption.xml") != nil && (archive.read("META-INF/encryption.xml", limit: 1 << 20).map { String(decoding: $0, as: UTF8.self).contains("EncryptedData") } ?? false)
        parsePackage(opf)
        findCover()
        parseTOC()
    }

    // MARK: - Package

    private func parsePackage(_ opf: String) {
        var current: (name: String, attributes: [(String, String)])?
        var text = ""
        var refines: [String: [(property: String, value: String)]] = [:]
        var idOf: [Int: String] = [:]   // creator index → id
        var contributorIds: [Int: String] = [:]
        var titles: [(id: String?, text: String)] = []
        var coverMeta: String?
        func attribute(_ attributes: [(String, String)], _ name: String) -> String? {
            attributes.first { $0.0 == name || $0.0.hasSuffix(":" + name) }?.1
        }
        for token in Markup.tokens(opf) {
            switch token {
            case .start(let raw, let attributes, let selfClosing):
                let name = raw.split(separator: ":").last.map(String.init) ?? raw
                switch name {
                case "package": version = attribute(attributes, "version") ?? version
                case "item":
                    if let id = attribute(attributes, "id"), let href = attribute(attributes, "href"), manifest.count < 20_000 {
                        manifest[id] = Item(id: id, href: resolve(href, relativeTo: opfPath), mediaType: attribute(attributes, "media-type") ?? "",
                                            properties: attribute(attributes, "properties") ?? "")
                    }
                case "itemref":
                    if let idref = attribute(attributes, "idref"), spine.count < 10_000 { spine.append((idref, attribute(attributes, "linear") != "no")) }
                case "spine":
                    if let toc = attribute(attributes, "toc") { ncxPath = toc }
                case "reference":
                    if attribute(attributes, "type")?.lowercased() == "cover", let href = attribute(attributes, "href"), coverPath == nil {
                        coverPath = "xhtml:" + resolve(href, relativeTo: opfPath)
                    }
                case "meta":
                    if let metaName = attribute(attributes, "name"), let content = attribute(attributes, "content") {
                        switch metaName {
                        case "cover": coverMeta = content
                        case "calibre:series": series = content
                        case "calibre:series_index": seriesIndex = content
                        default: break
                        }
                    }
                    if !selfClosing { current = (name, attributes); text = "" }
                default:
                    if !selfClosing { current = (name, attributes); text = "" }
                }
            case .text(let t):
                if current != nil { text += t }
            case .end(let raw):
                let name = raw.split(separator: ":").last.map(String.init) ?? raw
                guard let element = current, element.name == name else { continue }
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                let attributes = element.attributes
                let id = attribute(attributes, "id")
                switch name {
                case "title": if !value.isEmpty { titles.append((id, value)) }
                case "creator":
                    if !value.isEmpty, creators.count < 50 {
                        if let id { idOf[creators.count] = id }
                        creators.append(Person(name: value, role: attribute(attributes, "role"), fileAs: attribute(attributes, "file-as")))
                    }
                case "contributor":
                    if !value.isEmpty, contributors.count < 50 {
                        if let id { contributorIds[contributors.count] = id }
                        contributors.append(Person(name: value, role: attribute(attributes, "role"), fileAs: attribute(attributes, "file-as")))
                    }
                case "publisher": if publisher == nil, !value.isEmpty { publisher = value }
                case "date":
                    let event = attribute(attributes, "event")
                    if !value.isEmpty, date == nil || event == "publication" || event == "original-publication" { date = value }
                case "identifier": if !value.isEmpty, identifiers.count < 20 { identifiers.append((value, attribute(attributes, "scheme"))) }
                case "language": if language == nil, !value.isEmpty { language = value }
                case "description": if description == nil, !value.isEmpty { description = value }
                case "subject": if !value.isEmpty, subjects.count < 30 { subjects.append(value) }
                case "rights": if rights == nil, !value.isEmpty { rights = value }
                case "meta":
                    let property = attribute(attributes, "property")
                    if let target = attribute(attributes, "refines"), let property {
                        refines[String(target.drop { $0 == "#" }), default: []].append((property, value))
                    } else if property == "dcterms:modified" { modified = value }
                    else if property == "belongs-to-collection", series == nil {
                        series = value
                        if let id, let position = refines[id]?.first(where: { $0.property == "group-position" }) { seriesIndex = position.value }
                    }
                default: break
                }
                current = nil
            }
        }
        // EPUB 3 refinements: roles, file-as, title types, collection positions.
        for (index, id) in idOf {
            for r in refines[id] ?? [] {
                if r.property == "role" { creators[index].role = r.value }
                if r.property == "file-as" { creators[index].fileAs = r.value }
            }
        }
        for (index, id) in contributorIds {
            for r in refines[id] ?? [] where r.property == "role" { contributors[index].role = r.value }
        }
        if let main = titles.first(where: { t in t.id.flatMap { refines[$0]?.first(where: { $0.property == "title-type" })?.value } == "main" }) {
            title = main.text
        } else {
            title = titles.first?.text ?? ""
        }
        if let sub = titles.first(where: { t in t.id.flatMap { refines[$0]?.first(where: { $0.property == "title-type" })?.value } == "subtitle" }) {
            subtitle = sub.text
        } else if titles.count > 1, titles[1].text != title, titles[1].text.count < 200 {
            subtitle = titles[1].text
        }
        // Authors that aren't marked otherwise; illustrators and editors move to contributors.
        let moved = creators.filter { ($0.role ?? "aut") != "aut" }
        creators = creators.filter { ($0.role ?? "aut") == "aut" }
        contributors = moved + contributors
        if let coverMeta, let item = manifest[coverMeta] ?? manifest.values.first(where: { $0.href.hasSuffix(coverMeta) }), item.mediaType.hasPrefix("image/") {
            coverPath = item.href
        }
        if let ncx = ncxPath { ncxPath = manifest[ncx]?.href }
        if ncxPath == nil { ncxPath = manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }?.href }
        navPath = manifest.values.first { $0.properties.split(separator: " ").contains("nav") }?.href
    }

    private func findCover() {
        if let item = manifest.values.first(where: { $0.properties.split(separator: " ").contains("cover-image") }) { coverPath = item.href; return }
        if let path = coverPath, !path.hasPrefix("xhtml:") { return }
        // A cover page: its first image.
        let page = coverPath.map { String($0.dropFirst(6)) }
        coverPath = nil
        if let page, let image = firstImage(inPage: page) { coverPath = image; return }
        if let item = manifest.values.sorted(by: { $0.href < $1.href }).first(where: { $0.mediaType.hasPrefix("image/") && ($0.id.lowercased().contains("cover") || $0.href.lowercased().contains("cover")) }) {
            coverPath = item.href
            return
        }
        if let first = spine.first.flatMap({ manifest[$0.idref] }), let image = firstImage(inPage: first.href) { coverPath = image }
    }

    private func firstImage(inPage path: String) -> String? {
        guard let data = archive.read(path, limit: 4 << 20) else { return nil }
        for token in Markup.tokens(TextFile.decode(data).0, limit: 20_000) {
            if case .start(let name, let attributes, _) = token, name == "img" || name == "image" || name.hasSuffix(":image") {
                if let src = attributes.first(where: { $0.0 == "src" || $0.0 == "xlink:href" || $0.0 == "href" })?.1 {
                    return resolve(src, relativeTo: path)
                }
            }
        }
        return nil
    }

    // MARK: - Table of contents

    private func parseTOC() {
        if let nav = navPath, let data = archive.read(nav, limit: 8 << 20) {
            toc = parseNav(TextFile.decode(data).0, base: nav)
        }
        if toc.isEmpty, let ncx = ncxPath, let data = archive.read(ncx, limit: 8 << 20) {
            toc = parseNCX(TextFile.decode(data).0, base: ncx)
        }
        if toc.isEmpty {
            // No usable TOC: list the spine.
            toc = spine.enumerated().compactMap { index, ref in
                guard ref.linear, let item = manifest[ref.idref] else { return nil }
                return TOCEntry(title: (item.href as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " "), href: item.href, chapter: index, anchor: nil, children: [])
            }
        }
    }

    private func parseNav(_ source: String, base: String) -> [TOCEntry] {
        let tokens = Markup.tokens(source)
        // Find <nav epub:type="toc"> (or the first <nav>).
        var start = tokens.firstIndex { token in
            if case .start(let name, let attributes, _) = token, name == "nav" {
                return attributes.contains { ($0.0 == "epub:type" || $0.0 == "role") && $0.1.contains("toc") }
            }
            return false
        }
        if start == nil { start = tokens.firstIndex { if case .start("nav", _, _) = $0 { return true }; return false } }
        guard let first = start else { return [] }
        var stack: [[TOCEntry]] = [[]]
        var pending: [TOCEntry?] = []
        var label = ""
        var href: String?
        var inLabel = false
        var depth = 0
        var count = 0
        for token in tokens[first...] {
            switch token {
            case .start(let name, let attributes, _):
                if name == "nav" { depth += 1 }
                if name == "ol" || name == "ul" { stack.append([]) }
                if name == "li" { pending.append(nil); label = ""; href = nil }
                if name == "a" || name == "span" { inLabel = true; if name == "a" { href = attributes.first { $0.0 == "href" }?.1 } }
            case .text(let t):
                if inLabel { label += t }
            case .end(let name):
                if name == "a" || name == "span" {
                    inLabel = false
                    if !pending.isEmpty, pending[pending.count - 1] == nil, count < 2000 {
                        let target = href.map { resolve($0, relativeTo: base) } ?? ""
                        pending[pending.count - 1] = entry(title: label, target: target)
                        count += 1
                    }
                }
                if name == "ol" || name == "ul" {
                    let children = stack.popLast() ?? []
                    if !pending.isEmpty, var parent = pending[pending.count - 1] { parent.children = children; pending[pending.count - 1] = parent }
                    else if stack.count >= 1, stack.count > 0 { stack[stack.count - 1] += children }
                }
                if name == "li", let item = pending.popLast() {
                    if let item, !stack.isEmpty, stack.count < 12 { stack[stack.count - 1].append(item) }
                }
                if name == "nav" { depth -= 1; if depth <= 0 { return stack.first ?? [] } }
            }
        }
        return stack.first ?? []
    }

    private func parseNCX(_ source: String, base: String) -> [TOCEntry] {
        var stack: [TOCEntry] = []
        var roots: [TOCEntry] = []
        var inText = false
        var count = 0
        for token in Markup.tokens(source) {
            switch token {
            case .start(let name, let attributes, let selfClosing):
                if name == "navpoint", stack.count < 12 { stack.append(TOCEntry(title: "", href: "", chapter: nil, anchor: nil, children: [])) }
                if name == "text" { inText = true }
                if name == "content", let src = attributes.first(where: { $0.0 == "src" })?.1, !stack.isEmpty {
                    let resolved = entry(title: "", target: resolve(src, relativeTo: base))
                    stack[stack.count - 1].href = resolved.href
                    stack[stack.count - 1].chapter = resolved.chapter
                    stack[stack.count - 1].anchor = resolved.anchor
                }
                _ = selfClosing
            case .text(let t):
                if inText, !stack.isEmpty, stack[stack.count - 1].title.isEmpty { stack[stack.count - 1].title = t.trimmingCharacters(in: .whitespacesAndNewlines) }
            case .end(let name):
                if name == "text" { inText = false }
                if name == "navpoint", let done = stack.popLast(), count < 2000 {
                    count += 1
                    if stack.isEmpty { roots.append(done) } else { stack[stack.count - 1].children.append(done) }
                }
            }
        }
        return roots
    }

    private func entry(title: String, target: String) -> TOCEntry {
        let parts = target.split(separator: "#", maxSplits: 1).map(String.init)
        let path = parts.first ?? ""
        let chapter = spineIndex(of: path)
        let clean = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return TOCEntry(title: clean, href: target, chapter: chapter, anchor: parts.count > 1 ? parts[1] : nil, children: [])
    }

    func spineIndex(of path: String) -> Int? {
        spine.firstIndex { manifest[$0.idref]?.href == path }
    }

    // MARK: - Chapters

    func chapterPath(_ index: Int) -> String? {
        guard spine.indices.contains(index), let item = manifest[spine[index].idref] else { return nil }
        return item.href
    }

    /// The first spine item that reads like a chapter (not the cover, title page, contents or copyright).
    func firstChapter() -> Int {
        let skip = ["cover", "title", "toc", "contents", "copyright", "nav", "colophon", "imprint", "halftitle", "frontmatter", "dedication", "epigraph", "license", "pg-header"]
        var fallback: Int?
        for (index, ref) in spine.enumerated().prefix(60) where ref.linear {
            guard let item = manifest[ref.idref], item.mediaType.contains("html") || item.href.hasSuffix("html") || item.href.hasSuffix(".htm") else { continue }
            if fallback == nil { fallback = index }
            let name = (item.href as NSString).lastPathComponent.lowercased() + " " + item.id.lowercased()
            if item.properties.contains("nav") || skip.contains(where: { name.contains($0) }) { continue }
            guard let data = archive.read(item.href, limit: 16 << 20) else { continue }
            let text = Markup.text(TextFile.decode(data).0, limit: 60_000)
            if text.filter({ !$0.isWhitespace }).count >= 600 { return index }
        }
        return fallback ?? 0
    }

    /// A chapter as sanitised HTML, with images and links rewritten for the page.
    func chapterHTML(_ index: Int) -> (html: String, title: String?, words: Int)? {
        guard let path = chapterPath(index), let data = archive.read(path, limit: 16 << 20) else { return nil }
        let source = TextFile.decode(data).0
        var sanitizer = HTMLSanitizer()
        sanitizer.idPrefix = "c\(index)-"
        sanitizer.image = { [weak self] src in
            guard let self else { return nil }
            let resolved = self.resolve(src, relativeTo: path)
            guard self.archive.member(resolved) != nil, Self.isImage(resolved, mediaType: self.mediaType(of: resolved)) else { return nil }
            return "greece://module/item/" + Self.encode(resolved)
        }
        sanitizer.link = { [weak self] href in
            guard let self else { return nil }
            let trimmed = href.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") { return [("href", trimmed)] }
            if lower.contains(":") { return nil }
            if trimmed.hasPrefix("#") { return [("href", "#c\(index)-" + trimmed.dropFirst())] }
            let resolved = self.resolve(trimmed, relativeTo: path)
            let parts = resolved.split(separator: "#", maxSplits: 1).map(String.init)
            guard let chapter = self.spineIndex(of: parts[0]) else { return nil }
            if chapter == index { return [("href", parts.count > 1 ? "#c\(index)-\(parts[1])" : "#")] }
            var attributes = [("href", "#"), ("data-chapter", String(chapter))]
            if parts.count > 1 { attributes.append(("data-anchor", "c\(chapter)-\(parts[1])")) }
            return attributes
        }
        let html = sanitizer.sanitize(source)
        let text = Markup.text(source)
        var title: String?
        for token in Markup.tokens(source, limit: 4000) {
            if case .start(let name, _, _) = token, ["h1", "h2", "h3"].contains(name) { title = ""; continue }
            if title != nil {
                if case .text(let t) = token { title! += t }
                if case .end(let name) = token, ["h1", "h2", "h3"].contains(name) { break }
            }
        }
        let cleanTitle = title?.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return (html, cleanTitle?.isEmpty == false ? cleanTitle : nil, PreviewFactory.wordCount(text))
    }

    /// Words in the whole book (linear spine), within a time budget.
    func wordCount(budget: TimeInterval = 1.2) -> (words: Int, complete: Bool) {
        let deadline = Date().addingTimeInterval(budget)
        var words = 0
        var total = 0
        for ref in spine where ref.linear {
            guard Date() < deadline, total < 96 << 20 else { return (words, false) }
            guard let item = manifest[ref.idref], let data = archive.read(item.href, limit: 16 << 20) else { continue }
            total += data.count
            words += PreviewFactory.wordCount(Markup.text(TextFile.decode(data).0))
        }
        return (words, true)
    }

    // MARK: - Paths

    func mediaType(of path: String) -> String? { manifest.values.first { $0.href == path }?.mediaType }

    static func isImage(_ path: String, mediaType: String?) -> Bool {
        if let mediaType, mediaType.hasPrefix("image/") { return true }
        return ["jpg", "jpeg", "png", "gif", "svg", "webp"].contains((path as NSString).pathExtension.lowercased())
    }

    static func mime(for path: String, mediaType: String?) -> String {
        if let mediaType, mediaType.hasPrefix("image/") { return mediaType }
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    static func encode(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? path
    }

    /// Resolves an href against the file it appears in, inside the archive (no escaping the root).
    func resolve(_ href: String, relativeTo base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let parts = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var components = decoded.hasPrefix("/") ? [] : base.split(separator: "/").dropLast().map(String.init)
        for piece in parts[0].split(separator: "/") {
            if piece == "." || piece.isEmpty { continue }
            if piece == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(piece))
        }
        let path = components.joined(separator: "/")
        return parts.count > 1 ? path + "#" + parts[1] : path
    }

    // MARK: - Facts

    var isbn: String? {
        for (value, scheme) in identifiers {
            let lower = value.lowercased()
            var candidate: String?
            if lower.hasPrefix("urn:isbn:") { candidate = String(value.dropFirst(9)) }
            else if scheme?.lowercased() == "isbn" || lower.hasPrefix("isbn") { candidate = value.replacingOccurrences(of: "isbn:", with: "", options: .caseInsensitive) }
            else {
                let digits = value.filter { $0.isNumber || $0 == "X" || $0 == "x" }
                if (digits.count == 13 && (digits.hasPrefix("978") || digits.hasPrefix("979"))) || (digits.count == 10 && value.count <= 13) { candidate = value }
            }
            if let candidate {
                let digits = candidate.filter { $0.isNumber || $0 == "X" || $0 == "x" }
                if digits.count == 10 || digits.count == 13 { return candidate.trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    var otherIdentifier: String? {
        identifiers.first { !$0.value.lowercased().hasPrefix("urn:isbn") && $0.scheme?.lowercased() != "isbn" }?.value
    }
}

/// The EPUB preview: a book page with cover, metadata, contents and a readable chapter.
enum EPUBPreview {
    struct Payload: Encodable {
        var title: String
        var subtitle: String?
        var authors: [String]
        var contributors: [EPUBBook.Person]
        var publisher: String?
        var date: String?
        var language: String?
        var languageName: String?
        var isbn: String?
        var identifier: String?
        var description: String?
        var subjects: [String]
        var series: String?
        var seriesIndex: String?
        var rights: String?
        var cover: String?
        var toc: [EPUBBook.TOCEntry]
        var chapters: Int
        var chapter: Int
        var chapterHTML: String?
        var chapterTitle: String?
        var words: Int
        var encrypted: Bool
        var version: String
    }

    static func prepare(_ file: FileInfo) throws -> PreparedPreview {
        let book = try EPUBBook(url: file.url)
        let first = book.firstChapter()
        let chapter = book.encrypted ? nil : book.chapterHTML(first)
        let count = book.wordCount()
        let languageName = book.language.flatMap { Locale.current.localizedString(forIdentifier: $0) }
        let description = book.description.map { TeXText.tidy(Markup.text($0), paragraphs: true) }
        let payload = Payload(
            title: book.title.isEmpty ? file.url.deletingPathExtension().lastPathComponent : book.title,
            subtitle: book.subtitle,
            authors: book.creators.map(\.name),
            contributors: book.contributors,
            publisher: book.publisher,
            date: book.date,
            language: book.language,
            languageName: languageName,
            isbn: book.isbn,
            identifier: book.isbn == nil ? book.otherIdentifier : nil,
            description: description,
            subjects: book.subjects,
            series: book.series,
            seriesIndex: book.seriesIndex,
            rights: book.rights,
            cover: book.coverPath.map { "greece://module/item/" + EPUBBook.encode($0) },
            toc: book.toc,
            chapters: book.spine.count,
            chapter: first,
            chapterHTML: chapter?.html,
            chapterTitle: chapter?.title,
            words: count.words,
            encrypted: book.encrypted,
            version: book.version)
        var document = WebDocument(module: .init("epub"), data: payload, scripts: ["modules/documents.js"], styles: ["modules/documents.css"])
        document.resources = { path in
            if path.hasPrefix("item/") {
                let name = String(path.dropFirst(5)).removingPercentEncoding ?? String(path.dropFirst(5))
                let type = book.mediaType(of: name)
                guard EPUBBook.isImage(name, mediaType: type), let data = book.archive.read(name, limit: 24 << 20) else { return nil }
                return (data, EPUBBook.mime(for: name, mediaType: type))
            }
            if path.hasPrefix("chapter/"), !book.encrypted, let index = Int(path.dropFirst(8)), let chapter = book.chapterHTML(index) {
                struct Chapter: Encodable { var html: String; var title: String?; var index: Int }
                let json = (try? JSONEncoder().encode(Chapter(html: chapter.html, title: chapter.title, index: index))) ?? Data()
                return (json, "application/json")
            }
            return nil
        }
        var details: [String] = []
        if let author = book.creators.first?.name { details.append(book.creators.count > 1 ? "\(author) and others" : author) }
        let chapters = book.spine.filter(\.linear).count
        details.append(DocumentsModule.count(chapters, "section"))
        details += DocumentsModule.readingFacts(words: count.words)
        if book.encrypted { details.append("Protected") }
        return .web(document, FileSummary(symbol: "book.closed", title: "EPUB", details: details, trailing: file.modifiedText), NSSize(width: 1000, height: 800))
    }
}
