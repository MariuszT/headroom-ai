import Testing
import Foundation
@testable import HeadroomCore

/// Every test gets a service name of its own, so a run never collides with the
/// real "pl.tarnaski.headroom" entry of an installed copy of the app — and two
/// tests running in parallel never collide with each other.
private func temporaryKeychainStore() -> KeychainSecretStore {
    KeychainSecretStore(
        service: "pl.tarnaski.headroom.tests.\(UUID().uuidString)",
        account: "accounts"
    )
}

@Test func anUnwrittenKeychainSlotReadsAsNil() throws {
    let store = temporaryKeychainStore()
    defer { try? store.delete() }
    #expect(try store.read() == nil)
}

@Test func keychainWriteThenReadReturnsTheSameBytes() throws {
    let store = temporaryKeychainStore()
    defer { try? store.delete() }
    try store.write(Data("tokens".utf8))
    #expect(try store.read() == Data("tokens".utf8))
}

/// A second write has to UPDATE the existing item. Adding blindly would return
/// `errSecDuplicateItem`, and every token refresh — which rewrites the whole
/// document — would fail from the second one onward.
@Test func aSecondKeychainWriteReplacesTheFirst() throws {
    let store = temporaryKeychainStore()
    defer { try? store.delete() }
    try store.write(Data("first".utf8))
    try store.write(Data("second".utf8))
    #expect(try store.read() == Data("second".utf8))
}

@Test func deletingAKeychainSlotLeavesNothingToRead() throws {
    let store = temporaryKeychainStore()
    try store.write(Data("tokens".utf8))
    try store.delete()
    #expect(try store.read() == nil)
}

@Test func deletingAnAbsentKeychainSlotIsNotAnError() throws {
    try temporaryKeychainStore().delete()
}

/// Two stores naming the same slot are the same slot — this is what makes the
/// app see what a previous launch wrote.
@Test func aSeparateInstanceReadsWhatAnotherWrote() throws {
    let service = "pl.tarnaski.headroom.tests.\(UUID().uuidString)"
    let writer = KeychainSecretStore(service: service, account: "accounts")
    let reader = KeychainSecretStore(service: service, account: "accounts")
    defer { try? writer.delete() }

    try writer.write(Data("tokens".utf8))

    #expect(try reader.read() == Data("tokens".utf8))
}
