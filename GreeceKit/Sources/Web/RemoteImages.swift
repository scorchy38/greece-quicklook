import Foundation

/// Remote images in Markdown and notebooks, fetched by Greece instead of the web view, when the
/// reader allows remote images at all:
/// - kept in a disk cache, so badges and screenshots appear at once next time, and offline;
/// - sent without cookies, credentials or anything else that identifies the reader;
/// - only ever images, and never larger than `maxBytes`.
/// Pages ask for them as `greece://remote/<percent-encoded URL>`.
enum RemoteImages {
    static let maxBytes = 20 * 1024 * 1024

    static let session = makeSession()

    static func makeSession(protocolClasses: [AnyClass]? = nil, cacheDirectory: URL? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpAdditionalHeaders = ["Accept": "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8"]
        let folder = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteImages", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20, directory: folder)
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration)
    }

    /// The remote address in `greece://remote/<percent-encoded URL>`: http(s) only.
    static func target(of url: URL) -> URL? {
        let encoded = url.absoluteString.components(separatedBy: "://remote/").dropFirst().first ?? ""
        guard let decoded = encoded.removingPercentEncoding, let remote = URL(string: decoded),
              let scheme = remote.scheme?.lowercased(), scheme == "https" || scheme == "http", remote.host != nil else { return nil }
        return remote
    }

    /// What a page writes for a remote image.
    static func address(for remote: String) -> String {
        "greece://remote/" + (remote.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? remote)
    }

    /// Fetches an image (or the cached copy when the network fails) and calls back with its bytes
    /// and type, or nil. Called back on a background queue.
    static func fetch(_ remote: URL, session: URLSession = session, completion: @escaping ((data: Data, type: String)?) -> Void) {
        let request = URLRequest(url: remote)
        session.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let image = accept(data, http) {
                return completion(image)
            }
            // Offline, or the server is down: the last copy Greece saw, however old.
            if let cached = session.configuration.urlCache?.cachedResponse(for: request),
               let http = cached.response as? HTTPURLResponse, let image = accept(cached.data, http) {
                return completion(image)
            }
            completion(nil)
        }.resume()
    }

    private static func accept(_ data: Data, _ response: HTTPURLResponse) -> (data: Data, type: String)? {
        guard data.count <= maxBytes, let type = response.mimeType?.lowercased(), type.hasPrefix("image/") else { return nil }
        return (data, type)
    }
}
