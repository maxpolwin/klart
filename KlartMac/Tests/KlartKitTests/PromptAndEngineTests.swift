import XCTest
@testable import KlartKit

final class PromptBuilderTests: XCTestCase {
    let doc = """
    # Topic

    ## Section A
    Content of section A that is long enough to matter for the analysis of things.

    ## Secret [no-ai]
    hidden words that must never leave

    ## Section B
    B content.
    """

    func testContextFromCursorInSection() {
        let offset = (doc as NSString).range(of: "Content of section A").location
        let context = PromptContext.from(text: doc, cursorUTF16: offset)
        XCTAssertEqual(context?.topic, "Topic")
        XCTAssertEqual(context?.currentSectionTitle, "Section A")
        XCTAssertTrue(context?.currentSectionBody.contains("long enough") ?? false)
    }

    func testContextCarriesTheWholeDocumentWithExcludedBodiesRemoved() {
        let offset = (doc as NSString).range(of: "Content of section A").location
        let context = try! XCTUnwrap(PromptContext.from(text: doc, cursorUTF16: offset))
        XCTAssertTrue(context.documentText.contains("B content."), "the section is read against the whole document")
        XCTAssertTrue(context.documentText.contains("## Secret"), "the shape of the document stays visible")
        XCTAssertFalse(context.documentText.contains("hidden words"), "a [no-ai] body must never leave the machine")
        XCTAssertTrue(context.documentText.contains("(omitted)"))
    }

    func testRedactionHandlesNestedExcludedSections() {
        let nested = """
        # T

        ## Open
        open text

        ## Closed [no-ai]
        closed text

        ### Inner
        inner text

        ## After
        after text
        """
        let offset = (nested as NSString).range(of: "open text").location
        let context = try! XCTUnwrap(PromptContext.from(text: nested, cursorUTF16: offset))
        XCTAssertFalse(context.documentText.contains("closed text"))
        XCTAssertFalse(context.documentText.contains("inner text"), "a subsection of an excluded section is excluded with it")
        XCTAssertTrue(context.documentText.contains("after text"))
        XCTAssertTrue(context.documentText.contains("open text"))
    }

    func testExcludedSectionYieldsNilContext() {
        let offset = (doc as NSString).range(of: "hidden").location
        XCTAssertNil(PromptContext.from(text: doc, cursorUTF16: offset))
    }

    func testFeedbackMessagesContainContextAndRules() {
        let context = PromptContext(
            topic: "Topic",
            currentSectionTitle: "Section A",
            currentSectionBody: "Body text",
            documentText: "# Topic\n\n## Section A\nBody text\n\n## Section B\nOther body"
        )
        let flagged = FeedbackItem(kind: .evidence, text: "“40%” is stated as fact with nothing behind it.", source: .local, rule: "uncited-claim")
        let messages = PromptBuilder.feedbackMessages(
            context: context,
            kinds: [.gap, .question],
            style: TipStyle(tone: .direct, detail: .brief, maxTips: 2, language: "German"),
            alreadyFlagged: [flagged]
        )
        XCTAssertEqual(messages.count, 2)
        let system = messages[0].content
        let user = messages[1].content
        XCTAssertTrue(system.contains("at most 2"))
        XCTAssertTrue(system.contains("gap —"))
        XCTAssertTrue(system.contains("question —"))
        XCTAssertFalse(system.contains("mece —"))
        XCTAssertTrue(system.contains("German"))
        XCTAssertTrue(user.contains("Topic"))
        XCTAssertTrue(user.contains("Section A"))
        XCTAssertTrue(user.contains("Other body"), "the whole document travels, not just the other titles")
        XCTAssertTrue(user.contains("Body text"))
        XCTAssertTrue(user.contains("do not repeat"))
        XCTAssertTrue(user.contains("stated as fact"))
    }

