import Foundation

/// One slot holding one blob of secret bytes.
///
/// Deliberately keyless: `AccountStore` keeps every account in a single JSON
/// document, so a keyed interface would only ever be called with one key. The
/// key — where the slot actually lives — belongs to the implementation, which
/// is also what lets tests swap the keychain for memory without inventing a
/// name for something they never address.
public protocol SecretStore: Sendable {
    /// `nil` when the slot has never been written, which is the "no accounts
    /// yet" case rather than a failure.
    func read() throws -> Data?
    func write(_ data: Data) throws
    /// Deleting an absent slot succeeds — see `deletingSomethingAbsentIsNotAnError`.
    func delete() throws
}

/// The substitute the store tests run against, so that exercising
/// `AccountStore`'s semantics never touches a real keychain.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init(data: Data? = nil) {
        self.data = data
    }

    public func read() throws -> Data? {
        lock.withLock { data }
    }

    public func write(_ newData: Data) throws {
        lock.withLock { data = newData }
    }

    public func delete() throws {
        lock.withLock { data = nil }
    }
}
