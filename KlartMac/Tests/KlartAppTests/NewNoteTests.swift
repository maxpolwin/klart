#if os(macOS)
import XCTest
import AppKit
@testable import Klart

/// A note you have just opened should be one you can write in. This is the
/// whole app — real `AppState`, real `TeleprompterView` — because the bug it
/// guards only exists at that level: SwiftUI rebuilds the editor per note
/// (`.id(selectedNoteID)`), and removing the old view hands first responder
/// back to the window, so ⌘N left the caret at writing height in a view that
/// no keystroke could reach.
@MainActor
final class NewNoteTests: XCTestCase {
    private var app: AppFixture?

    override func setUp() async throws {
        try await super.setUp()
        try requireWindowServer()
    }

    override func tearDown() async throws {
        app?.tearDown()
        app = nil
        try await super.tearDown()
    }

    private func makeApp() -> AppFixture {
        let made = AppFixture()
        app = made
        return made
    }

    func testANewNoteHoldsTheKeyboard() throws {
        let fixture = makeApp()
        fixture.state.createNote()

        let textView = try XCTUnwrap(fixture.waitForEditor())
        XCTAssertTrue(
            pump(until: { fixture.window.firstResponder === textView },
                 "first responder is \(String(describing: fixture.window.firstResponder))")
        )
    }

    func testTypingIntoANewNoteLands() throws {
        let fixture = makeApp()
        fixture.state.createNote()
        let textView = try XCTUnwrap(fixture.waitForEditor())
        XCTAssertTrue(pump(until: { fixture.window.firstResponder === textView }))

        typeIntoWindow(fixture.window, "Hello")

        XCTAssertTrue(pump(until: { fixture.state.editorText == "# Hello" },
                           "the note reads \(fixture.state.editorText.debugDescription)"))
        XCTAssertEqual(textView.string, "# Hello")
    }

    func testSwitchingNotesLeavesTheNewOneWritable() throws {
        let fixture = makeApp()
        fixture.state.createNote()
        _ = try XCTUnwrap(fixture.waitForEditor())
        let first = try XCTUnwrap(fixture.state.selectedNoteID)

        fixture.state.createNote()
        XCTAssertTrue(pump(until: { fixture.state.selectedNoteID != first }))
        // Back to the first note: the editor is rebuilt again, which is the
        // moment focus used to be lost.
        fixture.state.selectedNoteID = first

        XCTAssertTrue(pump(until: {
            guard let textView = fixture.textView else { return false }
            return fixture.window.firstResponder === textView
        }, "the editor never took the keyboard back after a note switch"))

        typeIntoWindow(fixture.window, "x")
        XCTAssertTrue(pump(until: { fixture.state.editorText.contains("x") }))
    }

    /// The other half of claiming focus: never taking it from a control that
    /// already has it. Without the guard, every note switch would yank the
    /// keyboard out of the search field mid-query.
    func testTheEditorDoesNotTakeFocusFromAControlThatHasIt() {
        final class FocusHolder: NSView {
            override var acceptsFirstResponder: Bool { true }
        }

        let holder = FocusHolder(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let editor = EditorFixture("# Hello\n", focusHolder: holder)
        defer { editor.tearDown() }

        XCTAssertTrue(editor.window.firstResponder === holder, "fixture is wrong: the holder never had focus")
        // Wait for a POSITIVE signal that the deferred open path — the same
        // block that would claim focus — actually ran, so a green result means
        // "declined to steal" rather than "the claim never fired yet".
        XCTAssertTrue(pump(until: { editor.textView.textContainerInset.height > 100 },
                           "the deferred open-centring never ran, so nothing was tested"))

        XCTAssertTrue(editor.window.firstResponder === holder, "the editor stole focus from a live control")
        XCTAssertFalse(editor.window.firstResponder === editor.textView)
    }

    func testTheEditorDoesNotReclaimFocusAfterLosingIt() {
        let editor = EditorFixture("# Hello\n")
        defer { editor.tearDown() }
        XCTAssertTrue(pump(until: { editor.window.firstResponder === editor.textView }))

        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        editor.window.contentView?.addSubview(other)
        editor.window.makeFirstResponder(other)
        pumpFor(0.4)

        XCTAssertFalse(editor.window.firstResponder === editor.textView,
                       "the editor took the keyboard back after the user moved on")
    }
}
#endif
