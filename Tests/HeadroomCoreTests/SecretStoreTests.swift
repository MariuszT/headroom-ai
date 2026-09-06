import Testing
import Foundation
@testable import HeadroomCore

@Test func anEmptySecretStoreReadsAsNil() throws {
    #expect(try InMemorySecretStore().read() == nil)
}

@Test func writingThenReadingReturnsTheSameBytes() throws {
    let store = InMemorySecretStore()
    try store.write(Data("tokens".utf8))
    #expect(try store.read() == Data("tokens".utf8))
}

@Test func writingTwiceKeepsOnlyTheLastValue() throws {
    let store = InMemorySecretStore()
    try store.write(Data("first".utf8))
    try store.write(Data("second".utf8))
    #expect(try store.read() == Data("second".utf8))
}

@Test func deletingLeavesNothingToRead() throws {
    let store = InMemorySecretStore()
    try store.write(Data("tokens".utf8))
    try store.delete()
    #expect(try store.read() == nil)
}

/// Deleting what is not there is how `AccountStore.save([])` clears the last
/// account, and how a migration cleans up after a store that was already
/// empty — neither is an error.
@Test func deletingSomethingAbsentIsNotAnError() throws {
    try InMemorySecretStore().delete()
}
