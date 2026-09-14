#if os(macOS)
import XCTest
import AppKit
import KlartKit
@testable import Klart

/// Opening the editor's rail must not ghost its own text across the page.
///
/// The bug this pins: the rail slides in over two seconds, and during that
/// slide the editor's phase changes (the read starts, then finishes — for a
/// short section, within a frame). The empty card's text changed inside an
/// animated transaction, so the *old* words kept the position animation
/// they were mid-way through and slid from the middle of the window into
/// the card, while the new words were already sitting in it. Rendered
/// SwiftUI is invisible to the accessibility tree, so this samples real
/// frames from the window and looks for ink where there must be none.
@MainActor
final class RailOpeningTests: XCTestCase {
    private var app: AppFixture?

    override func setUp() async throws {
        try await super.setUp()
        try requireWindowServer()
        try requireAnimation()
    }

    override func tearDown() async throws {
        app?.tearDown()
        app = nil
        try await super.tearDown()
    }

    /// The spring the rail arrives on (`TeleprompterMotion.duration`) plus
    /// its settle.
    private static let slide: TimeInterval = 2.6

    private static let short = "# Untitled\n\nasdf"
    private static let skipped = "Keep writing — the editor reads a section from ~80 characters."

    func testOpeningTheRailWhileTheReadFinishesLeavesNoGhostText() throws {
        let fixture = AppFixture()
        app = fixture
        fixture.state.createNote()
        fixture.state.editorText = Self.short
        _ = fixture.waitForEditor()
        let view = try XCTUnwrap(fixture.window.contentView)

        // 1. Where the card settles, from a frame with nothing in flight.
        fixture.state.feedbackPhase = .skipped(Self.skipped)
        fixture.state.editorRailVisible = true
        pumpFor(Self.slide)
        let settled = try Frame(of: view)
        // The card is the only ink in the right two fifths of the window: the
        // pinned title straddles the centre and the note's text sits at the
        // left. Found rather than computed, so the zone is right whichever
        // way up the layer rendered.
        let card = try XCTUnwrap(
            settled.inkBounds(x: settled.widthPt * 0.6 ..< settled.widthPt, y: 0 ..< settled.heightPt),
            "the empty card should be the only ink in the right of the window"
        )
        // The ghost's path: the card's own rows, from the writing column's
        // middle up to the card's leading edge.
        let zoneX = settled.widthPt * 0.3 ..< max(settled.widthPt * 0.3 + 1, card.minX - 4)
        let zoneY = max(0, card.minY - 10) ..< min(settled.heightPt, card.maxY + 10)
        XCTAssertEqual(
            settled.inkCount(x: zoneX, y: zoneY), 0,
            "the strip left of the card must be bare page once everything is settled — if not, the zone is wrong"
        )

        // 2. Control: open the rail with nothing else changing. The rail
        //    arrives from the right edge, so its card never crosses the zone
        //    — if it does, the zone is measuring the slide, not a ghost.
        fixture.state.editorRailVisible = false
        pumpFor(Self.slide)
        fixture.state.editorRailVisible = true
        let clean = try worstInk(in: view, x: zoneX, y: zoneY)
        XCTAssertLessThan(
            clean.pixels, 12,
            "a plain open put \(clean.pixels) inked pixels left of the card at \(String(format: "%.2f", clean.at)) s — the zone is wrong, not the rail"
        )

        // 3. Open it the way the app does: the rail starts sliding and the
        //    read starts in the same turn; the read finishes a turn later,
        //    while the slide is still under way.
        fixture.state.editorRailVisible = false
        fixture.state.feedbackPhase = .idle
        pumpFor(Self.slide)

        fixture.state.editorRailVisible = true
        fixture.state.feedbackPhase = .analyzing
        pumpFor(0.03)
        fixture.state.feedbackPhase = .skipped(Self.skipped)

        let worst = try worstInk(in: view, x: zoneX, y: zoneY)
        XCTAssertLessThan(
            worst.pixels, 12,
            "the editor's text ghosted across the page while the rail opened — \(worst.pixels) inked pixels left of the card at \(String(format: "%.2f", worst.at)) s"
        )
    }

    /// Samples frames through one slide of the rail and reports the most ink
    /// seen in the zone, and when.
    private func worstInk(in view: NSView, x: Range<CGFloat>, y: Range<CGFloat>) throws -> (pixels: Int, at: TimeInterval) {
        var worst = 0
        var at: TimeInterval = 0
        var elapsed: TimeInterval = 0
        while elapsed < Self.slide {
            pumpFor(0.04)
            elapsed += 0.04
            let ink = try Frame(of: view).inkCount(x: x, y: y)
            if ink > worst { worst = ink; at = elapsed }
        }
        return (worst, at)
    }
}

/// One rendered frame of the window, read back as pixels — from the layer
/// tree's *presentation* copy, which carries the values an animation is
/// showing right now. `cacheDisplay` draws the model tree, i.e. where things
/// will end up, and never sees a ghost.
private struct Frame {
    let width: Int
    let height: Int
    private let pixels: [UInt8]
    /// Luminance of the page itself, sampled at a corner nothing draws on.
    let background: Double

    @MainActor
    init(of view: NSView) throws {
        let layer = try XCTUnwrap(view.layer, "the window's content must be layer-backed")
        let source = layer.presentation() ?? layer
        let w = Int(view.bounds.width)
        let h = Int(view.bounds.height)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        try buffer.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            source.render(in: ctx)
        }
        width = w
        height = h
        pixels = buffer
        background = Frame.luminance(buffer, width: w, px: 2, py: 2)
    }

    var widthPt: CGFloat { CGFloat(width) }
    var heightPt: CGFloat { CGFloat(height) }

    private func isInk(px: Int, py: Int) -> Bool {
        abs(Frame.luminance(pixels, width: width, px: px, py: py) - background) > 0.12
    }

    private static func luminance(_ pixels: [UInt8], width: Int, px: Int, py: Int) -> Double {
        let offset = (py * width + px) * 4
        let r = Double(pixels[offset]) / 255
        let g = Double(pixels[offset + 1]) / 255
        let b = Double(pixels[offset + 2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Ink pixels inside a rectangle, in the frame's own coordinates.
    func inkCount(x: Range<CGFloat>, y: Range<CGFloat>) -> Int {
        var count = 0
        forEachPixel(x: x, y: y) { px, py in
            if isInk(px: px, py: py) { count += 1 }
        }
        return count
    }

    /// The bounding box of every ink pixel in the rectangle; nil when there
    /// is none. Same coordinates as the rectangle, whichever way up the
    /// layer rendered — callers only ever compare boxes from one frame with
    /// zones in another of the same view.
    func inkBounds(x: Range<CGFloat>, y: Range<CGFloat>) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        forEachPixel(x: x, y: y) { px, py in
            guard isInk(px: px, py: py) else { return }
            minX = min(minX, px); maxX = max(maxX, px)
            minY = min(minY, py); maxY = max(maxY, py)
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func forEachPixel(x: Range<CGFloat>, y: Range<CGFloat>, _ body: (Int, Int) -> Void) {
        let px0 = max(0, Int(x.lowerBound)), px1 = min(width, Int(x.upperBound))
        let py0 = max(0, Int(y.lowerBound)), py1 = min(height, Int(y.upperBound))
        guard px0 < px1, py0 < py1 else { return }
        for py in py0..<py1 {
            for px in px0..<px1 { body(px, py) }
        }
    }
}
#endif
