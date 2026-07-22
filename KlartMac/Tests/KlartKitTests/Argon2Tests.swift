#if canImport(CryptoKit)
import XCTest
import CryptoKit
@testable import KlartKit

final class Argon2Tests: XCTestCase {
    // Small parameters for the property tests — correctness doesn't depend
    // on the work factor, and CI shouldn't grind 128 MiB per case.
    private let m = 1024   // KiB
    private let t = 2
    private let p = 1

    /// Official Argon2id test vector from the PHC reference test harness
    /// (src/test.c): v=0x13, t=2, m=2^16 KiB, p=1, "password"/"somesalt".
    /// This pins our vendored copy AND our Swift call path to the published
    /// known answer.
    func testOfficialKnownAnswerVector() throws {
        let key = try VaultCrypto.deriveKEKArgon2id(
            password: "password",
            salt: Data("somesalt".utf8),
            memoryKiB: 65_536,
            timeCost: 2,
            parallelism: 1
        )
        let hex = key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(hex, "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7")
    }

    func testDeterministicAndParameterSensitive() throws {
        let salt = VaultCrypto.generateSalt()
        let a = try VaultCrypto.deriveKEKArgon2id(password: "pw", salt: salt, memoryKiB: m, timeCost: t, parallelism: p)
        let b = try VaultCrypto.deriveKEKArgon2id(password: "pw", salt: salt, memoryKiB: m, timeCost: t, parallelism: p)
        XCTAssertEqual(a, b)

        // Any parameter change must change the derived key.
        let otherSalt = try VaultCrypto.deriveKEKArgon2id(password: "pw", salt: VaultCrypto.generateSalt(), memoryKiB: m, timeCost: t, parallelism: p)
        let otherPw = try VaultCrypto.deriveKEKArgon2id(password: "pw2", salt: salt, memoryKiB: m, timeCost: t, parallelism: p)
        let otherMem = try VaultCrypto.deriveKEKArgon2id(password: "pw", salt: salt, memoryKiB: m * 2, timeCost: t, parallelism: p)
        let otherTime = try VaultCrypto.deriveKEKArgon2id(password: "pw", salt: salt, memoryKiB: m, timeCost: t + 1, parallelism: p)
        XCTAssertNotEqual(a, otherSalt)
        XCTAssertNotEqual(a, otherPw)
        XCTAssertNotEqual(a, otherMem)
        XCTAssertNotEqual(a, otherTime)
    }

    func testUnicodeNormalizationAppliesToArgon2Too() throws {
        let salt = VaultCrypto.generateSalt()
        let precomposed = try VaultCrypto.deriveKEKArgon2id(password: "gl\u{00FC}ck", salt: salt, memoryKiB: m, timeCost: t, parallelism: p)
        let decomposed = try VaultCrypto.deriveKEKArgon2id(password: "glu\u{0308}ck", salt: salt, memoryKiB: m, timeCost: t, parallelism: p)
        XCTAssertEqual(precomposed, decomposed)
    }

    func testNewVaultsUseArgon2idAndRoundtrip() throws {
        let (masterKey, config) = try VaultCrypto.createVault(password: "argon pw 123", biometricUnlock: false)
        XCTAssertEqual(config.kdf, VaultCrypto.kdfArgon2id)
        XCTAssertEqual(config.kdfMemoryKiB, VaultCrypto.argon2MemoryKiB)
        XCTAssertEqual(config.kdfTimeCost, VaultCrypto.argon2TimeCost)
        XCTAssertEqual(config.kdfParallelism, VaultCrypto.argon2Parallelism)

        XCTAssertEqual(try VaultCrypto.unlock(config: config, password: "argon pw 123"), masterKey)
        XCTAssertThrowsError(try VaultCrypto.unlock(config: config, password: "wrong")) { error in
            guard case VaultError.wrongPassword = error else {
                return XCTFail("expected wrongPassword, got \(error)")
            }
        }
    }

    func testLegacyPBKDF2ConfigStillUnlocksAndRewrapUpgrades() throws {
        // A pre-Argon2 config: PBKDF2 KDF (kdf nil), ChaChaPoly wrap.
        let masterKey = VaultCrypto.generateMasterKey()
        let salt = VaultCrypto.generateSalt()
        let kek = VaultCrypto.deriveKEK(password: "legacy pw", salt: salt, iterations: 1_000)
        let wrapped = try VaultCrypto.wrap(masterKey: masterKey, with: kek, algo: .chachapoly)
        let legacy = VaultConfig(salt: salt, wrappedMasterKey: wrapped, iterations: 1_000, biometricUnlock: false)

        XCTAssertEqual(try VaultCrypto.unlock(config: legacy, password: "legacy pw"), masterKey)

        // Rewrap (password change / transparent upgrade) moves it to Argon2id
        // + AES-GCM without touching the master key.
        let upgraded = try VaultCrypto.rewrap(config: legacy, masterKey: masterKey, newPassword: "legacy pw")
        XCTAssertEqual(upgraded.kdf, VaultCrypto.kdfArgon2id)
        XCTAssertEqual(upgraded.wrapAlgo, "aesgcm")
        XCTAssertEqual(try VaultCrypto.unlock(config: upgraded, password: "legacy pw"), masterKey)
        XCTAssertThrowsError(try VaultCrypto.unlock(config: upgraded, password: "other"))
    }

    func testRotationWorksUnderArgon2id() throws {
        let (masterKey, config) = try VaultCrypto.createVault(password: "rotate me", biometricUnlock: false)
        let (old, new, pending) = try VaultCrypto.beginRotation(config: config, password: "rotate me")
        XCTAssertEqual(old, masterKey)
        XCTAssertNotEqual(old, new)
        let both = try VaultCrypto.unlockBoth(config: pending, password: "rotate me")
        XCTAssertEqual(both.current, new)
        XCTAssertEqual(both.previous, old)
    }
}
#endif
