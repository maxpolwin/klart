import Foundation
#if canImport(Security)
import Security
#endif

/// Abstraction over secret storage so API keys never touch settings files.
/// The real implementation uses the macOS Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String)
}

/// In-memory store for tests and non-Apple platforms.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public func setSecret(_ value: String?, for account: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value, !value.isEmpty {
            storage[account] = value
        } else {
            storage[account] = nil
        }
    }
}

#if canImport(Security)
/// macOS Keychain-backed secret store. Items are generic passwords scoped to
/// the Klårt service, accessible only while the device is unlocked.
public final class KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.klart.mac") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, for account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    // MARK: - Raw data items (Secure-Enclave-wrapped key blob)

    /// Stores opaque data (e.g. the enclave-encrypted master key). No
    /// user-presence ACL: the blob is ciphertext whose decryption is itself
    /// gated by the Secure Enclave key's access control.
    public func setData(_ value: Data?, for account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func data(for account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    // MARK: - User-presence protected items (vault master key)

    /// Stores data behind a user-presence access control: reading it back
    /// makes the system demand Touch ID / Apple Watch / the login password
    /// first. Used for the vault master key so biometric unlock never
    /// weakens the encryption below "this user, present, on this Mac".
    public func setProtectedData(_ value: Data?, for account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        ) else { return }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessControl as String] = access
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Reads a user-presence protected item. Blocks while the system runs
    /// the auth prompt — call it off the main thread. Returns nil if the
    /// user cancels or the item doesn't exist.
    public func protectedData(for account: String, prompt: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseOperationPrompt as String] = prompt
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    public func hasProtectedData(for account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
#endif
