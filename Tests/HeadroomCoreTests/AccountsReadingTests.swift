import Testing
import Foundation
import Security
@testable import HeadroomCore

private func sampleAccount(email: String = "a@b.pl") -> Account {
    Account(provider: .anthropic, email: email, expiresAt: .distantPast)
}

/// Refuses every read the way a locked keychain does.
private struct LockedSecretStore: SecretStore {
    func read() throws -> Data? { throw KeychainError(status: errSecInteractionNotAllowed) }
    func write(_ data: Data) throws {}
    func delete() throws {}
}

@Test func aSuccessfulReloadReportsWhatWasStored() throws {
    let store = AccountStore(secrets: InMemorySecretStore())
    try store.upsert(sampleAccount())

    #expect(store.reload(keeping: []) == .loaded([sampleAccount()]))
}

/// An empty store is a legitimate answer, not a failure — this is what a first
/// launch looks like.
@Test func reloadingAnEmptyStoreReportsNoAccountsRatherThanAnError() {
    #expect(AccountStore(secrets: InMemorySecretStore()).reload(keeping: []) == .loaded([]))
}

/// The bug this replaces: `(try? store.load()) ?? []` turned a locked keychain
/// into an empty list, so the panel showed nothing and the user read it as
/// "my accounts are gone".
@Test func aFailedReloadKeepsTheAccountsAlreadyOnScreen() {
    let previous = [sampleAccount()]

    let reading = AccountStore(secrets: LockedSecretStore()).reload(keeping: previous)

    guard case .failed(let kept, _) = reading else {
        Issue.record("expected a failure, got \(reading)")
        return
    }
    #expect(kept == previous)
}

/// A bare OSStatus in the panel tells nobody what went wrong; the system's own
/// sentence for the code does.
@Test func aFailedReloadExplainsItselfInWords() {
    let reading = AccountStore(secrets: LockedSecretStore()).reload(keeping: [])

    guard case .failed(_, let message) = reading else {
        Issue.record("expected a failure, got \(reading)")
        return
    }
    #expect(message.contains("interact") || message.contains("Interaction"))
    #expect(message.contains("\(errSecInteractionNotAllowed)") == false)
}
