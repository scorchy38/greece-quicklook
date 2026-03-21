import Cocoa
import WebKit

/// Renders diff/patch files with color-coded additions and removals.
final class DiffRenderer: NSObject, FileRenderer, WKNavigationDelegate {

    private var completionHandler: ((Error?) -> Void)?

    func render(fileAt url: URL, completion: @escaping (Error?) -> Void) -> NSView {
        self.completionHandler = completion

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            completion(NSError(domain: "GreeceQL", code: 6, userInfo: [NSLocalizedDescriptionKey: "Cannot read diff file"]))
            return NSView()
        }

        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")

        let html = buildDiffHTML(content)
        wv.loadHTMLString(html, baseURL: nil)

        return wv
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.setValue(true, forKey: "drawsBackground")
        completionHandler?(nil)
        completionHandler = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completionHandler?(error)
        completionHandler = nil
    }

    private func buildDiffHTML(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var htmlLines: [String] = []

        for (index, line) in lines.enumerated() {
            let escapedLine = line
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")

            let cssClass: String
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                cssClass = "file-header"
            } else if line.hasPrefix("@@") {
                cssClass = "hunk-header"
            } else if line.hasPrefix("+") {
                cssClass = "addition"
            } else if line.hasPrefix("-") {
                cssClass = "deletion"
            } else if line.hasPrefix("diff ") {
                cssClass = "diff-header"
            } else if line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
                cssClass = "meta"
            } else if line.hasPrefix("\\") {
                cssClass = "no-newline"
            } else {
                cssClass = "context"
            }

            htmlLines.append("<tr class=\"\(cssClass)\"><td class=\"line-num\">\(index + 1)</td><td class=\"line-content\">\(escapedLine.isEmpty ? " " : escapedLine)</td></tr>")
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }

                :root {
                    --bg: #ffffff;
                    --text: #1f2328;
                    --add-bg: #dafbe1;
                    --add-text: #116329;
                    --del-bg: #ffebe9;
                    --del-text: #82071e;
                    --hunk-bg: #ddf4ff;
                    --hunk-text: #0550ae;
                    --meta-text: #656d76;
                    --header-bg: #f6f8fa;
                    --border: #d1d9e0;
                    --line-num-text: #656d76;
                    --line-num-bg: transparent;
                }

                @media (prefers-color-scheme: dark) {
                    :root {
                        --bg: #0d1117;
                        --text: #e6edf3;
                        --add-bg: #12261e;
                        --add-text: #3fb950;
                        --del-bg: #2d1215;
                        --del-text: #f85149;
                        --hunk-bg: #0c2d6b;
                        --hunk-text: #79c0ff;
                        --meta-text: #8b949e;
                        --header-bg: #161b22;
                        --border: #30363d;
                        --line-num-text: #484f58;
                    }
                }

                body {
                    font-family: 'SF Mono', 'Menlo', 'Monaco', monospace;
                    font-size: 13px;
                    line-height: 1.45;
                    background: var(--bg);
                    color: var(--text);
                    -webkit-font-smoothing: antialiased;
                }

                table {
                    width: 100%;
                    border-collapse: collapse;
                    table-layout: fixed;
                }

                td {
                    padding: 0 12px;
                    white-space: pre;
                    overflow-x: auto;
                    vertical-align: top;
                }

                .line-num {
                    width: 52px;
                    min-width: 52px;
                    max-width: 52px;
                    text-align: right;
                    color: var(--line-num-text);
                    background: var(--line-num-bg);
                    user-select: none;
                    -webkit-user-select: none;
                    border-right: 1px solid var(--border);
                    padding-right: 8px;
                    font-size: 12px;
                }

                .line-content {
                    width: 100%;
                }

                .addition { background: var(--add-bg); }
                .addition .line-content { color: var(--add-text); }
                .deletion { background: var(--del-bg); }
                .deletion .line-content { color: var(--del-text); }
                .hunk-header { background: var(--hunk-bg); }
                .hunk-header .line-content { color: var(--hunk-text); font-weight: 600; }
                .diff-header { background: var(--header-bg); }
                .diff-header .line-content { font-weight: 700; }
                .file-header { background: var(--header-bg); }
                .file-header .line-content { font-weight: 600; }
                .meta .line-content { color: var(--meta-text); font-style: italic; }
                .no-newline .line-content { color: var(--meta-text); font-style: italic; }
                .context { }
            </style>
        </head>
        <body>
            <table>
                \(htmlLines.joined(separator: "\n"))
            </table>
        </body>
        </html>
        """
    }
}
