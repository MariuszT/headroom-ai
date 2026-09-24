import Testing
import Foundation
@testable import HeadroomCore

private func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockProtocol.self]
    return URLSession(configuration: configuration)
}

private let codexAccount = Account(
    provider: .openai, email: "a@b.pl",
    accessToken: "tok", refreshToken: "r", expiresAt: .distantFuture, accountId: "acc-1"
)

private let usagePath = "/backend-api/wham/usage"
private let creditsPath = "/backend-api/wham/rate-limit-reset-credits"

private func usageBody(available: Int?, applicable: Int? = nil) -> Data {
    var summary = ""
    if let available {
        let applicablePart = applicable.map { #", "applicable_available_count": \#($0)"# } ?? ""
        summary = #", "rate_limit_reset_credits": {"available_count": \#(available)\#(applicablePart)}"#
    }
    return Data((#"{"email": "a@b.pl", "rate_limit": {"primary_window": {"used_percent": 100, "reset_at": 1790260874}}"# + summary + "}").utf8)
}

/// The list as it came back on 2026-09-24 (expiries moved ten years ahead so
/// the client's real clock never sees them pass), plus a second, later-expiring
/// credit and one already spent.
private let creditsBody = Data(#"""
{"credits": [
  {"id": "RateLimitResetCredit_later", "reset_type": "codex_rate_limits", "status": "available",
   "granted_at": "2026-09-23T20:36:29.248381Z", "expires_at": "2036-11-01T00:00:00Z",
   "title": "Full reset (Weekly + 5 hr)"},
  {"id": "RateLimitResetCredit_spent", "reset_type": "codex_rate_limits", "status": "redeemed",
   "granted_at": "2026-09-01T00:00:00Z", "expires_at": "2036-09-30T00:00:00Z"},
  {"id": "RateLimitResetCredit_7bc9", "reset_type": "codex_rate_limits", "status": "available",
   "granted_at": "2026-09-22T20:36:29.248381Z", "expires_at": "2036-10-22T20:36:29.248381Z",
   "title": "Full reset (Weekly + 5 hr)"}
 ],
 "available_count": 2}
"""#.utf8)

@Test func theUsageSummaryAloneGivesACountWithoutADate() throws {
    let result = try CodexUsage.parse(usageBody(available: 1, applicable: 1), fetchedAt: Date()).usage.resets
    let resets = try #require(result)
    #expect(resets.available == 1)
    #expect(resets.expiresAt == nil)
    #expect(resets.claimID == "")
    #expect(resets.clears == ["5 hours", "Week"])
    #expect(resets.usableNow == true)
}

@Test func noSummaryOrZeroMeansNoResets() throws {
    #expect(try CodexUsage.parse(usageBody(available: nil), fetchedAt: Date()).usage.resets == nil)
    #expect(try CodexUsage.parse(usageBody(available: 0), fetchedAt: Date()).usage.resets == nil)
}

/// Seen live: one credit held, none applicable while the windows sat at 0% and
/// 5%. Assumed to mean "only once a limit is hit".
@Test func noApplicableCreditMeansNotUsableNow() throws {
    let resets = try #require(try CodexUsage.parse(usageBody(available: 1, applicable: 0), fetchedAt: Date()).usage.resets)
    #expect(resets.usableNow == false)
    #expect(resets.blockedReason == "Usable once you hit a limit")
}

/// An older server that does not send the field is not a reason to hide the
/// button — the server still has the last word when it is pressed.
@Test func aMissingApplicableCountIsTreatedAsUsable() throws {
    let resets = try #require(try CodexUsage.parse(usageBody(available: 1), fetchedAt: Date()).usage.resets)
    #expect(resets.usableNow == true)
}

/// An `available_count` of the wrong JSON type used to throw `CodexUsage.parse`
/// entirely — taking `rate_limit` down with a field that belongs to an
/// unrelated, undocumented feature. See `Lenient`.
@Test func aMalformedResetCreditsBlockLeavesTheWindowsAlone() throws {
    let json = #"{"email": "a@b.pl", "rate_limit": {"primary_window": {"used_percent": 100, "reset_at": 1790260874}}, "rate_limit_reset_credits": {"available_count": "x"}}"#
    let result = try CodexUsage.parse(Data(json.utf8), fetchedAt: Date())
    #expect(result.usage.session?.percent == 100)
    #expect(result.usage.resets == nil)
}

@Test func theEarliestExpiringAvailableCreditIsChosen() throws {
    let details = try #require(try CodexUsage.parseCreditDetails(creditsBody, now: AnthropicUsage.date("2026-09-24T12:00:00Z")!))
    #expect(details.claimID == "RateLimitResetCredit_7bc9")
    #expect(details.expiresAt == AnthropicUsage.date("2036-10-22T20:36:29.248381Z"))
}

extension NetworkTests {
    @Suite struct CodexResetClientReadingTests {
        @Test func theCreditListIsFetchedOnlyWhenThereAreCredits() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            MockProtocol.routes = [usagePath: (200, usageBody(available: 0))]

            let usage = try await CodexUsageClient(session: mockSession()).fetch(account: codexAccount)

            #expect(usage.resets == nil)
            #expect(MockProtocol.requestedPaths == [usagePath])
        }

        @Test func theCreditListAddsTheExpiryAndTheClaim() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            MockProtocol.routes = [
                usagePath: (200, usageBody(available: 2, applicable: 2)),
                creditsPath: (200, creditsBody),
            ]

            let usage = try await CodexUsageClient(session: mockSession()).fetch(account: codexAccount)

            let resets = try #require(usage.resets)
            #expect(resets.available == 2)
            #expect(resets.claimID == "RateLimitResetCredit_7bc9")
            #expect(resets.expiresAt == AnthropicUsage.date("2036-10-22T20:36:29.248381Z"))
            #expect(MockProtocol.requestedPaths == [usagePath, creditsPath])
            #expect(MockProtocol.lastHeaders["ChatGPT-Account-Id"] == "acc-1")
        }

        @Test func aFailingDetailsRequestKeepsTheCountWithoutADate() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            MockProtocol.routes = [
                usagePath: (200, usageBody(available: 1, applicable: 1)),
                creditsPath: (500, Data()),
            ]

            let usage = try await CodexUsageClient(session: mockSession()).fetch(account: codexAccount)

            #expect(usage.session?.percent == 100)
            let resets = try #require(usage.resets)
            #expect(resets.available == 1)
            #expect(resets.expiresAt == nil)
            #expect(resets.claimID == "")
        }
    }
}

/// A credit still marked available after its expiry is not one to spend or to
/// date the rest by.
@Test func aCreditPastItsExpiryIsSkipped() throws {
    let details = try #require(try CodexUsage.parseCreditDetails(creditsBody, now: AnthropicUsage.date("2036-10-25T00:00:00Z")!))
    #expect(details.claimID == "RateLimitResetCredit_later")
    #expect(try CodexUsage.parseCreditDetails(creditsBody, now: AnthropicUsage.date("2036-12-01T00:00:00Z")!) == nil)
}
