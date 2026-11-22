import Foundation
import WebKit
import UniformTypeIdentifiers

/// Bundled web assets (renderer, styles, vendored libraries).
enum WebAssets {
    private final class Marker {}
    static let bundle = Bundle(for: Marker.self)
    static let root: URL = bundle.resourceURL!.appendingPathComponent("Web", isDirectory: true)

    static func url(_ relativePath: String) -> URL? {
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Grammar ids that ship as separate files, read once from the bundle. Lookups only ever
    /// succeed for these exact names, so document text can never shape a script URL.
    static let bundledGrammars: Set<String> = {
        let directory = root.appendingPathComponent("vendor/highlight/languages")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(files.compactMap { $0.hasSuffix(".min.js") ? String($0.dropLast(7)) : nil })
    }()

    /// Every enhancer file in the bundle, listed once.
    private static let enhancerFiles: [String] = {
        let folder = root.appendingPathComponent("enhancers")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }()

    /// `enhancers/<kind>.<ext>` and `enhancers/<kind>-*.<ext>`, in name order.
    static func enhancers(for kind: String, ext: String) -> [String] {
        enhancerFiles.filter { name in
            name.hasSuffix("." + ext) && (name == "\(kind).\(ext)" || name.hasPrefix(kind + "-"))
        }.map { "enhancers/" + $0 }
    }

    static func hasGrammar(_ id: String) -> Bool {
        LanguageCatalog.commonGrammars.contains(id) || bundledGrammars.contains(id)
    }
}

/// Serves the page's resources:
/// - `greece://asset/<path>`: Greece's bundled renderer, styles and libraries.
/// - `greece://file/<absolute path>`: local media (images, video, audio, PDF) for Markdown and
///   notebooks, plus any file inside the document's `readableDirectory`. Never scriptable.
/// - `greece://module/<path>`: data a module computes on demand.
final class GreeceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "greece"

    private static let mediaTypes: [UTType] = [.image, .movie, .audio, .pdf]
    private let readableDirectory: String?
    private let resources: ModuleResources?
    /// Tasks WebKit has cancelled; answering one of them raises an exception.
    private var stopped = Set<ObjectIdentifier>()

    init(readableDirectory: URL? = nil, resources: ModuleResources? = nil) {
        self.readableDirectory = readableDirectory.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        self.resources = resources
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task) }
        let path = url.path
        var file: URL?
        var headers: [String: String] = ["Cache-Control": "max-age=86400"]
        switch url.host {
        case "asset":
            file = WebAssets.url(String(path.drop(while: { $0 == "/" })))
            // Fonts are loaded cross-origin from the document; assets are public anyway.
            headers["Access-Control-Allow-Origin"] = "*"
        case "file":
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            if isReadable(candidate) {
                file = candidate
            } else if let type = UTType(filenameExtension: candidate.pathExtension),
                      Self.mediaTypes.contains(where: { type.conforms(to: $0) }) {
                file = candidate
            }
            // Even if an SVG is ever opened directly, it can't run script or load anything.
            headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; sandbox"
            headers["Access-Control-Allow-Origin"] = "*"
        case "module":
            guard let resources else { return fail(task) }
            let id = ObjectIdentifier(task)
            let request = String(path.drop(while: { $0 == "/" })) + (url.query.map { "?" + $0 } ?? "")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = resources(request)
                DispatchQueue.main.async {
                    guard let self, self.stopped.remove(id) == nil else { return }
                    guard let result else { return self.fail(task) }
                    self.respond(task, url: url, data: result.data, headers: [
                        "Content-Type": result.mimeType, "Cache-Control": "no-store",
                        "Access-Control-Allow-Origin": "*",
                        "Content-Security-Policy": "default-src 'none'; sandbox",
                    ])
                }
            }
            return
        default:
            break
        }
        guard let file, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return fail(task) }
        headers["Content-Type"] = Self.mimeType(for: file)
        respond(task, url: url, data: data, headers: headers)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    /// Files inside the document's readable folder (after resolving links and `..`).
    private func isReadable(_ candidate: URL) -> Bool {
        guard let readableDirectory else { return false }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let root = readableDirectory.hasSuffix("/") ? readableDirectory : readableDirectory + "/"
        return resolved.hasPrefix(root)
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, headers: [String: String]) {
        var headers = headers
        headers["Content-Length"] = String(data.count)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "woff2": return "font/woff2"
        case "svg": return "image/svg+xml"
        default: return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    /// Base URL so relative links and images resolve against the document's folder.
    static func baseURL(for directory: URL?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        var path = directory?.standardizedFileURL.path ?? "/"
        if !path.hasSuffix("/") { path += "/" }
        components.path = path
        return components.url ?? URL(string: "greece://file/")!
    }
}
