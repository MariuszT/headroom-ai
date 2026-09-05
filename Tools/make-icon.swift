// Draws the app icon and writes an .icns next to the Info.plist.
//
// The icon is the menu bar glyph made large: a container with a level near the
// bottom and a lot of empty space above it. That empty space is the whole point
// of the app, so it is the whole point of the icon.
//
//     swift Tools/make-icon.swift Resources/AppIcon.icns
import AppKit

let side: CGFloat = 1024
// Apple's icon grid: the body sits in 824 of the 1024 canvas, leaving the
// margin the system expects, with a corner radius of about 185.
let bodyInset: CGFloat = 100
let bodyRadius: CGFloat = 185

func drawIcon(into size: CGFloat) -> NSImage {
    let scale = size / side
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.scaleBy(x: scale, y: scale)

        let body = NSRect(x: bodyInset, y: bodyInset, width: side - 2 * bodyInset, height: side - 2 * bodyInset)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: bodyRadius, yRadius: bodyRadius)

        // A quiet slate, so the glyph is what you see rather than the colour.
        NSGraphicsContext.saveGraphicsState()
        bodyPath.setClip()
        let background = NSGradient(
            starting: NSColor(srgbRed: 0.18, green: 0.21, blue: 0.27, alpha: 1),
            ending: NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        )!
        background.draw(in: body, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // The gauge, drawn like the menu bar glyph: an outline, filled from the
        // bottom, with the remaining space left visibly empty.
        // The menu bar glyph is 13 by 16, and the icon keeps that proportion so
        // the two read as the same object. Narrower than this and the outline
        // starts looking like a letter O at small sizes.
        let gauge = NSRect(x: 317, y: 272, width: 390, height: 480)
        let gaugeRadius: CGFloat = 118
        let stroke: CGFloat = 46

        let outline = NSBezierPath(roundedRect: gauge, xRadius: gaugeRadius, yRadius: gaugeRadius)
        outline.lineWidth = stroke
        NSColor.white.setStroke()
        outline.stroke()

        let inner = gauge.insetBy(dx: stroke, dy: stroke)
        let innerRadius = gaugeRadius - stroke
        let level: CGFloat = 0.36

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inner, xRadius: innerRadius, yRadius: innerRadius).setClip()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(
            x: inner.minX, y: inner.minY,
            width: inner.width, height: inner.height * level
        )).fill()
        NSGraphicsContext.restoreGraphicsState()

        return true
    }
    return image
}

func png(_ image: NSImage, _ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(into: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Headroom-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(point)x\(point).png" : "icon_\(point)x\(point)@2x.png"
    try! png(NSImage(), point * scale).write(to: iconset.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
