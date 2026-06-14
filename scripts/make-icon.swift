// Render a source square image into a macOS Big Sur-style app icon master:
// an 824pt rounded-rectangle tile centered in a 1024pt canvas (100pt margin)
// with a soft drop shadow. Output is a 1024x1024 PNG; the .icns is built from
// it by make-icon.sh via sips + iconutil.
//
// Usage: swift scripts/make-icon.swift <source.png> <out.png>
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <source.png> <out.png>\n".utf8))
    exit(1)
}
let srcPath = args[1]
let outPath = args[2]

let canvas: CGFloat = 1024          // full icon canvas
let tile: CGFloat = 824             // Apple's macOS icon tile size
let margin = (canvas - tile) / 2    // 100pt transparent margin all around
let radius: CGFloat = 185.4         // squircle-equivalent corner radius for 824 tile

guard let src = NSImage(contentsOfFile: srcPath) else {
    FileHandle.standardError.write(Data("error: cannot load \(srcPath)\n".utf8))
    exit(1)
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("error: cannot allocate bitmap\n".utf8))
    exit(1)
}
rep.size = NSSize(width: canvas, height: canvas)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("error: cannot create context\n".utf8))
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.interpolationQuality = .high
cg.setShouldAntialias(true)

cg.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let tileRect = NSRect(x: margin, y: margin, width: tile, height: tile)
let path = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)

// Soft drop shadow cast by the tile (y is up; negative offset = downward).
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 24,
             color: NSColor(white: 0, alpha: 0.35).cgColor)
NSColor.black.setFill()
path.fill()
cg.restoreGState()

// Clip to the rounded tile and draw the source art into it.
cg.saveGState()
path.addClip()
src.draw(in: tileRect, from: .zero, operation: .sourceOver, fraction: 1.0)
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: PNG encode failed\n".utf8))
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write(Data("error: write failed: \(error)\n".utf8))
    exit(1)
}
