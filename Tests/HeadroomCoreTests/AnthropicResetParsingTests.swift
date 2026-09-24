import Testing
import Foundation
@testable import HeadroomCore

/// The `cedar_ember` block as it came back on 2026-09-24 for a Max account.
private let liveGrant = #"""
{"id": "opus55-launch-promax-20260921",
 "label": "Claude Opus 5.5 launch: one usage-limit reset for Pro and Max",
 "resets_total": 1, "resets_left": 1,
 "starts_at": "2026-09-22T16:00:00+00:00", "ends_at": "2026-10-22T16:00:00+00:00",
 "clears": ["five_hour", "seven_day", "seven_day_overage_included"],
 "paused": false, "usable_now": true, "use_requires_limit": false,
 "blocking": [], "arm": null}
"""#

private func cedar(grants: String = "[\(liveGrant)]", extra: String = "") -> String {
    #"{"eligible": true, "ineligible_reason": null, "at_limit": false, "exhausted": [], "grants": "#
        + grants
        + #", "next_grant_id": "opus55-launch-promax-20260921", "cooldown_until": null"#
        + extra + "}"
}

/// A fixed moment inside the live grant's window, so these tests do not start
/// failing once 22 Oct 2026 has passed.
private let readingTime = AnthropicUsage.date("2026-09-24T12:00:00+00:00")!

private func resets(_ cedarEmber: String?, fetchedAt: Date = readingTime) throws -> ResetCredits? {
    let block = cedarEmber.map { #", "cedar_ember": "# + $0 } ?? ""
    let json = #"{"five_hour": {"utilization": 37, "resets_at": null}"# + block + "}"
    return try AnthropicUsage.parse(Data(json.utf8), fetchedAt: fetchedAt).resets
}

@Test func theLiveGrantBecomesOneUsableReset() throws {
    let result = try #require(try resets(cedar()))
    #expect(result.available == 1)
    #expect(result.expiresAt == AnthropicUsage.date("2026-10-22T16:00:00+00:00"))
    #expect(result.clears == ["5 hours", "Week"])
    #expect(result.usableNow == true)
    #expect(result.blockedReason == nil)
    #expect(result.claimID == "opus55-launch-promax-20260921")
}

@Test func noCedarEmberBlockMeansNoResets() throws {
    #expect(try resets(nil) == nil)
    #expect(try resets("null") == nil)
}

/// What the endpoint says to any caller that does not present itself as the
/// CLI — a real answer, not a missing one, and it must not turn into a reset.
@Test func anIneligibleAccountHasNoResets() throws {
    #expect(try resets(#"{"eligible": false, "ineligible_reason": "surface", "grants": []}"#) == nil)
}

@Test func noGrantsOrNoneLeftMeansNoResets() throws {
    #expect(try resets(cedar(grants: "[]")) == nil)
    let spent = liveGrant.replacingOccurrences(of: #""resets_left": 1"#, with: #""resets_left": 0"#)
    #expect(try resets(cedar(grants: "[\(spent)]")) == nil)
}

@Test func aGrantThatNeedsALimitFirstIsNotUsableNow() throws {
    let waiting = liveGrant
        .replacingOccurrences(of: #""usable_now": true"#, with: #""usable_now": false"#)
        .replacingOccurrences(of: #""use_requires_limit": false"#, with: #""use_requires_limit": true"#)
    let result = try #require(try resets(cedar(grants: "[\(waiting)]")))
    #expect(result.usableNow == false)
    #expect(result.blockedReason == "Usable once you hit a limit")
}

@Test func aCooldownBlocksTheResetAndSaysUntilWhen() throws {
    let json = cedar().replacingOccurrences(
        of: #""cooldown_until": null"#, with: #""cooldown_until": "2026-09-24T14:00:00+00:00""#
    )
    // Read an hour before the cooldown ends.
    let fetchedAt = try #require(AnthropicUsage.date("2026-09-24T13:00:00+00:00"))
    let result = try #require(try resets(json, fetchedAt: fetchedAt))
    #expect(result.usableNow == false)
    #expect(result.blockedReason?.hasPrefix("Cooling down until ") == true)
}

/// The server can still send a `cooldown_until` that has already passed by
/// the time it answers; that is no cooldown any more, and the grant's own
/// `usable_now` decides.
@Test func aCooldownThatHasAlreadyEndedDoesNotBlockTheReset() throws {
    let json = cedar().replacingOccurrences(
        of: #""cooldown_until": null"#, with: #""cooldown_until": "2026-09-24T14:00:00+00:00""#
    )
    let fetchedAt = try #require(AnthropicUsage.date("2026-09-24T15:00:00+00:00"))
    let result = try #require(try resets(json, fetchedAt: fetchedAt))
    #expect(result.usableNow == true)
    #expect(result.blockedReason == nil)
}

@Test func aPausedGrantIsNotUsableNow() throws {
    let paused = liveGrant.replacingOccurrences(of: #""paused": false"#, with: #""paused": true"#)
    let result = try #require(try resets(cedar(grants: "[\(paused)]")))
    #expect(result.usableNow == false)
    #expect(result.blockedReason == "Paused by Anthropic")
}

/// `next_grant_id` is the server's own pick, so it wins over list order for
/// the claim — while the count covers every grant, since all of them are
/// resets the account holds.
@Test func theNextGrantIdChoosesAmongSeveral() throws {
    let other = liveGrant
        .replacingOccurrences(of: "opus55-launch-promax-20260921", with: "older-grant")
        .replacingOccurrences(of: #""resets_left": 1"#, with: #""resets_left": 2"#)
        .replacingOccurrences(of: "2026-10-22T16:00:00+00:00", with: "2026-11-30T16:00:00+00:00")
    let result = try #require(try resets(cedar(grants: "[\(other), \(liveGrant)]")))
    #expect(result.claimID == "opus55-launch-promax-20260921")
    #expect(result.available == 3)
    // The expiry of the grant that will be spent next, not the other one's.
    #expect(result.expiresAt == AnthropicUsage.date("2026-10-22T16:00:00+00:00"))
}

@Test func twoGrantsOfOneResetEachCountAsTwo() throws {
    let other = liveGrant.replacingOccurrences(of: "opus55-launch-promax-20260921", with: "second-grant")
    let result = try #require(try resets(cedar(grants: "[\(liveGrant), \(other)]")))
    #expect(result.available == 2)
    #expect(result.claimID == "opus55-launch-promax-20260921")
}

/// A grant without an id cannot be claimed, and one with nothing left adds
/// nothing — neither may inflate the count.
@Test func onlyClaimableGrantsWithResetsLeftAreCounted() throws {
    let spent = liveGrant
        .replacingOccurrences(of: "opus55-launch-promax-20260921", with: "spent-grant")
        .replacingOccurrences(of: #""resets_left": 1"#, with: #""resets_left": 0"#)
    let anonymous = liveGrant
        .replacingOccurrences(of: #""id": "opus55-launch-promax-20260921""#, with: #""id": null"#)
        .replacingOccurrences(of: #""resets_left": 1"#, with: #""resets_left": 4"#)
    let result = try #require(try resets(cedar(grants: "[\(spent), \(anonymous), \(liveGrant)]")))
    #expect(result.available == 1)
}

@Test func withoutANextGrantIdTheFirstGrantWithResetsLeftIsUsed() throws {
    let spent = liveGrant
        .replacingOccurrences(of: "opus55-launch-promax-20260921", with: "spent-grant")
        .replacingOccurrences(of: #""resets_left": 1"#, with: #""resets_left": 0"#)
    let json = cedar(grants: "[\(spent), \(liveGrant)]")
        .replacingOccurrences(of: #""next_grant_id": "opus55-launch-promax-20260921""#, with: #""next_grant_id": null"#)
    let result = try #require(try resets(json))
    #expect(result.claimID == "opus55-launch-promax-20260921")
}

/// A `resets_left` of the wrong JSON type anywhere inside the block used to
/// throw `AnthropicUsage.parse` entirely — taking `five_hour` down with a
/// field that belongs to an unrelated, undocumented feature. See `Lenient`.
@Test func aMalformedCedarEmberBlockLeavesTheWindowsAlone() throws {
    let json = #"{"five_hour": {"utilization": 37, "resets_at": null}, "cedar_ember": {"eligible": true, "grants": [{"id": "g", "resets_left": "one"}]}}"#
    let usage = try AnthropicUsage.parse(Data(json.utf8), fetchedAt: Date())
    #expect(usage.session?.percent == 37)
    #expect(usage.resets == nil)
}

@Test func theFixtureStillParsesWithItsResets() throws {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/anthropic_usage", withExtension: "json"))
    let usage = try AnthropicUsage.parse(Data(contentsOf: url), fetchedAt: readingTime)
    #expect(usage.session?.percent == 54)
    #expect(usage.resets?.available == 1)
}

/// The date shown is the earliest among all counted grants, not the server's
/// pick: a reset that expires sooner must be the one the line warns about.
@Test func theExpiryIsTheEarliestAmongTheCountedGrants() throws {
    let sooner = liveGrant
        .replacingOccurrences(of: "opus55-launch-promax-20260921", with: "sooner-grant")
        .replacingOccurrences(of: "2026-10-22T16:00:00+00:00", with: "2026-10-01T16:00:00+00:00")
    let result = try #require(try resets(cedar(grants: "[\(liveGrant), \(sooner)]")))
    #expect(result.claimID == "opus55-launch-promax-20260921")
    #expect(result.available == 2)
    #expect(result.expiresAt == AnthropicUsage.date("2026-10-01T16:00:00+00:00"))
}

/// A grant the server still lists after its end, with resets left, is not a
/// reset the account holds. Counted, its past date would become the earliest
/// and withdraw every good reset for as long as the server keeps listing it.
@Test func aGrantPastItsEndIsNotCounted() throws {
    let ended = liveGrant
        .replacingOccurrences(of: "opus55-launch-promax-20260921", with: "ended-grant")
        .replacingOccurrences(of: "2026-10-22T16:00:00+00:00", with: "2026-09-01T16:00:00+00:00")
    let result = try #require(try resets(cedar(grants: "[\(ended), \(liveGrant)]")))
    #expect(result.available == 1)
    #expect(result.expiresAt == AnthropicUsage.date("2026-10-22T16:00:00+00:00"))
    #expect(result.claimID == "opus55-launch-promax-20260921")
    #expect(try resets(cedar(grants: "[\(ended)]")) == nil)
}
