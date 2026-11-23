// Draws the installer window background: the same quiet layout as Murmur's.
//   swift scripts/dmg-background.swift <out.png>
import AppKit

let size = NSSize(width: 680, height: 420)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
func text(_ value: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let width = (value as NSString).size(withAttributes: attributes).width
    (value as NSString).draw(at: NSPoint(x: (size.width - width) / 2, y: y), withAttributes: attributes)
}
text("Greece", y: 350, font: .systemFont(ofSize: 34, weight: .semibold), color: .black)
text("A better look at your files.", y: 318, font: .systemFont(ofSize: 16), color: .darkGray)
let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)!
arrow.withSymbolConfiguration(.init(pointSize: 32, weight: .light))?.draw(in: NSRect(x: 320, y: 180, width: 40, height: 32))
text("Drag Greece to Applications", y: 62, font: .systemFont(ofSize: 17, weight: .medium), color: .black)
text("Then open Greece once to turn on its Quick Look previews.", y: 36, font: .systemFont(ofSize: 12), color: .darkGray)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
