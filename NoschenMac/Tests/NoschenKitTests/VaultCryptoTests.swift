#if canImport(CryptoKit)
import XCTest
@testable import NoschenKit

final class VaultCryptoTests: XCTestCase {
    // Fast, test-only iteration count — the KDF's correctness doesn't depend
    // on the work factor, and 600k rounds per test would drag CI.
    private let iterations = 1_000

    func testSealOpenRoundtrip() throws {
        let key = VaultCrypto.generateMasterKey()
        let plaintext = Data("# Secret note\nwith contents".utf8)
        let sealed = try VaultCrypto.seal(plaintext, masterKey: key)

        XCTAssertTrue(VaultCrypto.isSealed(sealed))
        XCTAssertFalse(VaultCrypto.isSealed(plaintext))
        XCTAssertNotEqual(sealed, plaintext)
        XCTAssertFalse(sealed.dropFirst(VaultCrypto.magic.count).contains(subdata: Data("Secret".utf8)))

        XCTAssertEqual(try VaultCrypto.open(sealed, masterKey: key), plaintext)
    }

    func testOpenWithWrongKeyThrows() throws {
        let sealed = try VaultCrypto.seal(Data("data".utf8), masterKey: VaultCrypto.generateMasterKey())
        XCTAssertThrowsError(try VaultCrypto.open(sealed, masterKey: VaultCrypto.generateMasterKey()))
    }

    func testOpenPassesThroughPlaintext() throws {
        let plain = Data("not sealed".utf8)
        XCTAssertEqual(try VaultCrypto.open(plain, masterKey: VaultCrypto.generateMasterKey()), plain)
    }

    func testVaultUnlockRoundtrip() throws {
        let (masterKey, config) = try VaultCrypto.createVault(password: "correct horse battery", biometricUnlock: false)
        XCTAssertEqual(config.iterations, 600_000)

        let recovered = try VaultCrypto.unlock(config: config, password: "correct horse battery")
        XCTAssertEqual(recovered, masterKey)
    }

    func testWrongPasswordThrowsWrongPassword() throws {
        let (_, config) = try VaultCrypto.createVault(password: "right", biometricUnlock: false)
        XCTAssertThrowsError(try VaultCrypto.unlock(config: config, password: "wrong")) { error in
            guard case VaultError.wrongPassword = error else {
                return XCTFail("expected wrongPassword, got \(error)")
            }
        }
    }

    func testRewrapKeepsMasterKeyAndChangesSalt() throws {
        let (masterKey, config) = try VaultCrypto.createVault(password: "old", biometricUnlock: true)
        let rewrapped = try VaultCrypto.rewrap(config: config, masterKey: masterKey, newPassword: "new password")

        XCTAssertNotEqual(rewrapped.salt, config.salt)
        XCTAssertTrue(rewrapped.biometricUnlock)
        XCTAssertEqual(try VaultCrypto.unlock(config: rewrapped, password: "new password"), masterKey)
        XCTAssertThrowsError(try VaultCrypto.unlock(config: rewrapped, password: "old"))
    }

    func testDerivationIsDeterministicPerSaltAndPassword() {
        let salt = VaultCrypto.generateSalt()
        let a = VaultCrypto.deriveKEK(password: "pw", salt: salt, iterations: iterations)
        let b = VaultCrypto.deriveKEK(password: "pw", salt: salt, iterations: iterations)
        let c = VaultCrypto.deriveKEK(password: "pw", salt: VaultCrypto.generateSalt(), iterations: iterations)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testUnicodePasswordFormsDeriveTheSameKey() {
        // "ü" typed as one precomposed scalar vs. "u" + combining diaeresis:
        // visually identical, different UTF-8 — must derive the same key.
        let salt = VaultCrypto.generateSalt()
        let precomposed = "gl\u{00FC}ck"
        let decomposed = "glu\u{0308}ck"
        XCTAssertNotEqual(Array(precomposed.utf8), Array(decomposed.utf8))
        XCTAssertEqual(
            VaultCrypto.deriveKEK(password: precomposed, salt: salt, iterations: iterations),
            VaultCrypto.deriveKEK(password: decomposed, salt: salt, iterations: iterations)
        )
    }

    func testNoteStoreEncryptDecryptMigration() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noschen-vault-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = NoteStore(directory: dir)
        let note = Note(content: "# Migration test\nBody line")
        try await store.save(note)

        let key = VaultCrypto.generateMasterKey()
        try await store.encryptAllOnDisk(masterKey: key)

        // On disk: sealed, title not visible in the raw bytes.
        let file = dir.appendingPathComponent("\(note.id.uuidString).json")
        let raw = try Data(contentsOf: file)
        XCTAssertTrue(VaultCrypto.isSealed(raw))
        XCTAssertFalse(raw.contains(subdata: Data("Migration test".utf8)))

        // Loadable with the key set on the store.
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.map(\.id), [note.id])
        XCTAssertEqual(loaded.first?.content, note.content)

