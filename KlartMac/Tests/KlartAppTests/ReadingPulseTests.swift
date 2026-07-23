#if os(macOS)
import XCTest
import KlartKit
@testable import Klart

/// The editor's "reading" pulse is driven by one predicate and one beat, so
/// that what the surface says and what it does cannot disagree. The pulse
/// itself is a private SwiftUI modifier and cannot be observed; its inputs
/// can, and they are where the duplication would creep back in.
@MainActor
final class ReadingPulseTests: XCTestCase {
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

    func testEditorIsReadingOnlyWhileItIsActuallyWorking() {
        let fixture = AppFixture()
        app = fixture
        let state = fixture.state

        state.feedbackPhase = .idle
        state.coachRunning = false
        XCTAssertFalse(state.editorIsReading)

        state.feedbackPhase = .analyzing
        XCTAssertTrue(state.editorIsReading)

        state.feedbackPhase = .idle
        state.coachRunning = true
        XCTAssertTrue(state.editorIsReading, "a coach action is the editor reading too")

        state.coachRunning = false
        // The debounce is not reading: nothing is being worked on yet, and
        // pulsing through it would make the surface look busy while idle.
        state.feedbackPhase = .waiting
        XCTAssertFalse(state.editorIsReading)

        state.feedbackPhase = .error("boom")
        XCTAssertFalse(state.editorIsReading)
        state.feedbackPhase = .skipped("sensitive")
        XCTAssertFalse(state.editorIsReading)
    }

    /// One beat: the caret's blink timer and the reading pulse read the same
    /// constant, so the two can never drift into looking like separate clocks.
    func testTheSurfaceHasOneBeat() {
        XCTAssertEqual(KlartPulse.period, 1.0, accuracy: 0.001)
        XCTAssertEqual(KlartPulse.dimmedOpacity, 0.42, accuracy: 0.001)
    }
}
#endif
