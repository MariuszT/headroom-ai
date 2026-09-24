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
        /// The banked limit resets — Anthropic's internal name for the
        /// programme. Present only when the request asks for it.
        struct CedarEmber: Decodable {
            struct Grant: Decodable {
                let id: String?
                let resetsLeft: Int?
                let endsAt: String?
                let clears: [String]?
                let paused: Bool?
                let usableNow: Bool?
                let useRequiresLimit: Bool?
            }
            let eligible: Bool?
            let grants: [Grant]?
            let nextGrantId: String?
            let cooldownUntil: String?
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?
        // `Lenient`, not a bare `CedarEmber?`: a malformed reset block (a field
        // of the wrong type deep inside a grant) must not throw and take
        // `fiveHour`/`sevenDay` down with it — see `Lenient`.
        let cedarEmber: Lenient<CedarEmber>?
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

    /// The provider's window names mapped to the panel's labels. Names it does
    /// not map (the overage allowance, say) have no bar to clear, so they are
    /// left out rather than shown under a raw key.
    private static let windowLabels = ["five_hour": "5 hours", "seven_day": "Week"]

    private static func cooldownText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM HH:mm"
        return "Cooling down until \(formatter.string(from: date))"
    }

    private static func resets(from block: Response.CedarEmber?, fetchedAt: Date) -> ResetCredits? {
        guard let block, block.eligible == true else { return nil }
        let grants = block.grants ?? []
        // A grant the server still lists after its end is not a reset the
        // account holds: counted, its past date would become the earliest and
        // withdraw every good reset for as long as the server keeps listing it
        // (see `ResetCredits.current(now:)`).
        let usable = grants.filter { grant in
            guard (grant.resetsLeft ?? 0) > 0, grant.id != nil else { return false }
            return date(grant.endsAt).map { $0 > fetchedAt } ?? true
        }
        // The server's own pick wins; list order is only the fallback.
        guard let grant = usable.first(where: { $0.id == block.nextGrantId }) ?? usable.first,
              let id = grant.id
        else { return nil }
        // Every grant with resets left is a reset the account holds, so the
        // count spans all of them — only the claim (and with it what it
        // clears) belongs to the one grant spent next. The date is the
        // earliest among them: the line warns about the reset that runs out
        // first, and `ResetCredits.current(now:)` withdraws the offer once it
        // has, whichever grant the server would have spent.
        let available = usable.reduce(0) { $0 + ($1.resetsLeft ?? 0) }
        let expiresAt = usable.compactMap { date($0.endsAt) }.min()

        // Only a cooldown still running at the moment of the reading counts:
        // the field can outlive its own end, and a date already past would
        // otherwise block the reset for good while promising it "until" then.
        let cooldown = date(block.cooldownUntil).flatMap { $0 > fetchedAt ? $0 : nil }
        let paused = grant.paused == true
        let usableNow = grant.usableNow == true && cooldown == nil && !paused
        let blockedReason: String? = if usableNow {
            nil
        } else if let cooldown {
            cooldownText(cooldown)
        } else if paused {
            "Paused by Anthropic"
        } else if grant.useRequiresLimit == true {
            "Usable once you hit a limit"
        } else {
            "Not usable right now"
        }

        return ResetCredits(
            available: available,
            expiresAt: expiresAt,
            clears: (grant.clears ?? []).compactMap { windowLabels[$0] },
            usableNow: usableNow,
            blockedReason: blockedReason,
            claimID: id
        )
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
            staleness: .fresh,
            resets: resets(from: response.cedarEmber?.value, fetchedAt: fetchedAt)
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
