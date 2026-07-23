import XCTest
@testable import KlartKit

final class RecommendationLogTests: XCTestCase {
    var tempDir: URL!
    var fileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klart-reclog-\(UUID().uuidString)", isDirectory: true)
        fileURL = tempDir.appendingPathComponent("recommendations.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func record(
        _ outcome: RecommendationOutcome = .confirmed,
        kind: FeedbackKind = .gap,
        withContent: Bool = false,
        sensitive: Bool = false
    ) -> RecommendationRecord {
        RecommendationRecord(
            outcome: outcome,
            kind: kind,
            fingerprint: "fp-\(kind.rawValue)",
            model: "llama3.2",
            provider: "Ollama",
            systemPromptHash: StableHash.fnv1a("prompt"),
            usesDefaultPrompt: true,
            noteID: UUID(),
            fromSensitiveNote: sensitive,
            noteTitle: withContent ? "Pricing strategy" : nil,
            documentTopic: withContent ? "Pricing" : nil,
            sectionTitle: withContent ? "Who pays?" : nil,
            contextParagraph: withContent ? "Enterprise buyers care about seats." : nil,
            observation: withContent ? "No mention of churn." : nil,
            suggestion: withContent ? "Add a churn assumption." : nil
        )
    }

    // MARK: - Storage

