import SwiftUI
import AppKit
import HeadroomCore

/// The menu bar indicator: one rounded rectangle per provider, filled from the
/// bottom up to that provider's best account. The empty space on top is,
/// literally, the headroom that is left.
///
/// The whole label is drawn as a single `NSImage`, text included, rather than
/// composed from SwiftUI views. A `MenuBarExtra` label renders only the first
/// element of a `ForEach` — measured: 31 pt for what should have been two
/// glyphs — so anything dynamic has to be one image by the time SwiftUI sees
/// it. Being a template image also gets it the correct colour in a light bar,
/// a dark bar and the highlighted state.
enum MenuBarIcon {
    /// Sized to match the system icons in the menu bar.
    private static let glyph = NSSize(width: 13, height: 16)
    private static let glyphToText: CGFloat = 3
    private static let betweenReadings: CGFloat = 7

    private static var textFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    }

    /// `AppModel` lives on the main actor, so reading its state has to be
    /// isolated to it — otherwise strict concurrency rejects the build.
    @MainActor
    static func label(for model: AppModel) -> some View {
        Image(nsImage: image(
            readings: model.menuBarReadings,
            showsPercent: model.showsPercentInMenuBar
        ))
    }

    static func image(readings: [MenuBarReading], showsPercent: Bool) -> NSImage {
        // No accounts at all still needs a glyph to click on.
        let parts: [(fill: Double?, text: String?)] = readings.isEmpty
            ? [(nil, nil)]
            : readings.map { (fill: $0.fill, text: showsPercent ? $0.text : nil) }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.black,
        ]

        var width: CGFloat = 0
        for (index, part) in parts.enumerated() {
            if index > 0 { width += betweenReadings }
            width += glyph.width
            if let text = part.text {
                width += glyphToText + (text as NSString).size(withAttributes: attributes).width
            }
        }

        let image = NSImage(size: NSSize(width: width, height: glyph.height), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, part) in parts.enumerated() {
                if index > 0 { x += betweenReadings }
                draw(fill: part.fill, in: NSRect(x: x, y: 0, width: glyph.width, height: glyph.height))
                x += glyph.width
                if let text = part.text {
                    x += glyphToText
                    let size = (text as NSString).size(withAttributes: attributes)
                    (text as NSString).draw(
                        at: NSPoint(x: x, y: (glyph.height - size.height) / 2),
                        withAttributes: attributes
                    )
                    x += size.width
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// `fill` ranges over 0...100; `nil` draws the outline alone, so missing
    /// data does not look like a completely empty account.
    private static func draw(fill: Double?, in rect: NSRect) {
        let body = rect.insetBy(dx: 1, dy: 1.5)
        let radius: CGFloat = 3.5

        let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        outline.lineWidth = 1.3
        NSColor.black.setStroke()
        outline.stroke()

        guard let fill, fill > 0 else { return }

        // The fill sits inside the outline, so the stroke stays legible even at
        // 100%.
        let inner = body.insetBy(dx: 1.6, dy: 1.6)
        let ratio = min(max(fill / 100, 0), 1)
        let height = inner.height * ratio
        guard height > 0.4 else { return }

        // Clipped to the inner shape so that at full level the corners are
        // rounded exactly like the outline.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inner, xRadius: radius - 1.6, yRadius: radius - 1.6).setClip()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
