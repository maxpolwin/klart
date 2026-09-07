#if os(macOS)
import XCTest
import AppKit
import KlartKit
@testable import Klart

/// A rail whose cards outgrow the window scrolls; it never crushes them
/// together. Measured on the real thing — a real window, the real SwiftUI
/// layout, each card reporting where it actually landed — because the
/// placement pass is arithmetic that reads correctly and still stacked six
/// cards on top of one another at the top of the rail.
@MainActor
final class RailOverflowTests: XCTestCase {
    private var app: AppFixture?

    override func setUp() async throws {
        try await super.setUp()
        try requireWindowServer()
    }

    override func tearDown() async throws {
        app?.tearDown()
        app = nil
        try await super.tearDown()
    }

    private static let cardCount = 8
    /// Short enough that eight cards cannot fit however tightly they stack.
    private static let shortWindow = CGSize(width: 1200, height: 560)

    /// Sections far enough apart that neighbouring cards do not collide, so
    /// a card off its heading is off it for a reason the test cares about.
    private static let body: String = "# Overflow\n\n" + (1...cardCount).map { n in
        "## Section \(n)\n\n" + (1...4).map {
            "Sentence \($0) of section \(n), written out at length so this paragraph reliably takes a full line of the writing column."
        }.joined(separator: " ")
    }.joined(separator: "\n\n")

    private func makeApp(size: CGSize) -> AppFixture {
        let made = AppFixture(size: size)
        app = made
        return made
    }

    /// Opens `text` in a fresh note and scrolls to the top: pushing text into
    /// the editor leaves the caret at the end, and the typewriter margin then
    /// centres the last line, putting every heading above the viewport.
    private func open(_ text: String, in fixture: AppFixture) {
        fixture.state.createNote()
        fixture.state.editorText = text
        guard let textView = fixture.waitForEditor() else { return }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.enclosingScrollView?.contentView.scroll(to: .zero)
        textView.enclosingScrollView?.reflectScrolledClipView(textView.enclosingScrollView!.contentView)
    }

    /// One note per section, so every card has a heading to sit beside.
    private func seed(_ fixture: AppFixture) -> [FeedbackItem] {
        open(Self.body, in: fixture)
        let items = (1...Self.cardCount).map { n in
            FeedbackItem(
                kind: .gap,
                text: "Section \(n) states a claim it never backs with a number or an example.",
                suggestion: n.isMultiple(of: 2) ? "Add one figure." : nil,
                section: "Section \(n)"
            )
        }
        fixture.state.feedbackItems = items
        fixture.state.editorRailVisible = true
        return items
    }

