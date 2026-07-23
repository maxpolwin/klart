#if os(macOS)
import SwiftUI
import AppKit
import KlartKit

private extension NSAttributedString.Key {
    /// Marks syntax characters (heading `#`s, emphasis `*_`` ` ``~`) that should
    /// be hidden from layout while the cursor is on another line — the
    /// live-preview effect. The layout manager delegate nulls these glyphs.
    static let klartHiddenMarker = NSAttributedString.Key("klartHiddenMarker")
    /// The colour a run is *meant* to be, recorded once at styling time.
    /// Focus dimming interpolates the visible `.foregroundColor` away from
    /// this, so repeated dim passes read from the original every frame
    /// instead of compounding on their own output and sliding to black.
    static let klartBaseColor = NSAttributedString.Key("klartBaseColor")
}

struct EditorView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        MarkdownEditor(
            text: $state.editorText,
            clearClipboardAfterCopy: state.settings.vault != nil,
            onTextChange: { state.editorTextChanged() },
            onCursorChange: { state.cursorUTF16 = $0 }
        )
        .background(Theme.background)
        .id(state.selectedNoteID) // fresh editor (and undo stack) per note
    }
}

/// NSTextView that clears the pasteboard a while after a copy/cut from a
/// protected library — unless something else was copied since. Keeps note
/// content from lingering in clipboard history indefinitely.
final class KlartTextView: NSTextView {
    var clearsClipboardAfterCopy = false
    static let clipboardLifetime: TimeInterval = 45

    // MARK: Springing caret
    //
    // AppKit draws the insertion point itself and offers no hook to animate
    // it between positions, so the system caret is suppressed (see
    // `drawInsertionPoint`) and this one is drawn and integrated by hand. It
    // springs horizontally — the axis you actually travel while writing —
    // and jumps vertically, because a caret arcing between lines reads as a
    // glitch rather than as motion.

    /// Underdamped on purpose: the overshoot is the point.
    private enum CaretSpring {
        static let stiffness: CGFloat = 430
        static let damping: CGFloat = 26
        /// Below this gap the spring is over — snap and stop the timer.
        static let restEpsilon: CGFloat = 0.35
        static let blinkPeriod: TimeInterval = 1.0
    }

    private var caretTarget: NSRect = .zero
    private var caretDrawnX: CGFloat = 0
    private var caretVelocity: CGFloat = 0
    private var caretTimer: Timer?
    private var caretBlinkTimer: Timer?
    private var caretVisible = true
    /// Held solid while the caret is travelling or the user is typing —
    /// a blink mid-flight makes the spring impossible to read.
    private var caretSolidUntil: Date = .distantPast

    override var isFlipped: Bool { true }

