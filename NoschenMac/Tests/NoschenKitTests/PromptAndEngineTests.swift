import XCTest
@testable import NoschenKit

final class PromptBuilderTests: XCTestCase {
    let doc = """
    # Topic

    ## Section A
    Content of section A that is long enough to matter for the analysis of things.

    ## Secret [no-ai]
    hidden

    ## Section B
    B content.
    """

    func testContextFromCursorInSection() {
        let offset = (doc as NSString).range(of: "Content of section A").location
        let context = PromptContext.from(text: doc, cursorUTF16: offset)
        XCTAssertEqual(context?.topic, "Topic")
        XCTAssertEqual(context?.currentSectionTitle, "Section A")
        XCTAssertEqual(context?.otherSectionTitles, ["Secret", "Section B"])
        XCTAssertTrue(context?.currentSectionBody.contains("long enough") ?? false)
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
            otherSectionTitles: ["Section B"]
        )
        let messages = PromptBuilder.feedbackMessages(
            context: context,
            kinds: [.gap, .question],
            style: TipStyle(tone: .direct, detail: .brief, maxTips: 2, language: "German")
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
        XCTAssertTrue(user.contains("Section B"))
        XCTAssertTrue(user.contains("Body text"))
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
}

final class NoteEditingTests: XCTestCase {
    func testInsertAtSectionEnd() {
        let doc = "# T\n\n## A\nbody A\n\n## B\nbody B\n"
        let cursor = (doc as NSString).range(of: "body A").location
        let item = FeedbackItem(kind: .gap, text: "obs", suggestion: "Insert me")
        let result = NoteEditing.insertSuggestion(item, into: doc, cursorUTF16: cursor)
        let insertedAt = (result as NSString).range(of: "> ✎ Gap: Insert me").location
        let sectionB = (result as NSString).range(of: "## B").location
        XCTAssertNotEqual(insertedAt, NSNotFound)
        XCTAssertLessThan(insertedAt, sectionB)
        XCTAssertTrue(result.contains("body A"))
        XCTAssertTrue(result.contains("body B"))
    }

    func testInsertWithoutSectionsAppends() {
        let doc = "just plain text"
        let item = FeedbackItem(kind: .question, text: "What about X?")
        let result = NoteEditing.insertSuggestion(item, into: doc, cursorUTF16: 3)
        XCTAssertTrue(result.hasPrefix("just plain text"))
        XCTAssertTrue(result.contains("> ✎ Question: What about X?"))
    }

    func testMultilineSuggestionQuotedOnEveryLine() {
        let doc = "# T\n\n## A\nsome body content here\n"
        let cursor = (doc as NSString).range(of: "some body").location
        let item = FeedbackItem(kind: .structure, text: "obs", suggestion: "line1\nline2")
        let result = NoteEditing.insertSuggestion(item, into: doc, cursorUTF16: cursor)
        XCTAssertTrue(result.contains("> ✎ Structure: line1\n> line2"))
    }
}
