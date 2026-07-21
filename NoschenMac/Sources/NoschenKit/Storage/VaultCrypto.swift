import Foundation
#if canImport(CryptoKit)
import CryptoKit
import CommonCrypto
#endif

/// Configuration for at-rest note encryption, persisted in settings.json.
/// Contains no secret material: only the salt and the master key *wrapped*
/// (encrypted) by a key derived from the user's password. Without the
/// password — or the biometric-protected Keychain copy — the wrapped key
/// is useless.
public struct VaultConfig: Codable, Equatable, Sendable {
    public var salt: Data
    public var wrappedMasterKey: Data
    public var iterations: Int
    public var biometricUnlock: Bool

    public init(salt: Data, wrappedMasterKey: Data, iterations: Int, biometricUnlock: Bool) {
        self.salt = salt
        self.wrappedMasterKey = wrappedMasterKey
        self.iterations = iterations
        self.biometricUnlock = biometricUnlock
    }
}

public enum VaultError: LocalizedError {
    case wrongPassword
    case corruptData
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: return "Wrong password."
        case .corruptData: return "This file is encrypted but could not be decrypted."
        case .unsupportedPlatform: return "Note encryption requires macOS."
        }
    }
}

#if canImport(CryptoKit)
/// The cryptography behind "protect my notes":
/// - a random 256-bit master key encrypts every note file (ChaCha20-Poly1305)
/// - the master key is wrapped by a key derived from the user's password
///   (PBKDF2-HMAC-SHA256, 600k iterations, random salt)
/// - encrypted files start with a magic prefix so plaintext and sealed files
///   can coexist during migration
public enum VaultCrypto {
    /// Prefix identifying an encrypted Noschen file (version 1).
    public static let magic = Data("NSCHNVLT1\n".utf8)
    public static let defaultIterations = 600_000

    // MARK: Keys

    public static func generateMasterKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public static func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// PBKDF2-HMAC-SHA256. CryptoKit has no PBKDF2, so this uses CommonCrypto.
    /// The password is canonically normalized (NFC) first so the same visual
    /// password always derives the same key regardless of how the input
    /// method composed its characters.
    public static func deriveKEK(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        salt.withUnsafeBytes { saltBuffer in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived, derived.count
            )
        }
        return SymmetricKey(data: Data(derived))
    }

    // MARK: Master key wrapping

    public static func wrap(masterKey: Data, with kek: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(masterKey, using: kek).combined
    }

    public static func unwrap(wrapped: Data, with kek: SymmetricKey) throws -> Data {
        do {
            let box = try ChaChaPoly.SealedBox(combined: wrapped)
            return try ChaChaPoly.open(box, using: kek)
        } catch {
            throw VaultError.wrongPassword
        }
    }

    // MARK: File sealing

    public static func isSealed(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    public static func seal(_ plaintext: Data, masterKey: Data) throws -> Data {
        let key = SymmetricKey(data: masterKey)
        return magic + (try ChaChaPoly.seal(plaintext, using: key).combined)
    }

    public static func open(_ data: Data, masterKey: Data) throws -> Data {
        guard isSealed(data) else { return data }
        let key = SymmetricKey(data: masterKey)
        do {
            let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(magic.count))
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw VaultError.corruptData
        }
    }

    // MARK: Convenience

    /// Creates a fresh vault: master key + config wrapping it under `password`.
    public static func createVault(password: String, biometricUnlock: Bool) throws -> (masterKey: Data, config: VaultConfig) {
        let masterKey = generateMasterKey()
        let salt = generateSalt()
        let kek = deriveKEK(password: password, salt: salt, iterations: defaultIterations)
        let wrapped = try wrap(masterKey: masterKey, with: kek)
        return (masterKey, VaultConfig(
            salt: salt,
            wrappedMasterKey: wrapped,
            iterations: defaultIterations,
            biometricUnlock: biometricUnlock
        ))
    }

    /// Recovers the master key from a config; throws `.wrongPassword` on mismatch.
    public static func unlock(config: VaultConfig, password: String) throws -> Data {
        let kek = deriveKEK(password: password, salt: config.salt, iterations: config.iterations)
        return try unwrap(wrapped: config.wrappedMasterKey, with: kek)
    }

    /// Rewraps the master key under a new password (new salt, same key —
    /// notes on disk stay untouched).
    public static func rewrap(config: VaultConfig, masterKey: Data, newPassword: String) throws -> VaultConfig {
        var updated = config
        updated.salt = generateSalt()
        updated.iterations = defaultIterations
        let kek = deriveKEK(password: newPassword, salt: updated.salt, iterations: updated.iterations)
        updated.wrappedMasterKey = try wrap(masterKey: masterKey, with: kek)
        return updated
    }
}
#endif
