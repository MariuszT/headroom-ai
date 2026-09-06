import Foundation

/// Reads the `accounts.json` that versions before the move to the keychain left
/// on disk. Read-only on purpose: it exists solely so `KeychainMigration` can
/// pick those accounts up once and delete the file. Nothing writes this format
/// any more.
public struct LegacyFileStore: Sendable {
    public let directory: URL
    public let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("accounts.json")
    }

    private static func applicationSupport(_ name: String) -> LegacyFileStore {
        LegacyFileStore(
            directory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(name)
        )
    }

    /// Both places an installed copy may have left accounts, newest first:
    /// "Headroom" is where file-backed versions of this app wrote, "Limity" the
    /// name it shipped under before the rebrand. Order matters — the migration
    /// takes the first one that holds anything.
    public static var all: [LegacyFileStore] {
        [applicationSupport("Headroom"), applicationSupport("Limity")]
    }

    public func load() throws -> [Account] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([Account].self, from: data)
    }
}
