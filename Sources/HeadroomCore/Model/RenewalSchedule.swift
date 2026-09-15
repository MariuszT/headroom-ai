import Foundation

/// When an account's plan renews, and how far ahead to say so.
///
/// Neither provider reports this — the Claude Code OAuth token reaches
/// `/api/oauth/profile` and `/api/oauth/usage`, and the Codex one reaches
/// `backend-api/wham` and `backend-api/codex`; none of those carries a billing
/// date, and Anthropic's own `/api/organizations/{id}` answers OAuth tokens
/// with `oauth_token_not_accepted`. So this is the user's own knowledge, kept
/// by the app rather than fetched.
public struct RenewalSchedule: Codable, Sendable, Equatable {
    public enum Cycle: Codable, Sendable, Equatable {
        /// Every `interval` days. Unlike the two below it keeps no day of the
        /// month, so it drifts across months by design.
        case days(Int)
        case monthly
        case yearly
    }

    /// A date the plan is known to renew on. Every later date is counted from
    /// here — see `next(onOrAfter:calendar:)`.
    public var anchor: Date
    public var cycle: Cycle
    /// How many days before a renewal the account starts saying so.
    public var leadDays: Int

    public init(anchor: Date, cycle: Cycle, leadDays: Int) {
        self.anchor = anchor
        self.cycle = cycle
        self.leadDays = leadDays
    }

    /// The first renewal falling on today or later.
    ///
    /// The boundary is the DAY, not the instant. A plan renewing today has not
    /// been missed at 14:00 just because the anchor's time of day was 12:00 —
    /// comparing instants skipped it and reported the renewal a whole cycle
    /// away, on the very day the money actually leaves.
    ///
    /// Each candidate is the n-th cycle counted FROM THE ANCHOR, never one step
    /// from the previous candidate: adding a month to 31 January gives 28
    /// February, and stepping on from there would give 28 March, so a plan
    /// anchored on the 31st would silently become one renewing on the 28th.
    public func next(onOrAfter now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        // Start from a computed guess rather than from the anchor, then correct
        // upwards. Walking one cycle at a time is O(cycles elapsed), and this
        // runs on every redraw — twice per visible row plus once per account
        // for the menu bar dot. Measured on a daily schedule anchored two years
        // back: 1.34 ms a call stepping one at a time, against 0.046 ms for a
        // monthly one. The guess is floored, so it can fall short of the answer
        // but never past it, and the loop below closes the gap.
        var step = estimatedStep(to: today, calendar: calendar)
        var candidate = date(atStep: step, calendar: calendar) ?? anchor
        while calendar.startOfDay(for: candidate) < today {
            step += 1
            guard let advanced = date(atStep: step, calendar: calendar) else {
                // The calendar refused a date it has always produced. Whatever
                // is left in `candidate` failed the test above, so it is in the
                // PAST — returning it would make `daysAway` negative, and
                // `isAlerting` then stays true for good, pinning the dot and
                // the orange row on with no way back.
                return max(candidate, today)
            }
            candidate = advanced
        }
        return candidate
    }

    /// How many whole cycles fit between the anchor and today. Floored, and
    /// never negative — an anchor in the future starts at step zero, which is
    /// the anchor itself.
    private func estimatedStep(to today: Date, calendar: Calendar) -> Int {
        let unit: Calendar.Component = switch cycle {
        case .days: .day
        case .monthly: .month
        case .yearly: .year
        }
        let elapsed = calendar.dateComponents([unit], from: anchor, to: today).value(for: unit) ?? 0
        guard elapsed > 0 else { return 0 }
        switch cycle {
        case .days(let interval): return elapsed / max(1, interval)
        case .monthly, .yearly: return elapsed
        }
    }

    /// Where the next renewal stands right now.
    public func status(now: Date, calendar: Calendar = .current) -> RenewalStatus {
        let date = next(onOrAfter: now, calendar: calendar)
        // From the START of each day, so the answer counts midnights rather
        // than 24-hour blocks: at 23:00 a renewal at 00:00 is tomorrow, not
        // today.
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        return RenewalStatus(date: date, daysAway: days, leadDays: leadDays)
    }

    /// Days rather than seconds throughout: adding 86_400 across a daylight
    /// saving change moves the renewal by an hour, and enough of those walk it
    /// onto the previous day.
    private func date(atStep step: Int, calendar: Calendar) -> Date? {
        switch cycle {
        // `max(1, …)` is what guarantees the search in `next(onOrAfter:)`
        // terminates. A stored interval of zero steps nowhere and the loop
        // never ends; a negative one walks backwards forever. The editor's
        // stepper is bounded to 1...365, but `Preferences.renewal(for:)`
        // decodes whatever is under its key, and `{"days":{"_0":0}}` decodes
        // cleanly — so the guarantee has to live here, not at the one entry
        // point that happens to be safe today.
        case .days(let interval): calendar.date(byAdding: .day, value: step * max(1, interval), to: anchor)
        case .monthly: calendar.date(byAdding: .month, value: step, to: anchor)
        case .yearly: calendar.date(byAdding: .year, value: step, to: anchor)
        }
    }
}

/// The next renewal, and whether it is close enough to speak up about.
public struct RenewalStatus: Equatable, Sendable {
    public let date: Date
    /// Whole days from today to the renewal's day. Never negative — a renewal
    /// that has passed has already rolled on to the next one.
    public let daysAway: Int
    public let leadDays: Int

    public init(date: Date, daysAway: Int, leadDays: Int) {
        self.date = date
        self.daysAway = daysAway
        self.leadDays = leadDays
    }

    public var isAlerting: Bool { daysAway <= leadDays }
}