    /// Suppresses AppKit's own caret; ours is drawn in `draw(_:)`.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Intentionally empty.
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(false)
        refreshCaretTarget()
    }

    /// The caret's rect in view coordinates, derived from the layout manager
    /// rather than `firstRect(forCharacterRange:)` so it stays in this view's
    /// space and works at end-of-line and in empty documents.
    private func currentCaretRect() -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let location = min(selectedRange().location, (string as NSString).length)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)

        var line: NSRect
        if layoutManager.numberOfGlyphs == 0 {
            line = NSRect(origin: .zero, size: CGSize(width: 0, height: EditorStyler.bodyFont.boundingRectForFont.height))
        } else if glyphIndex >= layoutManager.numberOfGlyphs {
            line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil)
            line.origin.x += layoutManager.location(forGlyphAt: layoutManager.numberOfGlyphs - 1).x
        } else {
            line = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            line.origin.x += layoutManager.location(forGlyphAt: glyphIndex).x
        }
        _ = textContainer
        return NSRect(
            x: line.origin.x + textContainerInset.width,
            y: line.origin.y + textContainerInset.height,
            width: 2,
            height: line.height
        )
    }

    private func refreshCaretTarget() {
        let target = currentCaretRect()
        let movedLine = abs(target.origin.y - caretTarget.origin.y) > 0.5
        let firstPlacement = caretTarget == .zero
        caretTarget = target
        caretSolidUntil = Date().addingTimeInterval(0.6)
        caretVisible = true

        if firstPlacement || movedLine || reduceMotion {
            // A new line (or the very first placement) starts fresh at the
            // target instead of sweeping across the whole column to reach it.
            caretDrawnX = target.origin.x
            caretVelocity = 0
            needsDisplay = true
        } else {
            startCaretAnimation()
        }
        startBlinking()
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func startCaretAnimation() {
        guard caretTimer == nil else { return }
        let dt: CGFloat = 1.0 / 60
        caretTimer = Timer.scheduledTimer(withTimeInterval: Double(dt), repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let distance = self.caretTarget.origin.x - self.caretDrawnX
            // Standard damped-spring integration: acceleration pulls toward
            // the target, damping bleeds the overshoot back out.
            let acceleration = distance * CaretSpring.stiffness - self.caretVelocity * CaretSpring.damping
            self.caretVelocity += acceleration * dt
            self.caretDrawnX += self.caretVelocity * dt

            if abs(distance) < CaretSpring.restEpsilon, abs(self.caretVelocity) < CaretSpring.restEpsilon {
                self.caretDrawnX = self.caretTarget.origin.x
                self.caretVelocity = 0
                timer.invalidate()
                self.caretTimer = nil
            }
            self.needsDisplay = true
        }
    }

    private func startBlinking() {
        guard caretBlinkTimer == nil else { return }
        caretBlinkTimer = Timer.scheduledTimer(
            withTimeInterval: CaretSpring.blinkPeriod,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            // Solid while moving or just-typed; only idle carets blink.
            guard Date() >= self.caretSolidUntil, self.caretTimer == nil else {
                self.caretVisible = true
                self.needsDisplay = true
                return
            }
            self.caretVisible.toggle()
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let window, window.firstResponder === self else { return }
        guard selectedRange().length == 0, caretVisible else { return }
        guard caretTarget.height > 0 else { return }
        (insertionPointColor).set()
        NSRect(
            x: caretDrawnX,
            y: caretTarget.origin.y,
            width: caretTarget.width,
            height: caretTarget.height
        ).fill()
    }

    // MARK: Typewriter scrolling
    //
    // The line being written is eased to the vertical centre of the window
    // and kept there, so the eye stays at one height instead of tracking the
    // text down the screen. Deliberately slow: the scroll is meant to settle
    // under the writing, never to yank the page.

    private enum Typewriter {
        /// The spring is re-tuned every frame from how far it still has to
        /// travel, so the page is never moving at one fixed rate: a one-line
        /// nudge settles briskly, a jump across the note eases out over the
        /// full duration, and everything decelerates into place. A constant
        /// rate is what reads as mechanical.
        static let shortDuration: CGFloat = 1.4
        static let longDuration: CGFloat = 4.0
        /// Distance at which the slow end is reached.
        static let longDistance: CGFloat = 600

        /// Critically damped: the page settles rather than overshooting.
        /// Bounce belongs to the chrome, not to the text being read — an
        /// overshoot here drags the words past where the eye already went.
        static let zeta: CGFloat = 1.0

        static func duration(forDistance distance: CGFloat) -> CGFloat {
            let normalized = min(1, abs(distance) / longDistance)
            return shortDuration + (longDuration - shortDuration) * normalized
        }

        /// `spring(duration:bounce:)` in raw terms: ω = 2π/duration, ζ = 1 − bounce.
        static func stiffnessAndDamping(forDistance distance: CGFloat) -> (CGFloat, CGFloat) {
            let omega = 2 * .pi / duration(forDistance: distance)
            return (omega * omega, 2 * zeta * omega)
        }

        /// Below this the scroll is done.
        static let restEpsilon: CGFloat = 0.5
    }

    private var typewriterTimer: Timer?
    private var typewriterTarget: CGFloat = 0
    private var typewriterVelocity: CGFloat = 0

    /// AppKit reveals the caret by scrolling to it *immediately*. Left alone
    /// it beats the spring to the destination, so the page appears to jump
    /// and the animation has nothing left to travel — but suppressing it
    /// outright strands the caret off-screen whenever it moves somewhere the
    /// viewport isn't (arrow keys past the edge, ⌘↓, Find, a selection made
    /// by any command). So the request is honoured, just smoothly: the same
    /// spring, aimed at the same caret.
    override func scrollRangeToVisible(_ range: NSRange) {
        centerCaretLine()
    }

    /// A deliberate scroll always wins. Without this the typewriter spring
    /// keeps pulling toward its old target while the user is dragging, and
    /// the page fights the trackpad. Typing re-engages centring.
    override func scrollWheel(with event: NSEvent) {
        typewriterTimer?.invalidate()
        typewriterTimer = nil
        typewriterVelocity = 0
        super.scrollWheel(with: event)
    }

    /// Eases the view so the caret's line sits at the centre of the viewport.
    func centerCaretLine() {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let viewport = clip.bounds.height
        guard viewport > 0 else { return }
        let caret = currentCaretRect()
        guard caret.height > 0 else { return }

        // The last lines of a note can only reach the centre if the document
        // can scroll past its own end — otherwise typing at the bottom would
        // drift off-centre with nowhere left to go.
        let tail = viewport / 2
        if abs(scrollView.contentInsets.bottom - tail) > 1 {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: tail, right: 0)
        }

        let documentHeight = frame.height
        let maxOffset = max(0, documentHeight + tail - viewport)
        typewriterTarget = min(max(0, caret.midY - viewport / 2), maxOffset)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            applyTypewriterOffset(typewriterTarget, in: scrollView)
            return
        }
        startTypewriterAnimation(in: scrollView)
    }

    private func startTypewriterAnimation(in scrollView: NSScrollView) {
        guard typewriterTimer == nil else { return }
        let dt: CGFloat = 1.0 / 60
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: Double(dt), repeats: true) { [weak self, weak scrollView] timer in
            guard let self, let scrollView else { timer.invalidate(); return }
            let current = scrollView.contentView.bounds.origin.y
            let distance = self.typewriterTarget - current

            // Velocity carries across target changes, so continuous typing
            // reads as one unbroken glide rather than a restarted animation
            // on every keystroke. The spring is re-derived from the remaining
            // distance each frame, which is what makes the pace dynamic.
            let (stiffness, damping) = Typewriter.stiffnessAndDamping(forDistance: distance)
            let acceleration = distance * stiffness - self.typewriterVelocity * damping
            self.typewriterVelocity += acceleration * dt

            if abs(distance) < Typewriter.restEpsilon, abs(self.typewriterVelocity) < Typewriter.restEpsilon {
                self.typewriterVelocity = 0
                self.applyTypewriterOffset(self.typewriterTarget, in: scrollView)
                timer.invalidate()
                self.typewriterTimer = nil
                return
            }
            self.applyTypewriterOffset(current + self.typewriterVelocity * dt, in: scrollView)
        }
    }

    private func applyTypewriterOffset(_ y: CGFloat, in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    deinit {
        caretTimer?.invalidate()
        caretBlinkTimer?.invalidate()
        typewriterTimer?.invalidate()
    }

    override func copy(_ sender: Any?) {
        super.copy(sender)
        scheduleClipboardClear()
    }

    override func cut(_ sender: Any?) {
        super.cut(sender)
        scheduleClipboardClear()
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        // A paste can drop in many lines at once (a whole snippet, a code
        // block); the delegate's textDidChange only restyles the current
        // paragraph, so re-style everything to catch the rest.
        EditorStyler.restyleAll(self)
    }

    private func scheduleClipboardClear() {
        guard clearsClipboardAfterCopy else { return }
        let pasteboard = NSPasteboard.general
        let countAtCopy = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardLifetime) {
            if pasteboard.changeCount == countAtCopy {
                pasteboard.clearContents()
            }
        }
    }
}

