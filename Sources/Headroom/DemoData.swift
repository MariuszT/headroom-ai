import Foundation
import HeadroomCore

/// A populated panel for screenshots and for looking at the layout without
/// connecting anything. Enabled with `HEADROOM_DEMO=1` in the environment; the
/// app then never reads or writes the account store and never polls, so it
/// cannot disturb real accounts.
///
/// The accounts are chosen to show every state the panel can be in — fresh,
/// busy, over the amber line, exhausted, signed out, and stale — because a
/// screenshot of nine healthy accounts says nothing about what the app does
/// when something is wrong.
enum DemoData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["HEADROOM_DEMO"] == "1"
    }

    private static func account(_ provider: Provider, _ email: String, needsReauth: Bool = false) -> Account {
        Account(
            provider: provider,
            email: email,
            accessToken: "demo",
            refreshToken: "demo",
            expiresAt: .distantFuture,
            accountId: provider == .openai ? "demo" : nil,
            needsReauth: needsReauth
        )
    }

    static let accounts: [Account] = [
        account(.anthropic, "work@example.com"),
        account(.anthropic, "team@example.com"),
        account(.anthropic, "research@example.com"),
        account(.anthropic, "release@example.com"),
        account(.anthropic, "archive@example.com", needsReauth: true),
        account(.openai, "personal@example.com"),
        account(.openai, "plus@example.com"),
        account(.openai, "pro@example.com"),
        account(.openai, "shared@example.com"),
    ]

    static var usage: [String: AccountUsage] {
        let now = Date()
        func window(_ percent: Double, _ label: String, in seconds: TimeInterval?) -> LimitWindow {
            LimitWindow(
                percent: percent,
                resetsAt: seconds.map { now.addingTimeInterval($0) },
                label: label
            )
        }
        func entry(
            _ session: Double, in sessionResets: TimeInterval,
            week: Double, in weekResets: TimeInterval,
            model: Double? = nil,
            staleness: Staleness = .fresh
        ) -> AccountUsage {
            AccountUsage(
                session: window(session, "5 hours", in: sessionResets),
                weekly: window(week, "Week", in: weekResets),
                scoped: model.map { [window($0, "Fable", in: weekResets)] } ?? [],
                fetchedAt: now,
                staleness: staleness
            )
        }

        let day: TimeInterval = 86_400
        return [
            "anthropic:work@example.com": entry(4, in: 3.7 * 3600, week: 12, in: 5.2 * day, model: 0),
            "anthropic:team@example.com": entry(38, in: 1.2 * 3600, week: 26, in: 5.2 * day, model: 9),
            "anthropic:research@example.com": entry(84, in: 2.1 * 3600, week: 61, in: 5.2 * day, model: 47),
            "anthropic:release@example.com": entry(100, in: 18 * 60, week: 73, in: 5.2 * day, model: 12),
            "openai:personal@example.com": entry(0, in: 4.98 * 3600, week: 3, in: 1.9 * day),
            "openai:plus@example.com": entry(55, in: 2.3 * 3600, week: 41, in: 1.9 * day),
            "openai:pro@example.com": entry(92, in: 47 * 60, week: 88, in: 1.9 * day),
            "openai:shared@example.com": entry(
                31, in: 3.4 * 3600, week: 19, in: 1.9 * day,
                staleness: .cached(since: now.addingTimeInterval(-6 * 60))
            ),
            // archive@example.com has no usage on purpose: an account that needs
            // signing in again is one nothing is known about.
        ]
    }
}
