#if canImport(CryptoKit)
import XCTest
@testable import KlartKit

/// A note's identity is its filename: a stray or planted file must not
/// shadow the real note, and the sealing sweep must finish what it can.
final class NoteStoreIdentityTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klart-identity-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(for id: UUID, in directory: URL? = nil) -> URL {
        (directory ?? dir).appendingPathComponent("\(id.uuidString).json")
    }

    func testFileNamedForOneNoteClaimingAnotherIsIgnored() async throws {
        let store = NoteStore(directory: dir)
        let real = Note(content: "# Real")
        try await store.save(real)
        try FileManager.default.copyItem(at: file(for: real.id), to: file(for: UUID()))

        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.map(\.id), [real.id])
    }

    func testPlantedCopyWithNewerTimestampCannotShadowTheRealNote() async throws {
        let store = NoteStore(directory: dir)
        let real = Note(content: "# Real content", updatedAt: Date(timeIntervalSinceNow: -3600))
        try await store.save(real)

        // Written elsewhere, then dropped in under a name that is no note's.
        let elsewhere = dir.appendingPathComponent("elsewhere")
        let planted = Note(id: real.id, content: "# Planted", updatedAt: Date(timeIntervalSinceNow: 3600))
        try await NoteStore(directory: elsewhere).save(planted)
        try FileManager.default.moveItem(
            at: file(for: real.id, in: elsewhere),
            to: dir.appendingPathComponent("planted.json")
        )

        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.content, "# Real content")
    }

    func testSealingSweepKeepsGoingPastAnUnreadableFile() async throws {
        let store = NoteStore(directory: dir)
        let a = Note(content: "# Alpha secret")
        let b = Note(content: "# Beta secret")
        try await store.save(a)
        try await store.save(b)
        // A directory with a note-like name cannot be read as a file.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("\(UUID().uuidString).json"),
            withIntermediateDirectories: true
        )

        let key = VaultCrypto.generateMasterKey()
        let remaining = try await store.encryptAllOnDisk(masterKey: key)
        XCTAssertEqual(remaining, 1)
        XCTAssertTrue(VaultCrypto.isSealed(try Data(contentsOf: file(for: a.id))))
        XCTAssertTrue(VaultCrypto.isSealed(try Data(contentsOf: file(for: b.id))))

        // Idempotent: a second sweep changes nothing and still loads both.
        let before = try Data(contentsOf: file(for: a.id))
        _ = try await store.encryptAllOnDisk(masterKey: key)
        XCTAssertEqual(try Data(contentsOf: file(for: a.id)), before)
        let loaded = try await store.loadAll()
        XCTAssertEqual(Set(loaded.map(\.id)), [a.id, b.id])
    }
}
#endif
