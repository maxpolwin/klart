#if os(macOS)
import XCTest
import KlartKit
@testable import Klart

/// The tour shows itself once, and its sample note arrives with the editor
/// already reading it — real app state, real editor, no provider.
@MainActor
final class WelcomeTests: XCTestCase {
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

    func testAFreshInstallShowsTheTourAndFinishingItIsRemembered() {
        let fixture = AppFixture()
        app = fixture
        XCTAssertTrue(fixture.state.welcomeVisible, "a fresh install has never seen the tour")

        fixture.state.finishWelcome()
        XCTAssertFalse(fixture.state.welcomeVisible)
        XCTAssertTrue(fixture.state.settings.welcomeSeen)

        // A state built over the same settings starts without the tour.
        let again = AppState(
            noteStore: NoteStore(directory: fixture.directory.appendingPathComponent("Notes", isDirectory: true)),
            settingsStore: SettingsStore(fileURL: fixture.directory.appendingPathComponent("settings.json")),
            secrets: InMemorySecretStore(),
            recommendationLog: RecommendationLog(fileURL: fixture.directory.appendingPathComponent("recommendations.json"))
        )
        XCTAssertFalse(again.welcomeVisible, "the tour came back on the next launch")

        again.showWelcome()
        XCTAssertTrue(again.welcomeVisible, "Help ▸ Welcome Tour must still bring it back")
    }

    func testOpeningTheSampleNoteReadsItWithoutAProvider() {
        let fixture = AppFixture()
        app = fixture
        let state = fixture.state

        state.openSampleNote()

        XCTAssertFalse(state.welcomeVisible)
        XCTAssertTrue(state.settings.welcomeSeen)
        XCTAssertEqual(state.selectedNote?.content, SampleNote.english)
        XCTAssertTrue(state.editorRailVisible, "the sample opens with the editor's notes showing")
        XCTAssertNotNil(fixture.waitForEditor())

        pump(
            until: { !state.feedbackItems.isEmpty },
            timeout: 8,
            "the editor found nothing in the sample (phase: \(state.feedbackPhase))"
        )
        XCTAssertTrue(
            state.feedbackItems.allSatisfy { $0.source == .local },
            "no provider is configured here, so every note must be an offline check"
        )
        XCTAssertTrue(
            state.feedbackItems.contains { $0.section == SampleNote.readSection },
            "the read was aimed at \(SampleNote.readSection); notes: \(state.feedbackItems.map { $0.section ?? "-" })"
        )
    }
}
#endif
