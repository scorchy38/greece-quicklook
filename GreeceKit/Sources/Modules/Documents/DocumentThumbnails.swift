import AppKit

/// Finder thumbnails for documents, drawn natively: a typeset first page for LaTeX, a title
/// slide for Beamer, a references card for BibTeX, the cover for EPUB, a reading page for Org,
/// AsciiDoc and reStructuredText, and the figure itself for PGF.
enum DocumentThumbnails {
    static func page(for file: FileInfo, format: DocumentsModule.Format, size: CGSize, settings: PreviewSettings) -> ThumbnailPage? {
        switch format {
        case .epub:
            return epub(file, size: size)
        case .pgf:
            return pgf(file, size: size)
        case .bibtex:
            guard let text = try? TextFile(url: file.url, limit: 512 * 1024) else { return nil }
            let entries = BibTeX.parse(text.text, limit: 40).entries
            guard !entries.isEmpty else { return nil }
            return ThumbnailPage(size: Thumbnailer.pageSize(fitting: size), badge: "BIB") { rect in References.draw(entries, in: rect) }
        case .latex, .sweave:
            guard let text = try? TextFile(url: file.url, limit: 1024 * 1024) else { return nil }
            var source = text.text
            if format == .sweave { source = Sweave.latex(source) }
            let paper = Paper(source)
            if paper.isBeamer {
                let slide = fit(CGSize(width: 16, height: 9), in: size)
                return ThumbnailPage(size: slide, badge: "TEX") { rect in Slide.draw(paper, in: rect) }
            }
            guard !paper.isEmpty else { return nil }
            return ThumbnailPage(size: Thumbnailer.pageSize(fitting: size), badge: format == .sweave ? "RNW" : "TEX") { rect in paper.draw(in: rect) }
        case .typst:
            guard let text = try? TextFile(url: file.url, limit: 48 * 1024) else { return nil }
            return ThumbnailPage(size: Thumbnailer.pageSize(fitting: size), badge: "TYP") { rect in
                CodePage.draw(text.text, grammar: "typst", in: rect, theme: settings.codeTheme)
            }
        case .mermaid:
            guard let text = try? TextFile(url: file.url, limit: 48 * 1024) else { return nil }
            let badge = file.ext.uppercased() == "MERMAID" ? "MMD" : file.ext.uppercased()
            return ThumbnailPage(size: Thumbnailer.pageSize(fitting: size), badge: badge) { rect in
                CodePage.draw(text.text, grammar: "plaintext", in: rect, theme: settings.codeTheme)
            }
        case .org, .asciidoc, .rst, .quarto, .rmarkdown, .livebook, .multiMarkdown:
            guard let text = try? TextFile(url: file.url, limit: 64 * 1024) else { return nil }
            let doc = ProsePreview.convert(text.text, format: format)
            var markdown = ""
            if let title = doc.title { markdown += "# \(title)\n\n" }
            if let subtitle = doc.subtitle { markdown += "*\(subtitle)*\n\n" }
            markdown += unescape(doc.markdown)
            let badges: [DocumentsModule.Format: String] = [.org: "ORG", .asciidoc: "ADOC", .rst: "RST", .quarto: "QMD", .rmarkdown: "RMD", .livebook: "LIVEMD", .multiMarkdown: "MMD"]
            return ThumbnailPage(size: Thumbnailer.pageSize(fitting: size), badge: badges[format] ?? file.ext.uppercased()) { rect in
                MarkdownPage.draw(markdown, in: rect, palette: settings.codeTheme.light)
            }
        }
    }

