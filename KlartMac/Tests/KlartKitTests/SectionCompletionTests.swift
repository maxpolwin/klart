import XCTest
@testable import KlartKit

/// When does the editor read? When the writer is done with a section — not
/// on every pause in typing.
final class SectionCompletionTests: XCTestCase {
    let doc = """
    # Plan

    ## A
    first section body

    ## B
    second section body
    """

    private func offset(_ needle: String, in text: String? = nil) -> Int {
        ((text ?? doc) as NSString).range(of: needle).location
    }

    func testLeavingAnEditedSectionCompletesIt() {
        var tracker = SectionCompletionTracker()
        tracker.noteEdit(at: offset("first"), in: doc)
        XCTAssertNil(tracker.caretMoved(to: offset("first") + 3, in: doc), "moving within the section is not leaving it")
        let done = tracker.caretMoved(to: offset("second"), in: doc)
        XCTAssertEqual(done?.headingStart, offset("## A"))
        XCTAssertEqual(done?.cursorUTF16, offset("first"), "the read is pointed inside the finished section, not at the caret")
    }

    func testMovingWithoutEditingCompletesNothing() {
        var tracker = SectionCompletionTracker()
        XCTAssertNil(tracker.caretMoved(to: offset("first"), in: doc))
        XCTAssertNil(tracker.caretMoved(to: offset("second"), in: doc))
    }

    func testLeavingAndReturningUnchangedDoesNotReadTwice() {
        var tracker = SectionCompletionTracker()
        tracker.noteEdit(at: offset("first"), in: doc)
        XCTAssertNotNil(tracker.caretMoved(to: offset("second"), in: doc))
        // Back to A, no edit, out again.
        XCTAssertNil(tracker.caretMoved(to: offset("first"), in: doc))
        XCTAssertNil(tracker.caretMoved(to: offset("second"), in: doc))
        // Back to A, a real edit, out again: read.
        let edited = doc.replacingOccurrences(of: "first section body", with: "first section body, revised")
        tracker.noteEdit(at: offset("first", in: edited), in: edited)
        XCTAssertNotNil(tracker.caretMoved(to: offset("second", in: edited), in: edited))
    }

    func testOpeningANewHeadingBeneathCompletesTheSectionAbove() {
        // The writer is at the end of A and types a new "## C" line: the
        // caret is now in C, and A is done.
        var tracker = SectionCompletionTracker()
        tracker.noteEdit(at: offset("first") + 5, in: doc)
        let grown = doc.replacingOccurrences(of: "first section body\n", with: "first section body\n\n## C\n")
        let caretInC = (grown as NSString).range(of: "## C").location + 4
        let done = tracker.caretMoved(to: caretInC, in: grown)
        XCTAssertEqual(done?.headingStart, offset("## A"))
    }

    func testThePauseCompletesTheSectionUnderTheCaret() {
        var tracker = SectionCompletionTracker()
        tracker.noteEdit(at: offset("second"), in: doc)
        let done = tracker.pauseElapsed(at: offset("second"), in: doc)
        XCTAssertEqual(done?.headingStart, offset("## B"))
        XCTAssertNil(tracker.pauseElapsed(at: offset("second"), in: doc), "a second pause with nothing typed reads nothing")
    }

    func testAManualReadCountsAsReadingTheSection() {
        var tracker = SectionCompletionTracker()
        tracker.noteEdit(at: offset("first"), in: doc)
        tracker.markRead(at: offset("first"), in: doc)
        XCTAssertNil(tracker.caretMoved(to: offset("second"), in: doc), "⌘R already read it; leaving it must not read it again")
    }

    func testTextWithoutHeadingsIsOneSection() {
        let plain = "no headings here, just prose that gets edited and then paused on"
        var tracker = SectionCompletionTracker()
        tracker.noteEdit(at: 4, in: plain)
        XCTAssertNil(tracker.caretMoved(to: 20, in: plain))
        let done = tracker.pauseElapsed(at: 20, in: plain)
        XCTAssertEqual(done?.headingStart, -1)
        XCTAssertEqual(done?.cursorUTF16, 0)
    }

    func testADeletedSectionIsNotRead() {
        var tracker = SectionCompletionTracker()
        tracker.noteEdit(at: offset("first"), in: doc)
        let collapsed = doc.replacingOccurrences(of: "## A\nfirst section body\n\n", with: "")
        XCTAssertNil(tracker.caretMoved(to: offset("second", in: collapsed), in: collapsed))
    }

    func testResetForgetsEverything() {
        var tracker = SectionCompletionTracker()
        tracker.noteEdit(at: offset("first"), in: doc)
        tracker.reset()
        XCTAssertNil(tracker.caretMoved(to: offset("second"), in: doc))
    }
}
