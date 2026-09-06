import Testing
import Foundation
@testable import HeadroomCore

private func memoryStore() -> AccountStore {
    AccountStore(secrets: InMemorySecretStore())
}

private func sampleAccount(email: String = "a@b.pl") -> Account {
    Account(
        provider: .anthropic, email: email,
        accessToken: "tok", refreshToken: "ref",
        expiresAt: Date(timeIntervalSince1970: 1_788_500_000)
    )
}

@Test func anEmptyStoreReturnsAnEmptyList() throws {
    #expect(try memoryStore().load().isEmpty)
}

@Test func writingAndReadingPreservesTokens() throws {
    let store = memoryStore()
    try store.upsert(sampleAccount())
    let loaded = try store.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].refreshToken == "ref")
}

@Test func upsertOverwritesAnAccountWithTheSameIdentifier() throws {
    let store = memoryStore()
    try store.upsert(sampleAccount())
    var changed = sampleAccount()
    changed.accessToken = "rotated"
    try store.upsert(changed)
    let loaded = try store.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].accessToken == "rotated")
}

@Test func removingAnAccountWorksByIdentifier() throws {
    let store = memoryStore()
    try store.upsert(sampleAccount(email: "a@b.pl"))
    try store.upsert(sampleAccount(email: "c@d.pl"))
    try store.remove(id: "anthropic:a@b.pl")
    #expect(try store.load().map(\.email) == ["c@d.pl"])
}

@Test func expirySurvivesTheRoundTrip() throws {
    let store = memoryStore()
    try store.upsert(sampleAccount())
    #expect(try store.load()[0].expiresAt == Date(timeIntervalSince1970: 1_788_500_000))
}

/// Removing the last account must leave the slot genuinely empty rather than a
/// stored "[]", so that a later migration can tell "nothing here" from "someone
/// deliberately has no accounts" — and so the tokens' slot does not outlive the
/// tokens.
@Test func removingTheLastAccountClearsTheSecretSlot() throws {
    let secrets = InMemorySecretStore()
    let store = AccountStore(secrets: secrets)
    try store.upsert(sampleAccount())
    try store.remove(id: "anthropic:a@b.pl")
    #expect(try secrets.read() == nil)
}

/// A slot holding bytes that are not a valid account list is a real failure and
/// has to be reported — swallowing it would silently present the user with zero
/// accounts and then overwrite the damaged data on the next write.
@Test func unreadableStoredBytesThrow() throws {
    let store = AccountStore(secrets: InMemorySecretStore(data: Data("not json".utf8)))
    #expect(throws: (any Error).self) { try store.load() }
}

/// `update` exists so the poller cannot bring back an account the user deleted
/// while a check was in flight. A pass loads its accounts once and can be many
/// seconds long; `upsert` appends when the id is gone, so the deleted account
/// would reappear — usually flagged `needsReauth`, since a dead token is what
/// the write was recording.
@Test func updateDoesNothingWhenTheAccountIsNoLongerStored() throws {
    let store = memoryStore()
    try store.upsert(sampleAccount(email: "a@b.pl"))
    try store.remove(id: "anthropic:a@b.pl")

    var vanished = sampleAccount(email: "a@b.pl")
    vanished.needsReauth = true
    let written = try store.update(vanished)

    #expect(written == false)
    #expect(try store.load().isEmpty)
}

@Test func updateWritesAnAccountThatIsStillStored() throws {
    let store = memoryStore()
    try store.upsert(sampleAccount())

    var rotated = sampleAccount()
    rotated.accessToken = "rotated"
    let written = try store.update(rotated)

    #expect(written == true)
    #expect(try store.load()[0].accessToken == "rotated")
}

@Test func updateLeavesTheOtherAccountsAlone() throws {
    let store = memoryStore()
    try store.upsert(sampleAccount(email: "a@b.pl"))
    try store.upsert(sampleAccount(email: "c@d.pl"))

    var changed = sampleAccount(email: "c@d.pl")
    changed.accessToken = "rotated"
    _ = try store.update(changed)

    #expect(try store.load().map(\.email) == ["a@b.pl", "c@d.pl"])
    #expect(try store.load()[0].accessToken == "tok")
}

/// `upsert`, `update` and `remove` are read-modify-write over one blob, and
/// `AccountStore` is `Sendable` — it is written from three places that know
/// nothing of each other: `Poller` (an actor) rotating tokens, `LoginFlow`
/// storing a fresh sign-in from its own task, and `AppModel.remove` on the main
/// actor. Without serialising, the loser's write is simply dropped: a
/// just-added account vanishes, or a rotated refresh token is lost — and at
/// Anthropic the previous one is already dead on the server, so that account
/// then needs signing in again.
@Test func concurrentWritesDoNotLoseEachOther() async throws {
    let store = AccountStore(secrets: InMemorySecretStore())
    let count = 60

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<count {
            group.addTask {
                try? store.upsert(sampleAccount(email: "a\(index)@b.pl"))
            }
        }
    }

    #expect(try store.load().count == count)
}

/// The same for a mix of the operations, which is what actually happens: a
/// rotation lands while a sign-in is being stored.
@Test func concurrentUpdatesAndInsertsDoNotLoseEachOther() async throws {
    let store = AccountStore(secrets: InMemorySecretStore())
    for index in 0..<20 {
        try store.upsert(sampleAccount(email: "seed\(index)@b.pl"))
    }

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
            group.addTask {
                var rotated = sampleAccount(email: "seed\(index)@b.pl")
                rotated.accessToken = "rotated"
                _ = try? store.update(rotated)
            }
            group.addTask {
                try? store.upsert(sampleAccount(email: "new\(index)@b.pl"))
            }
        }
    }

    let loaded = try store.load()
    #expect(loaded.count == 40)
    #expect(loaded.filter { $0.accessToken == "rotated" }.count == 20)
}
