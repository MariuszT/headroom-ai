import Testing
import Foundation
@testable import HeadroomCore

private func account(needsReauth: Bool = false, provider: Provider = .anthropic) -> Account {
    Account(provider: provider, email: "a@b.pl", expiresAt: .distantPast, needsReauth: needsReauth)
}

private func usage(
    windows: Bool = true,
    staleness: Staleness = .fresh,
    fetchedAt: Date = Date()
) -> AccountUsage {
    AccountUsage(
        session: windows ? LimitWindow(percent: 10, resetsAt: nil, label: "5 hours") : nil,
        weekly: windows ? LimitWindow(percent: 20, resetsAt: nil, label: "Week") : nil,
        scoped: [],
        fetchedAt: fetchedAt,
        staleness: staleness
    )
}

/// A healthy account says nothing: the lines above it already carry the whole
/// story, and a note repeating them would be noise.
@Test func aFreshReadingWithWindowsNeedsNoNote() {
    #expect(AccountNote.text(for: account(), usage: usage()) == nil)
}

@Test func anAccountNeverCheckedSaysSo() {
    #expect(AccountNote.text(for: account(), usage: nil) == "Waiting for the first check.")
}

@Test func aRejectedAccountNamesItsOwnProvider() {
    #expect(AccountNote.text(for: account(needsReauth: true, provider: .openai), usage: usage())
        == "Rejected by Codex. Add this account again to renew it.")
}

@Test func anErrorSpeaksInTheWordsItCameWith() {
    let note = AccountNote.text(for: account(), usage: usage(staleness: .error("No connection.")))
    #expect(note == "No connection.")
}

@Test func aCachedReadingSaysHowOldItIs() {
    let note = AccountNote.text(for: account(), usage: usage(staleness: .cached(since: Date())))
    #expect(note?.hasPrefix("Last checked") == true)
}

/// The gap that making the windows optional opened. A reply that parses but
/// carries no windows is a real shape — `AnthropicUsage.parse(Data("{}"))`
/// produces exactly it — and every branch above declines to speak for it, so
/// the cell rendered its address, two buttons and nothing else: no bars, no
/// reason. A renamed field at either provider would blank every row on the
/// panel without a word.
@Test func aReplyCarryingNoWindowsExplainsItself() {
    #expect(AccountNote.text(for: account(), usage: usage(windows: false))
        == "Checked, but the provider reported no limits.")
}

/// The reason beats the silence even when the reading is merely stale.
@Test func aCachedReplyCarryingNoWindowsAlsoExplainsItself() {
    let note = AccountNote.text(
        for: account(),
        usage: usage(windows: false, staleness: .cached(since: Date()))
    )
    #expect(note == "Checked, but the provider reported no limits.")
}
