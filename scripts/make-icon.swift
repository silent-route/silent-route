// Draws the app icon: a white wireframe globe on a deep-blue-to-teal squircle.
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns
//
// Drawn in code rather than kept as a PNG so the icon can be changed with a
// diff, and rebuilt without design tools.

import AppKit

let size: CGFloat = 1024

func draw(in ctx: CGContext) {
    // macOS icon grid: an 824 pt squircle centred in the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.16, blue: 0.42, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.07, green: 0.12, blue: 0.36, alpha: 1),
        CGColor(red: 0.10, green: 0.36, blue: 0.72, alpha: 1),
        CGColor(red: 0.16, green: 0.74, blue: 0.80, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.minY),
                           end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])

    // Soft glow behind the globe.
    let c = CGPoint(x: size / 2, y: size / 2)
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.55, green: 0.95, blue: 1, alpha: 0.35),
        CGColor(red: 0.55, green: 0.95, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 380, options: [])

    // The globe.
    let r: CGFloat = 255
    let line: CGFloat = 26
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)

    let sphere = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    ctx.saveGState()
    ctx.addEllipse(in: sphere)
    ctx.clip()
    // Meridians: the central line and one ellipse.
    ctx.move(to: CGPoint(x: c.x, y: c.y - r))
    ctx.addLine(to: CGPoint(x: c.x, y: c.y + r))
    ctx.addEllipse(in: CGRect(x: c.x - r * 0.48, y: c.y - r, width: r * 0.96, height: 2 * r))
    // Parallels: the equator and two curved latitudes.
    ctx.move(to: CGPoint(x: c.x - r, y: c.y))
    ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
    for sign: CGFloat in [-1, 1] {
        let y = c.y + sign * r * 0.55
        let half = sqrt(r * r - (r * 0.55) * (r * 0.55))
        ctx.move(to: CGPoint(x: c.x - half, y: y))
        ctx.addQuadCurve(to: CGPoint(x: c.x + half, y: y),
                         control: CGPoint(x: c.x, y: y + sign * r * 0.12))
    }
    ctx.strokePath()
    ctx.restoreGState()
    ctx.setLineWidth(line * 1.15)
    ctx.addEllipse(in: sphere)
    ctx.strokePath()

    // Glass highlight across the top half of the tile.
    let shine = CGGradient(colorsSpace: space, colors: [
        CGColor(gray: 1, alpha: 0.28),
        CGColor(gray: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: c.x, y: tile.maxY),
                           end: CGPoint(x: c.x, y: tile.midY), options: [])
    ctx.restoreGState()

    // Thin inner rim, like light catching the edge of glass.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
    ctx.setLineWidth(6)
    ctx.strokePath()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    draw(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift OUT.icns\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[1])
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
