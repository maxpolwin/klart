import XCTest
@testable import KlartKit

final class OutlineTests: XCTestCase {
    let doc = """
    # Remote Work and Productivity

    Intro paragraph.

    ## Communication Patterns
    Async communication has become the norm.

    ## Personal Notes [no-ai]
    Don't analyze this.

    ## Measurement
    ### Metrics
    Output per hour.
    """

    func testTopicAndSections() {
        let outline = DocumentOutline.parse(doc)
        XCTAssertEqual(outline.topic, "Remote Work and Productivity")
        XCTAssertEqual(outline.sections.map(\.title), [
            "Remote Work and Productivity",
            "Communication Patterns",
            "Personal Notes",
            "Measurement",
            "Metrics",
        ])
        XCTAssertEqual(outline.sections.map(\.level), [1, 2, 2, 2, 3])
    }

    func testNoAIFlag() {
        let outline = DocumentOutline.parse(doc)
        let flags = outline.sections.map(\.excludedFromAI)
        XCTAssertEqual(flags, [false, false, true, false, false])
    }

    func testSectionAtCursor() {
        let outline = DocumentOutline.parse(doc)
        // Find offset inside "Async communication".
        let marker = "Async"
        let offset = (doc as NSString).range(of: marker).location
        XCTAssertNotEqual(offset, NSNotFound)
        let section = outline.section(atUTF16Offset: offset)
        XCTAssertEqual(section?.title, "Communication Patterns")
    }

    func testDeepestSectionWins() {
        let outline = DocumentOutline.parse(doc)
        let offset = (doc as NSString).range(of: "Output per hour").location
        let section = outline.section(atUTF16Offset: offset)
        XCTAssertEqual(section?.title, "Metrics")
        XCTAssertEqual(section?.level, 3)
    }

    func testBodyExtraction() {
        let outline = DocumentOutline.parse(doc)
        let comms = outline.sections.first { $0.title == "Communication Patterns" }!
        XCTAssertEqual(DocumentOutline.body(of: comms, in: doc), "Async communication has become the norm.")
    }

    func testBodyStopsAtSameLevelHeading() {
        let outline = DocumentOutline.parse(doc)
        let measurement = outline.sections.first { $0.title == "Measurement" }!
        let body = DocumentOutline.body(of: measurement, in: doc)
        XCTAssertTrue(body.contains("Metrics"))
        XCTAssertTrue(body.contains("Output per hour."))
    }

    func testOtherSectionTitlesExcludesCurrentAndNonH2() {
        let outline = DocumentOutline.parse(doc)
        let comms = outline.sections.first { $0.title == "Communication Patterns" }
        XCTAssertEqual(
            outline.otherSectionTitles(excluding: comms),
            ["Personal Notes", "Measurement"]
        )
    }

    func testNotAHeading() {
        let outline = DocumentOutline.parse("#NoSpace\n####### too deep\nplain")
        XCTAssertTrue(outline.sections.isEmpty)
        XCTAssertNil(outline.topic)
    }

    func testEmptyDocument() {
        let outline = DocumentOutline.parse("")
        XCTAssertTrue(outline.sections.isEmpty)
        XCTAssertNil(outline.section(atUTF16Offset: 0))
    }

    func testHeadingsInsideCodeFencesAreIgnored() {
        let text = """
        # Real Topic

        ## Real Section
        ```bash
        # not a heading, just a shell comment
        echo hi
        ```
        More text.

        ## Another Real Section
        """
        let outline = DocumentOutline.parse(text)
        XCTAssertEqual(outline.topic, "Real Topic")
        XCTAssertEqual(outline.sections.map(\.title), [
            "Real Topic",
            "Real Section",
            "Another Real Section",
        ])
    }

    func testUnicodeOffsets() {
        let text = "# Über 🧠 Denken\n\n## Erste Frage\nInhalt äöü."
        let outline = DocumentOutline.parse(text)
        XCTAssertEqual(outline.topic, "Über 🧠 Denken")
        let offset = (text as NSString).range(of: "Inhalt").location
        XCTAssertEqual(outline.section(atUTF16Offset: offset)?.title, "Erste Frage")
        let section = outline.sections.first { $0.title == "Erste Frage" }!
        XCTAssertEqual(DocumentOutline.body(of: section, in: text), "Inhalt äöü.")
    }
}
