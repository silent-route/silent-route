// Draws the disk image window's background: a transparent strip with an
// arrow from where the app sits to where Applications sits, for any theme.
//
//   swift scripts/make-dmg-background.swift Resources/dmg-background.png
//
// Positions match scripts/dmg-settings.py. The strip is shorter than the
// window: Finder lets a window scroll to show all of its picture, and the
// tab bar or path bar some people keep on take part of the height. One
// size only: Finder (macOS 15) draws a Retina version at twice the size.

import AppKit

let width: CGFloat = 540, height: CGFloat = 200
/// Icon centres, from the top left (as Finder counts).
let appX: CGFloat = 145, appsX: CGFloat = 395, iconY: CGFloat = 132

func draw(in ctx: CGContext) {
    let y = height - iconY
    let from = appX + 64 + 26, to = appsX - 64 - 26
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.57, blue: 0.62, alpha: 1))
    ctx.setLineWidth(3.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: from, y: y))
    ctx.addLine(to: CGPoint(x: to, y: y))
    ctx.move(to: CGPoint(x: to - 11, y: y + 11))
    ctx.addLine(to: CGPoint(x: to, y: y))
    ctx.addLine(to: CGPoint(x: to - 11, y: y - 11))
    ctx.strokePath()
}

func png(scale: CGFloat, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        .retagging(with: .sRGB)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    draw(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift out.png\n".utf8))
    exit(2)
}
try png(scale: 1, to: URL(fileURLWithPath: CommandLine.arguments[1]))
