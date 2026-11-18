import Foundation
#if canImport(Security)
import Security
import LocalAuthentication
#endif

/// Abstraction over secret storage so API keys never touch settings files.
/// The real implementation uses the macOS Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String)
    /// Like `setSecret`, but says whether the value was stored.
    @discardableResult
    func storeSecret(_ value: String?, for account: String) -> Bool
}

public extension SecretStore {
    @discardableResult
    func storeSecret(_ value: String?, for account: String) -> Bool {
        setSecret(value, for: account)
        return true
    }
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
///
/// Every query targets the **data-protection keychain** (the same one iOS
/// uses). It is the only macOS keychain that supports biometric access
/// control and Secure Enclave keys, and it binds items to the app's signing
/// identity instead of a per-binary ACL — so a rebuild neither re-prompts nor
/// loses them. It needs a signed bundle with an application identifier; in an
/// unsigned process (`swift run`, bare `swift test`) every call fails with
/// `errSecMissingEntitlement` and the store behaves as empty.
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
            kSecUseDataProtectionKeychain as String: true,
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
        _ = storeSecret(value, for: account)
    }

    /// Like `setSecret`, but says whether the item was stored. Removing an
    /// item (`nil`/empty value) always reports success.
    @discardableResult
    public func storeSecret(_ value: String?, for account: String) -> Bool {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Raw data items (Secure-Enclave-wrapped key blob)

    /// Stores opaque data (e.g. the enclave-encrypted master key). No
    /// user-presence ACL: the blob is ciphertext whose decryption is itself
    /// gated by the Secure Enclave key's access control.
    @discardableResult
    public func setData(_ value: Data?, for account: String) -> Bool {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
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
    /// makes the system demand Touch ID first. Used for the vault master key so biometric unlock never
    /// weakens the encryption below "this user, present, on this Mac".
    /// `.biometryCurrentSet`: only an enrolled fingerprint opens it (no login
    /// password fallback), and enrolling or removing a fingerprint
    /// invalidates the item — the vault password then unlocks and re-arms it.
    @discardableResult
    public func setProtectedData(_ value: Data?, for account: String) -> Bool {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else { return false }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessControl as String] = access
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Reads a user-presence protected item. Blocks while the system runs
    /// the auth prompt — call it off the main thread. Returns nil if the
    /// user cancels or the item doesn't exist.
    public func protectedData(for account: String, prompt: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // kSecUseOperationPrompt was deprecated in macOS 11: carry the prompt on
        // an LAContext instead and hand it to the keychain via
        // kSecUseAuthenticationContext.
        let context = LAContext()
        context.localizedReason = prompt
        query[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Best-effort removal of items an older build may have stored in the
    /// legacy file-based keychain, which `baseQuery` no longer reaches. Never
    /// shows UI: an item the system would prompt for is left alone.
    public func deleteLegacyItems(for accounts: [String]) {
        for account in accounts {
            let context = LAContext()
            context.interactionNotAllowed = true
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseAuthenticationContext as String: context,
            ] as CFDictionary)
        }
    }

    public func hasProtectedData(for account: String) -> Bool {
        var query = baseQuery(account: account)
        // kSecUseAuthenticationUIFail was deprecated in macOS 11: forbid the
        // auth UI via an LAContext with interactionNotAllowed instead, so a
        // protected item is reported present (errSecInteractionNotAllowed)
        // without ever prompting.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
#endif
