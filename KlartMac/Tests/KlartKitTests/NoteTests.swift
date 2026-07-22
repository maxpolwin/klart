import XCTest
@testable import KlartKit

final class NoteTests: XCTestCase {
    func testTitleStripsARealHeadingMarker() {
        XCTAssertEqual(Note(content: "# Hello\n\nWorld").title, "Hello")
        XCTAssertEqual(Note(content: "### Sub heading").title, "Sub heading")
    }

    func testTitlePreservesAHashNotUsedAsAHeading() {
        // No space after "#" — this is a hashtag/"C#"/"#1"-style "#", not a
        // heading marker, so it must survive into the title untouched.
        XCTAssertEqual(Note(content: "#idea quick note").title, "#idea quick note")
        XCTAssertEqual(Note(content: "#1 priority: ship it").title, "#1 priority: ship it")
        XCTAssertEqual(Note(content: "C# notes").title, "C# notes")
    }

    func testTitlePreservesTooManyHashesToBeAHeading() {
        XCTAssertEqual(Note(content: "####### too deep").title, "####### too deep")
    }

    func testTitleSkipsAnEmptyHeadingLineAndKeepsLooking() {
        XCTAssertEqual(Note(content: "#\nReal Title").title, "Real Title")
    }

    func testTitleFallsBackToUntitled() {
        XCTAssertEqual(Note(content: "").title, "Untitled")
        XCTAssertEqual(Note(content: "   \n\n  ").title, "Untitled")
    }

    func testPreviewSkipsARealHeadingButKeepsAPlainHashLine() {
        let note = Note(content: """
        My Title
        #reminder check this later
        Some actual body text
        """)
        // "#reminder..." has no space after "#" — it's body text, not a
        // heading, so it must be the preview, not skipped.
        XCTAssertEqual(note.preview, "#reminder check this later")
    }

    func testPreviewSkipsRealHeadingLines() {
        let note = Note(content: """
        My Title
        ## Section
        Some actual body text
        """)
        XCTAssertEqual(note.preview, "Some actual body text")
    }
}
