import Foundation
import CoreGraphics

/// The frame the panel's window should have for content of a given height.
///
/// `MenuBarExtra` in its window style grows the panel when the content grows,
/// but never shrinks it: the window keeps the tallest height it reached, and
/// SwiftUI centres the shorter content in it, leaving transparent bands above
/// and below. SwiftUI is never offered that extra height, so no frame or
/// background can fill it — the window itself has to be sized. Once this code
/// has shrunk it, SwiftUI will not reliably enlarge it again either, so the
/// window follows the content both ways. `MenuContentView` applies it.
public enum PanelWindowFit {
    /// - Parameters:
    ///   - window: the window's current frame, in AppKit coordinates (origin at
    ///     the bottom left, growing upward).
    ///   - content: the measured size the content wants.
    ///   - screen: the usable area of the window's screen, to keep a window
    ///     that widens from running off its right edge.
    /// - Returns: the frame to set, or `nil` when there is nothing to do.
    public static func frame(window: CGRect, content: CGSize, screen: CGRect?) -> CGRect? {
        // Unmeasured content is not a size to fit to, and a sub-point
        // difference is rounding, not a change.
        guard content.width > 0, content.height > 0,
              abs(window.width - content.width) >= 1 || abs(window.height - content.height) >= 1
        else { return nil }
        // The top and left edges stay where they are, so the panel keeps
        // hanging from the menu bar where it opened; only its bottom and right
        // edges move — unless widening would take it past the screen's edge.
        var x = window.minX
        if let screen, x + content.width > screen.maxX {
            x = max(screen.minX, screen.maxX - content.width)
        }
        return CGRect(x: x, y: window.maxY - content.height, width: content.width, height: content.height)
    }
}