        // Migrate back to plaintext.
        try await store.decryptAllOnDisk(masterKey: key)
        let plain = try Data(contentsOf: file)
        XCTAssertFalse(VaultCrypto.isSealed(plain))
        XCTAssertTrue(plain.contains(subdata: Data("Migration test".utf8)))
        let reloaded = try await store.loadAll()
        XCTAssertEqual(reloaded.first?.content, note.content)
    }

    func testAADBindingRoundtripAndMismatch() throws {
        let key = VaultCrypto.generateMasterKey()
        let plaintext = Data("bound".utf8)
        let aadA = Data("note-A".utf8)
        let sealed = try VaultCrypto.seal(plaintext, masterKey: key, aad: aadA)

        XCTAssertTrue(sealed.starts(with: VaultCrypto.magicV3))
        XCTAssertEqual(try VaultCrypto.open(sealed, masterKey: key, aad: aadA), plaintext)
        // Wrong identity or missing identity must fail, not decrypt.
        XCTAssertThrowsError(try VaultCrypto.open(sealed, masterKey: key, aad: Data("note-B".utf8)))
        XCTAssertThrowsError(try VaultCrypto.open(sealed, masterKey: key, aad: nil))
    }

    func testLegacyV1FilesStillOpen() throws {
        let key = VaultCrypto.generateMasterKey()
        let plaintext = Data("legacy".utf8)
        let v1 = try VaultCrypto.seal(plaintext, masterKey: key, aad: nil)

        XCTAssertTrue(v1.starts(with: VaultCrypto.magic))
        XCTAssertEqual(try VaultCrypto.open(v1, masterKey: key), plaintext)
        // A v1 file predates AAD binding — passing an identity is harmless.
        XCTAssertEqual(try VaultCrypto.open(v1, masterKey: key, aad: Data("any".utf8)), plaintext)
    }

    func testNoteStoreRejectsTransplantedCiphertext() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noschen-vault-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = NoteStore(directory: dir)
        let key = VaultCrypto.generateMasterKey()
        await store.setEncryptionKey(key)
        let note = Note(content: "# Original")
        try await store.save(note)

        // Simulate an attacker with disk access copying this note's sealed
        // bytes under a different note's filename.
        let original = dir.appendingPathComponent("\(note.id.uuidString).json")
        let transplanted = dir.appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: original, to: transplanted)

        // The transplant fails authentication and is skipped; the real note loads.
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.map(\.id), [note.id])
    }

    func testSecureEnclaveWrapDegradesGracefully() {
        // CI runners and most VMs have no Secure Enclave — wrap must return
        // nil there (callers fall back), never crash. On enclave hardware the
        // blob must be non-trivial; unwrap isn't exercised because it demands
        // interactive user presence.
        if let blob = SecureEnclaveWrap.wrap(Data("key-material".utf8)) {
            XCTAssertGreaterThan(blob.count, 32)
            SecureEnclaveWrap.deleteKey()
        }
    }

    func testLoadAllSkipsSealedFilesWithoutKey() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noschen-vault-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = NoteStore(directory: dir)
        try await store.save(Note(content: "# Sealed away"))
        try await store.encryptAllOnDisk(masterKey: VaultCrypto.generateMasterKey())
        await store.setEncryptionKey(nil)

        // Without the key the sealed note is skipped, not exposed or crashed on.
        let loaded = try await store.loadAll()
        XCTAssertTrue(loaded.isEmpty)
    }
}

private extension Data {
    func contains(subdata needle: Data) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return range(of: needle) != nil
    }
}
#endif
