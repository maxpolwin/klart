#if os(macOS)
import XCTest
import KlartKit
@testable import Klart

/// Judging an editor note teaches the coach without disturbing the writing.
/// These run against a real `AppState` with a temp-directory learning log,
/// because the claims worth guarding — "the note stays put", "the note text
/// only travels when you said it could", "the editor reads when a section is
/// finished" — are properties of the wiring, not of any one type.
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
        anchor: String? = "Enterprise buyers"
    ) -> FeedbackItem {
        FeedbackItem(kind: kind, anchor: anchor, text: text, why: "Revenue depends on it.", section: "Who actually pays?")
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

    func testRespondingWritesAPromptBlockAndStillLeavesTheCardBehind() {
        let fixture = makeApp()
        let item = tip()
        seeded(fixture, items: [item])

        fixture.state.respond(to: item)

        XCTAssertTrue(
            fixture.state.editorText.contains("> ✎ Gap — “Enterprise buyers”: No mention of churn.\n> Revenue depends on it."),
            "the note lands as a prompt in the writer's own words to come"
        )
        XCTAssertEqual(fixture.state.feedbackItems.count, 1)
        XCTAssertEqual(fixture.state.outcome(for: item), .responded)
        XCTAssertNotNil(fixture.state.pendingCaretUTF16, "the caret is sent to the empty line under the block")
    }

    func testTheEditorPutsTheCaretUnderTheResponseBlock() {
        let fixture = makeApp()
        let item = tip()
        seeded(fixture, items: [item])
        fixture.state.editorRailVisible = true
        pump(until: { fixture.window.contentView?.needsLayout == false }, timeout: 2, failOnTimeout: false)

        fixture.state.respond(to: item)
        let wanted = try? XCTUnwrap(fixture.state.pendingCaretUTF16)
        pump(until: { fixture.state.pendingCaretUTF16 == nil }, timeout: 4, "the editor never consumed the caret request")

        let textView = fixture.window.contentView.flatMap { firstDescendant($0, of: KlartTextView.self) }
        XCTAssertEqual(textView?.selectedRange().location, wanted)
    }

    func testASecondVerdictCannotOverwriteTheFirst() async {
        let fixture = makeApp()
        let item = tip()
        seeded(fixture, items: [item])

        fixture.state.confirm(item)
        fixture.state.reject(item)
        fixture.state.respond(to: item)

        XCTAssertEqual(fixture.state.outcome(for: item), .confirmed)
        XCTAssertFalse(
            fixture.state.editorText.contains("> ✎"),
            "an already-judged note must not still be respondable"
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

    // MARK: - When the editor reads

    /// Points the app at a provider with no model, so a read runs the offline
    /// checks and then stops at "no model selected" instead of reaching for
    /// a network — the trigger is what is under test, not the model.
    private func withoutAModel(_ fixture: AppFixture) {
        fixture.state.settings.activeProvider = .custom
        fixture.state.settings.setConfig(ProviderConfig(baseURL: "http://localhost:1/v1", model: ""), for: .custom)
        fixture.state.settings.autoFeedback = true
    }

    private static let twoSections = """
    # Pricing strategy

    ## Market

    Studies show that 40% of enterprise buyers churn inside a year, which is the whole reason the seat-count argument fails.

    ## Who actually pays?

    Enterprise buyers care about seat count, but the current draft only argues \
    about list price and never mentions how churn feeds back into revenue, \
    which is the question the whole document set out to answer.
    """

    func testLeavingAnEditedSectionReadsItAndTheOfflineChecksLandWithoutAModel() {
        let fixture = makeApp()
        withoutAModel(fixture)
        fixture.state.createNote()
        fixture.state.editorText = Self.twoSections
        let inMarket = (Self.twoSections as NSString).range(of: "Studies").location
        let inPays = (Self.twoSections as NSString).range(of: "Enterprise buyers care").location

        fixture.state.cursorMoved(to: inMarket)
        fixture.state.editorTextChanged()        // typed in Market
        XCTAssertEqual(fixture.state.feedbackPhase, .waiting)
        fixture.state.cursorMoved(to: inMarket + 3)
        XCTAssertTrue(fixture.state.feedbackItems.isEmpty, "moving within the section is not finishing it")

        fixture.state.cursorMoved(to: inPays)       // left Market
        pump(until: { !fixture.state.feedbackItems.isEmpty }, timeout: 4, "leaving an edited section must start a read")

        XCTAssertEqual(fixture.state.feedbackItems.map(\.rule), ["uncited-claim"])
        XCTAssertEqual(fixture.state.feedbackItems[0].section, "Market")
        pump(until: { if case .error = fixture.state.feedbackPhase { return true }; return false }, timeout: 4)
        XCTAssertEqual(fixture.state.feedbackItems.count, 1, "the model failing must not take the offline notes down")
    }

    func testMovingAroundWithoutTypingReadsNothing() {
        let fixture = makeApp()
        withoutAModel(fixture)
        fixture.state.createNote()
        fixture.state.editorText = Self.twoSections
        let inMarket = (Self.twoSections as NSString).range(of: "Studies").location
        let inPays = (Self.twoSections as NSString).range(of: "Enterprise buyers care").location

        fixture.state.cursorMoved(to: inMarket)
        fixture.state.cursorMoved(to: inPays)
        fixture.state.cursorMoved(to: inMarket)
        pumpFor(0.3)

        XCTAssertTrue(fixture.state.feedbackItems.isEmpty)
        XCTAssertEqual(fixture.state.feedbackPhase, .idle)
    }

    func testAFreshRoundReplacesOnlyThatSectionsNotes() {
        let fixture = makeApp()
        withoutAModel(fixture)
        fixture.state.createNote()
        fixture.state.editorText = Self.twoSections
        let inMarket = (Self.twoSections as NSString).range(of: "Studies").location
        let inPays = (Self.twoSections as NSString).range(of: "Enterprise buyers care").location
        // A note about the other section, from an earlier read.
        let earlier = FeedbackItem(kind: .gap, text: "Says nothing about procurement.", section: "Who actually pays?")
        fixture.state.feedbackItems = [earlier]

        fixture.state.cursorMoved(to: inMarket)
        fixture.state.editorTextChanged()
        fixture.state.cursorMoved(to: inPays)
        pump(until: { fixture.state.feedbackItems.count == 2 }, timeout: 4, "the earlier note must survive a read of a different section")

        XCTAssertTrue(fixture.state.feedbackItems.contains { $0.id == earlier.id })
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
        XCTAssertEqual(record.severity, .major)
        XCTAssertEqual(record.source, .model)
        XCTAssertFalse(record.systemPromptHash.isEmpty)
        XCTAssertTrue(record.usesDefaultPrompt)
        XCTAssertFalse(record.carriesContent, "note text is opt-in")
        XCTAssertNil(record.noteTitle)
        XCTAssertNil(record.contextParagraph)
        XCTAssertNil(record.anchor, "the anchor is note text")
    }

    func testALocalNoteIsAttributedToItsRuleNotTheModel() async {
        let fixture = makeApp()
        let item = FeedbackItem(kind: .evidence, anchor: "Studies show", text: "…", source: .local, rule: "uncited-claim", section: "Who actually pays?")
        seeded(fixture, items: [item])

        fixture.state.confirm(item)

        let logged = await records(fixture, expecting: 1)
        XCTAssertEqual(logged[0].source, .local)
        XCTAssertEqual(logged[0].rule, "uncited-claim")
        XCTAssertEqual(logged[0].provider, "Local checks")
        XCTAssertNil(logged[0].model)
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
        XCTAssertEqual(record.anchor, "Enterprise buyers")
        XCTAssertEqual(record.observation, "No mention of churn.")
        XCTAssertEqual(record.why, "Revenue depends on it.")
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
