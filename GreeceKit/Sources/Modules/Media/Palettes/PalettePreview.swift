import AppKit

enum PalettePreview {
    struct Payload: Encodable {
        var format: String
        var kind: String
        var name: String?
        var groups: [PaletteGroup]
        var columns: Int?
        var count: Int
    }

    static func load(_ file: FileInfo, format: PaletteFormat) throws -> Palette {
        try PaletteParser.parse(try file.mediaData(limit: 32 * 1024 * 1024), format: format)
    }

    static func prepare(_ file: FileInfo, format: PaletteFormat) throws -> PreparedPreview {
        let palette = try load(file, format: format)
        let name = palette.name ?? file.url.deletingPathExtension().lastPathComponent
        let payload = Payload(format: format.badge, kind: format.title, name: name, groups: palette.groups, columns: palette.columns, count: palette.count)
        let document = WebDocument(module: .init("media-palette"), data: payload,
                                   scripts: ["modules/media.common.js", "modules/media.palette.js"], styles: ["modules/media.css"])
        var details = [String(localized: "\(palette.count) colors", bundle: .greeceKit, comment: "Info bar detail: how many colours a palette has")]
        let named = palette.groups.filter { $0.name != nil }.count
        if named > 0 {
            details.append(String(localized: "\(named) groups", bundle: .greeceKit, comment: "Info bar detail: how many named groups of colours a palette has"))
        }
        let models = Set(palette.allColors.map(\.model))
        if models.count == 1, let model = models.first, model != "RGB" { details.append(displayName(model: model)) }
        let spots = palette.allColors.filter { $0.kind == "Spot" }.count
        if spots > 0 {
            details.append(String(localized: "\(spots) spot", bundle: .greeceKit,
                                  comment: "Info bar detail: how many of a palette’s colours are spot colours (printing inks), such as “3 spot”"))
        }
        let summary = FileSummary(symbol: "swatchpalette", title: format.title, details: details, trailing: file.modifiedText)
        return .web(document, summary, NSSize(width: 900, height: 700))
    }

    /// A colour model for the info bar. The model itself ("Gray", "CMYK") is an id the page reads.
    static func displayName(model: String) -> String {
        model == "Gray" ? String(localized: "Gray", bundle: .greeceKit, comment: "Info bar detail: the palette’s colours are shades of grey (a colour model, like RGB or CMYK)") : model
    }
}

/// The palette's colours as chips: bands for a handful, a grid for more.
enum PaletteThumbnail {
    static func make(_ file: FileInfo, format: PaletteFormat, size: CGSize) -> ThumbnailPage? {
        guard let palette = try? PalettePreview.load(file, format: format) else { return nil }
        let colors = palette.allColors.prefix(64).map { NSColor(srgbRed: CGFloat($0.rgb[0]) / 255, green: CGFloat($0.rgb[1]) / 255, blue: CGFloat($0.rgb[2]) / 255, alpha: 1) }
        guard !colors.isEmpty else { return nil }
        let side = max(16, min(size.width, size.height)).rounded()
        return ThumbnailPage(size: CGSize(width: side, height: side), badge: format.badge) { rect in
            NSColor.white.setFill()
            rect.fill()
            let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
            if colors.count <= 6 {
                // Paint chips: full-width bands.
                let gap = max(rect.height * 0.012, 0.5)
                let band = (inset.height - gap * CGFloat(colors.count - 1)) / CGFloat(colors.count)
                for (index, color) in colors.enumerated() {
                    let y = inset.maxY - CGFloat(index + 1) * band - CGFloat(index) * gap
                    chip(color, CGRect(x: inset.minX, y: y, width: inset.width, height: band), radius: rect.width * 0.025)
                }
            } else {
                let columns = Int(ceil(sqrt(Double(colors.count))))
                let rows = Int(ceil(Double(colors.count) / Double(columns)))
                let gap = rect.width * 0.018
                let cell = min((inset.width - gap * CGFloat(columns - 1)) / CGFloat(columns), (inset.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
                let width = cell * CGFloat(columns) + gap * CGFloat(columns - 1)
                let height = cell * CGFloat(rows) + gap * CGFloat(rows - 1)
                let origin = CGPoint(x: rect.midX - width / 2, y: rect.midY + height / 2)
                for (index, color) in colors.enumerated() {
                    let column = index % columns, row = index / columns
                    chip(color, CGRect(x: origin.x + CGFloat(column) * (cell + gap), y: origin.y - CGFloat(row + 1) * cell - CGFloat(row) * gap,
                                       width: cell, height: cell), radius: cell * 0.16)
                }
            }
        }
    }

    private static func chip(_ color: NSColor, _ rect: CGRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
        // A hairline keeps white and near-white chips visible on the white card.
        NSColor(white: 0, alpha: 0.08).setStroke()
        path.lineWidth = max(rect.width / 120, 0.5)
        path.stroke()
    }
}
