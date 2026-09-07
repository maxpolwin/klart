import XCTest
@testable import KlartKit

/// The offline checks are conservative on purpose: each test pins down both
/// that a rule fires on the text it is for and that it stays quiet on text
/// that merely resembles it.
final class LocalChecksTests: XCTestCase {
    private func cursor(_ text: String, at needle: String) -> Int {
        (text as NSString).range(of: needle).location
    }

    // MARK: uncited-claim

    func testAnEmpiricalClaimWithoutACitationIsFlaggedAndAnchored() {
        let text = """
        # Pricing

        ## Market
        Most economists agree the segment is saturated, and studies show that 40% of buyers churn within a year of signing.
        """
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "Most"))
        let claims = items.filter { $0.rule == "uncited-claim" }
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims[0].kind, .evidence)
        XCTAssertEqual(claims[0].source, .local)
        XCTAssertEqual(claims[0].section, "Market")
        XCTAssertEqual(claims[0].anchor, "Most economists agree the segment is saturated, and studies show that 40% of buyers churn", "the first fifteen words — enough to find the sentence")
        XCTAssertNotNil(claims[0].why)
    }

    func testACitedClaimIsLeftAlone() {
        let text = """
        # Pricing

        ## Market
        Studies show that 40% of buyers churn within a year of signing (Smith et al. 2021), which is settled.
        """
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "Studies"))
        XCTAssertTrue(items.filter { $0.rule == "uncited-claim" }.isEmpty)
    }

    func testAClaimInsideACodeBlockIsNotAClaim() {
        let text = """
        # Ops

        ## Script
        The script below prints the usage figures for the week, nothing more.

        ```
        echo "disk 95% full — studies show this"
        ```
        """
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "The script"))
        XCTAssertTrue(items.filter { $0.rule == "uncited-claim" }.isEmpty)
    }

    // MARK: hedge-density

    func testHeavyHedgingIsFlaggedOnlyOnceTheSectionIsLongEnough() {
        let hedged = Array(repeating: "It might perhaps seem that this could possibly matter, arguably.", count: 14).joined(separator: " ")
        let text = "# T\n\n## Position\n" + hedged
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "It might"))
        let hedges = items.filter { $0.rule == "hedge-density" }
        XCTAssertEqual(hedges.count, 1)
        XCTAssertEqual(hedges[0].kind, .clarity)
        XCTAssertNil(hedges[0].anchor, "the note is about the section, not one sentence")

        let short = "# T\n\n## Position\nIt might perhaps seem that this could possibly matter, arguably."
        XCTAssertTrue(LocalChecks.run(text: short, cursorUTF16: cursor(short, at: "It might")).filter { $0.rule == "hedge-density" }.isEmpty)
    }

    func testCommittedProseIsNotFlaggedForHedging() {
        let firm = Array(repeating: "The segment is saturated and the price has to fall before the quarter ends.", count: 14).joined(separator: " ")
        let text = "# T\n\n## Position\n" + firm
        XCTAssertTrue(LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "The segment")).filter { $0.rule == "hedge-density" }.isEmpty)
    }

    // MARK: undefined-term

    func testARecurringUndefinedAcronymIsFlagged() {
        let text = """
        # T

        ## Rollout
        The CRDT layer replicates every edit, and the CRDT also handles offline merges without a server round-trip.
        """
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "The CRDT"))
        let terms = items.filter { $0.rule == "undefined-term" }
        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms[0].anchor, "CRDT")
        XCTAssertEqual(terms[0].kind, .clarity)
    }

    func testADefinedOrCommonAcronymIsNotFlagged() {
        let text = """
        # T

        ## Rollout
        The CRDT (conflict-free replicated data type) layer replicates every edit; the CRDT also merges offline. The API and the UI are unchanged, and the API stays versioned.
        """
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "The CRDT"))
        XCTAssertTrue(items.filter { $0.rule == "undefined-term" }.isEmpty)
    }

    // MARK: thin-section

    func testAThinSectionElsewhereIsFlaggedButTheOneBeingWrittenIsNot() {
        let text = """
        # Plan

        ## Goals
        Ship.

        ## Risks
        We are writing this one right now, so it is short for a reason and must not be flagged.
        """
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "We are"))
        let thin = items.filter { $0.rule == "thin-section" }
        XCTAssertEqual(thin.map(\.section), ["Goals"])
        XCTAssertEqual(thin[0].kind, .gap)
    }

    func testAnExcludedSectionIsNeverReported() {
        let text = """
        # Plan

        ## Private [no-ai]
        x

        ## Risks
        Long enough to be the section being written, and the private one above must not be named at all.
        """
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "Long enough"))
        XCTAssertTrue(items.allSatisfy { $0.section != "Private" })
    }

    func testNothingRunsFromInsideAnExcludedSection() {
        let text = """
        # Plan

        ## Private [no-ai]
        Studies show that 90% of these are wrong, but nobody may read this section.

        ## Risks
        Ship.
        """
        XCTAssertTrue(LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "Studies")).isEmpty)
    }

    // MARK: title-overlap

    func testTwoHeadingsSharingASubstantiveWordAreFlaggedOnce() {
        let text = """
        # Plan

        ## Pricing strategy
        Long enough body here to be a proper section with an argument inside it, for sure.

        ## Pricing risks
        Another body long enough to be a proper section with an argument inside it as well.

        ## Pricing timeline
        And a third one, long enough too.
        """
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "And a third"))
        let overlaps = items.filter { $0.rule == "title-overlap" }
        XCTAssertEqual(overlaps.count, 1, "one MECE hint at most")
        XCTAssertEqual(overlaps[0].kind, .mece)
        XCTAssertEqual(overlaps[0].section, "Pricing risks")
        XCTAssertTrue(overlaps[0].text.contains("“pricing”"))
    }

    func testStopWordsAndShortWordsDoNotCountAsOverlap() {
        let text = """
        # Plan

        ## Overview of the plan
        Long enough body here to be a proper section with an argument inside it, for sure.

        ## Summary of the plan
        Another body long enough to be a proper section with an argument inside it as well.
        """
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "Another"))
        XCTAssertTrue(items.filter { $0.rule == "title-overlap" }.isEmpty)
    }

    // MARK: shape

    func testFindingsAreCapped() {
        var claims: [String] = []
        for i in 0..<6 {
            claims.append("Studies show that \(30 + i)% of teams miss the date, which everyone here already knows well.")
        }
        let text = "# T\n\n## A\n" + claims.joined(separator: " ") + "\n\n## B\nx\n\n## C\ny\n\n## D\nz"
        let items = LocalChecks.run(text: text, cursorUTF16: cursor(text, at: "Studies"))
        XCTAssertLessThanOrEqual(items.count, LocalChecks.maxFindings)
        XCTAssertEqual(items.filter { $0.rule == "uncited-claim" }.count, 2, "two per section, so one rule cannot crowd the rest out")
    }
}
