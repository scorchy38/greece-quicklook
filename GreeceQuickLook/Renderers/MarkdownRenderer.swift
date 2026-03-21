import Cocoa
import WebKit

/// Renders Markdown files using WKWebView with GFM, KaTeX, Mermaid, and TOC support.
final class MarkdownRenderer: NSObject, FileRenderer, WKNavigationDelegate {

    private var completionHandler: ((Error?) -> Void)?
    private var webView: WKWebView?

    func render(fileAt url: URL, completion: @escaping (Error?) -> Void) -> NSView {
        self.completionHandler = completion

        // Read file content
        let content: String
        let baseURL: URL

        if GreeceConstants.textBundleExtensions.contains(url.pathExtension.lowercased()) {
            // TextBundle: read text.md inside the bundle
            let textFile = url.appendingPathComponent("text.md")
            content = (try? String(contentsOf: textFile, encoding: .utf8)) ?? ""
            baseURL = url // Assets are relative to bundle root
        } else {
            content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            baseURL = url.deletingLastPathComponent()
        }

        // Create WKWebView with configuration
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Set up user content controller for scroll position
        let userContentController = WKUserContentController()
        config.userContentController = userContentController

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground") // Transparent until loaded
        self.webView = wv

        // Build the HTML
        let settings = GreeceSettings.shared
        let theme = ThemeManager.shared
        let html = buildHTML(
            content: content,
            baseURL: baseURL,
            markdownTheme: theme.currentMarkdownTheme,
            showTOC: settings.markdownShowTOC,
            renderMath: settings.markdownRenderMath,
            renderMermaid: settings.markdownRenderMermaid,
            renderEmoji: settings.markdownRenderEmoji,
            fontFamily: settings.markdownFontFamily,
            fontSize: settings.markdownFontSize,
            lineHeight: settings.markdownLineHeight
        )

        wv.loadHTMLString(html, baseURL: baseURL)

        // Restore scroll position if enabled
        if settings.rememberScrollPosition,
           let scrollY = settings.scrollPosition(for: url.path) {
            let js = "window.scrollTo(0, \(scrollY));"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                wv.evaluateJavaScript(js, completionHandler: nil)
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

    // MARK: - HTML Builder

    private func buildHTML(
        content: String,
        baseURL: URL,
        markdownTheme: String,
        showTOC: Bool,
        renderMath: Bool,
        renderMermaid: Bool,
        renderEmoji: Bool,
        fontFamily: String,
        fontSize: Int,
        lineHeight: Double
    ) -> String {
        // Escape content for JavaScript string
        let escapedContent = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let mathCSS = renderMath ? """
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        """ : ""

        let mathJS = renderMath ? """
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
        """ : ""

        let mermaidJS = renderMermaid ? """
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        """ : ""

        return """
        <!DOCTYPE html>
        <html data-theme="\(markdownTheme)">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(mathCSS)
            <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/styles/github.min.css">
            <style>
                :root {
                    --font-family: \(fontFamily), -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                    --font-size: \(fontSize)px;
                    --line-height: \(lineHeight);
                    --content-max-width: 900px;
                    --toc-width: 240px;
                }

                * { margin: 0; padding: 0; box-sizing: border-box; }

                html, body {
                    max-width: 100vw;
                    overflow-x: hidden;
                }

                body {
                    font-family: var(--font-family);
                    font-size: var(--font-size);
                    line-height: var(--line-height);
                    color: var(--text-color, #1f2328);
                    background: var(--bg-color, #ffffff);
                    display: flex;
                    -webkit-font-smoothing: antialiased;
                }

                /* Theme variables */
                [data-theme="github-light"] { --bg-color: #ffffff; --text-color: #1f2328; --heading-color: #1f2328; --link-color: #0969da; --border-color: #d1d9e0; --code-bg: #f6f8fa; --blockquote-border: #d1d9e0; --blockquote-text: #656d76; --table-border: #d1d9e0; --table-alt-bg: #f6f8fa; --toc-bg: #f6f8fa; --toc-active: #0969da; }
                [data-theme="github-dark"] { --bg-color: #0d1117; --text-color: #e6edf3; --heading-color: #e6edf3; --link-color: #58a6ff; --border-color: #30363d; --code-bg: #161b22; --blockquote-border: #30363d; --blockquote-text: #8b949e; --table-border: #30363d; --table-alt-bg: #161b22; --toc-bg: #161b22; --toc-active: #58a6ff; }
                [data-theme="solarized-light"] { --bg-color: #fdf6e3; --text-color: #657b83; --heading-color: #586e75; --link-color: #268bd2; --border-color: #eee8d5; --code-bg: #eee8d5; --blockquote-border: #eee8d5; --blockquote-text: #93a1a1; --table-border: #eee8d5; --table-alt-bg: #eee8d5; --toc-bg: #eee8d5; --toc-active: #268bd2; }
                [data-theme="solarized-dark"] { --bg-color: #002b36; --text-color: #839496; --heading-color: #93a1a1; --link-color: #268bd2; --border-color: #073642; --code-bg: #073642; --blockquote-border: #073642; --blockquote-text: #586e75; --table-border: #073642; --table-alt-bg: #073642; --toc-bg: #073642; --toc-active: #268bd2; }
                [data-theme="nord"] { --bg-color: #2e3440; --text-color: #d8dee9; --heading-color: #eceff4; --link-color: #88c0d0; --border-color: #3b4252; --code-bg: #3b4252; --blockquote-border: #3b4252; --blockquote-text: #7b88a1; --table-border: #3b4252; --table-alt-bg: #3b4252; --toc-bg: #3b4252; --toc-active: #88c0d0; }
                [data-theme="dracula"] { --bg-color: #282a36; --text-color: #f8f8f2; --heading-color: #f8f8f2; --link-color: #8be9fd; --border-color: #44475a; --code-bg: #44475a; --blockquote-border: #6272a4; --blockquote-text: #6272a4; --table-border: #44475a; --table-alt-bg: #44475a; --toc-bg: #343746; --toc-active: #bd93f9; }
                [data-theme="one-light"] { --bg-color: #fafafa; --text-color: #383a42; --heading-color: #383a42; --link-color: #4078f2; --border-color: #e5e5e6; --code-bg: #f0f0f1; --blockquote-border: #e5e5e6; --blockquote-text: #a0a1a7; --table-border: #e5e5e6; --table-alt-bg: #f0f0f1; --toc-bg: #f0f0f1; --toc-active: #4078f2; }
                [data-theme="one-dark"] { --bg-color: #282c34; --text-color: #abb2bf; --heading-color: #e5c07b; --link-color: #61afef; --border-color: #3e4451; --code-bg: #2c313c; --blockquote-border: #3e4451; --blockquote-text: #5c6370; --table-border: #3e4451; --table-alt-bg: #2c313c; --toc-bg: #21252b; --toc-active: #61afef; }
                [data-theme="monokai"] { --bg-color: #272822; --text-color: #f8f8f2; --heading-color: #f8f8f2; --link-color: #66d9ef; --border-color: #3e3d32; --code-bg: #3e3d32; --blockquote-border: #75715e; --blockquote-text: #75715e; --table-border: #3e3d32; --table-alt-bg: #3e3d32; --toc-bg: #1e1f1c; --toc-active: #a6e22e; }
                [data-theme="gruvbox-light"] { --bg-color: #fbf1c7; --text-color: #3c3836; --heading-color: #3c3836; --link-color: #076678; --border-color: #d5c4a1; --code-bg: #ebdbb2; --blockquote-border: #d5c4a1; --blockquote-text: #665c54; --table-border: #d5c4a1; --table-alt-bg: #ebdbb2; --toc-bg: #ebdbb2; --toc-active: #076678; }
                [data-theme="gruvbox-dark"] { --bg-color: #282828; --text-color: #ebdbb2; --heading-color: #ebdbb2; --link-color: #83a598; --border-color: #3c3836; --code-bg: #3c3836; --blockquote-border: #504945; --blockquote-text: #928374; --table-border: #3c3836; --table-alt-bg: #3c3836; --toc-bg: #1d2021; --toc-active: #83a598; }

                @media (prefers-color-scheme: dark) {
                    [data-theme="github-light"] { --bg-color: #0d1117; --text-color: #e6edf3; --heading-color: #e6edf3; --link-color: #58a6ff; --border-color: #30363d; --code-bg: #161b22; --blockquote-border: #30363d; --blockquote-text: #8b949e; --table-border: #30363d; --table-alt-bg: #161b22; --toc-bg: #161b22; --toc-active: #58a6ff; }
                }

                /* TOC Sidebar */
                #toc-sidebar {
                    width: var(--toc-width);
                    min-width: var(--toc-width);
                    height: 100vh;
                    position: sticky;
                    top: 0;
                    overflow-y: auto;
                    background: var(--toc-bg);
                    border-right: 1px solid var(--border-color);
                    padding: 16px 12px;
                    font-size: 12px;
                    display: \(showTOC ? "block" : "none");
                }

                #toc-sidebar ul { list-style: none; padding-left: 0; }
                #toc-sidebar li { padding: 3px 0; }
                #toc-sidebar li.toc-h2 { padding-left: 12px; }
                #toc-sidebar li.toc-h3 { padding-left: 24px; }
                #toc-sidebar li.toc-h4 { padding-left: 36px; }
                #toc-sidebar li.toc-h5 { padding-left: 48px; }
                #toc-sidebar li.toc-h6 { padding-left: 60px; }
                #toc-sidebar a {
                    color: var(--text-color);
                    text-decoration: none;
                    opacity: 0.7;
                    transition: opacity 0.15s;
                    display: block;
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                }
                #toc-sidebar a:hover { opacity: 1; }
                #toc-sidebar a.active {
                    color: var(--toc-active);
                    opacity: 1;
                    font-weight: 600;
                }

                /* Main content */
                #content {
                    flex: 1;
                    min-width: 0;
                    max-width: var(--content-max-width);
                    margin: 0 auto;
                    padding: 32px 40px;
                    overflow-wrap: break-word;
                    word-wrap: break-word;
                }

                /* Typography */
                h1, h2, h3, h4, h5, h6 {
                    color: var(--heading-color);
                    margin-top: 24px;
                    margin-bottom: 16px;
                    font-weight: 600;
                    line-height: 1.25;
                }
                h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border-color); }
                h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border-color); }
                h3 { font-size: 1.25em; }
                h4 { font-size: 1em; }

                p { margin-bottom: 16px; }
                a { color: var(--link-color); text-decoration: none; }
                a:hover { text-decoration: underline; }

                /* Code */
                code {
                    background: var(--code-bg);
                    padding: 0.2em 0.4em;
                    border-radius: 6px;
                    font-size: 85%;
                    font-family: 'SF Mono', 'Menlo', 'Monaco', monospace;
                }
                pre {
                    background: var(--code-bg);
                    border-radius: 6px;
                    padding: 16px;
                    overflow-x: auto;
                    margin-bottom: 16px;
                    position: relative;
                }
                pre code {
                    background: none;
                    padding: 0;
                    font-size: 13px;
                    line-height: 1.45;
                }

                /* Copy button */
                pre .copy-btn {
                    position: absolute;
                    top: 8px;
                    right: 8px;
                    padding: 4px 8px;
                    border: 1px solid var(--border-color);
                    border-radius: 6px;
                    background: var(--bg-color);
                    color: var(--text-color);
                    font-size: 12px;
                    cursor: pointer;
                    opacity: 0;
                    transition: opacity 0.15s;
                }
                pre:hover .copy-btn { opacity: 1; }
                pre .copy-btn:hover { background: var(--code-bg); }

                /* Blockquotes */
                blockquote {
                    border-left: 4px solid var(--blockquote-border);
                    padding: 0.5em 1em;
                    margin: 0 0 16px 0;
                    color: var(--blockquote-text);
                }

                /* GitHub-style Alerts */
                .markdown-alert {
                    border-left: 4px solid;
                    border-radius: 6px;
                    padding: 12px 16px;
                    margin-bottom: 16px;
                }
                .markdown-alert-title { font-weight: 600; display: flex; align-items: center; gap: 8px; margin-bottom: 4px; }
                .markdown-alert-note { border-color: #0969da; background: rgba(9, 105, 218, 0.1); }
                .markdown-alert-note .markdown-alert-title { color: #0969da; }
                .markdown-alert-tip { border-color: #1a7f37; background: rgba(26, 127, 55, 0.1); }
                .markdown-alert-tip .markdown-alert-title { color: #1a7f37; }
                .markdown-alert-important { border-color: #8250df; background: rgba(130, 80, 223, 0.1); }
                .markdown-alert-important .markdown-alert-title { color: #8250df; }
                .markdown-alert-warning { border-color: #9a6700; background: rgba(154, 103, 0, 0.1); }
                .markdown-alert-warning .markdown-alert-title { color: #9a6700; }
                .markdown-alert-caution { border-color: #cf222e; background: rgba(207, 34, 46, 0.1); }
                .markdown-alert-caution .markdown-alert-title { color: #cf222e; }

                /* Tables */
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin-bottom: 16px;
                    overflow: auto;
                    display: block;
                }
                th, td {
                    padding: 6px 13px;
                    border: 1px solid var(--table-border);
                }
                th { font-weight: 600; background: var(--code-bg); }
                tr:nth-child(even) { background: var(--table-alt-bg); }

                /* Task lists */
                .task-list-item { list-style: none; margin-left: -24px; }
                .task-list-item input[type="checkbox"] { margin-right: 8px; }

                /* Images */
                img { max-width: 100%; height: auto; border-radius: 6px; }

                /* Horizontal rule */
                hr { border: none; border-top: 1px solid var(--border-color); margin: 24px 0; }

                /* Lists */
                ul, ol { padding-left: 2em; margin-bottom: 16px; }
                li { margin-bottom: 4px; }
                li > p { margin-bottom: 4px; }

                /* Mermaid */
                .mermaid { text-align: center; margin: 16px 0; }

                /* KaTeX */
                .katex-display { margin: 1em 0; overflow-x: auto; overflow-y: hidden; }
            </style>
        </head>
        <body>
            <nav id="toc-sidebar"><ul id="toc-list"></ul></nav>
            <article id="content"></article>

            <script src="https://cdn.jsdelivr.net/npm/marked@15/marked.min.js"></script>
            <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/highlight.min.js"></script>
            \(mathJS)
            \(mermaidJS)

            <script>
            (function() {
                const rawContent = `\(escapedContent)`;

                // Emoji shortcode map (common ones)
                const emojiMap = {
                    '+1': '👍', '-1': '👎', 'heart': '❤️', 'smile': '😄', 'laughing': '😆',
                    'wink': '😉', 'cry': '😢', 'tada': '🎉', 'rocket': '🚀', 'fire': '🔥',
                    'star': '⭐', 'warning': '⚠️', 'check': '✅', 'x': '❌', 'bug': '🐛',
                    'bulb': '💡', 'memo': '📝', 'book': '📖', 'link': '🔗', 'eyes': '👀',
                    'thinking': '🤔', 'clap': '👏', 'pray': '🙏', 'muscle': '💪', 'wave': '👋',
                    'sparkles': '✨', 'boom': '💥', 'zap': '⚡', 'hammer': '🔨', 'wrench': '🔧',
                    'gear': '⚙️', 'lock': '🔒', 'key': '🔑', 'globe': '🌍', 'sun': '☀️',
                    'moon': '🌙', 'cloud': '☁️', 'umbrella': '☂️', 'snowflake': '❄️', 'coffee': '☕',
                    'pizza': '🍕', 'apple': '🍎', 'beer': '🍺', 'trophy': '🏆', 'medal': '🏅',
                    'gift': '🎁', 'balloon': '🎈', 'art': '🎨', 'music': '🎵', 'movie': '🎬',
                    'camera': '📷', 'phone': '📱', 'computer': '💻', 'email': '📧', 'inbox': '📥',
                    'outbox': '📤', 'package': '📦', 'calendar': '📅', 'chart': '📊', 'pin': '📌',
                    'scissors': '✂️', 'pencil': '✏️', 'pen': '🖊️', 'paperclip': '📎', 'folder': '📁',
                    'file': '📄', 'clipboard': '📋', 'pushpin': '📌', 'mag': '🔍', 'bell': '🔔',
                    'speaker': '🔊', 'mute': '🔇', 'hourglass': '⏳', 'stopwatch': '⏱️', 'alarm': '⏰',
                    'construction': '🚧', 'recycle': '♻️', 'white_check_mark': '✅', 'heavy_check_mark': '✔️',
                };

                // Configure marked
                marked.setOptions({
                    gfm: true,
                    breaks: false,
                    highlight: function(code, lang) {
                        if (lang && hljs.getLanguage(lang)) {
                            try { return hljs.highlight(code, { language: lang }).value; }
                            catch(e) {}
                        }
                        try { return hljs.highlightAuto(code).value; }
                        catch(e) {}
                        return code;
                    }
                });

                // Custom renderer for code blocks with copy button
                const renderer = new marked.Renderer();
                const origCode = renderer.code;
                renderer.code = function({ text, lang, escaped }) {
                    // Check for mermaid
                    if (lang === 'mermaid') {
                        return '<div class="mermaid">' + text + '</div>';
                    }
                    const highlighted = lang && hljs.getLanguage(lang)
                        ? hljs.highlight(text, { language: lang }).value
                        : (hljs.highlightAuto(text).value || text);
                    const langLabel = lang ? ' data-lang="' + lang + '"' : '';
                    return '<pre' + langLabel + '><button class="copy-btn" onclick="copyCode(this)">Copy</button><code>' + highlighted + '</code></pre>';
                };

                // Task list support
                renderer.listitem = function({ text, task, checked }) {
                    if (task) {
                        const checkbox = '<input type="checkbox" disabled' + (checked ? ' checked' : '') + '> ';
                        return '<li class="task-list-item">' + checkbox + text + '</li>\\n';
                    }
                    return '<li>' + text + '</li>\\n';
                };

                marked.use({ renderer: renderer });

                // Process GitHub Alerts
                let processed = rawContent;

                // GitHub-style alerts: > [!NOTE], > [!TIP], > [!IMPORTANT], > [!WARNING], > [!CAUTION]
                const alertTypes = ['NOTE', 'TIP', 'IMPORTANT', 'WARNING', 'CAUTION'];
                const alertIcons = {
                    'NOTE': 'ℹ️', 'TIP': '💡', 'IMPORTANT': '❗',
                    'WARNING': '⚠️', 'CAUTION': '🔴'
                };

                for (const type of alertTypes) {
                    const regex = new RegExp('> \\\\[!' + type + '\\\\]\\n((?:>.*\\n?)*)', 'gm');
                    processed = processed.replace(regex, function(match, body) {
                        const cleanBody = body.replace(/^> ?/gm, '').trim();
                        return '<div class="markdown-alert markdown-alert-' + type.toLowerCase() + '">' +
                            '<p class="markdown-alert-title">' + alertIcons[type] + ' ' + type.charAt(0) + type.slice(1).toLowerCase() + '</p>' +
                            '<p>' + cleanBody + '</p></div>\\n\\n';
                    });
                }

                // Emoji shortcodes
                \(renderEmoji ? """
                processed = processed.replace(/:([a-z0-9_]+):/g, function(match, code) {
                    return emojiMap[code] || match;
                });
                """ : "")

                // Render markdown
                const html = marked.parse(processed);
                document.getElementById('content').innerHTML = html;

                // Build TOC
                \(showTOC ? """
                const headings = document.querySelectorAll('#content h1, #content h2, #content h3, #content h4, #content h5, #content h6');
                const tocList = document.getElementById('toc-list');
                headings.forEach(function(h, i) {
                    const id = 'heading-' + i;
                    h.id = id;
                    const li = document.createElement('li');
                    li.className = 'toc-' + h.tagName.toLowerCase();
                    const a = document.createElement('a');
                    a.href = '#' + id;
                    a.textContent = h.textContent;
                    a.dataset.heading = id;
                    li.appendChild(a);
                    tocList.appendChild(li);
                });

                // Active heading highlight on scroll
                const observer = new IntersectionObserver(function(entries) {
                    entries.forEach(function(entry) {
                        if (entry.isIntersecting) {
                            document.querySelectorAll('#toc-sidebar a').forEach(a => a.classList.remove('active'));
                            const tocLink = document.querySelector('#toc-sidebar a[data-heading="' + entry.target.id + '"]');
                            if (tocLink) tocLink.classList.add('active');
                        }
                    });
                }, { rootMargin: '-20% 0px -80% 0px' });
                headings.forEach(h => observer.observe(h));
                """ : "")

                // Render KaTeX
                \(renderMath ? """
                renderMathInElement(document.getElementById('content'), {
                    delimiters: [
                        { left: '$$', right: '$$', display: true },
                        { left: '$', right: '$', display: false },
                        { left: '\\\\(', right: '\\\\)', display: false },
                        { left: '\\\\[', right: '\\\\]', display: true }
                    ],
                    throwOnError: false
                });
                """ : "")

                // Render Mermaid
                \(renderMermaid ? """
                if (typeof mermaid !== 'undefined') {
                    mermaid.initialize({
                        startOnLoad: true,
                        theme: document.documentElement.dataset.theme.includes('dark') ||
                               document.documentElement.dataset.theme.includes('nord') ||
                               document.documentElement.dataset.theme.includes('dracula') ||
                               document.documentElement.dataset.theme.includes('monokai') ? 'dark' : 'default'
                    });
                }
                """ : "")
            })();

            function copyCode(btn) {
                const code = btn.parentElement.querySelector('code').textContent;
                navigator.clipboard.writeText(code).then(function() {
                    btn.textContent = 'Copied!';
                    setTimeout(function() { btn.textContent = 'Copy'; }, 1500);
                });
            }
            </script>
        </body>
        </html>
        """
    }
}