    func testDefaultPromptNeverAsksForReplacementProse() {
        let system = PromptBuilder.defaultFeedbackTemplate
        XCTAssertFalse(system.lowercased().contains("ready-to-insert"))
        XCTAssertFalse(system.lowercased().contains("suggestion"))
        XCTAssertTrue(system.contains("Do not draft replacement prose"))
        XCTAssertTrue(system.contains("No praise"))
        for detail in FeedbackDetail.allCases {
            XCTAssertFalse(detail.promptFragment.lowercased().contains("insert"), "\(detail) must not reopen the ghostwriting door")
        }
    }

    func testDefaultTemplatePreservesJSONShapeAndCoachAction() {
        let feedback = PromptBuilder.feedbackMessages(
            context: PromptContext(currentSectionBody: "Body"),
            kinds: [.gap],
            style: TipStyle()
        )
        XCTAssertTrue(feedback[0].content.contains(PromptBuilder.feedbackJSONShape))
        XCTAssertTrue(PromptBuilder.feedbackJSONShape.contains("\"anchor\""))
        XCTAssertTrue(PromptBuilder.feedbackJSONShape.contains("\"why\""))
        XCTAssertTrue(PromptBuilder.feedbackJSONShape.contains("\"severity\""))

        let coach = PromptBuilder.coachMessages(action: .challenge, documentText: "notes")
        XCTAssertTrue(coach[0].content.contains(CoachAction.challenge.instruction))
    }

    func testCustomTemplateSubstitutesTokensAndReplacesPersona() {
        let template = "Custom persona.\nTypes:\n{{FEEDBACK_TYPES}}\nCap {{MAX_TIPS}}.\nShape: {{JSON_SHAPE}}"
        let messages = PromptBuilder.feedbackMessages(
            context: PromptContext(currentSectionBody: "Body"),
            kinds: [.gap],
            style: TipStyle(maxTips: 4),
            template: template
        )
        let system = messages[0].content
        XCTAssertTrue(system.hasPrefix("Custom persona."))
        XCTAssertFalse(system.contains("author's editor"))
        XCTAssertTrue(system.contains("gap —"))
        XCTAssertTrue(system.contains("Cap 4."))
        XCTAssertTrue(system.contains(PromptBuilder.feedbackJSONShape))
        XCTAssertFalse(system.contains("{{"))
    }

    func testCustomCoachTemplateSubstitutesAction() {
        let messages = PromptBuilder.coachMessages(
            action: .summarize,
            documentText: "notes",
            template: "Do this: {{ACTION_INSTRUCTION}}"
        )
        XCTAssertEqual(messages[0].content, "Do this: \(CoachAction.summarize.instruction)")
    }

    func testMissingRequiredPlaceholderDetected() {
        XCTAssertTrue(
            PromptBuilder.missingRequiredPlaceholders(
                in: PromptBuilder.defaultFeedbackTemplate,
                placeholders: PromptBuilder.feedbackPlaceholders
            ).isEmpty
        )
        XCTAssertEqual(
            PromptBuilder.missingRequiredPlaceholders(
                in: "no shape token here",
                placeholders: PromptBuilder.feedbackPlaceholders
            ),
            ["{{JSON_SHAPE}}"]
        )
    }

    func testClipKeepsHeadAndTail() {
        let long = String(repeating: "a", count: 5000) + "MIDDLE" + String(repeating: "z", count: 5000)
        let clipped = PromptBuilder.clip(long, to: 1000)
        XCTAssertLessThan(clipped.count, 1100)
        XCTAssertTrue(clipped.hasPrefix("aaa"))
        XCTAssertTrue(clipped.hasSuffix("zzz"))
        XCTAssertTrue(clipped.contains("[…]"))
    }
}

/// LLM stub for engine tests.
struct StubClient: LLMClient {
    let providerName = "Stub"
    let response: String

    func listModels() async throws -> [String] { ["stub-model"] }

    func complete(_ messages: [ChatMessage], model: String, options: CompletionOptions) async throws -> String {
        response
    }

