import Testing
import Foundation
@testable import HeadroomCore

private func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockProtocol.self]
    return URLSession(configuration: configuration)
}

private let claude = Account(
    provider: .anthropic, email: "a@b.pl",
    accessToken: "tok", refreshToken: "r", expiresAt: .distantFuture
)
private let codex = Account(
    provider: .openai, email: "a@b.pl",
    accessToken: "tok2", refreshToken: "r", expiresAt: .distantFuture, accountId: "acc-1"
)

private func credits(claimID: String) -> ResetCredits {
    ResetCredits(available: 1, expiresAt: nil, clears: ["5 hours", "Week"], usableNow: true, blockedReason: nil, claimID: claimID)
}

private let requestID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
private let profilePath = "/api/oauth/profile"
private let claimPath = "/api/organizations/o-1/reset_rate_limits"
private let consumePath = "/backend-api/wham/rate-limit-reset-credits/consume"
private let profileBody = Data(#"{"account": {"email": "a@b.pl"}, "organization": {"uuid": "o-1", "name": "Org"}}"#.utf8)

private func sentJSON() throws -> [String: Any] {
    let body = try #require(MockProtocol.lastBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

extension NetworkTests {
    @Suite struct ResetRedeemerTests {
        private func claim(_ status: Int, _ body: String) async throws -> ResetOutcome {
            MockProtocol.routes = [profilePath: (200, profileBody), claimPath: (status, Data(body.utf8))]
            return try await AnthropicResetClient(session: mockSession())
                .redeem(account: claude, credits: credits(claimID: "grant-1"), requestID: requestID)
        }

        private func consume(_ status: Int, _ body: String, claimID: String = "RateLimitResetCredit_1") async throws -> ResetOutcome {
            MockProtocol.routes = [consumePath: (status, Data(body.utf8))]
            return try await CodexResetClient(session: mockSession())
                .redeem(account: codex, credits: credits(claimID: claimID), requestID: requestID)
        }

        @Test func claudeClaimsOnTheTokensOrganisation() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            let outcome = try await claim(200, #"{"result": "reset"}"#)

            #expect(outcome == .reset)
            #expect(MockProtocol.lastURL?.absoluteString == "https://api.anthropic.com/api/organizations/o-1/reset_rate_limits")
            #expect(MockProtocol.lastMethod == "POST")
            #expect(MockProtocol.lastHeaders["User-Agent"] == HeadroomConstants.anthropicUserAgent)
            #expect(MockProtocol.lastHeaders["anthropic-beta"] == HeadroomConstants.anthropicBeta)
            #expect(MockProtocol.lastHeaders["Authorization"] == "Bearer tok")
            let json = try sentJSON()
            #expect(json["program"] as? String == "cedar_ember")
            #expect(json["grant_id"] as? String == "grant-1")
            #expect(json["request_id"] as? String == "3f2504e0-4f89-41d3-9a0c-0305e82c3301")
        }

        @Test func claudeOutcomesMapOntoTheCommonVocabulary() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            #expect(try await claim(200, #"{"result": "not_limited"}"#) == .nothingToReset)
            #expect(try await claim(200, #"{"status": "already_used"}"#) == .alreadyUsed)
            #expect(try await claim(200, #"{"outcome": "unavailable"}"#) == .alreadyUsed)
            #expect(try await claim(200, #"{"code": "cooldown"}"#) == .coolingDown)
            #expect(try await claim(200, #"{"result": "ineligible"}"#) == .ineligible)
        }

        /// A key present with a value we don't recognise (Anthropic's `status`
        /// here is not one of the vocabulary's words) must not be taken as the
        /// answer just because it came first — the outcome has to come from a
        /// key that actually names one, wherever in the list it sits.
        @Test func claudeSkipsAnUnrecognisedValueForALaterKeyThatNamesAKnownOutcome() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            #expect(try await claim(200, #"{"status": "ok", "code": "not_limited"}"#) == .nothingToReset)
        }

        /// Same rule on the error path: `result` names a known outcome, so it
        /// wins over `status` even though `status` appears first in the body.
        @Test func claudeReadsARefusalFromTheFirstRecognisedKeyEvenBehindAnUnrecognisedOne() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            #expect(try await claim(409, #"{"status": "error", "result": "already_used"}"#) == .alreadyUsed)
        }

        /// The success body has never been observed. A 2xx means the server
        /// accepted the claim, so an unrecognised one is taken as done — the
        /// confirming check three minutes later tells the truth either way.
        @Test func claudeTakesAnUnrecognised2xxAsDone() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            #expect(try await claim(200, "{}") == .reset)
            #expect(try await claim(204, "") == .reset)
        }

        @Test func claudeReadsARefusalFromAnErrorBody() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            #expect(try await claim(409, #"{"result": "already_used"}"#) == .alreadyUsed)
        }

        /// An error status must never be read as a spent reset, whatever the
        /// body claims.
        @Test func claudeNeverTakesAnErrorStatusAsDone() async {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            await #expect(throws: UsageError.http(500)) { _ = try await claim(500, #"{"result": "reset"}"#) }
            await #expect(throws: UsageError.unauthorized) { _ = try await claim(401, "") }
        }

        @Test func claudeWithoutAnOrganisationSendsNothing() async {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            MockProtocol.routes = [profilePath: (200, Data(#"{"account": {"email": "a@b.pl"}}"#.utf8))]
            await #expect(throws: ResetError.organizationUnknown) {
                _ = try await AnthropicResetClient(session: mockSession())
                    .redeem(account: claude, credits: credits(claimID: "grant-1"), requestID: requestID)
            }
            #expect(MockProtocol.requestedPaths == [profilePath])
        }

        @Test func claudeARejectedProfileMeansUnauthorized() async {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            MockProtocol.routes = [profilePath: (401, Data())]
            await #expect(throws: UsageError.unauthorized) {
                _ = try await AnthropicResetClient(session: mockSession())
                    .redeem(account: claude, credits: credits(claimID: "grant-1"), requestID: requestID)
            }
        }

        @Test func codexConsumesTheNamedCredit() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            let outcome = try await consume(200, #"{"code": "reset", "windows_reset": 2}"#)

            #expect(outcome == .reset)
            #expect(MockProtocol.lastURL?.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")
            #expect(MockProtocol.lastMethod == "POST")
            #expect(MockProtocol.lastHeaders["ChatGPT-Account-Id"] == "acc-1")
            #expect(MockProtocol.lastHeaders["Authorization"] == "Bearer tok2")
            let json = try sentJSON()
            #expect(json["redeem_request_id"] as? String == "3f2504e0-4f89-41d3-9a0c-0305e82c3301")
            #expect(json["credit_id"] as? String == "RateLimitResetCredit_1")
        }

        @Test func codexOmitsCreditIdWhenUnknown() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            _ = try await consume(200, #"{"code": "reset"}"#, claimID: "")
            #expect(try sentJSON()["credit_id"] == nil)
        }

        @Test func codexOutcomesMapOntoTheCommonVocabulary() async throws {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            #expect(try await consume(200, #"{"code": "nothing_to_reset"}"#) == .nothingToReset)
            #expect(try await consume(200, #"{"code": "no_credit"}"#) == .alreadyUsed)
            #expect(try await consume(200, #"{"code": "already_redeemed"}"#) == .alreadyUsed)
        }

        /// Unlike Claude, Codex's success shape is known from its own source,
        /// so a 2xx without a known code is a surprise, not a success.
        @Test func codexTreatsAnUnknown2xxAsUnrecognised() async {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            await #expect(throws: ResetError.unrecognizedResponse) { _ = try await consume(200, #"{"code": "mystery"}"#) }
        }

        @Test func codexA401IsUnauthorized() async {
            MockProtocol.reset()
            defer { MockProtocol.reset() }
            await #expect(throws: UsageError.unauthorized) { _ = try await consume(401, "") }
        }
    }
}
