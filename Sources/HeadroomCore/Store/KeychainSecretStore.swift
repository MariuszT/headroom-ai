import Foundation
import Security

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    /// `SecCopyErrorMessageString` turns the bare number into the sentence the
    /// system itself would show — worth having, because a raw `-25308` in the
    /// panel tells nobody that the keychain is locked.
    public var description: String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

/// The tokens' real home: one generic-password item in the login keychain.
///
/// The classic keychain, not the data-protection one
/// (`kSecUseDataProtectionKeychain`): that variant keys access off the team id
/// in the signature, which an ad-hoc build — what `make app` falls back to
/// without a Developer ID certificate — does not have.
public struct KeychainSecretStore: SecretStore {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static let `default` = KeychainSecretStore(
        service: "pl.tarnaski.headroom",
        account: "accounts"
    )

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)

        // "Nothing written yet" is the empty store, not a failure — the same
        // reading the file-backed store gave a missing accounts.json.
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    public func write(_ data: Data) throws {
        // Update first, add only if there was nothing to update. Adding blindly
        // returns errSecDuplicateItem, which would break every write after the
        // first — and writes happen on every token refresh.
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }

        var request = query
        request[kSecValueData as String] = data
        // The app polls in the background for as long as the user is logged in,
        // and a token refresh must not need the screen unlocked to store its
        // result.
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let add = SecItemAdd(request as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
