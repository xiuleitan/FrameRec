import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let side = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let s = CGFloat(side) / 1024
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 60*s, y: 60*s, width: 904*s, height: 904*s), xRadius: 205*s, yRadius: 205*s).fill()
        NSColor(srgbRed: 0.25, green: 0.85, blue: 0.35, alpha: 1).setStroke()
        for (x, y, dx, dy) in [(270.0, 270.0, 1.0, 1.0), (754, 270, -1, 1), (270, 754, 1, -1), (754, 754, -1, -1)] {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: (x + dx*130)*s, y: y*s))
            path.line(to: CGPoint(x: x*s, y: y*s))
            path.line(to: CGPoint(x: x*s, y: (y + dy*130)*s))
            path.lineWidth = 52*s; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        }
        NSColor(calibratedRed: 1, green: 0.32, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 407*s, y: 407*s, width: 210*s, height: 210*s)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
