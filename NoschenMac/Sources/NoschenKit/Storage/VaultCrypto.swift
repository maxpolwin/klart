import Foundation
#if canImport(CryptoKit)
import CryptoKit
import CommonCrypto
#endif

/// Configuration for at-rest note encryption, persisted in settings.json.
/// Contains no secret material: only the salt and the master key *wrapped*
/// (encrypted) by a key derived from the user's password. Without the
/// password — or the biometric-protected copy — the wrapped key is useless.
public struct VaultConfig: Codable, Equatable, Sendable {
    public var salt: Data
    public var wrappedMasterKey: Data
    public var iterations: Int
    public var biometricUnlock: Bool
    /// Key-wrap cipher: nil = ChaCha20-Poly1305 (legacy), "aesgcm" = AES-256-GCM.
    public var wrapAlgo: String?
    /// KDF identifier for forward migration; nil = "pbkdf2-sha256".
    public var kdf: String?
    /// Present only while a key rotation is in flight: the *old* master key,
    /// wrapped under the same KEK, so a crash mid-rotation is resumable.
    public var previousWrappedMasterKey: Data?

    public init(
        salt: Data,
        wrappedMasterKey: Data,
        iterations: Int,
        biometricUnlock: Bool,
        wrapAlgo: String? = nil,
        kdf: String? = nil,
        previousWrappedMasterKey: Data? = nil
    ) {
        self.salt = salt
        self.wrappedMasterKey = wrappedMasterKey
        self.iterations = iterations
        self.biometricUnlock = biometricUnlock
        self.wrapAlgo = wrapAlgo
        self.kdf = kdf
        self.previousWrappedMasterKey = previousWrappedMasterKey
    }
}

public enum VaultError: LocalizedError {
    case wrongPassword
    case corruptData
    case locked
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: return "Wrong password."
        case .corruptData: return "This file is encrypted but could not be decrypted."
        case .locked: return "Notes are locked."
        case .unsupportedPlatform: return "Note encryption requires macOS."
        }
    }
}

#if canImport(CryptoKit)
/// The cryptography behind "protect my notes". Current (v3) design:
/// - every note file is encrypted with AES-256-GCM (FIPS-approved) under a
///   per-note subkey derived from the master key via HKDF-SHA256, with the
///   note's identity as both derivation context and AAD
/// - plaintext is length-prefixed and zero-padded to 4 KiB buckets so file
///   sizes don't reveal note sizes
/// - the random 256-bit master key is wrapped by a key derived from the
///   user's password (PBKDF2-HMAC-SHA256, 600k iterations, NFC-normalized)
/// - v1 (ChaChaPoly, no AAD) and v2 (ChaChaPoly + AAD) files stay readable
///   and upgrade to v3 on their next save
/// Only Apple primitives are composed here; nothing is hand-rolled.
public enum VaultCrypto {
    public static let magic = Data("NSCHNVLT1\n".utf8)     // v1: ChaChaPoly, no AAD
    public static let magicV2 = Data("NSCHNVLT2\n".utf8)   // v2: ChaChaPoly + AAD
    public static let magicV3 = Data("NSCHNVLT3\n".utf8)   // v3: AES-GCM + HKDF subkey + AAD + padding
    public static let defaultIterations = 600_000
    /// File sizes are padded up to multiples of this bucket.
    public static let padBucket = 4096

    public enum WrapAlgo: String {
        case chachapoly
        case aesgcm
    }

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