    /// The card frames once they have stopped moving. Measured heights land a
    /// pass after the first layout and the document settles its own opening
    /// scroll, so the first report is never the last.
    private func settledFrames(
        _ fixture: AppFixture,
        count: Int = cardCount,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [UUID: CGRect] {
        guard let bridge = fixture.waitForEditor()?.bridge else {
            XCTFail("the editor never attached its geometry bridge", file: file, line: line)
            return [:]
        }
        pump(
            until: { bridge.railCardFrames.count == count },
            timeout: 8,
            "only \(bridge.railCardFrames.count) of \(count) cards reported a frame",
            file: file, line: line
        )
        var last = bridge.railCardFrames
        for _ in 0..<40 {
            pumpFor(0.15)
            let now = bridge.railCardFrames
            if now == last { return now }
            last = now
        }
        XCTFail("the rail never stopped moving", file: file, line: line)
        return last
    }

    private func railScrollView(in fixture: AppFixture) -> NSScrollView? {
        func collect(_ view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(collect)
        }
        guard let root = fixture.window.contentView else { return nil }
        // Not the editor's own scroll view, and not the notes panel parked off
        // the left edge: the one on the right is the rail's.
        return collect(root).first { scroll in
            !(scroll.documentView is KlartTextView)
                && scroll.convert(scroll.bounds, to: nil).minX > root.bounds.midX
        }
    }

    // MARK: - Overflow

    func testEightCardsOnAShortWindowNeverOverlap() {
        let fixture = makeApp(size: Self.shortWindow)
        let items = seed(fixture)
        let frames = settledFrames(fixture)
        let ordered = items.compactMap { frames[$0.id] }
        XCTAssertEqual(ordered.count, Self.cardCount)

        for (index, upper) in ordered.enumerated() {
            for lower in ordered[(index + 1)...] {
                // A point of slack: two cards sharing a rounded edge are not
                // overlapping, two sharing a whole header are.
                XCTAssertFalse(
                    upper.insetBy(dx: 0, dy: 1).intersects(lower),
                    "cards overlap: \(upper) and \(lower)"
                )
            }
        }

        let stackHeight = ordered.reduce(0) { $0 + $1.height }
        XCTAssertGreaterThan(
            stackHeight, Self.shortWindow.height,
            "the stack fits the window, so this never exercised overflow"
        )
    }

    func testAnOverflowingRailScrollsInsteadOfCompressing() {
        let fixture = makeApp(size: Self.shortWindow)
        _ = seed(fixture)
        let frames = settledFrames(fixture)

        let lowest = frames.values.map(\.maxY).max() ?? 0
        XCTAssertGreaterThan(
            lowest, Self.shortWindow.height,
            "every card was pulled inside the window — they were compressed, not left to scroll"
        )

        guard let rail = railScrollView(in: fixture), let content = rail.documentView else {
            return XCTFail("the rail is not a scroll view")
        }
        XCTAssertGreaterThan(
            content.frame.height, rail.frame.height,
            "the rail's content is no taller than its viewport, so nothing can be scrolled to"
        )
    }

    /// Overflow costs only the cards that do not fit. The first card still
    /// sits on its heading's line, exactly as it does in a tall window.
    func testCardsThatFitKeepTheirHeadingAnchorsWhileOverflowing() {
        let fixture = makeApp(size: Self.shortWindow)
        let items = seed(fixture)
        let frames = settledFrames(fixture)
        guard let bridge = fixture.textView?.bridge else { return XCTFail("no bridge") }

        let headingOffset = (Self.body as NSString).range(of: "## Section 1").location
        guard let headingY = bridge.lineY(atUTF16: headingOffset),
              let first = frames[items[0].id] else {
            return XCTFail("the first heading or its card could not be located")
        }
        XCTAssertEqual(
            first.minY, headingY, accuracy: 2,
            "the first card left its heading (card at \(first.minY), heading at \(headingY))"
        )
    }

    // MARK: - The tall window is untouched

    func testAFewCardsInATallWindowSitOnTheirHeadings() {
        let fixture = makeApp(size: CGSize(width: 1200, height: 800))
        open(Self.body, in: fixture)
        let items = [
            FeedbackItem(kind: .gap, text: "Section 1 never says who pays.", section: "Section 1"),
            FeedbackItem(kind: .gap, text: "Section 2 repeats the claim above.", section: "Section 2"),
        ]
        fixture.state.feedbackItems = items
        fixture.state.editorRailVisible = true
        let frames = settledFrames(fixture, count: items.count)
        guard let bridge = fixture.textView?.bridge else { return XCTFail("no bridge") }

        for (index, item) in items.enumerated() {
            let offset = (Self.body as NSString).range(of: "## Section \(index + 1)").location
            guard let headingY = bridge.lineY(atUTF16: offset), let frame = frames[item.id] else {
                return XCTFail("card \(index + 1) or its heading could not be located")
            }
            XCTAssertEqual(frame.minY, headingY, accuracy: 2, "card \(index + 1) is off its heading")
        }
        guard let rail = railScrollView(in: fixture), let content = rail.documentView else {
            return XCTFail("the rail is not a scroll view")
        }
        XCTAssertEqual(
            content.frame.height, rail.frame.height, accuracy: 1,
            "a rail that fits must not offer anything to scroll to"
        )
    }
}
#endif
