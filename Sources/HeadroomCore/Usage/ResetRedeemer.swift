import Foundation

/// What a provider said about a reset claim, in one vocabulary for both.
public enum ResetOutcome: Equatable, Sendable {
    case reset
    /// Nothing is used up enough to reset — the reset stays banked.
    case nothingToReset
    case alreadyUsed
    case coolingDown
    case ineligible
}

/// How a reset attempt ended, as the panel reports it. Beyond the provider's
/// own answers there are the cases where no answer came: `failed` when the
/// reset is certainly still there, `unconfirmed` when it may or may not be.
public enum ResetResult: Equatable, Sendable {
    case outcome(ResetOutcome)
    case failed
    case unconfirmed
    case nothingAvailable
    case alreadyInProgress
}

public enum ResetError: Error, Equatable {
    /// The Anthropic profile gave no organisation to claim on — nothing was sent.
    case organizationUnknown
    /// A 2xx whose body said nothing recognisable — the claim may have landed.
    case unrecognizedResponse
}

public protocol ResetRedeemer: Sendable {
    /// `requestID` is generated once per press of "Reset", so a request the
    /// network happens to repeat is still one claim to the server.
    func redeem(account: Account, credits: ResetCredits, requestID: UUID) async throws -> ResetOutcome
}

/// Reading a claim's answer, shared by both providers.
enum ResetResponse {
    static func outcome(for value: String) -> ResetOutcome? {
        switch value {
        case "reset": .reset
        case "not_limited", "nothing_to_reset": .nothingToReset
        case "already_used", "unavailable", "already_redeemed", "no_credit": .alreadyUsed
        case "cooldown": .coolingDown
        case "ineligible": .ineligible
        default: nil
        }
    }

    /// The first of `keys` whose value maps to a KNOWN outcome — Anthropic's
    /// success body has not been observed, so several plausible names are
    /// tried, but a key present with an unrecognised value (e.g. some other
    /// code Anthropic sends under an earlier key) must not shadow a later key
    /// that does name a known outcome.
    static func knownOutcome(in body: Data, keys: [String]) -> ResetOutcome? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        for key in keys {
            if let value = object[key] as? String, let outcome = outcome(for: value) {
                return outcome
            }
        }
        return nil
    }

    /// An error status is never read as `.reset`, whatever its body says: a
    /// refusal the body names is returned as such, and anything else throws
    /// through the same mapping the usage readers use.
    static func resolve(
        _ data: Data,
        _ response: URLResponse,
        keys: [String],
        acceptUnknownSuccess: Bool
    ) throws -> ResetOutcome {
        let known = knownOutcome(in: data, keys: keys)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if (200..<300).contains(status) {
            if let known { return known }
            if acceptUnknownSuccess { return .reset }
            throw ResetError.unrecognizedResponse
        }
        if let known, known != .reset { return known }
        try HTTPStatus.check(response, body: data)
        throw UsageError.http(status)
    }
}