    /// Per-file subkey: HKDF-SHA256 of the master key with the file identity
    /// as context. Compromise of one subkey exposes one note, and a subkey
    /// derived for one identity is useless for any other.
    static func fileKey(masterKey: Data, context: Data?) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            info: Data("noschen.v3.".utf8) + (context ?? Data("default".utf8)),
            outputByteCount: 32
        )
    }

    // MARK: Master key wrapping

    public static func wrap(masterKey: Data, with kek: SymmetricKey, algo: WrapAlgo = .aesgcm) throws -> Data {
        switch algo {
        case .chachapoly:
            return try ChaChaPoly.seal(masterKey, using: kek).combined
        case .aesgcm:
            guard let combined = try AES.GCM.seal(masterKey, using: kek).combined else {
                throw VaultError.corruptData
            }
            return combined
        }
    }

    public static func unwrap(wrapped: Data, with kek: SymmetricKey, algo: WrapAlgo = .aesgcm) throws -> Data {
        do {
            switch algo {
            case .chachapoly:
                return try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: wrapped), using: kek)
            case .aesgcm:
                return try AES.GCM.open(try AES.GCM.SealedBox(combined: wrapped), using: kek)
            }
        } catch {
            throw VaultError.wrongPassword
        }
    }

    // MARK: File sealing

    public static func isSealed(_ data: Data) -> Bool {
        data.starts(with: magic) || data.starts(with: magicV2) || data.starts(with: magicV3)
    }

    /// Seals `plaintext` as a v3 file: AES-GCM under an identity-derived
    /// subkey, identity as AAD, length-prefixed and padded to 4 KiB buckets.
    public static func seal(_ plaintext: Data, masterKey: Data, aad: Data? = nil) throws -> Data {
        var body = Data(count: 8)
        let length = UInt64(plaintext.count)
        for i in 0..<8 {
            body[i] = UInt8((length >> (8 * UInt64(7 - i))) & 0xFF)
        }
        body += plaintext
        let padded = ((body.count + padBucket - 1) / padBucket) * padBucket
        body += Data(count: padded - body.count)

        let key = fileKey(masterKey: masterKey, context: aad)
        let sealed = try AES.GCM.seal(body, using: key, authenticating: aad ?? Data())
        guard let combined = sealed.combined else { throw VaultError.corruptData }
        return magicV3 + combined
    }

    /// Opens any sealed version (plaintext passes through). v2/v3 files
    /// require the matching `aad`; v1 files ignore it.
    public static func open(_ data: Data, masterKey: Data, aad: Data? = nil) throws -> Data {
        if data.starts(with: magicV3) {
            do {
                let box = try AES.GCM.SealedBox(combined: data.dropFirst(magicV3.count))
                let key = fileKey(masterKey: masterKey, context: aad)
                let body = try AES.GCM.open(box, using: key, authenticating: aad ?? Data())
                guard body.count >= 8 else { throw VaultError.corruptData }
                var length: UInt64 = 0
                for i in 0..<8 {
                    length = (length << 8) | UInt64(body[body.startIndex + i])
                }
                guard length <= UInt64(body.count - 8) else { throw VaultError.corruptData }
                return body.dropFirst(8).prefix(Int(length))
            } catch {
                throw VaultError.corruptData
            }
        }
        if data.starts(with: magicV2) {
            guard let aad else { throw VaultError.corruptData }
            do {
                let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(magicV2.count))
                return try ChaChaPoly.open(box, using: SymmetricKey(data: masterKey), authenticating: aad)
            } catch {
                throw VaultError.corruptData
            }
        }
        if data.starts(with: magic) {
            do {
                let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(magic.count))
                return try ChaChaPoly.open(box, using: SymmetricKey(data: masterKey))
            } catch {
                throw VaultError.corruptData
            }
        }
        return data
    }

    // MARK: Vault lifecycle

    /// Creates a fresh vault: master key + config wrapping it under `password`.
    public static func createVault(password: String, biometricUnlock: Bool) throws -> (masterKey: Data, config: VaultConfig) {
        let masterKey = generateMasterKey()
        let salt = generateSalt()
        let kek = deriveKEK(password: password, salt: salt, iterations: defaultIterations)
        let wrapped = try wrap(masterKey: masterKey, with: kek, algo: .aesgcm)
        return (masterKey, VaultConfig(
            salt: salt,
            wrappedMasterKey: wrapped,
            iterations: defaultIterations,
            biometricUnlock: biometricUnlock,
            wrapAlgo: WrapAlgo.aesgcm.rawValue,
            kdf: "pbkdf2-sha256"
        ))
    }

    static func wrapAlgo(of config: VaultConfig) -> WrapAlgo {
        config.wrapAlgo.flatMap(WrapAlgo.init(rawValue:)) ?? .chachapoly
    }

    /// Recovers the master key from a config; throws `.wrongPassword` on mismatch.
    public static func unlock(config: VaultConfig, password: String) throws -> Data {
        let kek = deriveKEK(password: password, salt: config.salt, iterations: config.iterations)
        return try unwrap(wrapped: config.wrappedMasterKey, with: kek, algo: wrapAlgo(of: config))
    }

    /// Recovers both keys during an interrupted rotation (previous is nil in
    /// the steady state).
    public static func unlockBoth(config: VaultConfig, password: String) throws -> (current: Data, previous: Data?) {
        let kek = deriveKEK(password: password, salt: config.salt, iterations: config.iterations)
        let algo = wrapAlgo(of: config)
        let current = try unwrap(wrapped: config.wrappedMasterKey, with: kek, algo: algo)
        let previous = try config.previousWrappedMasterKey.map {
            try unwrap(wrapped: $0, with: kek, algo: algo)
        }
        return (current, previous)
    }

    /// Rewraps the master key under a new password (new salt, same key —
    /// notes on disk stay untouched). Upgrades the wrap cipher to AES-GCM.
    /// Callers must finish any pending rotation first: the old key is wrapped
    /// under the old salt's KEK and cannot survive a salt change.
    public static func rewrap(config: VaultConfig, masterKey: Data, newPassword: String) throws -> VaultConfig {
        guard config.previousWrappedMasterKey == nil else { throw VaultError.locked }
        var updated = config
        updated.salt = generateSalt()
        updated.iterations = defaultIterations
        updated.wrapAlgo = WrapAlgo.aesgcm.rawValue
        let kek = deriveKEK(password: newPassword, salt: updated.salt, iterations: updated.iterations)
        updated.wrappedMasterKey = try wrap(masterKey: masterKey, with: kek, algo: .aesgcm)
        return updated
    }

    /// Starts a key rotation: generates a new master key and stores BOTH the
    /// new and the old key (wrapped under the same KEK) so a crash while
    /// files are being re-encrypted is fully resumable.
    public static func beginRotation(config: VaultConfig, password: String) throws -> (oldKey: Data, newKey: Data, pending: VaultConfig) {
        let kek = deriveKEK(password: password, salt: config.salt, iterations: config.iterations)
        let oldKey = try unwrap(wrapped: config.wrappedMasterKey, with: kek, algo: wrapAlgo(of: config))
        let newKey = generateMasterKey()
        var pending = config
        pending.wrapAlgo = WrapAlgo.aesgcm.rawValue
        pending.wrappedMasterKey = try wrap(masterKey: newKey, with: kek, algo: .aesgcm)
        pending.previousWrappedMasterKey = try wrap(masterKey: oldKey, with: kek, algo: .aesgcm)
        return (oldKey, newKey, pending)
    }

    /// Finishes a rotation once every file is re-encrypted: drops the old key.
    public static func completeRotation(_ config: VaultConfig) -> VaultConfig {
        var done = config
        done.previousWrappedMasterKey = nil
        return done
    }
}
#endif
