import XCTest
@testable import KlartKit

final class FeedbackParserTests: XCTestCase {
    func testCleanJSON() {
        let raw = #"{"feedback":[{"type":"gap","anchor":"time zones","text":"Missing time zones.","why":"Remote teams are the case the section claims to cover.","severity":3}]}"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .gap)
        XCTAssertEqual(items[0].anchor, "time zones")
        XCTAssertEqual(items[0].text, "Missing time zones.")
        XCTAssertEqual(items[0].why, "Remote teams are the case the section claims to cover.")
        XCTAssertEqual(items[0].severity, .critical)
        XCTAssertEqual(items[0].source, .model)
    }

    func testFencedJSONWithProse() {
        let raw = """
        Sure! Here is my feedback:
        ```json
        {"feedback":[{"type":"mece","text":"Sync vs async overlaps hybrid."}]}
        ```
        Hope that helps!
        """
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .mece)
        XCTAssertNil(items[0].anchor)
        XCTAssertNil(items[0].why)
        XCTAssertEqual(items[0].severity, .major, "a note without a severity weakens the argument until told otherwise")
    }

    func testProseWrappedJSONWithBracesInStrings() {
        let raw = #"Analysis: {"feedback":[{"type":"structure","text":"Move {intro} first — see \"notes\"."}]} done."#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, #"Move {intro} first — see "notes"."#)
    }

    func testBareArrayRoot() {
        let raw = #"[{"type":"clarity","text":"Define 'productivity'."}]"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .clarity)
    }

    func testLooseTypeMapping() {
        let raw = #"{"feedback":[{"type":"Gaps in analysis","text":"a"},{"type":"Socratic Question","text":"b"},{"type":"weird","text":"c"},{"type":"source","text":"d"},{"type":"hidden assumption","text":"e"},{"type":"counter-argument","text":"f"},{"type":"missing warrant","text":"g"}]}"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.map(\.kind), [.gap, .question, .other, .evidence, .assumption, .counter, .warrant])
    }

    func testLooseSeverityValues() {
        let raw = #"{"feedback":[{"type":"gap","text":"a","severity":"1"},{"type":"gap","text":"b","severity":"critical"},{"type":"gap","text":"c","severity":9},{"type":"gap","text":"d","severity":"minor"}]}"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.map(\.severity), [.minor, .critical, .critical, .minor])
    }

    func testLegacySuggestionFieldIsIgnored() {
        // An older prompt (or a model that remembers one) still emits
        // replacement prose. It must never reach the UI.
        let raw = #"{"feedback":[{"type":"gap","text":"No churn.","suggestion":"Add: churn feeds back into revenue."}]}"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "No churn.")
        XCTAssertNil(items[0].why)
    }

    func testItemsWithoutTextDropped() {
        let raw = #"{"feedback":[{"type":"gap","text":"  "},{"type":"gap"},{"type":"gap","text":"real"}]}"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "real")
    }

    func testBlankAnchorAndWhyBecomeNil() {
        let raw = #"{"feedback":[{"type":"gap","anchor":"  ","text":"real","why":""}]}"#
        let items = FeedbackParser.parse(raw)
        XCTAssertNil(items[0].anchor)
        XCTAssertNil(items[0].why)
    }

    func testTruncatedJSONSalvagesCompleteItems() {
        let raw = #"{"feedback":[{"type":"gap","text":"Complete item."},{"type":"mece","text":"Cut off mid"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Complete item.")
    }

    func testGarbageReturnsEmpty() {
        XCTAssertTrue(FeedbackParser.parse("I could not analyze this.").isEmpty)
        XCTAssertTrue(FeedbackParser.parse("").isEmpty)
    }

    // MARK: - Identity

    func testFingerprintKeysOnTheAnchorWhenThereIsOne() {
        let a = FeedbackItem(kind: .gap, anchor: "Enterprise buyers", text: "No mention of churn.")
        let reworded = FeedbackItem(kind: .gap, anchor: "enterprise  buyers", text: "Churn is never addressed.")
        let otherWords = FeedbackItem(kind: .gap, anchor: "list price", text: "No mention of churn.")
        XCTAssertEqual(a.fingerprint, reworded.fingerprint, "rejecting a note means no note of this kind on these words")
        XCTAssertNotEqual(a.fingerprint, otherWords.fingerprint)
    }

    func testFingerprintFallsBackToTextWithoutAnAnchor() {
        let a = FeedbackItem(kind: .gap, text: "Missing  Time Zones")
        let b = FeedbackItem(kind: .gap, text: "missing time zones")
        let c = FeedbackItem(kind: .mece, text: "missing time zones")
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.fingerprint, c.fingerprint)
    }

    func testLocalNoteWithoutAnchorKeysOnItsRuleAndSection() {
        let a = FeedbackItem(kind: .clarity, text: "6 hedges in 140 words", source: .local, rule: "hedge-density", section: "Pricing")
        let b = FeedbackItem(kind: .clarity, text: "9 hedges in 200 words", source: .local, rule: "hedge-density", section: "Pricing")
        let c = FeedbackItem(kind: .clarity, text: "6 hedges in 140 words", source: .local, rule: "hedge-density", section: "Risks")
        XCTAssertEqual(a.fingerprint, b.fingerprint, "the counts change with every edit; the rule is the identity")
        XCTAssertNotEqual(a.fingerprint, c.fingerprint)
    }

    // MARK: - Compatibility

    func testOlderKindNamesStillDecode() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode([FeedbackKind].self, from: Data(#"["source","gap","nonsense"]"#.utf8)), [.evidence, .gap, .other])
    }
}
