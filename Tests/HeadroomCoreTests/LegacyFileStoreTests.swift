import Testing
import Foundation
@testable import HeadroomCore

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Exactly the shape the file-backed store used to write: dates as seconds
/// since the epoch, keys sorted. This is a real user's accounts.json, so the
/// test fails the day the decode stops matching what is on their disk.
private let storedDocument = """
[
  {
    "accessToken" : "tok",
    "email" : "a@b.pl",
    "expiresAt" : 1788500000,
    "hasSubscription" : true,
    "needsReauth" : false,
    "plan" : "max",
    "provider" : "anthropic",
    "refreshToken" : "ref"
  }
]
"""

private func writeStoredDocument(_ text: String = storedDocument, into directory: URL) throws {
    try Data(text.utf8).write(to: directory.appendingPathComponent("accounts.json"))
}

@Test func theLegacyStoreReadsAnAccountsFileWrittenByAnOlderVersion() throws {
    let directory = try tempDir()
    try writeStoredDocument(into: directory)

    let accounts = try LegacyFileStore(directory: directory).load()

    #expect(accounts.count == 1)
    #expect(accounts[0].email == "a@b.pl")
    #expect(accounts[0].refreshToken == "ref")
    #expect(accounts[0].expiresAt == Date(timeIntervalSince1970: 1_788_500_000))
    #expect(accounts[0].plan == "max")
}

@Test func theLegacyStoreReadsNothingWhenThereIsNoFile() throws {
    #expect(try LegacyFileStore(directory: try tempDir()).load().isEmpty)
}

@Test func theLegacyStoreReadsNothingFromAnEmptyFile() throws {
    let directory = try tempDir()
    try writeStoredDocument("", into: directory)
    #expect(try LegacyFileStore(directory: directory).load().isEmpty)
}

@Test func theLegacyStorePointsAtAccountsJson() throws {
    let directory = try tempDir()
    #expect(LegacyFileStore(directory: directory).fileURL.lastPathComponent == "accounts.json")
}

/// The two places an installed copy may have left a file: the current name and
/// the one before the rebrand. Both have to be looked at, and they must not be
/// the same directory.
@Test func theLegacyStoresCoverBothTheCurrentAndThePreRebrandDirectory() {
    let names = LegacyFileStore.all.map(\.directory.lastPathComponent)
    #expect(names == ["Headroom", "Limity"])
}
