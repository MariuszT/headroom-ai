import Foundation

/// How tall the account list may be.
///
/// The panel sizes itself to its content, so the list decides the panel's
/// height. It used to stop at a fixed 460 points, which put a scroll bar on
/// lists that had the whole screen to grow into. Now it grows until the panel
/// would run past the bottom of the screen, and only then scrolls.
public enum PanelHeight {
    /// Room kept free under the menu bar and above the Dock, so the panel's
    /// edge and shadow do not touch either.
    public static let screenMargin: CGFloat = 16
    /// However little the screen leaves, a list shorter than this is not a
    /// list anyone can use.
    public static let minimumList: CGFloat = 160

    /// - Parameters:
    ///   - content: the measured height of every cell together.
    ///   - chrome: everything else in the panel — banners, divider, footer.
    ///   - screen: the height of the screen's usable area, menu bar and Dock
    ///     already taken off.
    public static func list(content: CGFloat, chrome: CGFloat, screen: CGFloat) -> CGFloat {
        let room = max(screen - chrome - screenMargin, minimumList)
        // At least one point: a zero-height ScrollView inside a panel that
        // sizes to its content never gets measured again.
        return max(min(content, room), 1)
    }
}
