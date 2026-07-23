#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import CoreGraphics
import KlartKit
@testable import Klart

// The writing surface is geometry the user can see, so these tests measure the
// real thing: a real window, the real layout manager, real key events through
// the responder chain. Nothing here stands in for AppKit — a mocked layout
// manager would have happily reported the caret centred on the wrong line.

// MARK: - Waiting

/// Advances the main run loop until `predicate` holds, or `timeout` expires.
///
/// Never sleeps for a fixed duration: the editor's spring settles anywhere
/// between instantly (Reduce Motion) and four seconds (a jump across a long
/// note), and a fixed wait would be either flaky or slow at every call site.
/// The predicate is checked *before* the first wait, so the instant path costs
/// nothing.
@MainActor
@discardableResult
func pump(
    until predicate: () -> Bool,
    timeout: TimeInterval = 8,
    failOnTimeout: Bool = true,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) -> Bool {
    let tick: TimeInterval = 0.004
    let deadline = Date(timeIntervalSinceNow: timeout)
    let app: NSApplication? = NSApp

    while true {
        // Drain queued events first, so layout, first-responder changes and
        // timer callbacks have all landed before the predicate is asked.
        if let app {
            while let event = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }
        if predicate() { return true }

        let now = Date()
        if now >= deadline { break }
        RunLoop.current.run(mode: .default, before: min(now.addingTimeInterval(tick), deadline))
        // `run(mode:before:)` returns immediately when no input source is
        // attached, which would spin a core flat out; yield the slice by hand.
        if Date().timeIntervalSince(now) < tick / 2 {
            Thread.sleep(forTimeInterval: min(tick, max(0, deadline.timeIntervalSinceNow)))
        }
    }

    let settled = predicate()
    if !settled, failOnTimeout {
        let detail = message()
        XCTFail(
            "did not settle within \(timeout)s\(detail.isEmpty ? "" : ": \(detail)")",
            file: file, line: line
        )
    }
    return settled
}

/// Runs the loop for a fixed span, and never fails on its own. Only for
/// asserting that something *doesn't* happen — there is no predicate to poll
/// for the absence of an event, so the wait has to be real.
@MainActor
func pumpFor(_ duration: TimeInterval) {
    _ = pump(until: { false }, timeout: duration, failOnTimeout: false)
}

// MARK: - Environment

/// Whether this process can reach a window server.
///
/// Checked before any AppKit type is touched: with no session, the first
/// AppKit call aborts the process instead of returning an error, so there is
/// nothing left to catch afterwards. CI runners normally have an Aqua session;
/// SSH and daemon contexts do not.
func hasWindowServer() -> Bool {
    CGSessionCopyCurrentDictionary() != nil
}

func requireWindowServer(file: StaticString = #filePath, line: UInt = #line) throws {
    try XCTSkipUnless(
        hasWindowServer(),
        "no window server in this session — the editor's geometry cannot be measured",
        file: file, line: line
    )
}

/// The editor reads Reduce Motion straight from `NSWorkspace`, which a test
/// cannot set. Under Reduce Motion every animated path becomes an instant one,
/// so tests that need a spring in flight skip rather than quietly assert
/// nothing.
func requireAnimation(file: StaticString = #filePath, line: UInt = #line) throws {
    try XCTSkipIf(
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        "Reduce Motion is on: there is no animation to observe",
        file: file, line: line
    )
}

@MainActor
func bootstrapApp() {
    let app = NSApplication.shared
    if app.activationPolicy() != .accessory {
        app.setActivationPolicy(.accessory)
    }
}

@MainActor
func firstDescendant<T: NSView>(_ root: NSView, of type: T.Type) -> T? {
    if let match = root as? T { return match }
    for subview in root.subviews {
        if let match = firstDescendant(subview, of: type) { return match }
    }
    return nil
}

/// Sends `text` through the window the way a keyboard does — `sendEvent` into
/// the responder chain, not `insertText` into the view. The difference is the
/// entire point of the focus tests: `insertText` would happily type into a
/// view that no keystroke could actually reach.
///
/// Fails when nothing in the window can take text. A key event sent into a
/// window whose first responder is the window itself is silently dropped, and
/// a test that then asserts on unchanged geometry passes for the wrong reason.
@MainActor
func typeIntoWindow(
    _ window: NSWindow,
    _ text: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard window.firstResponder is NSTextView else {
        XCTFail(
            "nothing in this window can accept text (first responder: "
                + "\(String(describing: window.firstResponder))) — the keystrokes would go nowhere",
            file: file, line: line
        )
        return
    }
    for character in text {
        let isReturn = character == "\n" || character == "\r"
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: isReturn ? "\r" : String(character),
            charactersIgnoringModifiers: isReturn ? "\r" : String(character),
            isARepeat: false,
            keyCode: isReturn ? 36 : 0
        ) else { continue }
        window.sendEvent(event)
    }
}

// MARK: - The editor on its own

/// A live `MarkdownEditor` in a real window, with none of the app around it —
/// enough to measure the writing surface, cheap enough to build per test.
///
/// Borderless on purpose: a titled window has AppKit adjust the scroll view's
/// content insets for the title bar, which shifts every measurement here by
/// half that inset for no reason a test cares about.
@MainActor
final class EditorFixture {
    let window: NSWindow
    let textView: KlartTextView
    let scrollView: NSScrollView
    let bridge: EditorBridge

