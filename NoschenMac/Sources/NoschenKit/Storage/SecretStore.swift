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
/// the Noschen service, accessible only while the device is unlocked.
public final class KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.noschen.mac") {
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
}
#endif
