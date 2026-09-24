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
    /// Banked limit resets, when the provider reported any. `nil` is both "none"
    /// and "nothing known" — the row shows nothing either way.
    public let resets: ResetCredits?

    public init(
        session: LimitWindow?,
        weekly: LimitWindow?,
        scoped: [LimitWindow],
        fetchedAt: Date,
        staleness: Staleness,
        resets: ResetCredits? = nil
    ) {
        self.session = session
        self.weekly = weekly
        self.scoped = scoped
        self.fetchedAt = fetchedAt
        self.staleness = staleness
        self.resets = resets
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

    /// This reading, labelled no fresher than `shown` — what the row displayed
    /// before a reset attempt.
    ///
    /// A reset attempt answers from the poller's cache, and the cache only
    /// ever holds successful reads, so its answer always says `.fresh`.
    /// Written over a row that was showing old numbers after a failed check,
    /// that label would claim they had just been confirmed — for as long as
    /// the backoff keeps the next check away. A reset attempt is not a check.
    public func keepingStaleness(of shown: AccountUsage?) -> AccountUsage {
        guard staleness == .fresh, let shown, shown.staleness != .fresh else { return self }
        return AccountUsage(
            session: session, weekly: weekly, scoped: scoped,
            fetchedAt: fetchedAt, staleness: .cached(since: fetchedAt), resets: resets
        )
    }

    public func replacingResets(_ resets: ResetCredits?) -> AccountUsage {
        AccountUsage(
            session: session, weekly: weekly, scoped: scoped,
            fetchedAt: fetchedAt, staleness: staleness, resets: resets
        )
    }

    /// The reading as it stands straight after a reset was spent, before the
    /// provider can be asked again (see `Poller.minimumInterval`). The named
    /// windows drop to zero and lose their reset time — the old one no longer
    /// applies and the new one is not known yet.
    public func applyingReset(clearing labels: [String], remaining: ResetCredits?) -> AccountUsage {
        func cleared(_ window: LimitWindow?) -> LimitWindow? {
            guard let window else { return nil }
            guard labels.contains(window.label) else { return window }
            return LimitWindow(percent: 0, resetsAt: nil, label: window.label)
        }
        return AccountUsage(
            session: cleared(session),
            weekly: cleared(weekly),
            scoped: scoped.compactMap { cleared($0) },
            fetchedAt: fetchedAt,
            staleness: staleness,
            resets: remaining
        )
    }
}
