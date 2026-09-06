import Foundation

public struct LimitWindow: Equatable, Sendable, Codable {
    public let percent: Double
    public let resetsAt: Date?
    public let label: String

    public init(percent: Double, resetsAt: Date?, label: String) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.label = label
    }
}

public enum Staleness: Equatable, Sendable {
    case fresh
    case cached(since: Date)
    case error(String)
}

public struct AccountUsage: Equatable, Sendable {
    /// Optional, because a window the provider did not send is not a window
    /// sitting at zero. Reporting an absent field as 0% would assert maximum
    /// headroom at exactly the moment nothing is known — and the fixtures
    /// already carry a null window, so this is a real shape, not a hypothetical.
    public let session: LimitWindow?
    public let weekly: LimitWindow?
    public let scoped: [LimitWindow]
    public let fetchedAt: Date
    public let staleness: Staleness

    public init(
        session: LimitWindow?,
        weekly: LimitWindow?,
        scoped: [LimitWindow],
        fetchedAt: Date,
        staleness: Staleness
    ) {
        self.session = session
        self.weekly = weekly
        self.scoped = scoped
        self.fetchedAt = fetchedAt
        self.staleness = staleness
    }

    /// Every window there is anything to say about, in the order the panel
    /// draws them. What the provider did not send is absent rather than empty:
    /// a placeholder bar reads as broken data, and absence reads as absence.
    public var windows: [LimitWindow] {
        [session, weekly].compactMap { $0 } + scoped
    }

    /// The highest usage across every window — this is what the menu bar icon
    /// shows.
    public var worstPercent: Double {
        windows.map(\.percent).max() ?? 0
    }

    /// How full this account is, or `nil` when nothing is actually known.
    ///
    /// The one rule for judging an account, used by the menu bar and by the
    /// panel's "fullest first" order alike. A failed check still leaves an
    /// entry behind — `Poller.lastValueOr` returns empty windows reading 0% —
    /// so the presence of a reading is not the same question as whether
    /// anything is known, and an account in error must not pass for empty. A
    /// CACHED reading is different: it is the last thing genuinely known, the
    /// panel shows it, and so it counts.
    public var knownPercent: Double? {
        if case .error = staleness { return nil }
        // No windows at all is nothing known either — `worstPercent` would
        // answer 0, which is the reassuring direction.
        guard !windows.isEmpty else { return nil }
        return worstPercent
    }
}
