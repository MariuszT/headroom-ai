import Foundation

/// Spends one of Codex's banked limit resets, as the Codex CLI does
/// (`codex-rs/backend-client/src/client/rate_limit_resets.rs`).
public struct CodexResetClient: ResetRedeemer {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func redeem(account: Account, credits: ResetCredits, requestID: UUID) async throws -> ResetOutcome {
        var request = URLRequest(url: HeadroomConstants.codexConsumeResetURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = account.accountId {
            request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["redeem_request_id": requestID.uuidString.lowercased()]
        // Without an id the server picks the credit itself — what the CLI
        // does, and all that is left when the credit list could not be read.
        if !credits.claimID.isEmpty {
            body["credit_id"] = credits.claimID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        return try ResetResponse.resolve(data, response, keys: ["code"], acceptUnknownSuccess: false)
    }
}
