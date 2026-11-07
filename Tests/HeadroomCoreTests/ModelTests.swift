import Testing
import Foundation
@testable import HeadroomCore

@Test func worstPercentTakesTheHighestValue() {
    let usage = AccountUsage(
        session: LimitWindow(percent: 54, resetsAt: nil, label: "5h"),
        weekly: LimitWindow(percent: 10, resetsAt: nil, label: "7d"),
        scoped: [LimitWindow(percent: 91, resetsAt: nil, label: "Fable")],
        fetchedAt: Date(timeIntervalSince1970: 0),
        staleness: .fresh
    )
    #expect(usage.worstPercent == 91)
}

@Test func anAccountHasAStableIdentifierFromProviderAndEmail() {
    let first = Account(provider: .anthropic, email: "a@b.pl")
    let second = Account(provider: .anthropic, email: "a@b.pl")
    #expect(first.id == second.id)
}

@Test func twoWorkspacesAtOneAddressHaveDifferentIdentifiers() {
    let personal = Account(provider: .anthropic, email: "a@b.pl", organizationUUID: "o-1")
    let team = Account(provider: .anthropic, email: "a@b.pl", organizationUUID: "o-2")
    #expect(personal.id != team.id)

    let plus = Account(provider: .openai, email: "a@b.pl", accountId: "ws-1")
    let business = Account(provider: .openai, email: "a@b.pl", accountId: "ws-2")
    #expect(plus.id != business.id)
}
