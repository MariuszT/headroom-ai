import Foundation

/// Spends one of Claude's banked limit resets — the "Reset for free" button in
/// claude.ai's usage settings, which Claude Code 2.1.281 calls from
/// `/limit-reset` under the programme name `cedar_ember`.
public struct AnthropicResetClient: ResetRedeemer {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func redeem(account: Account, credits: ResetCredits, requestID: UUID) async throws -> ResetOutcome {
        let organization = try await organizationUUID(accessToken: account.accessToken)

        var request = URLRequest(url: HeadroomConstants.anthropicResetURL(organizationUUID: organization))
        request.httpMethod = "POST"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(HeadroomConstants.anthropicBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(HeadroomConstants.anthropicUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "program": "cedar_ember",
            "grant_id": credits.claimID,
            "request_id": requestID.uuidString.lowercased(),
        ])

        let (data, response) = try await session.data(for: request)
        // The success body has never been seen — a 2xx without a recognisable
        // answer is taken as done, and the confirming check settles it.
        return try ResetResponse.resolve(
            data, response,
            keys: ["result", "status", "outcome", "code"],
            acceptUnknownSuccess: true
        )
    }

    /// Asked at claim time rather than stored on the account: it is needed
    /// only here, and the token alone decides which organisation it speaks for.
    private func organizationUUID(accessToken: String) async throws -> String {
        let profile: AnthropicProfile
        do {
            profile = try await AnthropicProfileClient(session: session).fetch(accessToken: accessToken)
        } catch AnthropicProfileError.http(let code) where code == 401 || code == 403 {
            throw UsageError.unauthorized
        } catch {
            // Nothing has been claimed yet, so this is a plain failure — not
            // the "may have landed" uncertainty of a lost claim.
            throw ResetError.organizationUnknown
        }
        guard let uuid = profile.organizationUUID else { throw ResetError.organizationUnknown }
        return uuid
    }
}