    func stream(_ messages: [ChatMessage], model: String, options: CompletionOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }
}

final class FeedbackEngineTests: XCTestCase {
    let doc = """
    # Topic

    ## Section A
    This section has plenty of content, certainly more than the eighty character minimum required for analysis to run.
    """

    func cursorInSectionA() -> Int {
        (doc as NSString).range(of: "plenty").location
    }

    func testSkipsShortContent() async throws {
        let engine = FeedbackEngine()
        let outcome = try await engine.analyze(
            text: "# T\n\n## S\nshort",
            cursorUTF16: 10,
            settings: AppSettings(),
            rejectedFingerprints: [],
            client: StubClient(response: "")
        )
        guard case .skipped(.tooShort) = outcome else {
            return XCTFail("Expected .skipped(.tooShort), got \(outcome)")
        }
    }

    func testParsesAndCapsItems() async throws {
        let response = #"{"feedback":[{"type":"gap","text":"one"},{"type":"gap","text":"two"},{"type":"gap","text":"three"},{"type":"gap","text":"four"}]}"#
        var settings = AppSettings()
        settings.tipStyle.maxTips = 2
        let outcome = try await FeedbackEngine().analyze(
            text: doc,
            cursorUTF16: cursorInSectionA(),
            settings: settings,
            rejectedFingerprints: [],
            client: StubClient(response: response)
        )
        guard case .items(let items) = outcome else {
            return XCTFail("Expected items")
        }
        XCTAssertEqual(items.map(\.text), ["one", "two"])
        XCTAssertEqual(items.map(\.section), ["Section A", "Section A"], "every note is stamped with the section it was read from")
    }

    func testFiltersRejectedFingerprints() async throws {
        let response = #"{"feedback":[{"type":"gap","text":"seen before"},{"type":"gap","text":"new"}]}"#
        let rejected = FeedbackItem(kind: .gap, text: "seen before").fingerprint
        let outcome = try await FeedbackEngine().analyze(
            text: doc,
            cursorUTF16: cursorInSectionA(),
            settings: AppSettings(),
            rejectedFingerprints: [rejected],
            client: StubClient(response: response)
        )
        guard case .items(let items) = outcome else {
            return XCTFail("Expected items")
        }
        XCTAssertEqual(items.map(\.text), ["new"])
    }

    func testAFabricatedAnchorIsDroppedAndARealOneKept() async throws {
        let response = #"{"feedback":[{"type":"clarity","anchor":"Plenty of  content","text":"kept"},{"type":"clarity","anchor":"words not in the text","text":"dropped anchor"}]}"#
        let outcome = try await FeedbackEngine().analyze(
            text: doc,
            cursorUTF16: cursorInSectionA(),
            settings: AppSettings(),
            rejectedFingerprints: [],
            client: StubClient(response: response)
        )
        guard case .items(let items) = outcome else {
            return XCTFail("Expected items")
        }
        XCTAssertEqual(items[0].anchor, "Plenty of  content", "case and spacing differences are the model copying, not inventing")
        XCTAssertNil(items[1].anchor, "the writer must never hunt for words the model made up")
        XCTAssertEqual(items[1].text, "dropped anchor", "the observation itself still stands")
    }

    func testLocalNotesAreMergedAheadAndTheRoundIsOrderedBySeverity() async throws {
        let response = #"{"feedback":[{"type":"gap","text":"minor model","severity":1},{"type":"gap","text":"critical model","severity":3}]}"#
        let local = [FeedbackItem(kind: .evidence, text: "local major", severity: .major, source: .local, rule: "uncited-claim")]
        let outcome = try await FeedbackEngine().analyze(
            text: doc,
            cursorUTF16: cursorInSectionA(),
            settings: AppSettings(),
            rejectedFingerprints: [],
            local: local,
            client: StubClient(response: response)
        )
        guard case .items(let items) = outcome else {
            return XCTFail("Expected items")
        }
        XCTAssertEqual(items.map(\.text), ["critical model", "local major", "minor model"])
        XCTAssertEqual(items[1].id, local[0].id, "the local note keeps its identity through the merge")
    }

