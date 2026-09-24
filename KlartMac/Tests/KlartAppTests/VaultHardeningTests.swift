#if os(macOS)
import XCTest
import KlartKit
@testable import Klart

/// Security properties of the wiring in `AppState`: every password check
/// shares one throttle, unlock leaves no plaintext behind, and a markdown
/// restore never opens a sensitive note to the cloud. No window is needed,
/// but `AppState` registers AppKit observers, so these still need a session.
@MainActor
final class VaultHardeningTests: XCTestCase {
    private var directory: URL!
    private let password = "correct horse battery staple"

    override func setUp() async throws {
        try await super.setUp()
        try requireWindowServer()
        bootstrapApp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klart-vault-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private var notesDirectory: URL { directory.appendingPathComponent("Notes", isDirectory: true) }

    private func makeState() async -> AppState {
        let state = AppState(
            noteStore: NoteStore(directory: notesDirectory),
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            secrets: InMemorySecretStore(),
            recommendationLog: RecommendationLog(fileURL: directory.appendingPathComponent("recommendations.json"))
        )
        state.settings.autoFeedback = false
        await waitUntil { state.notesDidLoad }
        return state
    }

    private func waitUntil(_ condition: () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            attempts += 1
        }
        XCTAssertTrue(condition(), "condition not reached in time")
    }

    func testSettingsPasswordChecksShareTheUnlockThrottle() async throws {
        let state = await makeState()
        try await state.enableProtection(password: password, biometricUnlock: false)

        for _ in 0..<5 {
            do {
                try await state.disableProtection(password: "wrong")
                XCTFail("a wrong password must not turn protection off")
            } catch {
                XCTAssertEqual(error as? VaultError, .wrongPassword)
            }
        }
        XCTAssertGreaterThan(state.lockoutRemaining, 0)

        // Even the right password is refused until the lockout ends — from
        // Settings as from the lock screen.
        do {
            try await state.disableProtection(password: password)
            XCTFail("the lockout must cover Settings too")
        } catch VaultError.throttled {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let unlocked = await state.unlock(password: password)
        XCTAssertFalse(unlocked)
        XCTAssertNotNil(state.settings.vault, "protection must still be on")
    }

    func testUnlockSealsPlaintextLeftByAnInterruptedMigration() async throws {
        let state = await makeState()
        try await state.enableProtection(password: password, biometricUnlock: false)

        // A note written in plaintext behind the vault's back — what an
        // interrupted enableProtection leaves behind.
        let stray = Note(content: "# Stray\nWritten before sealing finished.")
        try await NoteStore(directory: notesDirectory).save(stray)
        let strayFile = notesDirectory.appendingPathComponent("\(stray.id.uuidString).json")
        XCTAssertFalse(VaultCrypto.isSealed(try Data(contentsOf: strayFile)))

        state.lockNow()
        await waitUntil { state.isLocked }
        let unlocked = await state.unlock(password: password)
        XCTAssertTrue(unlocked)

        XCTAssertTrue(VaultCrypto.isSealed(try Data(contentsOf: strayFile)))
        XCTAssertTrue(state.notes.contains { $0.id == stray.id })
    }

    func testImportKeepsASensitiveNoteSensitive() async throws {
        let state = await makeState()
        state.createNote()
        state.editorText = "# Diagnosis\nPrivate."
        state.toggleSensitive()
        let original = try XCTUnwrap(state.selectedNote)
        XCTAssertTrue(original.isSensitive)

        // An export made before the note was marked sensitive.
        let backup = MarkdownExport.fileContents(
            for: Note(id: original.id, content: "# Diagnosis\nRestored.", createdAt: original.createdAt)
        )
        state.importMarkdown(backup)

        let restored = try XCTUnwrap(state.notes.first { $0.id == original.id })
        XCTAssertTrue(restored.isSensitive)
        XCTAssertEqual(restored.content, "# Diagnosis\nRestored.")
        XCTAssertEqual(state.notes.filter { $0.id == original.id }.count, 1)
    }
}
#endif