    /// Markdown for the page drawer: escapes and chips dropped, soft-wrapped lines joined into
    /// paragraphs, list numbers counted, callout markers and footnote marks removed.
    static func unescape(_ markdown: String) -> String {
        let cleaned = markdown.replacingOccurrences(of: #"\\([\\`*_\[\]<>#|$~!&])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"<div class="(chunk-meta|org-properties|org-planning)[^"]*">.*</div>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[\^[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\^\[[^\]]*\]"#, with: "", options: .regularExpression)
        var out: [String] = []
        var fence = false
        var number = 0
        for raw in cleaned.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence.toggle(); out.append(raw); continue }
            if fence { out.append(raw); continue }
            if line == ">" || line.range(of: #"^> \[!\w+\]$"#, options: .regularExpression) != nil { continue }
            if let m = line.range(of: #"^\d+\. "#, options: .regularExpression), raw.hasPrefix(line.prefix(1)) {
                number += 1
                out.append("\(number). " + line[m.upperBound...])
                continue
            }
            if !line.hasPrefix("- ") && !line.hasPrefix("* ") { number = line.isEmpty ? number : 0 }
            let blockTag = line.range(of: #"^</?(div|aside|p|dl|dt|dd|table|a id)\b"#, options: .regularExpression) != nil
            // Quote lines continue the quote above them.
            if line.hasPrefix("> "), let last = out.last, last.hasPrefix("> "), !last.hasPrefix("> **") {
                out[out.count - 1] = last + " " + line.dropFirst(2)
                continue
            }
            let structural = line.isEmpty || line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("|")
                || line.hasPrefix(">") || blockTag || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            if !structural, let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty, !last.hasPrefix("#"), !last.hasPrefix("|"),
               !last.hasPrefix("```"), !last.hasPrefix(">"), last.range(of: #"^</?(div|aside|p|dl|dt|dd|table|a id)\b"#, options: .regularExpression) == nil,
               !last.hasSuffix("<br>") {
                out[out.count - 1] = last + " " + line
            } else {
                out.append(raw)
            }
        }
        return out.joined(separator: "\n")
    }

    static func fit(_ aspect: CGSize, in maximum: CGSize) -> CGSize {
        let scale = min(maximum.width / aspect.width, maximum.height / aspect.height)
        return CGSize(width: (aspect.width * scale).rounded(), height: (aspect.height * scale).rounded())
    }

    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = font.fontDescriptor.withDesign(.serif) { font = NSFont(descriptor: descriptor, size: size) ?? font }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1)
    static let hairline = NSColor(white: 0.86, alpha: 1)

    static func paragraph(alignment: NSTextAlignment = .natural, spacingBefore: CGFloat = 0, spacing: CGFloat = 0, indent: CGFloat = 0,
                          head: CGFloat = 0, tail: CGFloat = 0, lineHeight: CGFloat = 1.25) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacing
        style.firstLineHeadIndent = head + indent
        style.headIndent = head
        style.tailIndent = tail == 0 ? 0 : -tail
        style.lineHeightMultiple = lineHeight
        style.hyphenationFactor = 0.9
        style.lineBreakMode = .byWordWrapping
        return style
    }

    // MARK: - LaTeX paper

    struct Paper {
        var title: String?
        var authors: [String] = []
        var date: String?
        var abstract: String?
        var sections: [(title: String, number: String?, text: String)] = []
        var isBeamer = false
        var subtitle: String?
        var institute: String?

        var isEmpty: Bool { title == nil && abstract == nil && sections.isEmpty }

