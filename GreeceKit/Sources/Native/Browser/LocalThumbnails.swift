import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Thumbnails for the icons view, drawn in this process. Inside a Quick Look extension the
/// system's thumbnail service refuses the connection (`QLThumbnailGenerator` fails with Cocoa
/// error 4099), so Greece draws them itself: pictures through ImageIO, a PDF's first page, a
/// frame of a movie, and Greece's own Finder thumbnails for everything it previews (code,
/// Markdown, tables, maps, models, fonts, packages…). Framed like Finder's icon-mode thumbnails.
enum LocalThumbnails {
    static func image(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        let type = UTType(filenameExtension: url.pathExtension)
        let pixels = Int(side * scale)
        var content: CGImage?
        var plain = false
        if let type, type.conforms(to: .image) {
            content = picture(url, pixels: pixels)
            // A picture with transparency (an icon, a logo) shows as it is, without a frame.
            plain = content.map { [.premultipliedFirst, .premultipliedLast, .first, .last].contains($0.alphaInfo) } ?? false
        }
        else if let type, type.conforms(to: .pdf) { content = pdf(url, pixels: pixels) }
        else if let type, type.conforms(to: .audiovisualContent), !type.conforms(to: .audio) { content = await movie(url, pixels: pixels) }
        if content == nil, !Task.isCancelled { content = greece(url, side: side, scale: scale) }
        guard let content, !Task.isCancelled else { return nil }
        return framed(content, side: side, scale: scale, plain: plain)
    }

    // MARK: - Sources

    private static func picture(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary)
    }

    private static func pdf(_ url: URL, pixels: Int) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let fit = CGFloat(pixels) / max(box.width, box.height)
        let size = CGSize(width: (box.width * fit).rounded(), height: (box.height * fit).rounded())
        guard let context = bitmap(size) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: fit, y: fit)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func movie(_ url: URL, pixels: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        // A frame a little way in: the first is often black.
        let time = CMTime(seconds: duration > 2 ? min(duration * 0.1, 10) : 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    /// The thumbnail Greece's own extension gives Finder for this file.
    private static func greece(_ url: URL, side: CGFloat, scale: CGFloat) -> CGImage? {
        guard let page = Thumbnailer.page(for: url, maximumSize: CGSize(width: side, height: side), settings: SettingsStore.current()),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(page.size.width * scale), pixelsHigh: Int(page.size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = page.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        page.draw()
        return rep.cgImage
    }

    // MARK: - Frame

    /// The image fitted into a square, with a hairline edge and a soft shadow, as Finder frames
    /// document and picture thumbnails in its icon view.
    static func framed(_ image: CGImage, side: CGFloat, scale: CGFloat, plain: Bool = false) -> NSImage? {
        let canvas = CGSize(width: side * scale, height: side * scale)
        guard let context = bitmap(canvas) else { return nil }
        let inset = 3 * scale
        let room = CGSize(width: canvas.width - inset * 2, height: canvas.height - inset * 2)
        // Never larger than the image itself, as in Finder.
        let fit = min(room.width / CGFloat(image.width), room.height / CGFloat(image.height), 1)
        let size = CGSize(width: (CGFloat(image.width) * fit).rounded(), height: (CGFloat(image.height) * fit).rounded())
        let rect = CGRect(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        context.interpolationQuality = .high
        if plain {
            context.draw(image, in: rect)
            return context.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: side, height: side)) }
        }
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -0.5 * scale), blur: 2 * scale, color: CGColor(gray: 0, alpha: 0.28))
        context.setFillColor(.white)
        context.fill(rect)
        context.restoreGState()
        context.draw(image, in: rect)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        context.setLineWidth(max(1, scale / 2))
        context.stroke(rect.insetBy(dx: 0.25 * scale, dy: 0.25 * scale))
        guard let framed = context.makeImage() else { return nil }
        return NSImage(cgImage: framed, size: CGSize(width: side, height: side))
    }

    private static func bitmap(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