    private let host: NSView
    private let box: TextBox

    static let viewport = CGSize(width: 900, height: 768)

    final class TextBox {
        var text: String
        init(_ text: String) { self.text = text }
    }

    /// - Parameters:
    ///   - text: the note's markdown.
    ///   - focusHolder: a view planted in the same window that takes first
    ///     responder before the editor lands — for testing that the editor
    ///     never yanks focus away from a control already holding it.
    ///   - viewportHeight: the scroll view's height at plant time. Zero models
    ///     SwiftUI planting the editor before it has been given a size.
    init(_ text: String, focusHolder: NSView? = nil, viewportHeight: CGFloat? = nil) {
        bootstrapApp()
        box = TextBox(text)
        bridge = EditorBridge()

        let size = Self.viewport
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root

        if let focusHolder {
            root.addSubview(focusHolder)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(focusHolder)
        }

        let editor = MarkdownEditor(
            text: Binding(get: { [box] in box.text }, set: { [box] in box.text = $0 }),
            contentInset: NSSize(width: 40, height: 64),
            bridge: bridge,
            onTextChange: {},
            onCursorChange: { _ in }
        )
        let hosting = NSHostingView(rootView: editor)
        hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: viewportHeight ?? size.height)
        root.addSubview(hosting)
        host = hosting

        if focusHolder == nil { window.makeKeyAndOrderFront(nil) }
        window.layoutIfNeeded()

        guard let found = firstDescendant(hosting, of: KlartTextView.self),
              let enclosing = found.enclosingScrollView else {
            fatalError("MarkdownEditor did not produce a KlartTextView")
        }
        textView = found
        scrollView = enclosing
    }

    /// Grows the editor to the full viewport — models the size arriving after
    /// the view was already planted.
    func growToFullViewport() {
        host.frame = NSRect(origin: .zero, size: Self.viewport)
        window.layoutIfNeeded()
    }

    /// Waits for the editor to finish opening: margin applied, caret placed,
    /// keyboard claimed. Typing before this lands goes nowhere.
    @discardableResult
    func waitUntilReady(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        pump(
            until: { self.textView.textContainerInset.height > 100
                     && self.window.firstResponder === self.textView },
            timeout: 8,
            "the editor never finished opening",
            file: file, line: line
        )
    }

    var text: String { box.text }
    var viewportHeight: CGFloat { scrollView.frame.height }
    var scrollOffset: CGFloat { scrollView.contentView.bounds.origin.y }

    /// Where the caret's line sits on screen, measured from the top of the
    /// viewport — the number the reader actually perceives.
    var caretLineCentreOnScreen: CGFloat {
        textView.currentCaretRect().midY - scrollOffset
    }

    /// True once the editor has settled with the caret's line at the centre.
    func waitForCentredCaretLine(tolerance: CGFloat = 6, timeout: TimeInterval = 8) -> Bool {
        pump(
            until: { abs(self.caretLineCentreOnScreen - self.viewportHeight / 2) <= tolerance },
            timeout: timeout,
            "caret line settled at \(self.caretLineCentreOnScreen) of \(self.viewportHeight)"
        )
    }

    func tearDown() {
        window.contentView = nil
        window.orderOut(nil)
    }
}

// MARK: - The whole app

/// The real `TeleprompterView` over a real `AppState`, with every store in a
/// temp directory: nothing here can touch the notes library, the keychain, or
/// the network.
@MainActor
final class AppFixture {
    let state: AppState
    let window: NSWindow

    private let directory: URL

    init() {
        bootstrapApp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klart-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        state = AppState(
            noteStore: NoteStore(directory: directory.appendingPathComponent("Notes", isDirectory: true)),
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            // Never the login keychain: the real store writes items that
            // outlive the process, and on a runner with a locked keychain it
            // fails silently rather than loudly.
            secrets: InMemorySecretStore()
        )
        // No provider call can be reached without this: typing is wired to the
        // feedback debounce, which would otherwise fire a request mid-test.
        state.settings.autoFeedback = false

        let size = CGSize(width: 1200, height: 800)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: TeleprompterView().environmentObject(state))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
    }

    var textView: KlartTextView? {
        window.contentView.flatMap { firstDescendant($0, of: KlartTextView.self) }
    }

    /// The editor for the selected note, once SwiftUI has built it.
    func waitForEditor(file: StaticString = #filePath, line: UInt = #line) -> KlartTextView? {
        _ = pump(until: { self.textView != nil }, timeout: 8, "no editor was ever built", file: file, line: line)
        return textView
    }

    func tearDown() {
        // Lets TeleprompterView's `.onDisappear` cancel its rail and panel
        // tasks — one of them sleeps for five minutes holding the AppState,
        // then writes to it, which would land in whichever test came next.
        window.contentView = nil
        window.orderOut(nil)
        pumpFor(0.05)
        try? FileManager.default.removeItem(at: directory)
        // Set from `settings.teleprompterMode` in AppState.init, process-wide.
        Theme.monochrome = false
    }
}
#endif
