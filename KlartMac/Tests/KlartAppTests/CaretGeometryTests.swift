#if os(macOS)
import XCTest
import AppKit
@testable import Klart

/// The caret is drawn by hand (AppKit's own insertion point is suppressed), so
/// its rect is ours to get wrong. These lock its shape against the two ways it
/// has already been wrong: drawn to the line box instead of the type, and
/// placed on the line above the one the caret is actually on.
@MainActor
final class CaretGeometryTests: XCTestCase {
    private var fixture: EditorFixture?

    override func setUp() async throws {
        try await super.setUp()
        try requireWindowServer()
    }

    override func tearDown() async throws {
        fixture?.tearDown()
        fixture = nil
        try await super.tearDown()
    }

    private func makeFixture(_ text: String) -> EditorFixture {
        let made = EditorFixture(text)
        fixture = made
        return made
    }

    /// For tests that type: the editor has to have claimed the keyboard first,
    /// or the key events are dropped and the assertions measure nothing.
    private func makeReadyFixture(_ text: String) -> EditorFixture {
        let made = makeFixture(text)
        made.waitUntilReady()
        return made
    }

    private func fontHeight(_ font: NSFont) -> CGFloat { font.ascender - font.descender }

    // MARK: The caret is the height of the type

    func testCaretIsTheHeightOfTheFontNotOfTheLineBox() throws {
        let editor = makeFixture("# Title\nbody text on its own line\nand another line below\n")
        let textView = editor.textView
        let layoutManager = try XCTUnwrap(textView.layoutManager)

        // Middle of the first body line, which has a line below it — so its
        // fragment carries the full lineSpacing the caret must not inherit.
        let location = ("# Title\nbody te" as NSString).length
        textView.setSelectedRange(NSRange(location: location, length: 0))

        let caret = textView.currentCaretRect()
        XCTAssertEqual(
            caret.height, fontHeight(EditorStyler.bodyFont), accuracy: 0.01,
            "the caret should be exactly the body font's ascender-to-descender"
        )

        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        XCTAssertLessThan(
            caret.height, fragment.height - 3,
            "the caret is being drawn to the line box again (fragment \(fragment.height), caret \(caret.height))"
        )

        // The gap only exists because the paragraph carries this rhythm; if it
        // is ever tuned away, the assertion above stops meaning anything.
        let paragraph = EditorStyler.paragraphStyle
        XCTAssertEqual(paragraph.lineSpacing, 4.5, accuracy: 0.001)
        XCTAssertEqual(paragraph.paragraphSpacing, 4, accuracy: 0.001)
    }

    func testCaretScalesWithTheHeadingItStandsIn() throws {
        let editor = makeFixture("# Title\nbody\n")
        let textView = editor.textView

        textView.setSelectedRange(NSRange(location: 4, length: 0))   // inside "Title"
        let inHeading = textView.currentCaretRect().height
        textView.setSelectedRange(NSRange(location: 9, length: 0))   // inside "body"
        let inBody = textView.currentCaretRect().height

        XCTAssertEqual(inHeading, fontHeight(EditorStyler.headingFont(level: 1)), accuracy: 0.01)
        XCTAssertEqual(inBody, fontHeight(EditorStyler.bodyFont), accuracy: 0.01)
        XCTAssertGreaterThan(inHeading, inBody + 8, "an H1 caret should be visibly taller than a body one")
    }

    // MARK: The caret is on the line you are actually on

    func testCaretOnTheLineEnterOpensAtTheEndOfANote() throws {
        let editor = makeReadyFixture("first line\nsecond line")
        let textView = editor.textView
        let layoutManager = try XCTUnwrap(textView.layoutManager)

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        let lastLine = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil
        )
        typeIntoWindow(editor.window, "\n")

        let caret = textView.currentCaretRect()
        XCTAssertGreaterThanOrEqual(
            caret.minY, lastLine.maxY + textView.textContainerInset.height - 0.5,
            "the caret fell back to the previous line instead of the empty one Enter just opened"
        )
        XCTAssertEqual(caret.height, fontHeight(EditorStyler.bodyFont), accuracy: 0.01)
    }

    func testCaretStandsAfterTheLastCharacterNotBeforeIt() throws {
        let editor = makeFixture("abc")
        let textView = editor.textView
        let layoutManager = try XCTUnwrap(textView.layoutManager)

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        let afterFirst = textView.currentCaretRect().minX
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let atEnd = textView.currentCaretRect().minX

        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        XCTAssertEqual(atEnd, used.maxX + textView.textContainerInset.width, accuracy: 0.5)
        XCTAssertGreaterThan(atEnd, afterFirst, "the caret at the end sits before the last character")
    }

    /// Lines with no glyphs build their x by hand, and the text container's
    /// own padding is part of it — every other line gets it from the glyph
    /// location. Without it the caret sits left of where the first character
    /// lands and jumps right on the first keystroke.
    func testCaretOnAnEmptyNoteLinesUpWithTheFirstCharacter() throws {
        let editor = makeReadyFixture("")
        let textView = editor.textView
        let layoutManager = try XCTUnwrap(textView.layoutManager)

        let beforeTyping = textView.currentCaretRect().minX
        typeIntoWindow(editor.window, "H")
        layoutManager.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let firstGlyphX = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).origin.x
            + layoutManager.location(forGlyphAt: 0).x
            + textView.textContainerInset.width
        XCTAssertEqual(beforeTyping, firstGlyphX, accuracy: 0.5)
    }

    func testCaretOnTheLineEnterOpensLinesUpWithTheFirstCharacter() throws {
        let editor = makeReadyFixture("first line")
        let textView = editor.textView
        let layoutManager = try XCTUnwrap(textView.layoutManager)

        let firstGlyphX = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).origin.x
            + layoutManager.location(forGlyphAt: 0).x
            + textView.textContainerInset.width

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        typeIntoWindow(editor.window, "\n")

        XCTAssertEqual(textView.currentCaretRect().minX, firstGlyphX, accuracy: 0.5)
    }
}
#endif
