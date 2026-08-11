// Draws the Burnline icon set and leaves it in build/Burnline.iconset.
// Run: swift Tools/make-icon.swift
//
// A rounded violet-on-near-black tile with a diagonal burn line — the portfolio
// wordmark pattern. AppKit only, so no external tooling is required.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512]
let iconset = URL(fileURLWithPath: "build/Burnline.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    NSColor(calibratedRed: 10 / 255, green: 10 / 255, blue: 15 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: side * 0.06, y: side * 0.06,
                                     width: side * 0.88, height: side * 0.88),
                 xRadius: side * 0.22, yRadius: side * 0.22).fill()

    NSColor(calibratedRed: 124 / 255, green: 92 / 255, blue: 255 / 255, alpha: 1).setStroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: side * 0.26, y: side * 0.30))
    line.line(to: NSPoint(x: side * 0.74, y: side * 0.70))
    line.lineWidth = max(1, side * 0.085)
    line.lineCapStyle = .round
    line.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

for size in sizes {
    if let data = draw(size: size) {
        try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    }
    if let retina = draw(size: size * 2) {
        try retina.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
}
print("wrote \(iconset.path)")
