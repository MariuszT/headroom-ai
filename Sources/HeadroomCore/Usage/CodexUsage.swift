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
        let email: String?
        let planType: String?
        let rateLimit: RateLimit?
    }

    private static func window(_ window: Response.RateLimit.Window?, label: String) -> LimitWindow {
        LimitWindow(
            percent: window?.usedPercent ?? 0,
            resetsAt: window?.resetAt.map { Date(timeIntervalSince1970: $0) },
            label: label
        )
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
            staleness: .fresh
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
        var request = URLRequest(url: HeadroomConstants.codexUsageURL)
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = account.accountId {
            request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try checkStatus(response)
        return try CodexUsage.parse(data, fetchedAt: Date()).usage
    }
}
