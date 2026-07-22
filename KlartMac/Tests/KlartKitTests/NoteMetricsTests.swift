import XCTest
@testable import KlartKit

final class NoteMetricsTests: XCTestCase {
    func testCountsPlainWords() {
        XCTAssertEqual(NoteMetrics.wordCount("one two three"), 3)
        XCTAssertEqual(NoteMetrics.wordCount(""), 0)
        XCTAssertEqual(NoteMetrics.wordCount("   \n\n  "), 0)
    }

    func testMarkdownPunctuationIsNotAWord() {
        // Heading markers, bullets, emphasis stars, and dashes don't count;
        // the words they decorate do.
        XCTAssertEqual(NoteMetrics.wordCount("# Title"), 1)
        XCTAssertEqual(NoteMetrics.wordCount("- item one\n- item two"), 4)
        XCTAssertEqual(NoteMetrics.wordCount("a — b"), 2)
        XCTAssertEqual(NoteMetrics.wordCount("**bold** and *italic*"), 3)
    }

    func testCodeFencesAreSkipped() {
        let text = """
        before
        ```
        let x = someCode(with: arguments)
        ```
        after
        """
        XCTAssertEqual(NoteMetrics.wordCount(text), 2)
    }

    func testReadingMinutes() {
        XCTAssertEqual(NoteMetrics.readingMinutes(wordCount: 0), 0)
        XCTAssertEqual(NoteMetrics.readingMinutes(wordCount: 1), 1)
        XCTAssertEqual(NoteMetrics.readingMinutes(wordCount: 200), 1)
        XCTAssertEqual(NoteMetrics.readingMinutes(wordCount: 201), 2)
        XCTAssertEqual(NoteMetrics.readingMinutes(wordCount: 1000), 5)
    }

    func testSummary() {
        XCTAssertEqual(NoteMetrics.summary(for: ""), "0 words")
        XCTAssertEqual(NoteMetrics.summary(for: "hello"), "1 word · 1 min read")
        XCTAssertEqual(
            NoteMetrics.summary(for: Array(repeating: "word", count: 450).joined(separator: " ")),
            "450 words · 3 min read"
        )
    }
}