        init(_ source: String) {
            let text = TeXText.stripComments(source)
            isBeamer = text.range(of: #"\\documentclass\s*(\[[^\]]*\])?\s*\{beamer\}"#, options: .regularExpression) != nil
            title = TeXText.argument(of: "title", in: text).map { TeXText.tidy(TeXText.plain(removeThanks($0))) }.flatMap { $0.isEmpty ? nil : $0 }
            subtitle = TeXText.argument(of: "subtitle", in: text).map { TeXText.tidy(TeXText.plain($0)) }
            institute = TeXText.argument(of: "institute", in: text).map { TeXText.tidy(TeXText.plain($0.components(separatedBy: "\\\\").first ?? $0)) }
            authors = TeXText.argument(of: "author", in: text).map(TeXText.authors) ?? []
            if let raw = TeXText.argument(of: "date", in: text) {
                let plain = TeXText.tidy(TeXText.plain(raw))
                date = raw.contains("\\today") ? MD.todayLong() : (plain.isEmpty ? nil : plain)
            }
            abstract = TeXText.environment("abstract", in: text).map { TeXText.tidy(TeXText.plain(stripFloats($0))) }
            let body = TeXText.body(text)
            let regex = try! NSRegularExpression(pattern: #"\\(section|chapter)\*?\s*(\[[^\]]*\])?\s*\{"#)
            let starts = regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).prefix(4).compactMap { Range($0.range, in: body)?.lowerBound }
            var number = 0
            for (k, start) in starts.enumerated() {
                let segmentEnd = k + 1 < starts.count ? starts[k + 1] : body.endIndex
                let segment = String(body[start..<segmentEnd].prefix(8000))
                let command = segment.hasPrefix("\\chapter") ? "chapter" : "section"
                guard let heading = TeXText.argument(of: command, in: segment), let headingRange = segment.range(of: heading) else { continue }
                let starred = segment.dropFirst(command.count + 1).hasPrefix("*")
                if !starred { number += 1 }
                var rest = segment[headingRange.upperBound...]
                if rest.hasPrefix("}") { rest = rest.dropFirst() }
                let paragraph = TeXText.tidy(TeXText.plain(stripFloats(String(rest))), paragraphs: true)
                sections.append((TeXText.tidy(TeXText.plain(heading)), starred ? nil : "\(number)", paragraph))
            }
            if sections.isEmpty, title == nil {
                let paragraph = TeXText.tidy(TeXText.plain(stripFloats(String(body.prefix(6000)))), paragraphs: true)
                if !paragraph.isEmpty { sections.append(("", nil, paragraph)) }
            }
        }

        private func removeThanks(_ s: String) -> String {
            s.replacingOccurrences(of: #"\\thanks\s*\{[^{}]*(\{[^{}]*\}[^{}]*)*\}"#, with: "", options: .regularExpression)
        }

        private func stripFloats(_ s: String) -> String {
            var text = s
            for env in ["figure", "figure*", "table", "table*", "equation", "equation*", "align", "align*", "lstlisting", "verbatim", "tikzpicture", "itemize", "enumerate", "tabular", "algorithm"] {
                let e = NSRegularExpression.escapedPattern(for: env)
                text = text.replacingOccurrences(of: "\\\\begin\\{\(e)\\}[\\s\\S]*?\\\\end\\{\(e)\\}", with: " ", options: .regularExpression)
            }
            text = text.replacingOccurrences(of: #"[~ ]*\\(label|cite[pt]?|citealp|citeauthor|parencite|textcite|footnote)\s*(\[[^\]]*\])*\{[^}]*\}"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"[~ ]*\\(ref|eqref|autoref|cref|Cref)\s*\{[^}]*\}"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\\(sub)*section\*?\{[^}]*\}"#, with: "\n\n", options: .regularExpression)
            return text
        }

        func draw(in rect: CGRect) {
            NSColor.white.setFill()
            rect.fill()
            let margin = rect.width * 0.11
            let body = max(rect.width / 46, 1)
            let output = NSMutableAttributedString()
            func add(_ text: String, _ font: NSFont, _ color: NSColor = ink, _ style: NSParagraphStyle) {
                output.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
            }
            if let title {
                add(title, serif(body * 1.9, weight: .semibold), ink, paragraph(alignment: .center, spacingBefore: body * 1.2, spacing: body * 0.9, lineHeight: 1.08))
                if !authors.isEmpty { add(authors.joined(separator: "     "), serif(body * 1.15), ink, paragraph(alignment: .center, spacing: body * 0.45)) }
                if let date { add(date, serif(body * 1.05), secondary, paragraph(alignment: .center, spacing: body * 0.6)) }
            }
            if let abstract, !abstract.isEmpty {
                add(String(localized: "Abstract", bundle: .greeceKit, comment: "Heading above a paper’s abstract on a LaTeX thumbnail"), serif(body * 0.92, weight: .semibold), ink, paragraph(alignment: .center, spacingBefore: body * 0.9, spacing: body * 0.35))
                add(abstract, serif(body * 0.9), ink, paragraph(alignment: .justified, spacing: body * 0.6, head: body * 2.6, tail: body * 2.6, lineHeight: 1.18))
            }
            for section in sections {
                if !section.title.isEmpty {
                    let heading = (section.number.map { $0 + "   " } ?? "") + section.title
                    add(heading, serif(body * 1.22, weight: .semibold), ink, paragraph(spacingBefore: body * 1.1, spacing: body * 0.5))
                }
                for (index, para) in section.text.components(separatedBy: "\n").prefix(6).enumerated() where !para.isEmpty {
                    add(para, serif(body), ink, paragraph(alignment: .justified, spacing: 0, indent: index == 0 ? 0 : body * 1.4, lineHeight: 1.2))
                }
            }
            output.draw(with: rect.insetBy(dx: margin, dy: margin * 0.95), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // MARK: - Beamer

    enum Slide {
        static func draw(_ paper: Paper, in rect: CGRect) {
            NSColor(srgbRed: 0.98, green: 0.98, blue: 0.985, alpha: 1).setFill()
            rect.fill()
            let unit = rect.width / 40
            // A quiet accent bar, like a title frame.
            NSColor(srgbRed: 0.0, green: 0.48, blue: 1, alpha: 1).setFill()
            CGRect(x: rect.minX + unit * 2.6, y: rect.midY - unit * 0.6, width: unit * 4, height: max(1, unit * 0.16)).fill()
            let output = NSMutableAttributedString()
            let left = paragraph(alignment: .left, spacing: unit * 0.4, lineHeight: 1.05)
            if let title = paper.title {
                output.append(NSAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: unit * 2.1, weight: .bold), .foregroundColor: ink, .paragraphStyle: left]))
            }
            if let subtitle = paper.subtitle {
                output.append(NSAttributedString(string: subtitle + "\n", attributes: [.font: NSFont.systemFont(ofSize: unit * 1.25), .foregroundColor: secondary, .paragraphStyle: left]))
            }
            let textHeight = output.boundingRect(with: CGSize(width: rect.width - unit * 5.2, height: rect.height), options: [.usesLineFragmentOrigin]).height
            output.draw(with: CGRect(x: rect.minX + unit * 2.6, y: rect.midY + unit * 0.4, width: rect.width - unit * 5.2, height: min(textHeight, rect.height / 2 - unit)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let meta = NSMutableAttributedString()
            let names = paper.authors.joined(separator: ", ")
            if !names.isEmpty { meta.append(NSAttributedString(string: names + "\n", attributes: [.font: NSFont.systemFont(ofSize: unit * 1.05, weight: .medium), .foregroundColor: ink, .paragraphStyle: left])) }
            if let institute = paper.institute { meta.append(NSAttributedString(string: institute + "\n", attributes: [.font: NSFont.systemFont(ofSize: unit * 0.95), .foregroundColor: secondary, .paragraphStyle: left])) }
            if let date = paper.date { meta.append(NSAttributedString(string: date, attributes: [.font: NSFont.systemFont(ofSize: unit * 0.95), .foregroundColor: secondary, .paragraphStyle: left])) }
            meta.draw(with: CGRect(x: rect.minX + unit * 2.6, y: rect.minY + unit * 2, width: rect.width - unit * 5.2, height: rect.height / 2 - unit * 3.4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // MARK: - BibTeX

    enum References {
        static func draw(_ entries: [BibEntry], in rect: CGRect) {
            NSColor.white.setFill()
            rect.fill()
            let margin = rect.width * 0.085
            let body = max(rect.width / 34, 1)
            var y = rect.maxY - margin
            let width = rect.width - margin * 2
            let title = NSAttributedString(string: String(localized: "References", bundle: .greeceKit, comment: "Heading on a BibTeX file’s thumbnail"), attributes: [.font: NSFont.systemFont(ofSize: body * 1.45, weight: .bold), .foregroundColor: ink])
            title.draw(at: CGPoint(x: rect.minX + margin, y: y - body * 1.6))
            y -= body * 2.5
            let accent = NSColor(srgbRed: 0.0, green: 0.42, blue: 0.9, alpha: 1)
            for entry in entries {
                guard y > rect.minY + margin else { break }
                hairline.setFill()
                CGRect(x: rect.minX + margin, y: y, width: width, height: max(0.5, rect.width / 600)).fill()
                y -= body * 0.55
                let type = BibTeX.typeName(entry.type)?.localizedUppercase ?? entry.type.uppercased()
                let label = NSMutableAttributedString()
                label.append(NSAttributedString(string: BibTeX.shortCitation(entry), attributes: [.font: NSFont.systemFont(ofSize: body * 0.92, weight: .semibold), .foregroundColor: ink]))
                label.append(NSAttributedString(string: "   " + type, attributes: [.font: NSFont.systemFont(ofSize: body * 0.62, weight: .semibold), .foregroundColor: accent, .kern: body * 0.03]))
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                label.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: label.length))
                label.draw(with: CGRect(x: rect.minX + margin, y: y - body * 1.2, width: width, height: body * 1.25), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                y -= body * 1.25
                if let t = entry.plain("title") {
                    let titleStyle = NSMutableParagraphStyle()
                    titleStyle.lineBreakMode = .byWordWrapping
                    titleStyle.lineHeightMultiple = 1.08
                    let text = NSAttributedString(string: t, attributes: [.font: serif(body * 0.98), .foregroundColor: ink, .paragraphStyle: titleStyle])
                    let height = min(text.boundingRect(with: CGSize(width: width, height: body * 3), options: [.usesLineFragmentOrigin]).height, body * 2.6)
                    text.draw(with: CGRect(x: rect.minX + margin, y: y - height, width: width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                    y -= height + body * 0.15
                }
                let key = NSAttributedString(string: entry.key, attributes: [.font: NSFont.monospacedSystemFont(ofSize: body * 0.7, weight: .regular), .foregroundColor: secondary])
                key.draw(with: CGRect(x: rect.minX + margin, y: y - body * 0.95, width: width, height: body), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                y -= body * 1.5
            }
        }
    }

    // MARK: - EPUB

    static func epub(_ file: FileInfo, size: CGSize) -> ThumbnailPage? {
        guard let book = try? EPUBBook(url: file.url) else { return nil }
        if let path = book.coverPath, let data = book.archive.contents(named: path, limit: 24 << 20),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) * 2,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            let pageSize = fit(CGSize(width: image.width, height: image.height), in: size)
            return ThumbnailPage(size: pageSize, badge: "EPUB") { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                context.interpolationQuality = .high
                context.draw(image, in: rect)
                // A soft spine on the left edge, so it reads as a book.
                let spine = rect.width * 0.035
                let colors = [CGColor(gray: 0, alpha: 0.22), CGColor(gray: 1, alpha: 0.12), CGColor(gray: 0, alpha: 0)] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.45, 1]) {
                    context.saveGState()
                    context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: spine * 1.6, height: rect.height))
                    context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.minX + spine * 1.6, y: 0), options: [])
                    context.restoreGState()
                }
            }
        }
        // No cover: set one in type.
        let title = book.title.isEmpty ? file.url.deletingPathExtension().lastPathComponent : book.title
        let author = book.creators.map(\.name).joined(separator: ", ")
        return ThumbnailPage(size: fit(CGSize(width: 2, height: 3), in: size), badge: "EPUB") { rect in
            NSColor(srgbRed: 0.16, green: 0.2, blue: 0.27, alpha: 1).setFill()
            rect.fill()
            let unit = rect.width / 16
            NSColor(srgbRed: 0.85, green: 0.72, blue: 0.48, alpha: 1).setFill()
            CGRect(x: rect.minX + unit * 2, y: rect.maxY - unit * 6.2, width: unit * 3, height: max(1, unit * 0.12)).fill()
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(string: title + "\n", attributes: [.font: serif(unit * 1.7, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph(spacing: unit * 0.8, lineHeight: 1.05)]))
            text.append(NSAttributedString(string: author, attributes: [.font: serif(unit * 0.95, italic: true), .foregroundColor: NSColor(white: 1, alpha: 0.75)]))
            text.draw(with: CGRect(x: rect.minX + unit * 2, y: rect.minY + unit * 2, width: rect.width - unit * 4, height: rect.height - unit * 8.8), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // MARK: - PGF

    static func pgf(_ file: FileInfo, size: CGSize) -> ThumbnailPage? {
        guard let text = try? TextFile(url: file.url, limit: 8 * 1024 * 1024).text,
              let picture = PGF.parse(text, image: { name in try? Data(contentsOf: file.url.deletingLastPathComponent().appendingPathComponent(name)) }) else { return nil }
        let pageSize = fit(CGSize(width: max(picture.bounds.width, 1), height: max(picture.bounds.height, 1)), in: size)
        return ThumbnailPage(size: pageSize, badge: "PGF") { rect in
            NSColor.white.setFill()
            rect.fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            PGF.draw(picture, in: rect, context: context)
        }
    }
}
