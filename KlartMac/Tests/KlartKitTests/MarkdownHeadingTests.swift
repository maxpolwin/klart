import XCTest
@testable import KlartKit

final class MarkdownHeadingTests: XCTestCase {
    func testValidHeadingLevels() {
        XCTAssertEqual(MarkdownHeading.level(of: "# Title"), 1)
        XCTAssertEqual(MarkdownHeading.level(of: "## Title"), 2)
        XCTAssertEqual(MarkdownHeading.level(of: "###### Title"), 6)
    }

    func testTabAfterHashIsAValidHeading() {
        XCTAssertEqual(MarkdownHeading.level(of: "#\tTitle"), 1)
    }

    func testBareHashWithNoTitleIsStillALevelOneHeading() {
        XCTAssertEqual(MarkdownHeading.level(of: "#"), 1)
    }

    func testHashNotFollowedBySpaceIsNotAHeading() {
        XCTAssertNil(MarkdownHeading.level(of: "#hashtag"))
        XCTAssertNil(MarkdownHeading.level(of: "#idea quick note"))
        XCTAssertNil(MarkdownHeading.level(of: "#1 priority"))
    }

    func testTooManyHashesIsNotAHeading() {
        XCTAssertNil(MarkdownHeading.level(of: "####### too deep"))
    }

    func testPlainTextIsNotAHeading() {
        XCTAssertNil(MarkdownHeading.level(of: "Just a normal line"))
        XCTAssertNil(MarkdownHeading.level(of: "C# notes"))
    }
}
