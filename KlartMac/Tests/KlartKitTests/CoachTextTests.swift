import XCTest
@testable import KlartKit

/// Coach output is model text; nothing in it may become a clickable target.
final class CoachTextTests: XCTestCase {
    private func assertNoTargets(_ text: AttributedString, file: StaticString = #filePath, line: UInt = #line) {
        for run in text.runs {
            XCTAssertNil(run.link, "link survived: \(String(text[run.range].characters))", file: file, line: line)
            XCTAssertNil(run.imageURL, "image survived: \(String(text[run.range].characters))", file: file, line: line)
        }
    }

    func testInlineLinksKeepTheirLabelButLoseTheirTarget() {
        let text = CoachText.render("Your figure is unsupported; [the source you cited](https://attacker.example/login) says otherwise.")
        assertNoTargets(text)
        XCTAssertEqual(
            String(text.characters),
            "Your figure is unsupported; the source you cited says otherwise."
        )
    }

    func testCustomSchemesAndAutolinksAreInert() {
        assertNoTargets(CoachText.render("[open the export](x-some-app://payload) or <ssh://attacker.example>"))
    }

    func testImagesAreInert() {
        assertNoTargets(CoachText.render("![chart](https://attacker.example/pixel.png)"))
    }

    func testEmphasisStillRenders() {
        let text = CoachText.render("This is **the** gap.")
        XCTAssertEqual(String(text.characters), "This is the gap.")
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }
}
