#if canImport(CryptoKit)
import XCTest
import CryptoKit
@testable import KlartKit

final class HardeningTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klart-hardening-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: v3 format (AES-GCM + HKDF subkeys + padding)

    func testV3SealOpenRoundtripWithAAD() throws {
        let key = VaultCrypto.generateMasterKey()
        let plaintext = Data("# v3 content".utf8)
        let aad = Data("note-identity".utf8)
        let sealed = try VaultCrypto.seal(plaintext, masterKey: key, aad: aad)

        XCTAssertTrue(sealed.starts(with: VaultCrypto.magicV3))
        XCTAssertEqual(try VaultCrypto.open(sealed, masterKey: key, aad: aad), plaintext)
        XCTAssertThrowsError(try VaultCrypto.open(sealed, masterKey: key, aad: Data("other".utf8)))
        XCTAssertThrowsError(try VaultCrypto.open(sealed, masterKey: key, aad: nil))
        XCTAssertThrowsError(try VaultCrypto.open(sealed, masterKey: VaultCrypto.generateMasterKey(), aad: aad))
    }

    func testV3PaddingHidesPlaintextSize() throws {
        let key = VaultCrypto.generateMasterKey()
        let aad = Data("id".utf8)
        let short = try VaultCrypto.seal(Data("tiny".utf8), masterKey: key, aad: aad)
        let longer = try VaultCrypto.seal(Data(String(repeating: "x", count: 2000).utf8), masterKey: key, aad: aad)
        // Both fit the first 4 KiB bucket: identical ciphertext length.
        XCTAssertEqual(short.count, longer.count)
        // Crossing a bucket boundary grows by exactly one bucket.
        let huge = try VaultCrypto.seal(Data(String(repeating: "x", count: 5000).utf8), masterKey: key, aad: aad)
        XCTAssertEqual(huge.count - longer.count, VaultCrypto.padBucket)
        // And all of them round-trip exactly.
        XCTAssertEqual(try VaultCrypto.open(short, masterKey: key, aad: aad).count, 4)
        XCTAssertEqual(try VaultCrypto.open(huge, masterKey: key, aad: aad).count, 5000)
    }

    func testV3SubkeysDifferPerIdentity() throws {
        // The same master key must produce ciphertexts that cannot be opened
        // under a different identity even ignoring the AAD check — the
        // subkey itself differs. (Covered indirectly by the AAD test, but
        // this pins the HKDF context binding.)
        let a = VaultCrypto.fileKey(masterKey: Data(repeating: 1, count: 32), context: Data("A".utf8))
        let b = VaultCrypto.fileKey(masterKey: Data(repeating: 1, count: 32), context: Data("B".utf8))
        XCTAssertNotEqual(a, b)
    }

    func testLegacyV1AndV2FilesStillOpenAndUpgradeOnSave() async throws {
        let store = NoteStore(directory: dir)
        let masterKey = VaultCrypto.generateMasterKey()
        let key = SymmetricKey(data: masterKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The store decodes ISO-8601 dates; legacy files were written the same way.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Hand-write a v1 file (ChaChaPoly, no AAD)…
        let v1Note = Note(content: "# Legacy v1 note")
        let v1URL = dir.appendingPathComponent("\(v1Note.id.uuidString).json")
        let v1 = VaultCrypto.magic
            + (try ChaChaPoly.seal(encoder.encode(v1Note), using: key).combined)
        try v1.write(to: v1URL)

        // …and a v2 file (ChaChaPoly, AAD = note id).
        let v2Note = Note(content: "# Legacy v2 note")
        let v2URL = dir.appendingPathComponent("\(v2Note.id.uuidString).json")
        let v2 = VaultCrypto.magicV2 + (try ChaChaPoly.seal(
            encoder.encode(v2Note),
            using: key,
            authenticating: Data(v2Note.id.uuidString.utf8)
        ).combined)
        try v2.write(to: v2URL)

        await store.setEncryptionKey(masterKey)
        var loaded = try await store.loadAll()
        XCTAssertEqual(Set(loaded.map(\.id)), [v1Note.id, v2Note.id])

        // Saving rewrites either legacy format as v3.
        for note in loaded { try await store.save(note) }
        for url in [v1URL, v2URL] {
            XCTAssertTrue(
                try Data(contentsOf: url).starts(with: VaultCrypto.magicV3),
                "legacy files must upgrade to v3 on save"
            )
        }
        loaded = try await store.loadAll()
        XCTAssertEqual(Set(loaded.map(\.content)), ["# Legacy v1 note", "# Legacy v2 note"])
    }

    // MARK: Key wrap algorithms

    func testNewVaultsWrapWithAESGCMAndLegacyChaChaStillUnlocks() throws {
        let (masterKey, config) = try VaultCrypto.createVault(password: "pw123456", biometricUnlock: false)
        XCTAssertEqual(config.wrapAlgo, "aesgcm")
        XCTAssertEqual(try VaultCrypto.unlock(config: config, password: "pw123456"), masterKey)

        // Construct a legacy config (ChaChaPoly wrap, no wrapAlgo field).
        let salt = VaultCrypto.generateSalt()
        let kek = VaultCrypto.deriveKEK(password: "legacy pw", salt: salt, iterations: 1_000)
        let wrapped = try VaultCrypto.wrap(masterKey: masterKey, with: kek, algo: .chachapoly)
        let legacy = VaultConfig(salt: salt, wrappedMasterKey: wrapped, iterations: 1_000, biometricUnlock: false)
        XCTAssertNil(legacy.wrapAlgo)
        XCTAssertEqual(try VaultCrypto.unlock(config: legacy, password: "legacy pw"), masterKey)
    }

    // MARK: Key rotation

    func testKeyRotationReencryptsEverythingAndResumesAfterCrash() async throws {
        let store = NoteStore(directory: dir)
        let notes = (1...3).map { Note(content: "# Rotation note \($0)") }
        for note in notes { try await store.save(note) }

        let (oldKey, config) = try VaultCrypto.createVault(password: "rotate pw", biometricUnlock: false)
        try await store.encryptAllOnDisk(masterKey: oldKey)

        let (old, new, pending) = try VaultCrypto.beginRotation(config: config, password: "rotate pw")
        XCTAssertEqual(old, oldKey)
        XCTAssertNotNil(pending.previousWrappedMasterKey)
        // Both keys recoverable from the pending config — the crash window.
        let both = try VaultCrypto.unlockBoth(config: pending, password: "rotate pw")
        XCTAssertEqual(both.current, new)
        XCTAssertEqual(both.previous, old)

        // Simulate a crash after only ONE file was rotated.
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let firstFile = files[0]
        let firstID = UUID(uuidString: firstFile.deletingPathExtension().lastPathComponent)!
        let aad = Data(firstID.uuidString.utf8)
        let plaintext = try VaultCrypto.open(try Data(contentsOf: firstFile), masterKey: old, aad: aad)
        try VaultCrypto.seal(plaintext, masterKey: new, aad: aad).write(to: firstFile, options: .atomic)

        // Resume: a mixed old/new library reads fully with fallback and
        // rotates the rest.
        let resumed = NoteStore(directory: dir)
        await resumed.setEncryptionKey(SecureBytes(new), fallback: SecureBytes(old))
        let mixedCount = try await resumed.loadAll().count
        XCTAssertEqual(mixedCount, 3)
        try await resumed.rotateAllOnDisk(oldKey: old, newKey: new)

        // Everything now opens under the new key alone; the old key is dead.
        let done = NoteStore(directory: dir)
        await done.setEncryptionKey(new)
        let rotatedCount = try await done.loadAll().count
        XCTAssertEqual(rotatedCount, 3)
        let withOld = NoteStore(directory: dir)
        await withOld.setEncryptionKey(old)
        let staleCount = try await withOld.loadAll().count
        XCTAssertEqual(staleCount, 0)

        let completed = VaultCrypto.completeRotation(pending)
        XCTAssertNil(completed.previousWrappedMasterKey)
    }

    // MARK: SecureBytes

    func testSecureBytesRoundtripAndDestroy() {
        let secret = Data("super secret key material".utf8)
        let secure = SecureBytes(secret)
        XCTAssertEqual(secure.count, secret.count)
        secure.withData { view in
            XCTAssertEqual(view, secret)
        }
        secure.destroy()
        secure.destroy() // idempotent
    }

    // MARK: Audit log

    func testAuditLogChainsAndDetectsTampering() async throws {
        let url = dir.appendingPathComponent("audit.log")
        let secrets = InMemorySecretStore()
        let log = AuditLog(fileURL: url, secrets: secrets)
        await log.record(.vaultEnabled)
        await log.record(.unlockFailure)
        await log.record(.unlockSuccess)
        let count = await log.verify()
        XCTAssertEqual(count, 3)

        // A resumed log continues the same chain.
        let resumed = AuditLog(fileURL: url, secrets: secrets)
        await resumed.record(.locked)
        let resumedCount = await resumed.verify()
        XCTAssertEqual(resumedCount, 4)

        // Tampering with any line breaks verification.
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "unlock_failure", with: "unlock_success")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let tampered = await resumed.verify()
        XCTAssertNil(tampered)
    }

    /// Someone who can write the file but not read the Keychain rebuilds a
    /// clean-looking unkeyed chain with an event removed. It must not verify.
    func testAuditLogRejectsARegeneratedChain() async throws {
        let url = dir.appendingPathComponent("audit.log")
        let log = AuditLog(fileURL: url, secrets: InMemorySecretStore())
        await log.record(.unlockFailure)
        await log.record(.unlockFailure)
        await log.record(.unlockSuccess)

        var prev = "klart-audit-genesis"
        var lines: [String] = []
        for event in ["unlock_success", "locked", "unlock_success"] {
            let ts = "2026-01-01T00:00:00Z"
            let hash = SHA256.hash(data: Data("\(prev)|\(ts)|\(event)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            lines.append(#"{"ts":"\#(ts)","event":"\#(event)","prev":"\#(prev)","hash":"\#(hash)"}"#)
            prev = hash
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let count = await log.verify()
        XCTAssertNil(count)
    }

    func testAuditLogDetectsTruncationAndDeletion() async throws {
        let url = dir.appendingPathComponent("audit.log")
        let secrets = InMemorySecretStore()
        let log = AuditLog(fileURL: url, secrets: secrets)
        await log.record(.unlockFailure)
        await log.record(.unlockFailure)
        await log.record(.unlockSuccess)

        let full = try String(contentsOf: url, encoding: .utf8)
        let truncated = full.split(separator: "\n").dropLast().joined(separator: "\n") + "\n"
        try truncated.write(to: url, atomically: true, encoding: .utf8)
        let afterTruncation = await log.verify()
        XCTAssertNil(afterTruncation)

        try FileManager.default.removeItem(at: url)
        let afterDeletion = await log.verify()
        XCTAssertNil(afterDeletion)

        // The next launch notices, and the notice itself stays in the chain.
        let relaunched = AuditLog(fileURL: url, secrets: secrets)
        await relaunched.record(.locked)
        let recorded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(recorded.contains("tamper_detected"))
        let afterRelaunch = await relaunched.verify()
        XCTAssertNil(afterRelaunch, "a log that records tampering never verifies clean")
    }

    func testAuditLogToleratesAStopBetweenAppendAndAnchor() async throws {
        let url = dir.appendingPathComponent("audit.log")
        let secrets = InMemorySecretStore()
        let log = AuditLog(fileURL: url, secrets: secrets)
        await log.record(.unlockSuccess)
        let anchorAfterFirst = secrets.secret(for: AuditLog.anchorAccount)
        await log.record(.locked)
        // Roll the anchor back one write, as if the app stopped in between.
        secrets.setSecret(anchorAfterFirst, for: AuditLog.anchorAccount)

        let count = await log.verify()
        XCTAssertEqual(count, 2)
        let relaunched = AuditLog(fileURL: url, secrets: secrets)
        await relaunched.record(.unlockSuccess)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("tamper_detected"))
    }

    func testAuditLogContinuesALegacyChain() async throws {
        let url = dir.appendingPathComponent("audit.log")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var prev = "klart-audit-genesis"
        var lines: [String] = []
        for event in ["vault_enabled", "locked"] {
            let ts = "2025-06-01T00:00:00Z"
            let hash = SHA256.hash(data: Data("\(prev)|\(ts)|\(event)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            lines.append(#"{"ts":"\#(ts)","event":"\#(event)","prev":"\#(prev)","hash":"\#(hash)"}"#)
            prev = hash
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let log = AuditLog(fileURL: url, secrets: InMemorySecretStore())
        await log.record(.unlockSuccess)
        let count = await log.verify()
        XCTAssertEqual(count, 3)
    }

    func testAuditLogWhoseKeyIsGoneIsArchivedAndRestarted() async throws {
        let url = dir.appendingPathComponent("audit.log")
        let first = AuditLog(fileURL: url, secrets: InMemorySecretStore())
        await first.record(.vaultEnabled)

        // Same file, empty Keychain: a restored backup on a new Mac.
        let second = AuditLog(fileURL: url, secrets: InMemorySecretStore())
        await second.record(.unlockSuccess)
        let count = await second.verify()
        XCTAssertEqual(count, 1)
        let archived = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("audit-unverifiable-") }
        XCTAssertEqual(archived.count, 1)
    }

    // MARK: Sensitive notes / provider locality

    func testProviderLocalityDecidesByEndpointNotLabel() {
        XCTAssertTrue(ProviderFactory.isLocal(kind: .ollama, config: .init(baseURL: "http://localhost:11434", model: "")))
        XCTAssertTrue(ProviderFactory.isLocal(kind: .lmstudio, config: .init(baseURL: "http://192.168.1.10:1234/v1", model: "")))
        XCTAssertTrue(ProviderFactory.isLocal(kind: .custom, config: .init(baseURL: "https://mymac.local:8080/v1", model: "")))
        // Cloud endpoints are never local — including a "Custom" pointed remotely.
        XCTAssertFalse(ProviderFactory.isLocal(kind: .openrouter, config: .init(baseURL: "https://openrouter.ai/api/v1", model: "")))
        XCTAssertFalse(ProviderFactory.isLocal(kind: .custom, config: .init(baseURL: "https://api.example.com/v1", model: "")))
        // OpenRouter stays cloud even if someone rewrites its URL to localhost
        // (defense against a confused config).
        XCTAssertFalse(ProviderFactory.isLocal(kind: .openrouter, config: .init(baseURL: "http://localhost:9999", model: "")))
        XCTAssertFalse(ProviderFactory.isLocal(kind: .custom, config: .init(baseURL: "not a url", model: "")))
    }

    func testNoteSensitiveFlagPersistsAndDefaultsFalse() throws {
        var note = Note(content: "# Secret project")
        XCTAssertFalse(note.isSensitive)
        note.isSensitive = true

        let encoded = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(Note.self, from: encoded)
        XCTAssertTrue(decoded.isSensitive)

        // Old note files without the field decode as not sensitive.
        let legacy = Data("{\"content\":\"# Old note\"}".utf8)
        XCTAssertFalse(try JSONDecoder().decode(Note.self, from: legacy).isSensitive)
    }

    func testAutoLockSettingsRoundtripAndClamp() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.autoLockMinutes, 15)
        XCTAssertTrue(settings.lockOnScreenSleep)
        XCTAssertTrue(settings.excludeFromCapture)

        settings.autoLockMinutes = 30
        settings.lockOnScreenSleep = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.autoLockMinutes, 30)
        XCTAssertFalse(decoded.lockOnScreenSleep)

        let outOfRange = Data(#"{"autoLockMinutes": 100000}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: outOfRange).autoLockMinutes, 240)
    }
}
#endif
