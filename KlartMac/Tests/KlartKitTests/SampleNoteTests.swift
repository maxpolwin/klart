import XCTest
@testable import KlartKit

/// The welcome tour's sample note has to earn its place: the editor must
/// find something in it with no model configured, and the outline must read
/// it the way the tour describes it.
final class SampleNoteTests: XCTestCase {
    func testTheOutlineReadsTheSampleTheWayTheTourSaysItDoes() {
        let outline = DocumentOutline.parse(SampleNote.english)
        let sections = outline.sections.filter { $0.level == 2 }
        XCTAssertGreaterThanOrEqual(sections.count, 7, "the sample lost sections")
        XCTAssertTrue(sections.contains { $0.title == SampleNote.readSection })
        let excluded = sections.filter(\.excludedFromAI)
        XCTAssertEqual(excluded.count, 1, "exactly one section is marked [no-ai]")
        XCTAssertFalse(
            outline.sections.contains { $0.title.contains("Morning footfall") },
            "a # inside a fenced block is a comment, not a heading"
        )
    }

    func testTheFirstReadFindsTheUncitedRuleOfThumb() {
        let notes = LocalChecks.run(text: SampleNote.english, cursorUTF16: SampleNote.readCursorUTF16)
        XCTAssertFalse(notes.isEmpty, "the tour promises notes before any model is set up")
        XCTAssertTrue(
            notes.contains { $0.rule == "uncited-claim" && $0.section == SampleNote.readSection },
            "the 12% rule of thumb has nothing behind it; got \(notes.map { $0.rule ?? "?" })"
        )
        XCTAssertTrue(notes.allSatisfy { $0.source == .local })
    }

    func testTheOfflineChecksFindTheHedgedRiskSection() {
        let ns = SampleNote.english as NSString
        let heading = ns.range(of: "## Risks\n\n")
        XCTAssertNotEqual(heading.location, NSNotFound)
        let notes = LocalChecks.run(text: SampleNote.english, cursorUTF16: heading.location + heading.length)
        XCTAssertTrue(
            notes.contains { $0.rule == "hedge-density" && $0.section == "Risks" },
            "the risk section hedges in every sentence; got \(notes.map { $0.rule ?? "?" })"
        )
    }

    func testTheReadCursorLandsInsideTheReadSection() {
        let outline = DocumentOutline.parse(SampleNote.english)
        let section = outline.section(atUTF16Offset: SampleNote.readCursorUTF16)
        XCTAssertEqual(section?.title, SampleNote.readSection)
    }
}

final class WelcomeSettingsTests: XCTestCase {
    func testTheTourIsUnseenByDefaultAndSurvivesARoundTrip() throws {
        XCTAssertFalse(AppSettings().welcomeSeen)

        // A settings file from before the tour existed has no key: unseen.
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.welcomeSeen)

        var seen = AppSettings()
        seen.welcomeSeen = true
        let data = try JSONEncoder().encode(seen)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: data).welcomeSeen)
    }
}
