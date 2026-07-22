#if canImport(CryptoKit)
import XCTest
@testable import KlartKit

/// End-to-end vault behavior at the storage layer, mirroring the app's real
/// sequence: write notes → enable protection → relaunch locked → unlock →
/// edit → lock → disable. Verifies that plaintext never touches disk while
/// protection is on and that no content is lost across any transition.
final class VaultLifecycleTests: XCTestCase {
    private var dir: URL!
    private var store: NoteStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klart-lifecycle-\(UUID().uuidString)")
        store = NoteStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func rawFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
    }

    private func assertNoPlaintextOnDisk(_ needles: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        for url in try rawFiles() {
            let raw = try Data(contentsOf: url)
            XCTAssertTrue(VaultCrypto.isSealed(raw), "\(url.lastPathComponent) is not sealed", file: file, line: line)
            for needle in needles {
                XCTAssertNil(
                    raw.range(of: Data(needle.utf8)),
                    "plaintext “\(needle)” leaked into \(url.lastPathComponent)",
                    file: file, line: line
                )
            }
        }
    }

    func testFullVaultLifecycle() async throws {
        let secrets = ["Merger negotiation timeline", "Therapy session notes", "Diagnosed with"]
        var ids: [UUID] = []
        for secret in secrets {
            let note = Note(content: "# \(secret)\nDetails about \(secret.lowercased()).")
            ids.append(note.id)
            try await store.save(note)
        }

        // Enable protection.
        let key = VaultCrypto.generateMasterKey()
        try await store.encryptAllOnDisk(masterKey: key)
        try assertNoPlaintextOnDisk(secrets)

        // While unlocked: everything loads, edits stay sealed on disk.
        var loaded = try await store.loadAll()
        XCTAssertEqual(Set(loaded.map(\.id)), Set(ids))
        var edited = loaded[0]
        edited.content += "\nAppended after enabling."
        try await store.save(edited)
        try assertNoPlaintextOnDisk(secrets + ["Appended after enabling"])

        // Simulated relaunch with protection on: a fresh store, locked.
        let relaunched = NoteStore(directory: dir)
        await relaunched.lock()
        let whileLocked = try await relaunched.loadAll()
        XCTAssertTrue(whileLocked.isEmpty, "locked store must expose no notes")

        // Unlock and verify nothing was lost.
        await relaunched.setEncryptionKey(key)
        loaded = try await relaunched.loadAll()
        XCTAssertEqual(Set(loaded.map(\.id)), Set(ids))
        XCTAssertTrue(loaded.contains { $0.content.contains("Appended after enabling.") })

        // Disable protection: plaintext returns, contents intact.
        try await relaunched.decryptAllOnDisk(masterKey: key)
        for url in try rawFiles() {
            XCTAssertFalse(VaultCrypto.isSealed(try Data(contentsOf: url)))
        }
        let final = try await relaunched.loadAll()
        XCTAssertEqual(Set(final.map(\.id)), Set(ids))
    }

    func testLockedStoreRefusesAllWrites() async throws {
        let note = Note(content: "# Existing")
        try await store.save(note)
        let key = VaultCrypto.generateMasterKey()
        try await store.encryptAllOnDisk(masterKey: key)
        await store.lock()

        // A stray save while locked (menu action, late autosave) must throw,
        // not silently write plaintext into the encrypted library.
        do {
            try await store.save(Note(content: "# Sneaky plaintext"))
            XCTFail("save must throw while locked")
        } catch VaultError.locked {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        do {
            try await store.delete(id: note.id)
            XCTFail("delete must throw while locked")
        } catch VaultError.locked {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // The library holds exactly the one sealed file, untouched.
        let files = try rawFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(VaultCrypto.isSealed(try Data(contentsOf: files[0])))

        // Unlocking restores full function.
        await store.setEncryptionKey(key)
        try await store.save(Note(content: "# After unlock"))
        XCTAssertEqual(try rawFiles().count, 2)
        try assertNoPlaintextOnDisk(["After unlock"])
    }

    func testLoadAllWithWrongKeySkipsInsteadOfGarbage() async throws {
        try await store.save(Note(content: "# Real content"))
        try await store.encryptAllOnDisk(masterKey: VaultCrypto.generateMasterKey())

        let attacker = NoteStore(directory: dir)
        await attacker.setEncryptionKey(VaultCrypto.generateMasterKey())
        let loaded = try await attacker.loadAll()
        XCTAssertTrue(loaded.isEmpty, "wrong key must never yield decoded notes")
    }

    func testSettingsRoundtripPreservesVaultConfig() throws {
        let fileURL = dir.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: fileURL)

        let (_, config) = try VaultCrypto.createVault(password: "roundtrip pw", biometricUnlock: true)
        var settings = AppSettings()
        settings.vault = config
        try store.save(settings)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.vault, config)
        // And the wrapped key still unlocks with the right password.
        XCTAssertNoThrow(try VaultCrypto.unlock(config: reloaded.vault!, password: "roundtrip pw"))
        XCTAssertThrowsError(try VaultCrypto.unlock(config: reloaded.vault!, password: "other"))

        // The settings file itself must never contain raw key material — only
        // the wrapped (encrypted) master key. Nothing to grep for beyond
        // structure: assert the expected fields exist and nothing else secret.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let vault = json?["vault"] as? [String: Any]
        XCTAssertNotNil(vault?["salt"])
        XCTAssertNotNil(vault?["wrappedMasterKey"])
        XCTAssertEqual(vault?["iterations"] as? Int, VaultCrypto.defaultIterations)
    }
}
#endif
