import XCTest
@testable import KlartKit

final class FeedbackParserTests: XCTestCase {
    func testCleanJSON() {
        let raw = #"{"feedback":[{"type":"gap","text":"Missing time zones.","suggestion":"Add a paragraph on time zones."}]}"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .gap)
        XCTAssertEqual(items[0].text, "Missing time zones.")
        XCTAssertEqual(items[0].suggestion, "Add a paragraph on time zones.")
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
        XCTAssertNil(items[0].suggestion)
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
        let raw = #"{"feedback":[{"type":"Gaps in analysis","text":"a"},{"type":"Socratic Question","text":"b"},{"type":"weird","text":"c"}]}"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.map(\.kind), [.gap, .question, .other])
    }

    func testItemsWithoutTextDropped() {
        let raw = #"{"feedback":[{"type":"gap","text":"  "},{"type":"gap"},{"type":"gap","text":"real"}]}"#
        let items = FeedbackParser.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "real")
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

    func testFingerprintStableAcrossWhitespaceAndCase() {
        let a = FeedbackItem(kind: .gap, text: "Missing  Time Zones")
        let b = FeedbackItem(kind: .gap, text: "missing time zones")
        let c = FeedbackItem(kind: .mece, text: "missing time zones")
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.fingerprint, c.fingerprint)
    }
}
