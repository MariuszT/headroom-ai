import Testing
import Foundation
@testable import HeadroomCore

private func tempDefaults() -> (defaults: UserDefaults, name: String) {
    let name = UUID().uuidString
    return (UserDefaults(suiteName: name)!, name)
}

private let schedule = RenewalSchedule(
    anchor: Date(timeIntervalSince1970: 1_789_000_000),
    cycle: .monthly,
    leadDays: 3
)

/// The renewal lives in `Preferences`, keyed by account id, and NOT on
/// `Account` — which is what the obvious design would have done.
///
/// Two writers would have clobbered it there. `Poller.refresh` takes a snapshot
/// of the account at the start of a pass and, after rotating a token, writes
/// that whole snapshot back through `store.update`; a renewal edited while a
/// check was in flight would be overwritten by the older copy. And signing an
/// account in again goes through `upsert`, which replaces the whole record — so
/// every re-login would wipe the date. A date the user typed is also not a
/// secret, so the keychain is the wrong home for it either way.
@Test func aRenewalSurvivesAWriteAndComesBackUnchanged() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)

    preferences.setRenewal(schedule, for: "anthropic:a@b.pl")

    #expect(preferences.renewal(for: "anthropic:a@b.pl") == schedule)
}


@Test func oneAccountsRenewalSaysNothingAboutAnothers() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)

    preferences.setRenewal(schedule, for: "anthropic:a@b.pl")

    #expect(preferences.renewal(for: "openai:a@b.pl") == nil)
}


@Test func clearingARenewalRemovesIt() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)
    preferences.setRenewal(schedule, for: "anthropic:a@b.pl")

    preferences.setRenewal(nil, for: "anthropic:a@b.pl")

    #expect(preferences.renewal(for: "anthropic:a@b.pl") == nil)
}


/// Stored shapes change between versions, and a renewal that no longer decodes
/// reads as "none set" rather than throwing the panel over. The same rule the
/// rest of `Preferences` already follows for an unrecognised sort mode.
@Test func aStoredValueThatNoLongerDecodesReadsAsNoRenewal() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(Data("not a renewal".utf8), forKey: "renewal.anthropic:a@b.pl")

    #expect(Preferences(defaults: defaults).renewal(for: "anthropic:a@b.pl") == nil)
}
