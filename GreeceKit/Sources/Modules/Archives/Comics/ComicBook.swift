import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A comic book archive (CBZ, CBR, CB7, CBT): its pages in reading order, its ComicInfo.xml, and
/// page images served on demand. ZIPs read any page directly; RAR, 7z and tar pages are extracted
/// once, in order, to the preview's scratch folder as the page asks for them.
final class ComicBook: @unchecked Sendable {
    struct Info: Encodable {
        var series: String?
        var number: String?
        var title: String?
        var year: String?
        var writer: String?
        var artist: String?
        var publisher: String?
        var summary: String?
        var rightToLeft = false
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "jxl"]
    static let pageLimit: UInt64 = 64 * 1024 * 1024
    static let maxPages = 5000

    let session: ArchiveSession
    let pages: [ArchiveEntry]
    let info: Info
    private let scratch: ArchiveScratch
    private let condition = NSCondition()
    private var extracted: [Int: URL] = [:]
    private var extracting = false
    private var finishedExtracting = false
    private let thumbnails = NSCache<NSString, NSData>()

    init?(session: ArchiveSession, listing: ArchiveListing, scratch: ArchiveScratch) {
        let images = listing.entries.filter { entry in
            guard !entry.isDirectory, !entry.isEncrypted, entry.size <= ComicBook.pageLimit else { return false }
            let path = entry.path
            guard !path.hasPrefix("__MACOSX/"), !(path as NSString).lastPathComponent.hasPrefix(".") else { return false }
            return ComicBook.imageExtensions.contains((path as NSString).pathExtension.lowercased())
        }
        guard !images.isEmpty else { return nil }
        self.session = session
        self.scratch = scratch
        pages = Array(images.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.prefix(ComicBook.maxPages))
        var info = Info()
        if let entry = listing.entries.first(where: { ($0.path as NSString).lastPathComponent.lowercased() == "comicinfo.xml" && $0.size < 1 << 20 }),
           let data = session.data(entry, limit: 1 << 20), let xml = PackageFormats.XMLDigest(data) {
            info.series = xml.text("comicinfo/series")
            info.number = xml.text("comicinfo/number")
            info.title = xml.text("comicinfo/title")
            info.year = xml.text("comicinfo/year")
            info.writer = xml.text("comicinfo/writer")
            info.artist = xml.text("comicinfo/penciller") ?? xml.text("comicinfo/artist")
            info.publisher = xml.text("comicinfo/publisher")
            info.summary = xml.text("comicinfo/summary")
            info.rightToLeft = xml.text("comicinfo/manga")?.lowercased() == "yesandrighttoleft"
        }
        self.info = info
    }

    // MARK: - Pages

    /// A page's original bytes.
    func page(_ index: Int) -> Data? {
        guard pages.indices.contains(index) else { return nil }
        if session.hasRandomAccess { return session.data(pages[index], limit: ComicBook.pageLimit) }
        startExtracting()
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(30)
        while extracted[index] == nil && !finishedExtracting {
            if !condition.wait(until: deadline) { break }
        }
        return extracted[index].flatMap { try? Data(contentsOf: $0) }
    }

    private func startExtracting() {
        condition.lock()
        guard !extracting else { condition.unlock(); return }
        extracting = true
        condition.unlock()
        let order = Dictionary(pages.enumerated().map { ($1.index, $0) }, uniquingKeysWith: { first, _ in first })
        let session = self.session, pages = self.pages, scratch = self.scratch
        // Weakly held: when the preview closes and the book goes, extraction stops at the next page.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var written: UInt64 = 0
            session.extractInOrder(pages, limit: ComicBook.pageLimit) { entry, data in
                guard let self else { return false }
                var url: URL?
                if let data, let page = order[entry.index], written < 2 * 1024 * 1024 * 1024 {
                    let destination = scratch.location(for: String(page) + "." + (entry.path as NSString).pathExtension)
                    if (try? data.write(to: destination)) != nil { url = destination; written += UInt64(data.count) }
                }
                self.condition.lock()
                if let url, let page = order[entry.index] { self.extracted[page] = url }
                self.condition.broadcast()
                self.condition.unlock()
                return true
            }
            guard let self else { return }
            condition.lock()
            finishedExtracting = true
            condition.broadcast()
            condition.unlock()
        }
    }

    /// A page scaled to fit `width` pixels, as JPEG, cached.
    func thumbnail(_ index: Int, width: Int) -> Data? {
        let key = "\(index)@\(width)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached as Data }
        guard let data = page(index), let image = ComicBook.downsample(data, maxPixels: width * 3 / 2) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        thumbnails.setObject(output, forKey: key)
        return output as Data
    }

    static func downsample(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, min(maxPixels, 4096)),
        ] as CFDictionary)
    }

    // MARK: - Serving the page

    /// `thumb/<page>?w=<pixels>` and `page/<page>` for the comic's web view.
    func resource(_ request: String) -> (data: Data, mimeType: String)? {
        let parts = request.split(separator: "?", maxSplits: 1)
        let path = parts.first.map(String.init) ?? ""
        let query = parts.count > 1 ? String(parts[1]) : ""
        let components = path.split(separator: "/")
        guard components.count == 2, let index = Int(components[1]), pages.indices.contains(index) else { return nil }
        switch components[0] {
        case "thumb":
            let width = query.split(separator: "&").compactMap { pair -> Int? in
                let kv = pair.split(separator: "=")
                return kv.count == 2 && kv[0] == "w" ? Int(kv[1]) : nil
            }.first ?? 320
            return thumbnail(index, width: min(max(width, 64), 1400)).map { ($0, "image/jpeg") }
        case "page":
            guard let data = page(index) else { return nil }
            let ext = (pages[index].path as NSString).pathExtension.lowercased()
            // Formats WebKit can't draw become JPEG; the rest go as they are.
            if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "jxl"].contains(ext) {
                return (data, UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream")
            }
            return thumbnail(index, width: 2400).map { ($0, "image/jpeg") }
        default:
            return nil
        }
    }

    // MARK: - Page data

    struct Page: Encodable { let name: String }

    struct Payload: Encodable {
        var title: String
        var subtitle: String?
        var eyebrow: String
        var facts: [String]
        var summary: String?
        var rightToLeft: Bool
        var pages: [Page]
    }

    func payload(fileName: String, format: String) -> Payload {
        let base = (fileName as NSString).deletingPathExtension
        var title = info.series ?? base
        if let number = info.number, info.series != nil { title += " #" + number }
        let subtitle = info.series != nil ? info.title : nil
        var facts: [String] = []
        facts.append("\(pages.count) \(pages.count == 1 ? "page" : "pages")")
        if let writer = info.writer { facts.append(writer) }
        if let artist = info.artist, artist != info.writer { facts.append(artist) }
        if let publisher = info.publisher { facts.append(publisher) }
        if let year = info.year { facts.append(year) }
        return Payload(title: title, subtitle: subtitle, eyebrow: "Comic Book · \(format)", facts: facts, summary: info.summary,
                       rightToLeft: info.rightToLeft, pages: pages.map { Page(name: ($0.path as NSString).lastPathComponent) })
    }
}
