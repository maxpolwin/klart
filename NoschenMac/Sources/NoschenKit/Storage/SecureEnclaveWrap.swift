import Foundation
#if canImport(Security)
import Security

/// Wraps the vault master key with a P-256 key that lives inside the Secure
/// Enclave (Apple Silicon / T2). The private key never leaves the hardware
/// and its access control demands user presence, so decrypting the master
/// key always runs the Touch ID / Apple Watch / login-password prompt inside
/// the enclave's policy — stronger than a software key behind a Keychain
/// ACL. Macs without an enclave get `wrap` == nil and the caller falls back.
public enum SecureEnclaveWrap {
    private static let keyTag = Data("com.noschen.mac.vault-se-key".utf8)
    /// ECIES: ephemeral ECDH against the enclave key + AES-GCM payload.
    private static let algorithm: SecKeyAlgorithm = .eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    private static func existingKey(prompt: String?) -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        if let prompt {
            query[kSecUseOperationPrompt as String] = prompt
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecKey) // swiftlint:disable:this force_cast
    }

    private static func createKey() -> SecKey? {
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            nil
        ) else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
    }

    /// Encrypts `data` to the enclave key, creating the key on first use.
    /// Encryption uses only the public half — no auth prompt. Returns nil on
    /// hardware without a Secure Enclave (older Intel Macs, most VMs).
    public static func wrap(_ data: Data) -> Data? {
        guard let privateKey = existingKey(prompt: nil) ?? createKey(),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm)
        else { return nil }
        return SecKeyCreateEncryptedData(publicKey, algorithm, data as CFData, nil) as Data?
    }

    /// Decrypts a `wrap` blob. The private key's access control makes the
    /// system demand user presence here. Blocks during the prompt — call off
    /// the main thread. Returns nil on cancel or missing key.
    public static func unwrap(_ blob: Data, prompt: String) -> Data? {
        guard let privateKey = existingKey(prompt: prompt) else { return nil }
        return SecKeyCreateDecryptedData(privateKey, algorithm, blob as CFData, nil) as Data?
    }

    public static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
