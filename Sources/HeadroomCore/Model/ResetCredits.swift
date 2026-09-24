import Foundation

/// A banked reset of an account's usage limits: a one-off grant the provider
/// gives out now and then, which puts the named windows back to zero whenever
/// the user chooses to spend it.
///
/// Both providers describe these differently (Anthropic as grants with a count,
/// OpenAI as individual credits), so this is the common shape the panel needs:
/// how many, until when, what they clear, and whether one can be used now.
public struct ResetCredits: Equatable, Sendable {
    public let available: Int
    public let expiresAt: Date?
    /// The windows a reset clears, in the panel's own labels ("5 hours",
    /// "Week") so they can be matched against `LimitWindow.label`.
    public let clears: [String]
    public let usableNow: Bool
    /// Why a reset cannot be used right now — only when `usableNow` is false.
    public let blockedReason: String?
    /// What the provider needs to spend one: Anthropic's grant id, or OpenAI's
    /// credit id. Empty when the credit list could not be read — OpenAI then
    /// picks the credit itself, as the Codex CLI does.
    public let claimID: String

    public init(
        available: Int,
        expiresAt: Date?,
        clears: [String],
        usableNow: Bool,
        blockedReason: String?,
        claimID: String
    ) {
        self.available = available
        self.expiresAt = expiresAt
        self.clears = clears
        self.usableNow = usableNow
        self.blockedReason = blockedReason
        self.claimID = claimID
    }

    /// What is left after one reset is spent, or `nil` once none are.
    ///
    /// `nextClaimID` because the providers differ: an Anthropic grant holds a
    /// count and keeps its id, while every OpenAI credit is its own id — so
    /// after spending one, the id this held is dead and the caller passes ""
    /// to let the server choose. (An Anthropic count sums every grant, so the
    /// kept id is a best guess until the next reading names the server's
    /// pick again.)
    public func consumingOne(nextClaimID: String) -> ResetCredits? {
        guard available > 1 else { return nil }
        // The date belonged to the reset just spent — the one that expires
        // first. The others' dates are unknown until the next reading, and
        // inheriting this one would call them urgent, or hide them once it
        // passes.
        return ResetCredits(
            available: available - 1,
            expiresAt: nil,
            clears: clears,
            usableNow: usableNow,
            blockedReason: blockedReason,
            claimID: nextClaimID
        )
    }

    /// What is still on offer at `now`, or `nil` once nothing is.
    ///
    /// A cached reading can outlive the resets it reports. `expiresAt` is the
    /// earliest date among everything counted; once it has passed, which of
    /// the rest are still good is unknown, and the claim id may belong to the
    /// dead one — a press would only earn "already used". So the whole offer
    /// steps aside until the next reading says what is left: hiding a good
    /// reset for one polling interval costs nothing, a wrong answer does.
    public func current(now: Date = Date()) -> ResetCredits? {
        isExpired(now: now) ? nil : self
    }

    /// Whether the earliest counted reset's date has passed.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}
