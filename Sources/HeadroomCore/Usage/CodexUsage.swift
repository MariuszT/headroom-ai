import Foundation

public enum CodexUsage {
    private struct Response: Decodable {
        struct RateLimit: Decodable {
            struct Window: Decodable {
                let usedPercent: Double?
                let resetAt: Double?
            }
            let primaryWindow: Window?
            let secondaryWindow: Window?
        }
        struct ResetSummary: Decodable {
            let availableCount: Int?
            let applicableAvailableCount: Int?
        }
        let email: String?
        let planType: String?
        let rateLimit: RateLimit?
        // `Lenient`, not a bare `ResetSummary?` — a malformed reset block must
        // not throw and take the rate-limit windows down with it; see
        // `Lenient`.
        let rateLimitResetCredits: Lenient<ResetSummary>?
    }

    /// Built only from a percentage the provider actually sent — an absent
    /// window is left out rather than reported as zero.
    private static func window(_ window: Response.RateLimit.Window?, label: String) -> LimitWindow? {
        guard let used = window?.usedPercent else { return nil }
        return LimitWindow(
            percent: used,
            resetsAt: window?.resetAt.map { Date(timeIntervalSince1970: $0) },
            label: label
        )
    }

    /// Every Codex credit is a "Full reset (Weekly + 5 hr)".
    private static let clearedWindows = ["5 hours", "Week"]

    private static func resets(from summary: Response.ResetSummary?) -> ResetCredits? {
        guard let count = summary?.availableCount, count > 0 else { return nil }
        // `applicable_available_count` sat at 0 beside one held credit while
        // the windows read 0% and 5% (2026-09-24), so it reads as "usable only
        // once a limit is hit". Absent, the button stays live — the server
        // answers `nothing_to_reset` if it disagrees.
        let usableNow = summary?.applicableAvailableCount.map { $0 > 0 } ?? true
        return ResetCredits(
            available: count,
            expiresAt: nil,
            clears: clearedWindows,
            usableNow: usableNow,
            blockedReason: usableNow ? nil : "Usable once you hit a limit",
            claimID: ""
        )
    }

    private struct CreditList: Decodable {
        struct Credit: Decodable {
            let id: String
            let status: String?
            let expiresAt: String?
        }
        let credits: [Credit]
    }

    /// The credit to spend next: the available one that expires first, so a
    /// reset is never lost to its date while a later one is used. One still
    /// marked available after its expiry at `now` is skipped — neither
    /// spendable nor a date to warn by, and as the earliest it would withdraw
    /// every good credit (see `ResetCredits.current(now:)`).
    public static func parseCreditDetails(_ data: Data, now: Date) throws -> (expiresAt: Date?, claimID: String)? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let list = try decoder.decode(CreditList.self, from: data)
        let next = list.credits
            .filter { $0.status == "available" }
            .map { (credit: $0, expiresAt: AnthropicUsage.date($0.expiresAt)) }
            .filter { $0.expiresAt.map { $0 > now } ?? true }
            .min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        guard let next else { return nil }
        return (next.expiresAt, next.credit.id)
    }

    public static func parse(
        _ data: Data,
        fetchedAt: Date
    ) throws -> (usage: AccountUsage, email: String?, plan: String?) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)

        let usage = AccountUsage(
            session: window(response.rateLimit?.primaryWindow, label: "5 hours"),
            weekly: window(response.rateLimit?.secondaryWindow, label: "Week"),
            scoped: [],
            fetchedAt: fetchedAt,
            staleness: .fresh,
            resets: resets(from: response.rateLimitResetCredits?.value)
        )
        return (usage, response.email, response.planType)
    }
}

public struct CodexUsageClient: UsageProvider {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(account: Account) async throws -> AccountUsage {
        let (data, response) = try await session.data(for: request(HeadroomConstants.codexUsageURL, account: account))
        try checkStatus(response)
        let usage = try CodexUsage.parse(data, fetchedAt: Date()).usage
        guard let resets = usage.resets else { return usage }
        return usage.replacingResets(await detailed(resets, account: account, now: usage.fetchedAt))
    }

    /// The expiry and the credit id come from a second endpoint. Its failure
    /// costs only the date: the count is already known, and the reading itself
    /// must not fail over a detail.
    private func detailed(_ resets: ResetCredits, account: Account, now: Date) async -> ResetCredits {
        guard let (data, response) = try? await session.data(for: request(HeadroomConstants.codexResetCreditsURL, account: account)),
              (try? checkStatus(response)) != nil,
              let details = try? CodexUsage.parseCreditDetails(data, now: now)
        else { return resets }
        return ResetCredits(
            available: resets.available,
            expiresAt: details.expiresAt,
            clears: resets.clears,
            usableNow: resets.usableNow,
            blockedReason: resets.blockedReason,
            claimID: details.claimID
        )
    }

    private func request(_ url: URL, account: Account) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = account.accountId {
            request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
