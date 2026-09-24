import XCTest
@testable import KlartKit

/// The markdown export is the recommended backup, so a restore must bring a
/// note back exactly as protected as it left.
final class MarkdownExportTests: XCTestCase {
    func testSensitiveNoteRoundTripsItsMark() {
        let note = Note(content: "# Diagnosis\nPrivate.", isSensitive: true)
        let file = MarkdownExport.fileContents(for: note)
        XCTAssertTrue(file.hasPrefix("<!-- klart:id=\(note.id.uuidString) "))
        XCTAssertTrue(file.contains(" sensitive=true "))

        let parsed = MarkdownExport.parse(file)
        XCTAssertEqual(parsed.id, note.id)
        XCTAssertTrue(parsed.isSensitive)
        XCTAssertEqual(parsed.body, note.content)
        XCTAssertEqual(
            parsed.createdAt?.timeIntervalSince1970 ?? 0,
            note.createdAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testOrdinaryNoteCarriesNoSensitiveField() {
        let file = MarkdownExport.fileContents(for: Note(content: "# Plan"))
        XCTAssertFalse(file.contains("sensitive"))
        XCTAssertFalse(MarkdownExport.parse(file).isSensitive)
    }

    func testHeaderWrittenBeforeTheSensitiveFieldStillParses() {
        let id = UUID()
        let file = "<!-- klart:id=\(id.uuidString) created=2026-01-02T03:04:05Z -->\n# Old export"
        let parsed = MarkdownExport.parse(file)
        XCTAssertEqual(parsed.id, id)
        XCTAssertNotNil(parsed.createdAt)
        XCTAssertFalse(parsed.isSensitive)
        XCTAssertEqual(parsed.body, "# Old export")
    }

    func testFileWithoutHeaderImportsAsPlainMarkdown() {
        let parsed = MarkdownExport.parse("# Just markdown\n<!-- klart:id=x -->\n")
        XCTAssertNil(parsed.id)
        XCTAssertFalse(parsed.isSensitive)
        XCTAssertEqual(parsed.body, "# Just markdown\n<!-- klart:id=x -->\n")
    }

    func testImportNeverClearsAnExistingSensitiveMark() {
        let existing = Note(content: "# Private", rejectedFingerprints: ["tip-1"], isSensitive: true)
        // An export made before the note was marked, or a doctored copy.
        let unmarked = MarkdownExport.fileContents(for: Note(id: existing.id, content: "# Private\nEdited"))

        let imported = MarkdownExport.note(from: MarkdownExport.parse(unmarked), existing: existing)
        XCTAssertEqual(imported.id, existing.id)
        XCTAssertTrue(imported.isSensitive)
        XCTAssertEqual(imported.rejectedFingerprints, ["tip-1"])
        XCTAssertEqual(imported.content, "# Private\nEdited")
    }

    func testImportCanMarkANoteSensitive() {
        let marked = MarkdownExport.fileContents(for: Note(content: "# New", isSensitive: true))
        let imported = MarkdownExport.note(from: MarkdownExport.parse(marked), existing: nil)
        XCTAssertTrue(imported.isSensitive)

        let existing = Note(id: imported.id, content: "# New")
        XCTAssertTrue(MarkdownExport.note(from: MarkdownExport.parse(marked), existing: existing).isSensitive)
    }
}
