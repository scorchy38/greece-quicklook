import Cocoa
import WebKit

/// Renders source code files with syntax highlighting, line numbers, and auto-formatting.
final class SourceCodeRenderer: NSObject, FileRenderer, WKNavigationDelegate {

    private var completionHandler: ((Error?) -> Void)?

    func render(fileAt url: URL, completion: @escaping (Error?) -> Void) -> NSView {
        self.completionHandler = completion

        guard let data = try? Data(contentsOf: url),
              var content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            completion(NSError(domain: "GreeceQL", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read file"]))
            return NSView()
        }

        // Truncate if too large
        let lines = content.components(separatedBy: "\n")
        let truncated = lines.count > GreeceConstants.maxCodeLines
        if truncated {
            content = lines.prefix(GreeceConstants.maxCodeLines).joined(separator: "\n")
        }

        let settings = GreeceSettings.shared
        let theme = ThemeManager.shared

        // Detect language
        let language = LanguageDetector.detect(url: url, content: content)
        let displayName = LanguageDetector.displayName(forLanguage: language)

        // Auto-format if enabled
        if settings.codeAutoFormat && GreeceConstants.autoFormatExtensions.contains(url.pathExtension.lowercased()) {
            content = autoFormat(content, language: language)
        }

        let codeTheme = theme.currentCodeTheme

        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")

        let html = buildHTML(
            content: content,
            language: language,
            displayName: displayName,
            theme: codeTheme,
            showLineNumbers: settings.codeShowLineNumbers,
            fontFamily: settings.codeFontFamily,
            fontSize: settings.codeFontSize,
            fontWeight: settings.codeFontWeight,
            tabWidth: settings.codeTabWidth,
            wordWrap: settings.codeWordWrap,
            truncated: truncated,
            totalLines: lines.count
        )

        wv.loadHTMLString(html, baseURL: nil)

        // Restore scroll position
        if settings.rememberScrollPosition,
           let scrollY = settings.scrollPosition(for: url.path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                wv.evaluateJavaScript("window.scrollTo(0, \(scrollY));", completionHandler: nil)
            }
        }

        return wv
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.setValue(true, forKey: "drawsBackground")
        completionHandler?(nil)
        completionHandler = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completionHandler?(error)
        completionHandler = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completionHandler?(error)
        completionHandler = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        completionHandler?(NSError(domain: "GreeceQL", code: 2, userInfo: [NSLocalizedDescriptionKey: "Web content process terminated"]))
        completionHandler = nil
    }

    // MARK: - Auto-Formatting

    private func autoFormat(_ content: String, language: String) -> String {
        switch language {
        case "json":
            return formatJSON(content)
        case "xml", "svg", "html":
            return content // XML formatting is complex; keep as-is for now
        case "css":
            return formatCSS(content)
        default:
            return content
        }
    }

    private func formatJSON(_ content: String) -> String {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let result = String(data: pretty, encoding: .utf8) else {
            return content
        }
        return result
    }

    private func formatCSS(_ content: String) -> String {
        // Basic CSS formatting: one property per line
        var result = content
        result = result.replacingOccurrences(of: "{", with: " {\n  ")
        result = result.replacingOccurrences(of: ";", with: ";\n  ")
        result = result.replacingOccurrences(of: "}", with: "\n}\n")
        result = result.replacingOccurrences(of: "  \n}", with: "\n}")
        return result
    }

    // MARK: - HTML Builder

    private func buildHTML(
        content: String,
        language: String,
        displayName: String,
        theme: String,
        showLineNumbers: Bool,
        fontFamily: String,
        fontSize: Int,
        fontWeight: String,
        tabWidth: Int,
        wordWrap: Bool,
        truncated: Bool,
        totalLines: Int
    ) -> String {
        let escapedContent = content
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let cssWeight: String = {
            switch fontWeight.lowercased() {
            case "ultralight": return "100"
            case "thin": return "200"
            case "light": return "300"
            case "regular": return "400"
            case "medium": return "500"
            case "semibold": return "600"
            case "bold": return "700"
            case "heavy": return "800"
            case "black": return "900"
            default: return "400"
            }
        }()

        let truncationNotice = truncated ?
            "<div class=\"truncation-notice\">⚠ File truncated: showing \(GreeceConstants.maxCodeLines.formatted()) of \(totalLines.formatted()) lines</div>" : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/styles/\(theme).min.css">
            <style>
                :root {
                    --font-family: '\(fontFamily)', 'SF Mono', 'Menlo', 'Monaco', monospace;
                    --font-size: \(fontSize)px;
                    --font-weight: \(cssWeight);
                    --tab-width: \(tabWidth);
                }

                * { margin: 0; padding: 0; box-sizing: border-box; }

                body {
                    font-family: var(--font-family);
                    font-size: var(--font-size);
                    font-weight: var(--font-weight);
                    -webkit-font-smoothing: antialiased;
                    tab-size: var(--tab-width);
                    -moz-tab-size: var(--tab-width);
                }

                pre {
                    margin: 0;
                    padding: 0;
                }

                .code-container {
                    display: flex;
                    min-height: 100vh;
                }

                .line-numbers {
                    display: \(showLineNumbers ? "block" : "none");
                    padding: 16px 12px 16px 16px;
                    text-align: right;
                    user-select: none;
                    -webkit-user-select: none;
                    color: rgba(128, 128, 128, 0.5);
                    font-size: var(--font-size);
                    line-height: 1.45;
                    font-family: var(--font-family);
                    font-weight: var(--font-weight);
                    border-right: 1px solid rgba(128, 128, 128, 0.2);
                    min-width: 48px;
                    flex-shrink: 0;
                }

                .code-content {
                    flex: 1;
                    overflow-x: auto;
                    padding: 16px;
                }

                code {
                    font-family: var(--font-family) !important;
                    font-size: var(--font-size) !important;
                    font-weight: var(--font-weight) !important;
                    line-height: 1.45;
                    white-space: \(wordWrap ? "pre-wrap" : "pre");
                    word-wrap: \(wordWrap ? "break-word" : "normal");
                    display: block;
                }

                .truncation-notice {
                    padding: 8px 16px;
                    background: rgba(255, 165, 0, 0.15);
                    color: #b86e00;
                    font-size: 12px;
                    text-align: center;
                    border-top: 1px solid rgba(255, 165, 0, 0.3);
                }

                @media (prefers-color-scheme: dark) {
                    .truncation-notice { color: #ffa500; }
                }

                /* Progressive rendering: show immediately */
                hljs { visibility: visible !important; }
            </style>
        </head>
        <body>
            <div class="code-container">
                <div class="line-numbers" id="line-numbers"></div>
                <div class="code-content">
                    <pre><code id="code-block" class="language-\(language)">\(escapedContent)</code></pre>
                </div>
            </div>
            \(truncationNotice)

            <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/highlight.min.js"></script>
            <script>
            (function() {
                const codeBlock = document.getElementById('code-block');

                // Highlight (graceful fallback if CDN fails)
                try { if (typeof hljs !== 'undefined') hljs.highlightElement(codeBlock); } catch(e) {}

                // Generate line numbers
                \(showLineNumbers ? """
                const lineCount = codeBlock.textContent.split('\\n').length;
                const lineNums = document.getElementById('line-numbers');
                const nums = [];
                for (let i = 1; i <= lineCount; i++) {
                    nums.push(i);
                }
                lineNums.textContent = nums.join('\\n');
                """ : "")
            })();
            </script>
        </body>
        </html>
        """
    }
}
