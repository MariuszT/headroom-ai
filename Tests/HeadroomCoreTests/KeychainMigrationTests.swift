import Testing
import Foundation
@testable import HeadroomCore

private func tempDir(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeAccounts(_ emails: [String], into directory: URL) throws {
    // Re-created on purpose: a test that writes the file again after a
    // migration is modelling a delete that failed, and the migration removed
    // the directory along with it.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let accounts = emails.map {
        Account(
            provider: .anthropic, email: $0,
            accessToken: "tok", refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 1_788_500_000)
        )
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode(accounts).write(to: directory.appendingPathComponent("accounts.json"))
}

/// A fresh marker per test, so no test can see another's.
private func marker() -> MigrationMarker {
    MigrationMarker(defaults: UserDefaults(suiteName: UUID().uuidString)!)
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

@Test func migrationImportsAccountsFromTheLegacyFile() throws {
    let directory = try tempDir("Headroom")
    try writeAccounts(["a@b.pl"], into: directory)
    let store = AccountStore(secrets: InMemorySecretStore())

    let migrated = try KeychainMigration.run(from: [LegacyFileStore(directory: directory)], to: store, marker: marker())

    #expect(migrated == true)
    #expect(try store.load().map(\.email) == ["a@b.pl"])
}

/// The tokens have to leave the disk — an import that keeps the file achieves
/// nothing the change was made for.
@Test func migrationRemovesEveryLegacyDirectoryOnceImported() throws {
    let current = try tempDir("Headroom")
    let preRebrand = try tempDir("Limity")
    try writeAccounts(["a@b.pl"], into: current)
    try writeAccounts(["old@b.pl"], into: preRebrand)

    _ = try KeychainMigration.run(
        from: [LegacyFileStore(directory: current), LegacyFileStore(directory: preRebrand)],
        to: AccountStore(secrets: InMemorySecretStore()),
        marker: marker()
    )

    #expect(exists(current) == false)
    #expect(exists(preRebrand) == false)
}

/// Both directories can hold a file; the one listed first is the current name
/// and therefore the more recent truth.
@Test func migrationTakesTheFirstDirectoryThatHoldsAnything() throws {
    let current = try tempDir("Headroom")
    let preRebrand = try tempDir("Limity")
    try writeAccounts(["current@b.pl"], into: current)
    try writeAccounts(["old@b.pl"], into: preRebrand)
    let store = AccountStore(secrets: InMemorySecretStore())

    _ = try KeychainMigration.run(
        from: [LegacyFileStore(directory: current), LegacyFileStore(directory: preRebrand)],
        to: store,
        marker: marker()
    )

    #expect(try store.load().map(\.email) == ["current@b.pl"])
}

@Test func migrationFallsBackToThePreRebrandDirectory() throws {
    let current = try tempDir("Headroom")
    let preRebrand = try tempDir("Limity")
    try writeAccounts(["old@b.pl"], into: preRebrand)
    let store = AccountStore(secrets: InMemorySecretStore())

    let migrated = try KeychainMigration.run(
        from: [LegacyFileStore(directory: current), LegacyFileStore(directory: preRebrand)],
        to: store,
        marker: marker()
    )

    #expect(migrated == true)
    #expect(try store.load().map(\.email) == ["old@b.pl"])
}

/// A keychain that already holds accounts is the newer truth. Importing over it
/// would undo whatever happened since, and deleting the file would destroy the
/// only other copy — so this case touches neither.
@Test func migrationDoesNothingWhenTheKeychainAlreadyHasAccounts() throws {
    let directory = try tempDir("Headroom")
    try writeAccounts(["fromFile@b.pl"], into: directory)
    let store = AccountStore(secrets: InMemorySecretStore())
    try store.upsert(
        Account(provider: .anthropic, email: "inKeychain@b.pl", expiresAt: .distantPast)
    )

    let migrated = try KeychainMigration.run(from: [LegacyFileStore(directory: directory)], to: store, marker: marker())

    #expect(migrated == false)
    #expect(try store.load().map(\.email) == ["inKeychain@b.pl"])
    #expect(exists(directory) == true)
}

@Test func migrationIsANoOpWhenThereIsNothingToImport() throws {
    let migrated = try KeychainMigration.run(
        from: [LegacyFileStore(directory: try tempDir("Headroom"))],
        to: AccountStore(secrets: InMemorySecretStore()),
        marker: marker()
    )
    #expect(migrated == false)
}

/// Verify before deleting: a write that cannot be read back has not happened,
/// and the file is the only remaining copy of the tokens.
@Test func migrationKeepsTheFileWhenTheImportCannotBeReadBack() throws {
    let directory = try tempDir("Headroom")
    try writeAccounts(["a@b.pl"], into: directory)

    let migrated = try KeychainMigration.run(
        from: [LegacyFileStore(directory: directory)],
        to: AccountStore(secrets: SwallowingSecretStore()),
        marker: marker()
    )

    #expect(migrated == false)
    #expect(exists(directory) == true)
}

/// Accepts every write and forgets it — the shape of a keychain that reports
/// success but stores nothing.
private struct SwallowingSecretStore: SecretStore {
    func read() throws -> Data? { nil }
    func write(_ data: Data) throws {}
    func delete() throws {}
}

// MARK: - Having run once is remembered, not inferred

/// An empty keychain used to mean "not migrated yet". It does not: removing the
/// last account clears the slot (see `removingTheLastAccountClearsTheSecretSlot`),
/// so if the legacy file had survived the delete — it is removed with `try?` —
/// the next launch would import the accounts the user had just deleted.
@Test func migrationDoesNotRunAgainOnceItHas() throws {
    let directory = try tempDir("Headroom")
    try writeAccounts(["a@b.pl"], into: directory)
    let done = marker()
    let store = AccountStore(secrets: InMemorySecretStore())

    #expect(try KeychainMigration.run(from: [LegacyFileStore(directory: directory)], to: store, marker: done) == true)

    // The user then deletes every account, which empties the slot, and the
    // file is somehow still on disk.
    try store.save([])
    try writeAccounts(["a@b.pl"], into: directory)

    #expect(try KeychainMigration.run(from: [LegacyFileStore(directory: directory)], to: store, marker: done) == false)
    #expect(try store.load().isEmpty)
}

/// A file that outlived a failed delete still holds live tokens, so later runs
/// keep trying to remove it even though there is nothing left to import.
@Test func aLegacyDirectoryLeftBehindIsStillCleanedUpOnALaterRun() throws {
    let directory = try tempDir("Headroom")
    try writeAccounts(["a@b.pl"], into: directory)
    let done = marker()
    let store = AccountStore(secrets: InMemorySecretStore())

    _ = try KeychainMigration.run(from: [LegacyFileStore(directory: directory)], to: store, marker: done)
    try writeAccounts(["a@b.pl"], into: directory) // as though the delete had failed

    _ = try KeychainMigration.run(from: [LegacyFileStore(directory: directory)], to: store, marker: done)

    #expect(exists(directory) == false)
}

/// One unreadable file must not take the others down with it. `AppModel` calls
/// the migration through `try?`, so a throw here left the user with an empty
/// panel, no message, and their tokens still on disk.
@Test func anUnreadableDirectoryDoesNotStopTheNextOneBeingImported() throws {
    let broken = try tempDir("Headroom")
    let preRebrand = try tempDir("Limity")
    try Data("this is not an account list".utf8)
        .write(to: broken.appendingPathComponent("accounts.json"))
    try writeAccounts(["old@b.pl"], into: preRebrand)
    let store = AccountStore(secrets: InMemorySecretStore())

    let migrated = try KeychainMigration.run(
        from: [LegacyFileStore(directory: broken), LegacyFileStore(directory: preRebrand)],
        to: store,
        marker: marker()
    )

    #expect(migrated == true)
    #expect(try store.load().map(\.email) == ["old@b.pl"])
}
