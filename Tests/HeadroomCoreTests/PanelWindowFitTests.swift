import Testing
import Foundation
import CoreGraphics
@testable import HeadroomCore

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

/// AppKit frames grow upward from their origin, so a panel hanging from the
/// menu bar keeps its place only if its TOP edge stays put.
@Test func aShorterContentShrinksTheWindowFromTheBottom() {
    let window = CGRect(x: 100, y: 200, width: 460, height: 600)
    let fitted = PanelWindowFit.frame(window: window, content: CGSize(width: 460, height: 450), screen: screen)
    #expect(fitted == CGRect(x: 100, y: 350, width: 460, height: 450))
    #expect(fitted?.maxY == window.maxY)
}

/// Taller content grows the window the same way, top edge pinned. Leaving
/// growth to SwiftUI alone is not safe once this code has sized the window:
/// nothing then makes SwiftUI enlarge it again, and the footer is cut off.
@Test func aTallerContentGrowsTheWindowDownward() {
    let window = CGRect(x: 0, y: 500, width: 300, height: 400)
    let fitted = PanelWindowFit.frame(window: window, content: CGSize(width: 300, height: 520), screen: screen)
    #expect(fitted == CGRect(x: 0, y: 380, width: 300, height: 520))
}

/// The panel widens to two columns once a second account arrives, and
/// narrows back when it leaves — the width follows as the height does.
@Test func theWidthFollowsTheContentWithTheLeftEdgePinned() {
    let window = CGRect(x: 200, y: 300, width: 380, height: 400)
    #expect(PanelWindowFit.frame(window: window, content: CGSize(width: 560, height: 400), screen: screen)
        == CGRect(x: 200, y: 300, width: 560, height: 400))
    let wide = CGRect(x: 200, y: 300, width: 560, height: 400)
    #expect(PanelWindowFit.frame(window: wide, content: CGSize(width: 380, height: 400), screen: screen)
        == CGRect(x: 200, y: 300, width: 380, height: 400))
}

/// A panel near the right edge that widens must not run off the screen.
@Test func aWiderWindowIsKeptOnTheScreen() {
    let window = CGRect(x: 1000, y: 300, width: 380, height: 400)
    let fitted = PanelWindowFit.frame(window: window, content: CGSize(width: 560, height: 400), screen: screen)
    #expect(fitted == CGRect(x: 880, y: 300, width: 560, height: 400))
}

/// Sub-point differences are rounding, not a change worth a resize.
@Test func aMatchingWindowIsLeftAlone() {
    let window = CGRect(x: 0, y: 0, width: 300, height: 400)
    #expect(PanelWindowFit.frame(window: window, content: CGSize(width: 300.4, height: 399.6), screen: screen) == nil)
}

/// A size not measured yet is not a size to fit to.
@Test func anUnmeasuredContentIsIgnored() {
    let window = CGRect(x: 0, y: 0, width: 300, height: 400)
    #expect(PanelWindowFit.frame(window: window, content: CGSize(width: 300, height: 0), screen: screen) == nil)
    #expect(PanelWindowFit.frame(window: window, content: CGSize(width: 0, height: 400), screen: screen) == nil)
}
