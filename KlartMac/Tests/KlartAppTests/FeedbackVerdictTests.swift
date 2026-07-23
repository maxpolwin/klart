#if os(macOS)
import XCTest
import KlartKit
@testable import Klart

/// Judging an editor note teaches the coach without disturbing the writing.
/// These run against a real `AppState` with a temp-directory learning log,
/// because the two claims worth guarding — "the note stays put" and "the note
/// text only travels when you said it could" — are properties of the wiring,
/// not of any one type.
@MainActor
final class FeedbackVerdictTests: XCTestCase {
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

    private static let body = """
    # Pricing strategy

    ## Who actually pays?

    Enterprise buyers care about seat count, but the current draft only argues \
    about list price and never mentions how churn feeds back into revenue.
    """

    private func seeded(_ fixture: AppFixture, items: [FeedbackItem]) {
        fixture.state.createNote()
        fixture.state.editorText = Self.body
        fixture.state.cursorUTF16 = Self.body.utf16.count - 5
        fixture.state.feedbackItems = items
    }

    private func tip(
        _ kind: FeedbackKind = .gap,
        text: String = "No mention of churn.",
        suggestion: String? = "Add a churn assumption."
    ) -> FeedbackItem {
        FeedbackItem(kind: kind, text: text, suggestion: suggestion, section: "Who actually pays?")
    }

