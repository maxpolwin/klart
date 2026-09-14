#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import CoreGraphics
import KlartKit
@testable import Klart

// KNOWN DEFECT, recorded rather than fixed — the assertion below is wrapped in
// `XCTExpectFailure`, so the suite stays green and XCTest reports an
// *unexpected pass* the day someone makes it hold.
//
// Opening the notes rail narrows the writing column over a 2 s spring, so the
// document re-wraps continuously for the length of the animation. Re-wrapping
// changes how many lines sit *above* the viewport, but nothing moves the clip
// origin — it is held in points, and the only three things that ever move it are
// `keyDown`, `textDidChange` and the one-shot open centring. So the prose slides
// under the reader by one line height for every line the re-wrap added above
// them. Measured here: 128 pt of walk in five discrete 22.5 pt hops across a
// 264 pt narrowing.
//
// This is also what made the rail's cards appear to stair-step: `lineY` was
// tracking a moving target faithfully. Smoothing the cards (commit 01dd67e,
// since reverted) treated the symptom and introduced a worse one — opaque cards
// lapping over each other, because `EditorRail.layout(in:)` enforces its 12 pt
// non-overlap on *target* y only.
//
// Why it is not fixed here: the width change is detected in
// `KlartTextView.setFrameSize`, but a `setBoundsOrigin` issued from inside that
// call does not persist — the scroll view re-imposes the clip bounds once the
// layout pass returns. (Verified: the correction computes correctly and is
// simply discarded, the same call succeeding from `applyTypewriterOffset`'s
// timer, which runs outside layout.) Holding a scroll position across a
// document resize wants a custom `NSClipView` overriding `constrainBoundsRect`,
// which is a larger change than this note.

@MainActor
final class RewrapAnchorTests: XCTestCase {
    private var fixture: EditorFixture?

    override func tearDown() {
        // Ordered out, not merely released: this test leaves a *narrowed* key
        // window behind, and `testEnterAtTheVeryEndCentresTheNewLine` in
        // WritingSurfaceTests settles its caret differently depending on what
        // window state it inherits. It fails on its own even without this file
        // present, so the fragility is not new — but nothing here should be what
        // provokes it.
        fixture?.window.orderOut(nil)
        fixture = nil
        pumpFor(0.05)
        super.tearDown()
    }

    /// Paragraphs long enough that their line count really changes across the
    /// sweep. A paragraph that wraps to two lines at both the open and the
    /// closed width moves nothing, and measures a misleading zero.
    private func longNote() -> String {
        func filler(_ label: String) -> String {
            (1...9).map { "Sentence \($0) of the \(label) body, written out at length so this paragraph reliably gains and loses whole lines as the writing column gives up room to the rail." }
                .joined(separator: " ")
        }
        return """
        # Alpha section

        \(filler("alpha"))

        ## Beta section

        \(filler("beta"))

        ## Gamma section

        \(filler("gamma"))

        ## Delta section

        \(filler("delta"))
        """
    }

    /// UTF-16 offset of the character sitting on the viewport's top edge, plus
    /// where that character's line currently sits relative to that edge.
    private func topOfViewport(_ editor: EditorFixture) -> (offset: Int, screenY: CGFloat)? {
        let textView = editor.textView
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let onTopEdge = NSPoint(
            x: 0,
            y: textView.visibleRect.minY - textView.textContainerInset.height
        )
        let glyph = layoutManager.glyphIndex(for: onTopEdge, in: container)
        let offset = layoutManager.characterIndexForGlyph(at: glyph)
        guard let screenY = editor.bridge.lineY(atUTF16: offset) else { return nil }
        return (offset, screenY)
    }

    /// The invariant a reader expects and the only one that can hold: whatever is
    /// at the top of the viewport stays at the top of the viewport when only the
    /// width changes. Text further down may still move relative to it — the
    /// re-wrap genuinely changed the distance between them — but the page must
    /// not walk out from under the reader.
    func testTheTopOfTheViewportSurvivesAWidthChange() throws {
        let editor = EditorFixture(longNote())
        fixture = editor
        editor.waitUntilReady()

        // Park the reader mid-note, so there are plenty of wrapped lines above
        // the viewport for a re-wrap to add to.
        let middle = (editor.textView.string as NSString).length / 2
        editor.textView.setSelectedRange(NSRange(location: middle, length: 0))
        editor.textView.centerCaretLine(animated: false)
        pumpFor(0.4)

        // Resizing the SwiftUI host, not the scroll view: a direct scroll-view
        // resize is undone by the next layout pass, which re-imposes SwiftUI's
        // own frame and leaves the wrap exactly where it started.
        let host = try XCTUnwrap(editor.window.contentView?.subviews.first, "no hosting view")
        let anchor = try XCTUnwrap(topOfViewport(editor), "could not read the top of the viewport")

        let full = editor.textView.frame.width
        let railWidth: CGFloat = 264
        var worstDrift: CGFloat = 0
        var driftPerStep: [CGFloat] = []

        // Checked at every step, not just at the end: the artifact is the walk,
        // not the destination.
        for step in 1...30 {
            host.frame = NSRect(
                x: 0, y: 0,
                width: full - railWidth * CGFloat(step) / 30,
                height: editor.window.frame.height
            )
            editor.window.layoutIfNeeded()
            pumpFor(0.02)

            let now = try XCTUnwrap(
                editor.bridge.lineY(atUTF16: anchor.offset),
                "the anchor character stopped resolving mid-sweep"
            )
            let drift = now - anchor.screenY
            driftPerStep.append((drift * 10).rounded() / 10)
            worstDrift = max(worstDrift, abs(drift))
        }

        XCTExpectFailure(
            "the page still walks under the reader across a width-driven re-wrap — see this file's header"
        )
        XCTAssertLessThan(
            worstDrift, 12,
            """
            the page walked under the reader by \(Int(worstDrift)) pt while only the \
            width changed — drift per step: \(driftPerStep)
            """
        )
    }
}
#endif
