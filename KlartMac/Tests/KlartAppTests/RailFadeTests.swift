#if os(macOS)
import XCTest
import AppKit
import KlartKit
@testable import Klart

/// The editor's rail goes away on its own once the writer carries on: three
/// seconds after the first keystroke, as one thing — not per note, and not
/// after minutes. Real window and real key events, since the countdown lives
/// in the view that receives the keystrokes.
@MainActor
final class RailFadeTests: XCTestCase {
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

    private func railFixture() -> AppFixture {
        let fixture = AppFixture()
        app = fixture
        fixture.state.createNote()
        fixture.state.editorText = "# Untitled\n\nasdf"
        _ = fixture.waitForEditor()
        fixture.state.feedbackItems = [
            FeedbackItem(kind: .gap, anchor: nil, text: "Nothing here.", section: "Untitled"),
            FeedbackItem(kind: .clarity, anchor: nil, text: "Vague.", section: "Other"),
        ]
        fixture.state.editorRailVisible = true
        pumpFor(2.6)   // the arrival spring
        return fixture
    }

    func testTheWholeRailFadesAfterFiveSecondsOverTwenty() {
        let fixture = railFixture()
        XCTAssertTrue(fixture.state.editorRailVisible)

        typeIntoWindow(fixture.window, "x")
        pumpFor(8)
        XCTAssertTrue(fixture.state.editorRailVisible, "still there mid-fade: the fade takes 20 s")

        pumpFor(19)    // 5 s wait + 20 s fade = 25 s, with margin
        XCTAssertFalse(fixture.state.editorRailVisible, "gone after the countdown, notes about other sections included")
    }

    func testAnUntouchedRailStays() {
        let fixture = railFixture()
        pumpFor(6)
        XCTAssertTrue(fixture.state.editorRailVisible, "no typing, no fade")
    }
}
#endif
