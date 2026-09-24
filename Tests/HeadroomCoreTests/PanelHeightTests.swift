import Testing
import Foundation
@testable import HeadroomCore

/// While everything fits, the list is exactly as tall as its content — no
/// scroll bar for a list that has room to spare.
@Test func aListThatFitsIsShownWhole() {
    #expect(PanelHeight.list(content: 620, chrome: 90, screen: 1000) == 620)
}

/// Only past the screen does the list stop growing, leaving room for the
/// banners, the footer and the gap under the menu bar.
@Test func aListTallerThanTheScreenStopsAtItsEdge() {
    #expect(PanelHeight.list(content: 2000, chrome: 90, screen: 1000) == 1000 - 90 - PanelHeight.screenMargin)
}

/// A tiny screen or a tall stack of banners must still leave a usable list,
/// never a negative or collapsed one.
@Test func theListNeverCollapses() {
    #expect(PanelHeight.list(content: 800, chrome: 700, screen: 600) == PanelHeight.minimumList)
    #expect(PanelHeight.list(content: 0, chrome: 90, screen: 1000) == 1)
}
