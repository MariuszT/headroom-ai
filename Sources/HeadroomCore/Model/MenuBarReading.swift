import Foundation

/// What the one number in the menu bar is supposed to answer.
///
/// These are three genuinely different questions, not three ways of phrasing
/// one. Which is right depends on how you work, so it is a setting rather than
/// a decision made for everyone.
///
/// Two candidates were deliberately left out. An AVERAGE across accounts
/// describes no account you could actually use — you work on one at a time, and
/// the mean of a full account and an empty one is a number matching neither.
/// TOTAL remaining capacity has the same defect and adds another: accounts sit
/// on different plans, so their percentages are not the same unit and summing
/// them is arithmetic on incomparable things.
public enum MenuBarMetric: String, Codable, Sendable, CaseIterable, Identifiable {
    /// "Is there somewhere fresh to work?" — the account you would switch to.
    case bestAccount
    /// "Is anything about to run out?" — the account closest to its limit.
    case worstAccount
    /// "How much runway is left across the fleet?" — how many accounts still
    /// have room.
    case accountsWithRoom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bestAccount: "Best account"
        case .worstAccount: "Busiest account"
        case .accountsWithRoom: "Accounts with room"
        }
    }

    public var explanation: String {
        switch self {
        case .bestAccount:
            "How much of the emptiest account is used — the one you would switch to. A full icon means there is nowhere left to go."
        case .worstAccount:
            "How much of the fullest account is used. Useful when you want to notice an account running out, not find a free one."
        case .accountsWithRoom:
            "How many accounts are still under \(Int(MenuBarReading.roomThreshold))%. The icon fills as they get used up."
        }
    }
}

/// What the menu bar shows for one provider.
public struct MenuBarReading: Equatable, Sendable, Identifiable {
    public let provider: Provider
    /// How full to draw the glyph, 0...100. `nil` when nothing is known, which
    /// draws the outline alone.
    public let fill: Double?
    /// What to print beside the glyph, when the user asked for a number.
    public let text: String?

    public var id: String { provider.rawValue }

    public init(provider: Provider, fill: Double?, text: String?) {
        self.provider = provider
        self.fill = fill
        self.text = text
    }

    /// The line between an account with room and one without. It matches the
    /// point at which a limit row turns amber, so the menu bar and the panel
    /// agree about what "getting tight" means.
    public static let roomThreshold: Double = 80

    /// One reading per provider that has accounts, and deliberately not one
    /// number for everything: running out of Claude Code is not helped by Codex
    /// sitting idle.
    ///
    /// Whatever the metric, an account is measured by its WORST window — an
    /// account is only as usable as its tightest limit.
    ///
    /// Accounts in an error state with no cache at all are excluded rather than
    /// counted as 0%: counting them would make the menu bar look better than it
    /// is precisely when least is known.
    public static func all(
        accounts: [Account],
        usage: [String: AccountUsage],
        metric: MenuBarMetric
    ) -> [MenuBarReading] {
        Provider.allCases.compactMap { provider in
            let ids = accounts.filter { $0.provider == provider }.map(\.id)
            guard !ids.isEmpty else { return nil }

            let known = ids.compactMap { id -> Double? in
                guard let accountUsage = usage[id] else { return nil }
                if case .error = accountUsage.staleness { return nil }
                return accountUsage.worstPercent
            }

            switch metric {
            case .bestAccount:
                return reading(provider: provider, percent: known.min())
            case .worstAccount:
                return reading(provider: provider, percent: known.max())
            case .accountsWithRoom:
                guard !known.isEmpty else {
                    return MenuBarReading(provider: provider, fill: nil, text: nil)
                }
                let withRoom = known.filter { $0 < roomThreshold }.count
                // The glyph fills as accounts are used up, so a full glyph means
                // none are left — the same direction as every other metric.
                let used = Double(known.count - withRoom) / Double(known.count) * 100
                return MenuBarReading(provider: provider, fill: used, text: "\(withRoom)")
            }
        }
    }

    private static func reading(provider: Provider, percent: Double?) -> MenuBarReading {
        MenuBarReading(
            provider: provider,
            fill: percent,
            text: percent.map { "\(Int($0))%" }
        )
    }
}
