import Foundation

/// Remembers that the move to the keychain has happened.
///
/// A separate record rather than something read off the store, because every
/// property of the store that looks like an answer is a coincidence. "The
/// keychain is empty" is the tempting one, and it is wrong: removing the last
/// account clears the slot, so a legacy file that outlived its delete would be
/// imported again — handing back the accounts the user had just deleted.
public struct MigrationMarker {
    private static let key = "keychainMigrationDone"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasRun: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// A one-off import of the accounts that older versions kept in a file, into
/// the keychain — after which the file goes, because leaving it would defeat
/// the point of moving.
public enum KeychainMigration {
    /// Returns `true` when accounts were actually imported.
    ///
    /// `legacy` is searched in order and the first store holding anything wins;
    /// see `LegacyFileStore.all` for why that order is newest-first.
    @discardableResult
    public static func run(
        from legacy: [LegacyFileStore],
        to store: AccountStore,
        marker: MigrationMarker
    ) throws -> Bool {
        // Already done. There is nothing left to import, but a file may have
        // outlived a delete that failed, and it still holds live tokens — so
        // the sweep below runs anyway.
        guard !marker.hasRun else {
            remove(legacy)
            return false
        }

        // Accounts already in the keychain are the newer truth: importing over
        // them would undo everything since, and deleting the file would destroy
        // the only other copy. So this case leaves both alone.
        guard try store.load().isEmpty else { return false }

        var accounts: [Account] = []
        for old in legacy {
            // Per store, so that one unreadable file does not take the others
            // down with it. `AppModel` calls this through `try?`: a throw here
            // left the user with an empty panel, no message, and their tokens
            // still on disk, while a perfectly readable file sat behind the
            // broken one.
            accounts = (try? old.load()) ?? []
            if !accounts.isEmpty { break }
        }
        guard !accounts.isEmpty else { return false }

        try store.save(accounts)

        // Verify before deleting: a write that cannot be read back has not
        // happened, and until it has, the file is the only copy of the tokens.
        guard try store.load().count == accounts.count else { return false }

        // Marked before the sweep, not after: once the accounts are safely in
        // the keychain the move HAS happened, whether or not the old files can
        // be cleaned up.
        marker.hasRun = true
        remove(legacy)
        return true
    }

    /// What the app runs at launch.
    @discardableResult
    public static func run(to store: AccountStore, marker: MigrationMarker = MigrationMarker()) throws -> Bool {
        try run(from: LegacyFileStore.all, to: store, marker: marker)
    }

    /// Every legacy directory goes, not only the one imported from: any file
    /// left behind still holds live tokens on disk. A failure to remove one is
    /// not fatal — the accounts are already in the keychain — and the next
    /// launch tries again.
    private static func remove(_ legacy: [LegacyFileStore]) {
        for old in legacy {
            try? FileManager.default.removeItem(at: old.directory)
        }
    }
}
