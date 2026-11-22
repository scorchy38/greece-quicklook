import XCTest
import WebKit
@testable import GreeceKit

/// Remote images go through Greece: only http(s), only images, cached for when the network is
/// gone, and only when the reader allows remote images.
final class RemoteImagesTests: XCTestCase {
    /// Answers requests from a table, so no test touches the network.
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var responses: [String: (status: Int, type: String, body: Data)] = [:]
        nonisolated(unsafe) static var offline = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard !Stub.offline, let url = request.url, let answer = Stub.responses[url.absoluteString] else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": answer.type, "Cache-Control": "max-age=60"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var cache: URL!

    override func setUp() {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteImages-\(UUID().uuidString)")
        Stub.responses = [:]
        Stub.offline = false
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cache)
    }

    private func fetch(_ url: String, session: URLSession) -> (data: Data, type: String)? {
        let done = expectation(description: url)
        var result: (data: Data, type: String)?
        RemoteImages.fetch(URL(string: url)!, session: session) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    func testOnlyWebAddressesAreFetched() {
        let address = RemoteImages.address(for: "https://img.shields.io/badge/build-passing-green?style=flat&x=1")
        XCTAssertTrue(address.hasPrefix("greece://remote/"))
        XCTAssertEqual(RemoteImages.target(of: URL(string: address)!)?.absoluteString, "https://img.shields.io/badge/build-passing-green?style=flat&x=1")
        for refused in ["file:///etc/passwd", "javascript:alert(1)", "greece://file/etc/hosts", "ftp://example.com/a.png", "https://"] {
            XCTAssertNil(RemoteImages.target(of: URL(string: RemoteImages.address(for: refused))!), refused)
        }
    }

    func testImagesOnlyAndCachedForWhenOffline() {
        let session = RemoteImages.makeSession(protocolClasses: [Stub.self], cacheDirectory: cache)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        Stub.responses["https://example.com/logo.png"] = (200, "image/png", png)
        Stub.responses["https://example.com/page"] = (200, "text/html", Data("<script>".utf8))
        Stub.responses["https://example.com/missing.png"] = (404, "image/png", Data())

        XCTAssertEqual(fetch("https://example.com/logo.png", session: session)?.data, png)
        XCTAssertEqual(fetch("https://example.com/logo.png", session: session)?.type, "image/png")
        XCTAssertNil(fetch("https://example.com/page", session: session), "only images")
        XCTAssertNil(fetch("https://example.com/missing.png", session: session))

        Stub.offline = true
        XCTAssertEqual(fetch("https://example.com/logo.png", session: session)?.data, png, "the cached copy, offline")
        XCTAssertNil(fetch("https://example.com/never-seen.png", session: session))
    }

    func testTooLargeIsRefused() {
        let session = RemoteImages.makeSession(protocolClasses: [Stub.self], cacheDirectory: cache)
        Stub.responses["https://example.com/huge.png"] = (200, "image/png", Data(count: RemoteImages.maxBytes + 1))
        XCTAssertNil(fetch("https://example.com/huge.png", session: session))
    }

    @MainActor
    func testPagesAskGreeceForRemoteImagesOnlyWhenAllowed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Remote-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        ![Build](https://img.shields.io/badge/build-passing-green)

        <picture><source srcset="https://example.com/dark.png 2x" media="(prefers-color-scheme: dark)"><img src="https://example.com/light.png" alt="Shot"></picture>
        """.write(to: url, atomically: true, encoding: .utf8)
        let script = "return [Array.from(document.querySelectorAll('article img')).map((i) => i.getAttribute('src')), Array.from(document.querySelectorAll('article source')).map((s) => s.getAttribute('srcset')), document.querySelectorAll('.remote-image').length]"

        var allowed = PreviewSettings()
        allowed.loadRemoteImages = true
        let on = try await PreviewFactory.makePreview(for: url, settings: allowed)
        await on.waitUntilReady()
        let onState = try await XCTUnwrap(on.webView as? WKWebView).callAsyncJavaScript(script, contentWorld: .page) as? [Any]
        let sources = onState?[0] as? [String] ?? []
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.allSatisfy { $0.hasPrefix("greece://remote/https%3A%2F%2F") }, "\(sources)")
        XCTAssertEqual((onState?[1] as? [String])?.first?.hasPrefix("greece://remote/"), true)

        var refused = PreviewSettings()
        refused.loadRemoteImages = false
        let off = try await PreviewFactory.makePreview(for: url, settings: refused)
        await off.waitUntilReady()
        let offState = try await XCTUnwrap(off.webView as? WKWebView).callAsyncJavaScript(script, contentWorld: .page) as? [Any]
        XCTAssertEqual(offState?[2] as? Int, 2, "both images become placeholders")
        XCTAssertEqual((offState?[1] as? [String])?.first, "", "a picture's remote source is dropped")
    }
}
