import Foundation

public enum AnthropicUsage {
    private struct Response: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
        }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let displayName: String? }
                let model: Model?
            }
            let kind: String?
            let percent: Double?
            let resetsAt: String?
            let scope: Scope?
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }

        // Two variants, because the `resets_at` fields carry a six-digit
        // fraction of a second that a formatter without `.withFractionalSeconds`
        // refuses.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = withFraction.date(from: text) {
            return date
        }

        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        return withoutFraction.date(from: text)
    }

    public static func parse(_ data: Data, fetchedAt: Date) throws -> AccountUsage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)

        // A window is built only from a utilization the provider actually
        // sent. Absent or null means nothing is known about it, and it is left
        // out entirely rather than reported as zero.
        func window(_ raw: Response.Window?, label: String) -> LimitWindow? {
            guard let utilization = raw?.utilization else { return nil }
            return LimitWindow(percent: utilization, resetsAt: date(raw?.resetsAt), label: label)
        }

        let session = window(response.fiveHour, label: "5 hours")
        let weekly = window(response.sevenDay, label: "Week")
        let scoped = (response.limits ?? [])
            .filter { $0.kind == "weekly_scoped" }
            .compactMap { limit -> LimitWindow? in
                guard let name = limit.scope?.model?.displayName,
                      let percent = limit.percent else { return nil }
                return LimitWindow(percent: percent, resetsAt: date(limit.resetsAt), label: name)
            }

        return AccountUsage(
            session: session,
            weekly: weekly,
            scoped: scoped,
            fetchedAt: fetchedAt,
            staleness: .fresh
        )
    }
}

public struct AnthropicUsageClient: UsageProvider {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(account: Account) async throws -> AccountUsage {
        var request = URLRequest(url: HeadroomConstants.anthropicUsageURL)
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(HeadroomConstants.anthropicBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(HeadroomConstants.anthropicUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, body: data)
        return try AnthropicUsage.parse(data, fetchedAt: Date())
    }
}
