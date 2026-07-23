#if os(macOS)
import XCTest
import AppKit
@testable import Klart

/// The typewriter surface: the line being written is held at the centre of the
/// window, and the page under it stays clickable. The second half is not
/// decoration — putting the margin in the scroll view's `contentInsets` once
/// collapsed the text view to the height of its own text, and every click
/// outside that band stopped reaching the editor at all.
@MainActor
final class WritingSurfaceTests: XCTestCase {
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

    private func makeFixture(_ text: String, viewportHeight: CGFloat? = nil) -> EditorFixture {
        let made = EditorFixture(text, viewportHeight: viewportHeight)
        fixture = made
        return made
    }

    private func longNote(lines: Int = 80) -> String {
        "# A long note\n" + (1...lines).map { "Line \($0) of the body." }.joined(separator: "\n")
    }

    // MARK: Where the margin lives

    func testTheMarginIsHalfAViewportOfTextContainerInset() {
        let editor = makeFixture("# Hello\n")
        XCTAssertTrue(pump(until: { editor.textView.textContainerInset.height > 100 },
                           "the margin was never applied"))

        XCTAssertEqual(
            editor.textView.textContainerInset.height, (editor.viewportHeight / 2).rounded(),
            accuracy: 1
        )
    }

    /// The regression that made a new note untypable: with the margin in
    /// `contentInsets`, two half-viewport insets shrank the scroll view's
    /// content area to nothing and the document view collapsed.
    func testTheWholePageUnderTheCursorIsClickable() throws {
        let editor = makeFixture("# Hello\n")
        XCTAssertTrue(pump(until: { editor.textView.textContainerInset.height > 100 }))

        XCTAssertEqual(editor.scrollView.contentInsets.top, 0, accuracy: 0.5,
                       "the typewriter margin belongs in the text container, not in contentInsets")
        XCTAssertEqual(editor.scrollView.contentInsets.bottom, 0, accuracy: 0.5,
                       "the typewriter margin belongs in the text container, not in contentInsets")

        XCTAssertGreaterThanOrEqual(
            editor.textView.frame.height, editor.viewportHeight,
            "the document view no longer fills the window: clicks outside the text will miss the editor"
        )

        let root = try XCTUnwrap(editor.window.contentView)
        for point in [NSPoint(x: 450, y: 60), NSPoint(x: 450, y: 384), NSPoint(x: 450, y: 700)] {
            XCTAssertTrue(
                root.hitTest(point) === editor.textView,
                "a click at \(point) does not reach the editor"
            )
        }
    }

    // MARK: Where the line sits

    func testANoteOpensWithItsFirstLineAtTheCentre() {
        let editor = makeFixture("# Hello\nsome body text\n")
        XCTAssertTrue(editor.waitForCentredCaretLine())
    }

    func testTheLastLineOfALongNoteReachesTheCentre() {
        let editor = makeFixture(longNote())
        let textView = editor.textView
        XCTAssertTrue(pump(until: { textView.textContainerInset.height > 100 }))

        editor.waitUntilReady()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        typeIntoWindow(editor.window, "!")

        XCTAssertTrue(editor.waitForCentredCaretLine(),
                      "the tail margin is not deep enough for the last line to reach the centre")
    }

    func testEnterAtTheVeryEndCentresTheNewLine() throws {
        let editor = makeFixture(longNote())
        let textView = editor.textView
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        XCTAssertTrue(pump(until: { textView.textContainerInset.height > 100 }))

        editor.waitUntilReady()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        let lastLine = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil
        )
        typeIntoWindow(editor.window, "\n")

        XCTAssertTrue(editor.waitForCentredCaretLine())
        XCTAssertGreaterThanOrEqual(
            textView.currentCaretRect().minY, lastLine.maxY + textView.textContainerInset.height - 0.5,
            "the page centred on the line above the one Enter opened"
        )
    }

    /// SwiftUI plants the editor before it has a size. The centring must
    /// survive that: a chance that came too early is not the one chance the
    /// note gets.
    func testANoteStillCentresWhenItsViewportArrivesLate() {
        let editor = makeFixture("# Hello\nbody\n", viewportHeight: 0)
        pumpFor(0.2)                       // let every early attempt come and go
        XCTAssertEqual(editor.textView.textContainerInset.height, 64, accuracy: 1,
                       "there was no viewport yet; nothing should have been centred against it")

        editor.growToFullViewport()
        XCTAssertTrue(pump(until: { editor.textView.textContainerInset.height > 100 },
                           "the note never centred once its viewport arrived"))
        XCTAssertTrue(editor.waitForCentredCaretLine())
    }

    // MARK: Cost

    /// `centerCaretLine` runs on every keystroke. If the margin were reapplied
    /// each time, every character would invalidate the whole layout — correct,
    /// and unusable on a long note.
    func testReCentringDoesNotKeepRewritingTheLayout() {
        let editor = makeFixture(longNote(lines: 200))
        XCTAssertTrue(pump(until: { editor.textView.textContainerInset.height > 100 }))

        let inset = editor.textView.textContainerInset
        let frame = editor.textView.frame
        for _ in 0..<200 { editor.textView.centerCaretLine(animated: false) }

        XCTAssertEqual(editor.textView.textContainerInset.height, inset.height, accuracy: 0.001)
        XCTAssertEqual(editor.textView.frame.height, frame.height, accuracy: 0.001)
    }

    // MARK: The rail rides on the same margin

    /// `EditorBridge.lineY` anchors every margin-note card, and it reads
    /// `textContainerInset`. Move the margin somewhere else and the cards
    /// silently shift by most of a screen while every test above still passes.
    func testRailAnchorsFollowTheMargin() throws {
        let editor = makeFixture(longNote())
        let textView = editor.textView
        XCTAssertTrue(pump(until: { textView.textContainerInset.height > 100 }))

        let middle = (textView.string as NSString).length / 2
        textView.setSelectedRange(NSRange(location: middle, length: 0))
        textView.centerCaretLine(animated: false)

        // Loose on purpose: `lineY` reports the line fragment's top where the
        // centring aims the caret's middle, so the two differ by most of a
        // line. Moving the margin out of the text container shifts this by
        // ~356 pt, which ±30 still catches by an order of magnitude.
        let anchor = try XCTUnwrap(editor.bridge.lineY(atUTF16: middle))
        XCTAssertEqual(anchor, editor.viewportHeight / 2, accuracy: 30)
        XCTAssertGreaterThan(anchor, 0, "the rail would draw this card above the window")
        XCTAssertLessThan(anchor, editor.viewportHeight, "the rail would draw this card below the window")
    }
}
#endif