/// Bridges the AppKit text machinery to SwiftUI overlays that need text
/// geometry — the Teleprompter's right-hand rail aligns each of the editor's
/// notes with the section of text it refers to.
@MainActor
final class EditorBridge: ObservableObject {
    private(set) weak var textView: NSTextView?
    /// Bumped on every scroll or edit so geometry-dependent overlays recompute.
    @Published private(set) var layoutTick = 0
    private var boundsObserver: NSObjectProtocol?

    func attach(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bump() }
        }
    }

    func bump() {
        layoutTick &+= 1
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    /// Y of the line containing the given UTF-16 offset, in the editor's
    /// visible (viewport) coordinate space. Nil while detached or empty.
    func lineY(atUTF16 offset: Int) -> CGFloat? {
        guard let textView, let layoutManager = textView.layoutManager else { return nil }
        let length = (textView.string as NSString).length
        guard length > 0 else { return nil }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: max(0, min(offset, length - 1)))
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return rect.minY + textView.textContainerInset.height - textView.visibleRect.minY
    }
}

/// Plain-text markdown editor with live styling: headings get larger fonts and
/// their `#` markers are hidden (revealed only on the line you're editing), and
/// emphasis markers dim/hide the same way — so notes read like rendered
/// markdown while the text on disk stays plain markdown. Styling is applied per
/// edited paragraph, so typing stays fast in large documents.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var clearClipboardAfterCopy = false
    /// Top/bottom (height) and side (width) padding around the text.
    var contentInset = NSSize(width: 32, height: 28)
    /// When set, receives the text view for geometry queries (Teleprompter).
    var bridge: EditorBridge? = nil
    /// Slash commands: called with the command name (e.g. "editor") after
    /// the typed `/editor` has been removed from the text.
    var onCommand: ((String) -> Void)? = nil
    var onTextChange: () -> Void
    var onCursorChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Assembled manually (instead of NSTextView.scrollableTextView()) so
        // the document view can be our clipboard-aware subclass.
        let textView = KlartTextView()
        textView.clearsClipboardAfterCopy = clearClipboardAfterCopy
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.borderType = .noBorder
        // Without this the scroll view paints its own default
        // controlBackgroundColor behind the (transparent) text view, a
        // visibly different shade than Theme.background — a seam right at
        // the column's edges instead of one uniform canvas.
        scrollView.drawsBackground = false

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.nsInsertionPoint
        textView.textContainerInset = contentInset
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.typingAttributes = EditorStyler.bodyAttributes

        // Accessing layoutManager pins the view to TextKit 1, whose
        // shouldGenerateGlyphs delegate is what lets us hide marker glyphs.
        textView.layoutManager?.delegate = context.coordinator

        textView.string = text
        EditorStyler.restyleAll(textView)
        context.coordinator.lastActiveParagraphStart = EditorStyler.activeParagraphRange(textView).location
        bridge?.attach(textView: textView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        (textView as? KlartTextView)?.clearsClipboardAfterCopy = clearClipboardAfterCopy
        // Only push external changes (accepted suggestions, note switches);
        // user typing already updated the binding via the delegate.
        if !context.coordinator.isEditing && textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            EditorStyler.restyleAll(textView)
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            context.coordinator.lastActiveParagraphStart = EditorStyler.activeParagraphRange(textView).location
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: MarkdownEditor
        var isEditing = false
        /// Start location of the paragraph whose markers are currently revealed,
        /// so a cursor move can re-hide it and reveal the new one.
        var lastActiveParagraphStart = 0

        // Focus dimming. Text attributes don't animate implicitly, so the
        // fade is stepped on a timer at the same pace as the sidebars.
        private var focusAmount: CGFloat = 0
        private var focusTarget: CGFloat = 0
        private var focusTimer: Timer?
        private var idleTimer: Timer?

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        deinit {
            focusTimer?.invalidate()
            idleTimer?.invalidate()
        }

        /// Re-asserts the current dim after any restyle (styling always
        /// repaints a range at full ink).
        func reapplyFocus(in textView: NSTextView) {
            guard focusAmount > 0 else { return }
            EditorStyler.applyFocus(in: textView, amount: focusAmount)
        }

        /// Writing dims the rest of the note; pausing brings it back.
        func writingActivity(in textView: NSTextView) {
            setFocus(target: 1, in: textView)
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(
                withTimeInterval: EditorStyler.focusIdleSeconds,
                repeats: false
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                self.setFocus(target: 0, in: textView)
            }
        }

        private func setFocus(target: CGFloat, in textView: NSTextView) {
            focusTarget = target
            guard focusAmount != target else { return }
            focusTimer?.invalidate()

            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                focusAmount = target
                EditorStyler.applyFocus(in: textView, amount: focusAmount)
                return
            }

            let fps: CGFloat = 60
            let step = 1 / (EditorStyler.focusFadeSeconds * fps)
            focusTimer = Timer.scheduledTimer(
                withTimeInterval: 1 / Double(fps),
                repeats: true
            ) { [weak self, weak textView] timer in
                guard let self, let textView else { timer.invalidate(); return }
                if abs(self.focusAmount - self.focusTarget) <= step {
                    self.focusAmount = self.focusTarget
                    timer.invalidate()
                    self.focusTimer = nil
                } else {
                    self.focusAmount += self.focusAmount < self.focusTarget ? step : -step
                }
                EditorStyler.applyFocus(in: textView, amount: self.focusAmount)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // A typed slash command ("/editor") is removed from the text and
            // reported via onCommand. The removal re-enters textDidChange,
            // which does the full binding/styling pass — skip our own.
            if handleSlashCommand(in: textView) { return }
            isEditing = true
            parent.text = textView.string
            isEditing = false
            EditorStyler.restyleParagraph(around: textView.selectedRange(), in: textView)
            lastActiveParagraphStart = EditorStyler.activeParagraphRange(textView).location
            writingActivity(in: textView)
            reapplyFocus(in: textView)
            // Typing (not clicking around) is what pins the line to the
            // centre — a recentre on every stray click would fight the user.
            (textView as? KlartTextView)?.centerCaretLine()
            parent.onCursorChange(textView.selectedRange().location)
            parent.onTextChange()
            parent.bridge?.bump()
        }

        /// Commands the user can type directly into the note.
        private static let slashCommands = ["editor"]

        /// Detects a just-completed slash command immediately before the
        /// cursor (at a word boundary), removes it, and fires onCommand.
        private func handleSlashCommand(in textView: NSTextView) -> Bool {
            guard let onCommand = parent.onCommand else { return false }
            let ns = textView.string as NSString
            let cursor = textView.selectedRange().location
            guard cursor <= ns.length else { return false }
            for name in Self.slashCommands {
                let token = "/" + name
                let length = (token as NSString).length
                guard cursor >= length else { continue }
                let start = cursor - length
                guard ns.substring(with: NSRange(location: start, length: length))
                    .lowercased() == token else { continue }
                // Only at a word boundary, so a pasted URL path never triggers.
                if start > 0 {
                    guard let scalar = Unicode.Scalar(ns.character(at: start - 1)),
                          CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
                }
                textView.insertText("", replacementRange: NSRange(location: start, length: length))
                // Deliver after the current AppKit event settles — the
                // handler mutates observable app state.
                DispatchQueue.main.async { onCommand(name) }
                return true
            }
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Reveal the markers on the line the cursor moved to, re-hide the
            // line it left.
            EditorStyler.refreshActiveLine(in: textView, lastActiveStart: &lastActiveParagraphStart)
            // Moving the cursor changes which paragraphs are lit, so the dim
            // has to be recomputed even when the text itself didn't change.
            reapplyFocus(in: textView)
            parent.onCursorChange(textView.selectedRange().location)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return EditorStyler.handleListContinuation(in: textView)
        }

        // MARK: NSLayoutManagerDelegate — hide marker glyphs

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font aFont: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage else { return 0 }
            let count = glyphRange.length
            var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
            var changed = false
            for i in 0..<count {
                var property = props[i]
                let charIndex = charIndexes[i]
                if charIndex < storage.length,
                   storage.attribute(.klartHiddenMarker, at: charIndex, effectiveRange: nil) != nil {
                    property.insert(.null)   // zero-width, non-drawn glyph
                    changed = true
                }
                newProps[i] = property
            }
            guard changed else { return 0 }   // 0 → let the layout manager proceed normally
            newProps.withUnsafeBufferPointer { buffer in
                layoutManager.setGlyphs(
                    glyphs,
                    properties: buffer.baseAddress!,
                    characterIndexes: charIndexes,
                    font: aFont,
                    forGlyphRange: glyphRange
                )
            }
            return count
        }
    }
}

