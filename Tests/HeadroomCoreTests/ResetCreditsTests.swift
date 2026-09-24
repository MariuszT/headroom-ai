import Testing
import Foundation
@testable import HeadroomCore

private func credits(available: Int = 1, expiresAt: Date? = nil, claimID: String = "g-1") -> ResetCredits {
    ResetCredits(
        available: available, expiresAt: expiresAt, clears: ["5 hours", "Week"],
        usableNow: true, blockedReason: nil, claimID: claimID
    )
}

private func reading(resets: ResetCredits?) -> AccountUsage {
    AccountUsage(
        session: LimitWindow(percent: 37, resetsAt: Date(timeIntervalSince1970: 100), label: "5 hours"),
        weekly: LimitWindow(percent: 73, resetsAt: Date(timeIntervalSince1970: 200), label: "Week"),
        scoped: [LimitWindow(percent: 12, resetsAt: nil, label: "Fable")],
        fetchedAt: Date(timeIntervalSince1970: 50),
        staleness: .fresh,
        resets: resets
    )
}

@Test func usingTheLastResetLeavesNone() {
    #expect(credits(available: 1).consumingOne(nextClaimID: "g-1") == nil)
}

@Test func usingOneOfTwoCountsDownAndTakesTheNextClaim() {
    let left = credits(available: 2, claimID: "c-1").consumingOne(nextClaimID: "")
    #expect(left?.available == 1)
    #expect(left?.claimID == "")
    #expect(left?.clears == ["5 hours", "Week"])
}

@Test func aResetWithoutAnExpiryNeverExpires() {
    #expect(credits(expiresAt: nil).isExpired(now: .distantFuture) == false)
}

@Test func aResetPastItsExpiryIsExpired() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(credits(expiresAt: now).isExpired(now: now) == true)
    #expect(credits(expiresAt: now.addingTimeInterval(1)).isExpired(now: now) == false)
}

/// Only the windows the reset names drop to zero. A per-model limit it does not
/// name keeps its number — zeroing it would claim headroom nobody granted.
@Test func applyingAResetZeroesOnlyTheNamedWindows() {
    let after = reading(resets: credits()).applyingReset(clearing: ["5 hours", "Week"], remaining: nil)
    #expect(after.session?.percent == 0)
    #expect(after.session?.resetsAt == nil)
    #expect(after.weekly?.percent == 0)
    #expect(after.scoped.first?.percent == 12)
    #expect(after.resets == nil)
    #expect(after.fetchedAt == Date(timeIntervalSince1970: 50))
    #expect(after.staleness == .fresh)
}

@Test func replacingResetsKeepsEverythingElse() {
    let before = reading(resets: nil)
    let after = before.replacingResets(credits())
    #expect(after.resets == credits())
    #expect(after.windows == before.windows)
}

/// The poller's cache only ever holds successful reads, so what a reset
/// attempt hands back is always labelled fresh. When the row was showing old
/// numbers, the answer must say so too — a reset attempt is not a check.
@Test func aResetAnswerKeepsTheRowStaleWhenItWasStale() {
    let answer = reading(resets: nil)
    let shown = AccountUsage(
        session: nil, weekly: nil, scoped: [],
        fetchedAt: Date(timeIntervalSince1970: 50),
        staleness: .cached(since: Date(timeIntervalSince1970: 50))
    )
    #expect(answer.keepingStaleness(of: shown).staleness == .cached(since: Date(timeIntervalSince1970: 50)))
    #expect(answer.keepingStaleness(of: shown).windows == answer.windows)
}

@Test func aResetAnswerAfterAFailedCheckIsNotFresh() {
    let shown = AccountUsage(session: nil, weekly: nil, scoped: [], fetchedAt: Date(), staleness: .error("No connection."))
    #expect(reading(resets: nil).keepingStaleness(of: shown).staleness == .cached(since: Date(timeIntervalSince1970: 50)))
}

@Test func aResetAnswerStaysFreshWhenTheRowWasFresh() {
    let answer = reading(resets: nil)
    #expect(answer.keepingStaleness(of: answer) == answer)
    #expect(answer.keepingStaleness(of: nil) == answer)
}

/// The date belongs to the reset spent next — the one that expires first. Once
/// it is spent the others keep counting, but their dates are unknown until the
/// next reading, and inheriting the spent one's would call them urgent, or
/// hide them when it passes.
@Test func spendingOneDropsTheDateItCarried() {
    let left = credits(available: 2, expiresAt: Date(timeIntervalSince1970: 1_000)).consumingOne(nextClaimID: "")
    #expect(left?.available == 1)
    #expect(left?.expiresAt == nil)
}

/// `expiresAt` is the earliest date among everything counted. Once it has
/// passed on a cached reading, which resets are still good is unknown — and
/// claiming with the id of a dead one would only earn "already used". The
/// whole offer steps aside until the next reading says what is left.
@Test func aPassedDateWithdrawsTheOfferUntilTheNextReading() {
    let now = Date(timeIntervalSince1970: 2_000)
    let past = Date(timeIntervalSince1970: 1_000)
    #expect(credits(available: 1, expiresAt: past).current(now: now) == nil)
    #expect(credits(available: 3, expiresAt: past).current(now: now) == nil)
    let future = credits(available: 2, expiresAt: now.addingTimeInterval(60))
    #expect(future.current(now: now) == future)
    #expect(credits(available: 2, expiresAt: nil).current(now: now) == credits(available: 2, expiresAt: nil))
}
