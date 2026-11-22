import AppKit
import QuickLookThumbnailing

/// Finder's own thumbnails for files in a folder, asked of Quick Look a few at a time (the ones on
/// screen), cancelled when they scroll away, and cached by file, modification date and size.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    struct Ticket: Hashable {
        fileprivate let key: String
        fileprivate let id: Int
    }

    private final class Job {
        let request: QLThumbnailGenerator.Request
        var waiters: [Int: (NSImage?, Bool) -> Void] = [:]
        var best = -1
        init(request: QLThumbnailGenerator.Request) { self.request = request }
    }

    private let cache = NSCache<NSString, NSImage>()
    /// Files with no thumbnail (no generator for their kind): not asked again while they're unchanged.
    private var failures = Set<String>()
    private var jobs: [String: Job] = [:]
    private var nextID = 0
    private let generator: QLThumbnailGenerator

    init(generator: QLThumbnailGenerator = .shared) {
        self.generator = generator
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    static func key(_ url: URL, modified: Date?, pixels: Int) -> String {
        "\(pixels)|\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(url.path)"
    }

    /// A thumbnail already made for this file as it is now, at this size.
    func cached(_ url: URL, modified: Date?, side: CGFloat, scale: CGFloat) -> NSImage? {
        cache.object(forKey: Self.key(url, modified: modified, pixels: Int(side * scale)) as NSString)
    }

    /// True when Quick Look has said it has no thumbnail for this file.
    func hasNone(_ url: URL, modified: Date?, side: CGFloat, scale: CGFloat) -> Bool {
        failures.contains(Self.key(url, modified: modified, pixels: Int(side * scale)))
    }

    /// Asks for a thumbnail. `update` runs on the main thread with each better image (a quick
    /// low-quality one may come first) and `final` set on the last call. Nil when there's nothing
    /// to wait for: the file is known to have no thumbnail.
    func load(_ url: URL, modified: Date?, side: CGFloat, scale: CGFloat,
              update: @escaping (NSImage?, _ final: Bool) -> Void) -> Ticket? {
        let key = Self.key(url, modified: modified, pixels: Int(side * scale))
        if let image = cache.object(forKey: key as NSString) {
            update(image, true)
            return nil
        }
        guard !failures.contains(key) else { return nil }
        nextID += 1
        let ticket = Ticket(key: key, id: nextID)
        if let job = jobs[key] {
            job.waiters[ticket.id] = update
            return ticket
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: [.lowQualityThumbnail, .thumbnail])
        // Finder's icon style: documents as pages, pictures with their edge.
        request.iconMode = true
        let job = Job(request: request)
        job.waiters[ticket.id] = update
        jobs[key] = job
        generator.generateRepresentations(for: request) { [weak self] representation, type, error in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.receive(image, type: type, failed: error != nil, key: key, job: job)
                }
            }
        }
        return ticket
    }

    /// Stops waiting; the request itself is cancelled once nobody is waiting for it.
    func cancel(_ ticket: Ticket) {
        guard let job = jobs[ticket.key] else { return }
        job.waiters[ticket.id] = nil
        guard job.waiters.isEmpty else { return }
        jobs[ticket.key] = nil
        generator.cancel(job.request)
    }

    /// Requests in flight (for tests and measurements).
    var pendingCount: Int { jobs.count }

    private func receive(_ image: NSImage?, type: QLThumbnailRepresentation.RepresentationType, failed: Bool, key: String, job: Job) {
        guard jobs[key] === job else { return }
        let final = type == .thumbnail
        if let image, type.rawValue > job.best {
            job.best = type.rawValue
            if final {
                let pixels = image.size.width * image.size.height * 4 * job.request.scale * job.request.scale
                cache.setObject(image, forKey: key as NSString, cost: Int(pixels))
            }
            for waiter in job.waiters.values { waiter(image, final) }
        } else if final {
            if failed && job.best < 0 { failures.insert(key) }
            for waiter in job.waiters.values { waiter(nil, true) }
        }
        if final { jobs[key] = nil }
    }
}
