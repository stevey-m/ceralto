import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let mobile = CommandLine.arguments.contains("--ios")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let sizes = mobile ? [(512, 2)] : [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in sizes {
    let pixels = points * scale
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not allocate the Folio icon bitmap.")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let background = mobile ? NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        : NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196)
    NSColor(srgbRed: 0.18, green: 0.17, blue: 0.26, alpha: 1).setFill()
    background.fill()
    let cover = NSBezierPath(roundedRect: NSRect(x: 230, y: 170, width: 570, height: 690), xRadius: 56, yRadius: 56)
    NSColor(srgbRed: 0.63, green: 0.46, blue: 0.92, alpha: 1).setFill()
    cover.fill()
    let page = NSBezierPath(roundedRect: NSRect(x: 278, y: 194, width: 500, height: 642), xRadius: 34, yRadius: 34)
    NSColor(srgbRed: 0.98, green: 0.96, blue: 0.90, alpha: 1).setFill()
    page.fill()
    let bookmark = NSBezierPath()
    bookmark.move(to: NSPoint(x: 652, y: 836))
    bookmark.line(to: NSPoint(x: 716, y: 836))
    bookmark.line(to: NSPoint(x: 716, y: 664))
    bookmark.line(to: NSPoint(x: 684, y: 696))
    bookmark.line(to: NSPoint(x: 652, y: 664))
    bookmark.close()
    NSColor(srgbRed: 0.63, green: 0.46, blue: 0.92, alpha: 1).setFill()
    bookmark.fill()
    for (y, width) in [(620.0, 230.0), (506.0, 310.0), (392.0, 250.0)] {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 358, y: y))
        line.line(to: NSPoint(x: 358 + width, y: y))
        line.lineWidth = 28
        line.lineCapStyle = .round
        NSColor(srgbRed: 0.30, green: 0.28, blue: 0.38, alpha: 1).setStroke()
        line.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let output: NSBitmapImageRep
    if mobile {
        guard let source = bitmap.cgImage,
              let opaque = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                  bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            fatalError("Could not allocate the opaque iPad icon.")
        }
        opaque.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = opaque.makeImage() else { fatalError("Could not render the iPad icon.") }
        output = NSBitmapImageRep(cgImage: image)
    } else {
        output = bitmap
    }
    guard let png = output.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode the Folio icon.")
    }
    let suffix = scale == 2 ? "@2x" : ""
    let filename = mobile ? "AppIcon.png" : "icon_\(points)x\(points)\(suffix).png"
    try png.write(to: directory.appendingPathComponent(filename))
}
