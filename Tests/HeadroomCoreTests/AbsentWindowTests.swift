import Testing
import Foundation
@testable import HeadroomCore

/// A window the provider did not send is not a window sitting at zero.
///
/// Reporting an absent field as 0% asserts maximum headroom at exactly the
/// moment nothing is known — the reassuring direction, which this project
/// deliberately errs away from (see the note in `ResetFormatter`). The fixtures
/// already carry `"seven_day_opus": null`, so absent windows are a real shape,
/// and a renamed or nulled field would otherwise paint every account empty.

@Test func anAbsentAnthropicFiveHourWindowIsNotReportedAsEmpty() throws {
    let data = Data(#"{"seven_day": {"utilization": 40}}"#.utf8)

    let usage = try AnthropicUsage.parse(data, fetchedAt: Date())

    #expect(usage.session == nil)
    #expect(usage.weekly?.percent == 40)
}


@Test func anAbsentCodexWindowIsNotReportedAsEmpty() throws {
    let data = Data(#"{"rate_limit": {"primary_window": {"used_percent": 30}}}"#.utf8)

    let parsed = try CodexUsage.parse(data, fetchedAt: Date())

    #expect(parsed.usage.session?.percent == 30)
    #expect(parsed.usage.weekly == nil)
}


/// `windows` is the one list the panel draws and the one `worstPercent` reads,
/// so an absent window disappears from both rather than drawing an empty bar.
@Test func theWindowsListSkipsWhatIsAbsentAndKeepsTheOrder() {
    let usage = AccountUsage(
        session: nil,
        weekly: LimitWindow(percent: 40, resetsAt: nil, label: "Week"),
        scoped: [LimitWindow(percent: 10, resetsAt: nil, label: "Fable")],
        fetchedAt: Date(),
        staleness: .fresh
    )

    #expect(usage.windows.map(\.label) == ["Week", "Fable"])
    #expect(usage.worstPercent == 40)
}
