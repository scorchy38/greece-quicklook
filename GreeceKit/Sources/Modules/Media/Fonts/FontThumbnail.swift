import AppKit
import CoreText

/// An "Aa" card in the font itself, on its baseline and x-height guides, with the family name
/// underneath once there's room to read it. Icon fonts show a few of their icons instead.
enum FontThumbnail {
    static func make(_ file: FileInfo, size: CGSize) -> ThumbnailPage? {
        guard let data = try? file.mediaData(limit: 48 * 1024 * 1024), let info = try? FontFileInfo(data: data) else { return nil }
        let face = info.faces[0]
        let codepoints = face.codepoints(limit: 4000)
        let icon = FontFaceInfo.isIconFont(codepoints)
        let scripts = FontScripts.scripts(in: codepoints)
        let hero = FontPreview.chooseHero(covered: Set(codepoints), codepoints: codepoints, primary: scripts.first ?? "Latin", icon: icon)
        let name = info.faces.count > 1 ? face.family : face.fullName
        let side = max(16, min(size.width, size.height)).rounded()
        let badge = file.ext.isEmpty ? "FONT" : file.ext.uppercased()
        let iconGlyphs = icon ? codepoints.filter { $0 >= 0xE000 }.prefix(9).map { $0 } : []

        return ThumbnailPage(size: CGSize(width: side, height: side), badge: badge) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            NSColor.white.setFill()
            rect.fill()
            if icon {
                drawIcons(iconGlyphs, face: face, in: rect, context: context)
            } else {
                drawHero(hero, face: face, in: rect, showsName: side >= 96, name: name, context: context)
            }
        }
    }

    private static func drawHero(_ hero: String, face: FontFaceInfo, in rect: CGRect, showsName: Bool, name: String, context: CGContext) {
        let upm = CGFloat(max(face.unitsPerEm, 1))
        let font = face.font
        let capHeight = max(CTFontGetCapHeight(font), upm * 0.5) / upm
        let xHeight = max(CTFontGetXHeight(font), upm * 0.3) / upm
        let descent = CTFontGetDescent(font) / upm

        let nameBand = showsName ? rect.height * 0.22 : 0
        let area = rect.insetBy(dx: rect.width * 0.12, dy: 0)
        let usable = rect.height - nameBand
        var pointSize = usable * 0.5 / capHeight
        var line = makeLine(hero, font: font, size: pointSize)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        if width > area.width { pointSize *= area.width / width; line = makeLine(hero, font: font, size: pointSize) }
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)

        // The cap height sits in the middle of the space above the name, nudged up a little so
        // descenders have room; "Aa" reads as centred.
        let capBand = capHeight * pointSize
        let baseline = rect.minY + nameBand + (usable - capBand) / 2 + min(descent * pointSize, usable * 0.08) * 0.5

        let guide = NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 0.28)
        context.setFillColor(guide.cgColor)
        let hairline = max(rect.height / 320, 0.5)
        for y in [baseline, baseline + xHeight * pointSize, baseline + capHeight * pointSize] {
            context.fill(CGRect(x: rect.minX, y: y - hairline / 2, width: rect.width, height: hairline))
        }

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.midX - lineWidth / 2, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()

        guard showsName else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: rect.height * 0.062, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1),
            .paragraphStyle: style,
        ])
        let labelHeight = rect.height * 0.09
        label.draw(with: CGRect(x: rect.minX + rect.width * 0.08, y: rect.minY + nameBand * 0.38, width: rect.width * 0.84, height: labelHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func drawIcons(_ codepoints: [Int], face: FontFaceInfo, in rect: CGRect, context: CGContext) {
        guard !codepoints.isEmpty else { return }
        let columns = codepoints.count >= 9 ? 3 : codepoints.count >= 4 ? 2 : 1
        let cell = rect.width * 0.8 / CGFloat(columns)
        let origin = CGPoint(x: rect.midX - cell * CGFloat(columns) / 2, y: rect.midY + cell * CGFloat(columns) / 2)
        let upm = CGFloat(max(face.unitsPerEm, 1))
        let pointSize = cell * 0.62 * upm / max(CTFontGetAscent(face.font) + CTFontGetDescent(face.font), upm * 0.5)
        context.saveGState()
        context.textMatrix = .identity
        for (index, codepoint) in codepoints.prefix(columns * columns).enumerated() {
            guard let scalar = Unicode.Scalar(UInt32(codepoint)) else { continue }
            let line = makeLine(String(Character(scalar)), font: face.font, size: pointSize, color: NSColor(white: 0.12, alpha: 1))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            let center = CGPoint(x: origin.x + (column + 0.5) * cell, y: origin.y - (row + 0.5) * cell)
            context.textPosition = CGPoint(x: center.x - width / 2, y: center.y - (ascent - descent) / 2)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    private static func makeLine(_ text: String, font: CTFont, size: CGFloat, color: NSColor = NSColor(white: 0.08, alpha: 1)) -> CTLine {
        let sized = CTFontCreateCopyWithAttributes(font, max(size, 1), nil, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): sized,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }
}