    func testAppendAndLoadRoundtrip() async throws {
        let log = RecommendationLog(fileURL: fileURL)
        try await log.append(record(.confirmed, kind: .gap))
        try await log.append(record(.rejected, kind: .mece))

        let loaded = await log.loadAll()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].outcome, .confirmed)
        XCTAssertEqual(loaded[0].kind, .gap)
        XCTAssertEqual(loaded[1].outcome, .rejected)
        XCTAssertEqual(loaded[1].kind, .mece)
        XCTAssertEqual(loaded[1].model, "llama3.2")
    }

    func testMissingFileLoadsEmptyRatherThanThrowing() async {
        let log = RecommendationLog(fileURL: fileURL)
        let loaded = await log.loadAll()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testCorruptFileLoadsEmptyRatherThanTakingTheLogDown() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let log = RecommendationLog(fileURL: fileURL)
        let loaded = await log.loadAll()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testClearRemovesEverything() async throws {
        let log = RecommendationLog(fileURL: fileURL)
        try await log.append(record())
        try await log.clear()
        let count = await log.count()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Vault behaviour

    func testLockedLogRefusesWrites() async throws {
        let log = RecommendationLog(fileURL: fileURL)
        await log.lock()
        do {
            try await log.append(record())
            XCTFail("a locked log must refuse to append")
        } catch {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSealedRoundtripAndOpaqueOnDisk() async throws {
        let key = Data(repeating: 7, count: 32)
        let log = RecommendationLog(fileURL: fileURL)
        await log.setEncryptionKey(key)
        try await log.append(record(.rejected, withContent: true))

        // On disk it must not be readable as plain JSON.
        let raw = try Data(contentsOf: fileURL)
        XCTAssertTrue(VaultCrypto.isSealed(raw))
        XCTAssertNil(try? JSONDecoder().decode([RecommendationRecord].self, from: raw))

        let loaded = await log.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].noteTitle, "Pricing strategy")
    }

    func testEncryptThenDecryptOnDiskReturnsPlaintext() async throws {
        let key = Data(repeating: 9, count: 32)
        let log = RecommendationLog(fileURL: fileURL)
        try await log.append(record(.confirmed, withContent: true))   // plaintext first

        try await log.encryptOnDisk(masterKey: key)
        XCTAssertTrue(VaultCrypto.isSealed(try Data(contentsOf: fileURL)))
        var loaded = await log.loadAll()
        XCTAssertEqual(loaded.count, 1, "sealing must not lose records")

        try await log.decryptOnDisk(masterKey: key)
        XCTAssertFalse(VaultCrypto.isSealed(try Data(contentsOf: fileURL)))
        loaded = await log.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].outcome, .confirmed)
    }

    func testRotateOnDiskRewrapsUnderTheNewKey() async throws {
        let oldKey = Data(repeating: 1, count: 32)
        let newKey = Data(repeating: 2, count: 32)
        let log = RecommendationLog(fileURL: fileURL)
        await log.setEncryptionKey(oldKey)
        try await log.append(record(.rejected))

        try await log.rotateOnDisk(oldKey: oldKey, newKey: newKey)

        // A fresh store holding only the new key must be able to read it.
        let reopened = RecommendationLog(fileURL: fileURL)
        await reopened.setEncryptionKey(newKey)
        let loaded = await reopened.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].outcome, .rejected)
    }

    func testRotateIsIdempotentSoAnInterruptedRotationCanResume() async throws {
        let oldKey = Data(repeating: 3, count: 32)
        let newKey = Data(repeating: 4, count: 32)
        let log = RecommendationLog(fileURL: fileURL)
        await log.setEncryptionKey(oldKey)
        try await log.append(record())

        try await log.rotateOnDisk(oldKey: oldKey, newKey: newKey)
        try await log.rotateOnDisk(oldKey: oldKey, newKey: newKey)   // resume path

        let loaded = await log.loadAll()
        XCTAssertEqual(loaded.count, 1)
    }

    func testMigrationsOnAnAbsentLogAreHarmless() async throws {
        let key = Data(repeating: 5, count: 32)
        let log = RecommendationLog(fileURL: fileURL)
        try await log.encryptOnDisk(masterKey: key)
        try await log.decryptOnDisk(masterKey: key)
        try await log.rotateOnDisk(oldKey: key, newKey: Data(repeating: 6, count: 32))
        let loaded = await log.loadAll()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Record shape

    func testForgivingDecodeOfAnOlderRecord() throws {
        let json = Data(#"{"outcome":"rejected","kind":"clarity"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(RecommendationRecord.self, from: json)
        XCTAssertEqual(record.outcome, .rejected)
        XCTAssertEqual(record.kind, .clarity)
        XCTAssertTrue(record.usesDefaultPrompt)
        XCTAssertFalse(record.carriesContent)
    }

    func testRedactingContentKeepsTheSignalTier() {
        let full = record(.rejected, withContent: true)
        XCTAssertTrue(full.carriesContent)

        let redacted = full.redactingContent()
        XCTAssertFalse(redacted.carriesContent)
        XCTAssertNil(redacted.contextParagraph)
        XCTAssertNil(redacted.observation)
        // The signal that makes the log useful must survive redaction.
        XCTAssertEqual(redacted.outcome, .rejected)
        XCTAssertEqual(redacted.kind, full.kind)
        XCTAssertEqual(redacted.fingerprint, full.fingerprint)
        XCTAssertEqual(redacted.systemPromptHash, full.systemPromptHash)
        XCTAssertEqual(redacted.model, "llama3.2")
        XCTAssertEqual(redacted.noteID, full.noteID)
    }

    func testClipContextBoundsStoredText() {
        let long = String(repeating: "word ", count: 2000)
        let clipped = RecommendationRecord.clipContext(long)
        XCTAssertLessThanOrEqual(clipped.count, RecommendationRecord.maxContextLength + 1)
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertEqual(RecommendationRecord.clipContext("short"), "short")
    }

    func testPromptHashDistinguishesEditedPrompts() {
        let a = StableHash.fnv1a(PromptBuilder.defaultFeedbackTemplate)
        let b = StableHash.fnv1a(PromptBuilder.defaultFeedbackTemplate + " Be terse.")
        XCTAssertNotEqual(a, b, "an edited prompt must be distinguishable in the log")
        XCTAssertEqual(a, StableHash.fnv1a(PromptBuilder.defaultFeedbackTemplate))
    }

    // MARK: - Export

    func testExportWithoutContentRedactsEveryRecord() {
        let records = [record(.confirmed, withContent: true), record(.rejected, withContent: true)]
        let export = RecommendationExport.make(from: records, includeContent: false)

        XCTAssertFalse(export.includesContent)
        XCTAssertEqual(export.recordCount, 2)
        XCTAssertTrue(export.records.allSatisfy { !$0.carriesContent })
        XCTAssertTrue(export.records.allSatisfy { !$0.fingerprint.isEmpty })
    }

    func testExportWithContentStillRedactsSensitiveNotes() {
        let records = [
            record(.confirmed, withContent: true, sensitive: false),
            record(.rejected, withContent: true, sensitive: true)
        ]
        let export = RecommendationExport.make(from: records, includeContent: true)

        XCTAssertTrue(export.records[0].carriesContent)
        XCTAssertFalse(
            export.records[1].carriesContent,
            "a sensitive note's text must not leave the machine through an export"
        )
        XCTAssertEqual(export.records[1].outcome, .rejected, "its signal is still worth keeping")
    }

    func testExportEncodesSelfDescribingEnvelope() throws {
        let export = RecommendationExport.make(from: [record()], includeContent: false)
        let data = try export.encoded()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["schema"] as? String, RecommendationExport.currentSchema)
        XCTAssertEqual(json["includesContent"] as? Bool, false)
        XCTAssertEqual(json["recordCount"] as? Int, 1)
        XCTAssertNotNil(json["exportedAt"])
        XCTAssertEqual((json["records"] as? [Any])?.count, 1)
    }
}