    func testLocalItemsRespectRejections() {
        let text = """
        # T

        ## Claims
        Studies show that 40% of teams ship late, which is why this matters a great deal to everyone here.
        """
        let cursor = (text as NSString).range(of: "Studies").location
        let first = FeedbackEngine().localItems(text: text, cursorUTF16: cursor, rejectedFingerprints: [])
        XCTAssertEqual(first.map(\.rule), ["uncited-claim"])
        let again = FeedbackEngine().localItems(text: text, cursorUTF16: cursor, rejectedFingerprints: [first[0].fingerprint])
        XCTAssertTrue(again.isEmpty, "a rejected local note stays rejected")
    }
}

final class NoteEditingTests: XCTestCase {
    func testResponseLandsAtTheEndOfTheNamedSectionWithTheCaretBeneathIt() {
        let doc = "# T\n\n## A\nbody A\n\n## B\nbody B\n"
        let cursorInB = (doc as NSString).range(of: "body B").location
        let item = FeedbackItem(kind: .gap, anchor: "body A", text: "No churn.", why: "Revenue depends on it.", section: "A")
        let response = NoteEditing.respond(to: item, in: doc, cursorUTF16: cursorInB)
        let result = response.text
        let block = (result as NSString).range(of: "> ✎ Gap — “body A”: No churn.\n> Revenue depends on it.").location
        let sectionB = (result as NSString).range(of: "## B").location
        XCTAssertNotEqual(block, NSNotFound)
        XCTAssertLessThan(block, sectionB, "the block goes to the section the note names, not the cursor's")
        XCTAssertTrue(result.contains("body A"))
        XCTAssertTrue(result.contains("body B"))
        // The caret sits on an empty line under the block, with a blank line
        // still separating it from the next heading.
        let ns = result as NSString
        let caret = response.caretUTF16
        XCTAssertEqual(ns.substring(with: NSRange(location: caret - 1, length: 1)), "\n")
        XCTAssertEqual(ns.substring(with: NSRange(location: caret, length: 1)), "\n")
        XCTAssertTrue(ns.substring(from: caret).hasPrefix("\n## B"))
    }

    func testResponseFallsBackToTheCursorSection() {
        let doc = "# T\n\n## A\nbody A\n\n## B\nbody B\n"
        let cursor = (doc as NSString).range(of: "body A").location
        let item = FeedbackItem(kind: .gap, text: "obs", section: "Nowhere")
        let result = NoteEditing.respond(to: item, in: doc, cursorUTF16: cursor).text
        XCTAssertLessThan((result as NSString).range(of: "> ✎ Gap: obs").location, (result as NSString).range(of: "## B").location)
    }

    func testResponseWithoutSectionsAppendsAndLeavesTheCaretAtTheEnd() {
        let doc = "just plain text"
        let item = FeedbackItem(kind: .question, text: "What about X?")
        let response = NoteEditing.respond(to: item, in: doc, cursorUTF16: 3)
        XCTAssertEqual(response.text, "just plain text\n\n> ✎ Question: What about X?\n")
        XCTAssertEqual(response.caretUTF16, response.text.utf16.count)
    }

    func testResponseNeverCarriesModelProse() {
        // The block is a prompt, never an answer: the writer's own words go
        // under it. Multi-line observations are flattened so the quote stays
        // one block.
        let doc = "# T\n\n## A\nsome body content here\n"
        let cursor = (doc as NSString).range(of: "some body").location
        let item = FeedbackItem(kind: .structure, text: "line1\nline2")
        let result = NoteEditing.respond(to: item, in: doc, cursorUTF16: cursor).text
        XCTAssertTrue(result.contains("> ✎ Structure: line1 line2\n"))
    }
}
