import Foundation

/// Every account, as one JSON document in one `SecretStore` slot.
///
/// The store knows nothing about where that slot lives: the app puts it in the
/// login keychain, the tests in memory. Keeping the whole list in a single slot
/// rather than one per account is what makes `upsert` and `remove` a plain
/// read-modify-write, with no partially written set of accounts to reconcile.
public struct AccountStore: Sendable {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public static var `default`: AccountStore {
        AccountStore(secrets: KeychainSecretStore.default)
    }

    public func load() throws -> [Account] {
        // An empty slot is an empty list. Anything else that fails to decode is
        // a genuine error and is thrown: reporting zero accounts for damaged
        // data would invite the next write to overwrite it for good.
        guard let data = try secrets.read(), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([Account].self, from: data)
    }

    /// Serialises every read-modify-write below.
    ///
    /// The store is written from three places that know nothing of each other:
    /// `Poller` (an actor) rotating tokens, `LoginFlow` storing a fresh sign-in
    /// from its own task, and `AppModel.remove` on the main actor. Each reads
    /// the whole document, changes one account and writes it back, so without
    /// this the loser's write is simply dropped — a just-added account
    /// disappears, or a rotated refresh token is lost, and at Anthropic the
    /// previous one is already dead on the server, so that account then needs
    /// signing in again.
    ///
    /// Static because the slot is what is being guarded, not the value that
    /// addresses it: `AccountStore.default` builds a new instance on every
    /// access, and they all name the same keychain item.
    private static let lock = NSLock()

    public func save(_ accounts: [Account]) throws {
        try Self.lock.withLock { try write(accounts) }
    }

    /// The write itself, with no lock of its own — the mutators below already
    /// hold it across their read and their write, and `NSLock` is not
    /// recursive.
    private func write(_ accounts: [Account]) throws {
        // The last account leaving clears the slot rather than storing "[]", so
        // the tokens' hiding place does not outlive the tokens.
        guard !accounts.isEmpty else {
            try secrets.delete()
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try secrets.write(try encoder.encode(accounts))
    }

    /// Reads, changes and writes back under one lock. Returning `nil` from
    /// `change` writes nothing at all.
    @discardableResult
    private func mutate(_ change: ([Account]) -> [Account]?) throws -> Bool {
        try Self.lock.withLock {
            guard let changed = change(try load()) else { return false }
            try write(changed)
            return true
        }
    }

    public func upsert(_ account: Account) throws {
        try mutate { accounts in
            var accounts = accounts
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index] = account
            } else {
                accounts.append(account)
            }
            return accounts
        }
    }

    /// Writes an account only if it is still stored, and reports whether it
    /// was. This is what the poller uses, and the difference from `upsert`
    /// matters: a pass loads its accounts once and can run for many seconds,
    /// so the user can delete one while a check on it is in flight. `upsert`
    /// would append the deleted account straight back — usually with
    /// `needsReauth` set, since a dead token is what the write was recording.
    @discardableResult
    public func update(_ account: Account) throws -> Bool {
        try mutate { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return nil }
            var accounts = accounts
            accounts[index] = account
            return accounts
        }
    }

    public func remove(id: String) throws {
        try mutate { $0.filter { $0.id != id } }
    }
}

/// What reading the store produced. A failure carries the accounts that were
/// already on screen, because showing none of them is indistinguishable from
/// having lost them.
public enum AccountsReading: Equatable {
    case loaded([Account])
    case failed(previous: [Account], message: String)

    public var accounts: [Account] {
        switch self {
        case .loaded(let accounts): accounts
        case .failed(let previous, _): previous
        }
    }

    public var message: String? {
        switch self {
        case .loaded: nil
        case .failed(_, let message): message
        }
    }
}

extension AccountStore {
    /// The reading the app does at launch and after every change.
    ///
    /// Never throws. A missing slot is `.loaded([])` — a first launch owns no
    /// accounts. Anything else keeps what the caller already had: a locked
    /// keychain, or a refused prompt, must not empty the panel.
    public func reload(keeping previous: [Account]) -> AccountsReading {
        do {
            return .loaded(try load())
        } catch {
            return .failed(previous: previous, message: "\(error)")
        }
    }
}
