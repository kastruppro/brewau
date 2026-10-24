import AppKit

// App icon: the brewau mark (branding/logo/final/brewau-app-icon*.svg) on Apple's 1024 grid.
// Geometry is in the mark's 256-unit space; sizes up to 32 px use the small cut.
let kedel = NSColor(srgbRed: 18 / 255, green: 52 / 255, blue: 59 / 255, alpha: 1)
let malt = NSColor(srgbRed: 242 / 255, green: 163 / 255, blue: 58 / 255, alpha: 1)
let skum = NSColor(srgbRed: 246 / 255, green: 241 / 255, blue: 231 / 255, alpha: 1)

func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

func drawMark(small: Bool) {
    let ring = small
        ? NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 224, height: 224), xRadius: 68, yRadius: 68)
        : NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 208, height: 208), xRadius: 64, yRadius: 64)
    ring.append(small
        ? NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 160, height: 160), xRadius: 36, yRadius: 36)
        : NSBezierPath(roundedRect: NSRect(x: 53, y: 53, width: 150, height: 150), xRadius: 35, yRadius: 35))
    ring.windingRule = .evenOdd
    skum.setFill()
    ring.fill()
    malt.setFill()
    let bubbles: [(CGFloat, CGFloat, CGFloat)] = small
        ? [(120, 96, 32), (146, 164, 21)]
        : [(120, 172, 10.25), (144, 136, 15.25), (124, 90, 21.25)]
    for (x, y, r) in bubbles { circle(x, y, r).fill() }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .retagging(with: .sRGB)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // Draw top-down in 1024 units, like the SVG masters.
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: CGFloat(size))
        transform.scale(by: CGFloat(size) / 1024)
        transform.scaleX(by: 1, yBy: -1)
        transform.concat()
        kedel.setFill()
        NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
        let markScale: CGFloat = 0.8 * 824 / 208, offset = (1024 - 256 * markScale) / 2
        let place = NSAffineTransform()
        place.translateX(by: offset, yBy: offset - 1024 * 0.012)
        place.scale(by: markScale)
        place.concat()
        drawMark(small: size <= 32)
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
