import AppKit

/// A frame of the animation drawn natively (shapes, fills, strokes, gradients, transforms and
/// precomps), or a quiet card when the animation needs more than that to look right.
enum LottieThumbnail {
    static func make(_ file: FileInfo, packaged: Bool, size: CGSize) -> ThumbnailPage? {
        guard let (payload, animations) = try? LottiePreview.load(file, packaged: packaged), let json = animations.first,
              let animation = payload.animations.first else { return nil }
        let aspect = animation.width / animation.height
        var target = size
        if aspect >= 1 { target.height = max(1, (size.width / aspect).rounded()) } else { target.width = max(1, (size.height * aspect).rounded()) }
        let renderer = LottieRenderer(json: json)
        let frame = renderer?.representativeFrame()
        return ThumbnailPage(size: target, badge: packaged ? "LOTTIE" : "JSON") { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            if let renderer, let frame {
                renderer.draw(frame: frame, in: rect, context: context)
            } else {
                card(animation, in: rect, context: context)
            }
        }
    }

    private static func card(_ animation: LottiePreview.Animation, in rect: CGRect, context: CGContext) {
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
        rect.fill()
        let side = min(rect.width, rect.height)
        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.3, weight: .light)
            .applying(.init(paletteColors: [NSColor(srgbRed: 0.0, green: 0.48, blue: 1, alpha: 1)]))
        if let symbol = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let size = symbol.size
            symbol.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + side * 0.06, width: size.width, height: size.height))
        }
        guard side >= 96 else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = "\(SVGPreview.format(animation.width))×\(SVGPreview.format(animation.height))  ·  \(animation.duration.formatted(.number.precision(.fractionLength(1)))) s"
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: side * 0.065, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1), .paragraphStyle: style,
        ]).draw(with: CGRect(x: rect.minX, y: rect.midY - side * 0.32, width: rect.width, height: side * 0.1), options: .usesLineFragmentOrigin)
    }
}