    /// Waits for the fire-and-forget append to land.
    private func records(_ fixture: AppFixture, expecting count: Int) async -> [RecommendationRecord] {
        let log = fixture.state.recommendationLog
        for _ in 0..<200 {
            let loaded = await log.loadAll()
            if loaded.count >= count { return loaded }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await log.loadAll()
    }

    // MARK: - The note stays put

    func testConfirmingLeavesTheNoteOnScreenAndMarksIt() {
        let fixture = makeApp()
        let item = tip()
        seeded(fixture, items: [item])

        fixture.state.confirm(item)

        XCTAssertEqual(
            fixture.state.feedbackItems.count, 1,
            "a judged note must stay in the rail — greying out is the whole point"
        )
        XCTAssertEqual(fixture.state.outcome(for: item), .confirmed)
    }

    func testRejectingLeavesTheNoteOnScreenAndRemembersItForTheFile() {
        let fixture = makeApp()
        let item = tip(.mece)
        seeded(fixture, items: [item])

        fixture.state.reject(item)

        XCTAssertEqual(fixture.state.feedbackItems.count, 1)
        XCTAssertEqual(fixture.state.outcome(for: item), .rejected)
        XCTAssertEqual(
            fixture.state.selectedNote?.rejectedFingerprints, [item.fingerprint],
            "a rejected note must not come back for this file"
        )
    }

    func testInsertingWritesTheNoteAndStillLeavesTheCardBehind() {
        let fixture = makeApp()
        let item = tip()
        seeded(fixture, items: [item])

        fixture.state.accept(item)

        XCTAssertTrue(fixture.state.editorText.contains("> ✎"), "the suggestion should land in the note")
        XCTAssertEqual(fixture.state.feedbackItems.count, 1)
        XCTAssertEqual(fixture.state.outcome(for: item), .inserted)
    }

    func testASecondVerdictCannotOverwriteTheFirst() async {
        let fixture = makeApp()
        let item = tip()
        seeded(fixture, items: [item])

        fixture.state.confirm(item)
        fixture.state.reject(item)
        fixture.state.accept(item)

        XCTAssertEqual(fixture.state.outcome(for: item), .confirmed)
        XCTAssertFalse(
            fixture.state.editorText.contains("> ✎"),
            "an already-judged note must not still be insertable"
        )
        let logged = await records(fixture, expecting: 2)
        XCTAssertEqual(logged.count, 1, "one judgement, one record")
    }

    func testANewRoundOfNotesDropsTheOldVerdicts() {
        let fixture = makeApp()
        let item = tip()
        seeded(fixture, items: [item])
        fixture.state.confirm(item)

        fixture.state.feedbackItems = [tip(.clarity, text: "Sharpen the claim.")]

        XCTAssertTrue(
            fixture.state.itemOutcomes.isEmpty,
            "verdicts belong to the notes on screen"
        )
    }

    /// Renders the real rail, so the verdict controls are actually built and
    /// laid out rather than merely compiled.
    func testTheRailKeepsRenderingAJudgedCard() {
        let fixture = makeApp()
        let item = tip()
        seeded(fixture, items: [item])
        fixture.state.editorRailVisible = true
        pump(until: { fixture.window.contentView?.needsLayout == false }, timeout: 2, failOnTimeout: false)

        fixture.state.confirm(item)
        fixture.window.layoutIfNeeded()
        pump(until: { fixture.state.outcome(for: item) == .confirmed }, timeout: 2)

        XCTAssertEqual(fixture.state.feedbackItems.count, 1)
        XCTAssertTrue(fixture.state.editorRailVisible, "judging must not retire the rail")
    }

    // MARK: - What gets recorded

    func testTheSignalIsRecordedWithoutNoteTextByDefault() async {
        let fixture = makeApp()
        let item = tip()
        seeded(fixture, items: [item])
        XCTAssertFalse(fixture.state.settings.logRecommendationContent)

        fixture.state.reject(item)

        let logged = await records(fixture, expecting: 1)
        XCTAssertEqual(logged.count, 1)
        let record = logged[0]
        XCTAssertEqual(record.outcome, .rejected)
        XCTAssertEqual(record.kind, .gap)
        XCTAssertEqual(record.fingerprint, item.fingerprint)
        XCTAssertFalse(record.systemPromptHash.isEmpty)
        XCTAssertTrue(record.usesDefaultPrompt)
        XCTAssertFalse(record.carriesContent, "note text is opt-in")
        XCTAssertNil(record.noteTitle)
        XCTAssertNil(record.contextParagraph)
    }

    func testOptingInRecordsTheParagraphTheAdviceReactedTo() async {
        let fixture = makeApp()
        fixture.state.settings.logRecommendationContent = true
        let item = tip()
        seeded(fixture, items: [item])

        fixture.state.confirm(item)

        let logged = await records(fixture, expecting: 1)
        XCTAssertEqual(logged.count, 1)
        let record = logged[0]
        XCTAssertEqual(record.noteTitle, "Pricing strategy")
        XCTAssertEqual(record.sectionTitle, "Who actually pays?")
        XCTAssertEqual(record.observation, "No mention of churn.")
        XCTAssertEqual(
            record.contextParagraph?.contains("Enterprise buyers care about seat count"), true,
            "the log should carry the text the advice was reacting to"
        )
    }

    func testASensitiveNoteNeverContributesItsText() async {
        let fixture = makeApp()
        fixture.state.settings.logRecommendationContent = true
        let item = tip()
        seeded(fixture, items: [item])
        fixture.state.toggleSensitive()
        XCTAssertEqual(fixture.state.selectedNote?.isSensitive, true)

        fixture.state.reject(item)

        let logged = await records(fixture, expecting: 1)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].fromSensitiveNote)
        XCTAssertFalse(
            logged[0].carriesContent,
            "opting in to content must not override a note marked sensitive"
        )
        XCTAssertEqual(logged[0].outcome, .rejected, "the signal itself is still recorded")
    }

    func testAnEditedSystemPromptIsDistinguishableInTheLog() async {
        let fixture = makeApp()
        fixture.state.settings.feedbackSystemPrompt =
            PromptBuilder.defaultFeedbackTemplate + "\nBe terse. {{JSON_SHAPE}}"
        let item = tip()
        seeded(fixture, items: [item])

        fixture.state.confirm(item)

        let logged = await records(fixture, expecting: 1)
        XCTAssertEqual(logged.count, 1)
        XCTAssertFalse(logged[0].usesDefaultPrompt)
        XCTAssertNotEqual(
            logged[0].systemPromptHash,
            StableHash.fnv1a(PromptBuilder.defaultFeedbackTemplate),
            "verdicts must be attributable to the prompt that produced them"
        )
    }

    func testDeletingANoteLogsNothingAboutIt() async {
        let fixture = makeApp()
        fixture.state.settings.logRecommendationContent = true
        seeded(fixture, items: [tip(), tip(.clarity, text: "Sharpen the claim.")])
        let doomed = try? XCTUnwrap(fixture.state.selectedNoteID)

        fixture.state.deleteNote(id: doomed!)

        // Give any stray append time to land before asserting it didn't.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let logged = await fixture.state.recommendationLog.loadAll()
        XCTAssertTrue(
            logged.isEmpty,
            "a deleted note's tips must not be attributed to whatever is selected next"
        )
    }

    func testLeavingANoteLogsWhatWasNeverJudged() async {
        let fixture = makeApp()
        let judged = tip()
        let ignored = tip(.clarity, text: "Sharpen the claim.")
        seeded(fixture, items: [judged, ignored])
        fixture.state.confirm(judged)

        fixture.state.createNote()   // switches selection away

        let logged = await records(fixture, expecting: 2)
        XCTAssertEqual(logged.count, 2)
        XCTAssertEqual(logged.filter { $0.outcome == .confirmed }.count, 1)
        XCTAssertEqual(
            logged.filter { $0.outcome == .dismissed }.count, 1,
            "walking away from a note is itself a (weak) signal"
        )
    }
}
#endif