enum EditorStyler {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static func boldFont(ofSize size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .semibold)
    }
    static func italicFont(ofSize size: CGFloat) -> NSFont {
        let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
    }
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    static let textColor = Theme.nsTextPrimary
    static let quoteColor = Theme.nsTextSecondary
    static let syntaxColor = Theme.nsTextTertiary
    /// Accent-tinted normally, gray in Teleprompter (monochrome). Computed
    /// so it's resolved at styling time, not frozen at first use.
    static var markerColor: NSColor { Theme.nsMarker }

    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: #"^\s{0,8}(?:[-*+]|\d{1,3}[.)])(?=\s)"#
    )
    private static let taskCheckboxRegex = try! NSRegularExpression(
        pattern: #"^\[([ xX])\]\s"#
    )
    private static let boldRegex = try! NSRegularExpression(
        pattern: #"(?<!\\)\*\*(?!\s)(?:[^*\n]|\*(?!\*))+?(?<!\s)\*\*"#
    )
    private static let italicRegex = try! NSRegularExpression(
        pattern: #"(?<![\w*_\\])[*_](?![\s*_])[^*_\n]+?(?<![\s*_])[*_](?![\w*_])"#
    )
    private static let codeRegex = try! NSRegularExpression(
        pattern: #"(?<!\\)`[^`\n]+`"#
    )
    private static let strikethroughRegex = try! NSRegularExpression(
        pattern: #"(?<!\\)~~(?!\s)[^~\n]+?(?<!\s)~~"#
    )
    private static let codeFenceRegex = try! NSRegularExpression(
        pattern: #"^\s{0,3}(?:`{3,}|~{3,})"#
    )
    private static let horizontalRuleRegex = try! NSRegularExpression(
        pattern: #"^\s{0,3}(?:-\s*){3,}$|^\s{0,3}(?:\*\s*){3,}$|^\s{0,3}(?:_\s*){3,}$"#
    )

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4.5
        style.paragraphSpacing = 4
        return style
    }

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 26, weight: .semibold)
        case 2: return .systemFont(ofSize: 20, weight: .semibold)
        case 3: return .systemFont(ofSize: 17, weight: .semibold)
        default: return .systemFont(ofSize: 15, weight: .semibold)
        }
    }

    // MARK: Focus dimming

    /// Matched to the Teleprompter's sidebar spring, so the whole surface
    /// moves at one speed.
    static let focusFadeSeconds: CGFloat = 2.0
    /// Writing stops for this long and the note comes back up to full ink.
    static let focusIdleSeconds: Double = 2.0
    /// How far a dimmed paragraph travels toward the background. Not all the
    /// way: the rest of the note stays legible context, it just stops
    /// competing with the line being written.
    static let focusDimMax: CGFloat = 0.62

    /// Sinks every paragraph except the live ones toward the background.
    /// `amount` is 0 (all ink) to 1 (fully dimmed) and is stepped frame by
    /// frame by the coordinator — `NSTextStorage` attributes have no implicit
    /// animation, so the fade has to be driven by hand.
    static func applyFocus(in textView: NSTextView, amount: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        guard let background = Theme.nsBackground.usingColorSpace(.sRGB) else { return }
        let full = NSRange(location: 0, length: storage.length)
        let lit = focusRanges(in: textView)

        storage.beginEditing()
        storage.enumerateAttribute(.klartBaseColor, in: full, options: []) { value, range, _ in
            guard let base = value as? NSColor else { return }
            let isLit = lit.contains { NSIntersectionRange($0, range).length > 0 }
            let fraction = isLit ? 0 : amount * focusDimMax
            let resolved: NSColor
            if fraction <= 0.001 {
                resolved = base
            } else if let srgb = base.usingColorSpace(.sRGB),
                      let blended = srgb.blended(withFraction: fraction, of: background) {
                resolved = blended
            } else {
                resolved = base
            }
            storage.addAttribute(.foregroundColor, value: resolved, range: range)
        }
        storage.endEditing()
    }

    /// How many lines above the one being written stay at full ink. Blank
    /// lines count toward this budget: the gaps between blocks are part of
    /// what the eye is travelling over, so they must not buy extra lit text.
    static let focusLinesAbove = 3

    /// The line being written plus exactly `focusLinesAbove` lines above it,
    /// counting blank lines. A short, fixed window — everything older sinks
    /// back regardless of where the paragraph breaks fall.
    private static func focusRanges(in textView: NSTextView) -> [NSRange] {
        let ns = textView.string as NSString
        let active = activeParagraphRange(textView)
        var ranges = [active]

        var probe = active.location - 1
        var taken = 0
        while probe >= 0, taken < focusLinesAbove {
            let previous = ns.paragraphRange(for: NSRange(location: probe, length: 0))
            ranges.append(previous)
            taken += 1
            if previous.location == 0 { break }
            probe = previous.location - 1
        }
        return ranges
    }

    /// The paragraph range under the cursor — its markers stay visible so the
    /// raw markdown is always editable.
    static func activeParagraphRange(_ textView: NSTextView) -> NSRange {
        let ns = textView.string as NSString
        let location = min(textView.selectedRange().location, ns.length)
        return ns.paragraphRange(for: NSRange(location: location, length: 0))
    }

    static func restyleAll(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        style(storage, in: NSRange(location: 0, length: storage.length),
              activeParagraph: activeParagraphRange(textView))
        textView.typingAttributes = bodyAttributes
    }

    static func restyleParagraph(around selection: NSRange, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let location = min(selection.location, ns.length)
        let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
        // The edited paragraph is the active one, so keep its markers visible.
        style(storage, in: paragraph, activeParagraph: paragraph)
    }

    /// On a cursor move: reveal the markers on the newly active line and re-hide
    /// the line the cursor left. Touches at most two paragraphs, so it stays
    /// cheap on every selection change.
    static func refreshActiveLine(in textView: NSTextView, lastActiveStart: inout Int) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let active = activeParagraphRange(textView)
        guard active.location != lastActiveStart else { return }
        style(storage, in: active, activeParagraph: active)
        if lastActiveStart >= 0, lastActiveStart <= ns.length {
            let previous = ns.paragraphRange(for: NSRange(location: min(lastActiveStart, ns.length), length: 0))
            if previous.location != active.location {
                style(storage, in: previous, activeParagraph: active)
            }
        }
        lastActiveStart = active.location
    }

    private static func style(_ storage: NSTextStorage, in range: NSRange, activeParagraph: NSRange) {
        guard range.length > 0 || storage.length == 0 else {
            return
        }
        let ns = storage.string as NSString
        storage.beginEditing()
        storage.addAttributes(bodyAttributes, range: range)
        // Clear any stale hidden-marker flags first, so revealing a line (by
        // restyling it as active) actually shows its markers again.
        storage.removeAttribute(.klartHiddenMarker, range: range)

        // Fenced code blocks span multiple lines, so a per-paragraph restyle
        // needs to know whether it's starting inside an already-open fence —
        // found by scanning fence markers from the top of the document. This
        // is a plain string scan (no attribute writes), so it's cheap even
        // though it reruns on every edit.
        var insideCodeBlock = codeBlockOpen(before: range.location, in: ns)

        ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = ns.substring(with: lineRange)
            // Markers are hidden on every line except the one being edited.
            let hideMarkers = !NSLocationInRange(lineRange.location, activeParagraph)

            if isCodeFenceLine(line) {
                insideCodeBlock.toggle()
                storage.addAttributes([.font: codeFont, .foregroundColor: syntaxColor], range: lineRange)
                return
            }
            if insideCodeBlock {
                // Inside a fence, the line is verbatim code — never headings,
                // lists, or emphasis, no matter what characters it contains.
                storage.addAttributes([.font: codeFont, .foregroundColor: textColor], range: lineRange)
                return
            }

            if let level = MarkdownHeading.level(of: line) {
                // The leading "#…# " marker renders at body size and dimmed while
                // you edit the line, and is hidden entirely otherwise — so only
                // the heading text shows once the heading is defined.
                let markerLength = min(level + 1, lineRange.length)
                let markerRange = NSRange(location: lineRange.location, length: markerLength)
                let textRange = NSRange(
                    location: lineRange.location + markerLength,
                    length: lineRange.length - markerLength
                )
                storage.addAttribute(.font, value: bodyFont, range: markerRange)
                storage.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
                storage.addAttribute(.font, value: headingFont(level: level), range: textRange)
                // A heading can still carry bold/italic/code/strikethrough —
                // style it at the heading's own size so emphasis doesn't
                // shrink back down to body text.
                styleInline(line, lineRange: lineRange, in: storage,
                            emphasisFontSize: headingFont(level: level).pointSize, hideMarkers: hideMarkers)
                if hideMarkers {
                    storage.addAttribute(.klartHiddenMarker, value: true, range: markerRange)
                }
            } else if isHorizontalRule(line) {
                storage.addAttribute(.foregroundColor, value: markerColor, range: lineRange)
            } else if line.hasPrefix(">") {
                storage.addAttributes([
                    .foregroundColor: quoteColor,
                    .font: NSFont.systemFont(ofSize: 14),
                ], range: lineRange)
                // Quoted text can still carry emphasis, code, etc. — style it
                // the same as a normal line so it isn't silently dropped.
                styleInline(line, lineRange: lineRange, in: storage, hideMarkers: hideMarkers)
            } else {
                styleListMarker(line, lineRange: lineRange, in: storage)
                styleInline(line, lineRange: lineRange, in: storage, hideMarkers: hideMarkers)
            }
        }
        // Every run's colour is now final for this pass — record it as the
        // base the focus fade interpolates from. Styling always resets
        // `.foregroundColor` to full ink, so the caller re-applies the
        // current dim afterwards.
        storage.enumerateAttribute(.foregroundColor, in: range, options: []) { value, sub, _ in
            guard let color = value as? NSColor else { return }
            storage.addAttribute(.klartBaseColor, value: color, range: sub)
        }
        storage.endEditing()
    }

    private static func isCodeFenceLine(_ line: String) -> Bool {
        let full = NSRange(location: 0, length: (line as NSString).length)
        return codeFenceRegex.firstMatch(in: line, range: full) != nil
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let full = NSRange(location: 0, length: (line as NSString).length)
        return horizontalRuleRegex.firstMatch(in: line, range: full) != nil
    }

    /// Whether an unclosed code fence is open at `location`, determined by
    /// counting fence-marker lines from the start of the document.
    private static func codeBlockOpen(before location: Int, in ns: NSString) -> Bool {
        guard location > 0 else { return false }
        var open = false
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: location),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            if isCodeFenceLine(ns.substring(with: lineRange)) {
                open.toggle()
            }
        }
        return open
    }

    /// Tints `- ` / `* ` / `+ ` / `1. ` markers so lists read as lists, and
    /// renders `- [ ]` / `- [x]` as a task item — dimming the checkbox and,
    /// once checked, striking through the item's text.
    private static func styleListMarker(_ line: String, lineRange: NSRange, in storage: NSTextStorage) {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = listMarkerRegex.firstMatch(in: line, range: full) else { return }
        storage.addAttribute(
            .foregroundColor,
            value: markerColor,
            range: NSRange(location: lineRange.location + match.range.location, length: match.range.length)
        )

        let afterMarker = match.range.location + match.range.length + 1 // skip the required space
        guard afterMarker <= ns.length else { return }
        let remainder = ns.substring(from: afterMarker)
        guard let checkbox = taskCheckboxRegex.firstMatch(
            in: remainder,
            range: NSRange(location: 0, length: (remainder as NSString).length)
        ) else { return }

        let checkboxRange = NSRange(location: lineRange.location + afterMarker, length: checkbox.range.length)
        storage.addAttribute(.foregroundColor, value: markerColor, range: checkboxRange)

        let isChecked = (remainder as NSString).substring(with: checkbox.range(at: 1)).lowercased() == "x"
        if isChecked {
            let textStart = checkboxRange.location + checkboxRange.length
            let textRange = NSRange(location: textStart, length: lineRange.location + lineRange.length - textStart)
            guard textRange.length > 0 else { return }
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: quoteColor,
            ], range: textRange)
        }
    }

    private struct ListMarker {
        let indent: String
        let marker: String
        /// Location (in the line) of the first character after the marker,
        /// not including the single required space the regex looks ahead for.
        let markerEndLocation: Int
    }

    private static func matchListMarker(in line: String) -> ListMarker? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = listMarkerRegex.firstMatch(in: line, range: full) else { return nil }
        let matched = ns.substring(with: match.range)
        let indentLength = matched.prefix { $0 == " " || $0 == "\t" }.count
        return ListMarker(
            indent: String(matched.prefix(indentLength)),
            marker: String(matched.dropFirst(indentLength)),
            markerEndLocation: match.range.location + match.range.length
        )
    }

    /// Continues `- ` / `* ` / `+ ` / `1. ` lists onto the next line when the
    /// user presses Enter, incrementing ordered-list numbers as it goes.
    /// Pressing Enter again on an empty item exits the list instead of adding
    /// another empty marker. Returns whether it handled the newline itself.
    static func handleListContinuation(in textView: NSTextView) -> Bool {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()

        // Use the paragraph's content range only (excludes the trailing "\n"),
        // so clearing an empty item's marker below never eats the newline and
        // merges into the following line.
        var start = 0, contentsEnd = 0
        ns.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(selection.location, ns.length), length: 0))
        let lineRange = NSRange(location: start, length: contentsEnd - start)
        let line = ns.substring(with: lineRange)
        // Don't treat a "- " line inside a fenced code block as a list —
        // it's verbatim code (e.g. YAML), not markdown. Likewise a horizontal
        // rule like "- - -" matches the list-marker pattern but is styled and
        // meant as a rule, not a list item.
        guard !codeBlockOpen(before: lineRange.location, in: ns) else { return false }
        guard !isHorizontalRule(line) else { return false }
        guard let listMarker = matchListMarker(in: line) else { return false }

        let contentStart = min(listMarker.markerEndLocation + 1, (line as NSString).length)
        let restOfLine = (line as NSString).substring(from: contentStart)

        if restOfLine.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty list item: pressing Enter here exits the list rather than
            // continuing it with another empty marker.
            textView.insertText("", replacementRange: lineRange)
            return true
        }

        let nextMarker: String
        if listMarker.marker.count > 1,
           let punctuation = listMarker.marker.last, punctuation == "." || punctuation == ")",
           let number = Int(listMarker.marker.dropLast()) {
            nextMarker = "\(listMarker.indent)\(number + 1)\(punctuation) "
        } else {
            nextMarker = "\(listMarker.indent)\(listMarker.marker) "
        }

        textView.insertText("\n" + nextMarker, replacementRange: selection)
        return true
    }

    /// Live inline markdown: **bold**, *italic* / _italic_, `code`, ~~strike~~.
    /// The surrounding syntax markers are dimmed while you edit the line and
    /// hidden otherwise, so the text reads like the rendered result while
    /// staying plain markdown on disk.
    private static func styleInline(
        _ line: String,
        lineRange: NSRange,
        in storage: NSTextStorage,
        emphasisFontSize: CGFloat = bodyFont.pointSize,
        hideMarkers: Bool = false
    ) {
        let full = NSRange(location: 0, length: (line as NSString).length)
        let emphasisBoldFont = boldFont(ofSize: emphasisFontSize)
        let emphasisItalicFont = italicFont(ofSize: emphasisFontSize)

        codeRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttributes([.font: codeFont, .foregroundColor: quoteColor], range: range)
            markEdges(of: range, width: 1, in: storage, hide: hideMarkers)
        }
        boldRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttribute(.font, value: emphasisBoldFont, range: range)
            markEdges(of: range, width: 2, in: storage, hide: hideMarkers)
        }
        italicRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttribute(.font, value: emphasisItalicFont, range: range)
            markEdges(of: range, width: 1, in: storage, hide: hideMarkers)
        }
        strikethroughRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            markEdges(of: range, width: 2, in: storage, hide: hideMarkers)
        }
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    /// The `width` syntax characters at each end of `range` are the emphasis
    /// markers: hide them (live preview) or dim them (while editing the line).
    private static func markEdges(of range: NSRange, width: Int, in storage: NSTextStorage, hide: Bool) {
        guard range.length >= width * 2 else { return }
        let head = NSRange(location: range.location, length: width)
        let tail = NSRange(location: range.location + range.length - width, length: width)
        if hide {
            storage.addAttribute(.klartHiddenMarker, value: true, range: head)
            storage.addAttribute(.klartHiddenMarker, value: true, range: tail)
        } else {
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: head)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: tail)
        }
    }
}
#endif
