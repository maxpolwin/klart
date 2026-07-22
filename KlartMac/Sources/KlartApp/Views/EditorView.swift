#if os(macOS)
import SwiftUI
import AppKit
import KlartKit

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

/// Plain-text markdown editor with live, lightweight styling: headings get
/// larger fonts, quote lines are dimmed. Styling is applied per edited
/// paragraph, so typing stays fast in large documents.
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

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.string = text
        EditorStyler.restyleAll(textView)
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
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var isEditing = false

        init(_ parent: MarkdownEditor) {
            self.parent = parent
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
            parent.onCursorChange(textView.selectedRange().location)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return EditorStyler.handleListContinuation(in: textView)
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

    static func restyleAll(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        style(storage, in: NSRange(location: 0, length: storage.length))
        textView.typingAttributes = bodyAttributes
    }

    static func restyleParagraph(around selection: NSRange, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let location = min(selection.location, ns.length)
        let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
        style(storage, in: paragraph)
    }

    private static func style(_ storage: NSTextStorage, in range: NSRange) {
        guard range.length > 0 || storage.length == 0 else {
            return
        }
        let ns = storage.string as NSString
        storage.beginEditing()
        storage.addAttributes(bodyAttributes, range: range)

        // Fenced code blocks span multiple lines, so a per-paragraph restyle
        // needs to know whether it's starting inside an already-open fence —
        // found by scanning fence markers from the top of the document. This
        // is a plain string scan (no attribute writes), so it's cheap even
        // though it reruns on every edit.
        var insideCodeBlock = codeBlockOpen(before: range.location, in: ns)

        ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = ns.substring(with: lineRange)

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
                // Keep the leading # marker at body size and dimmed, so only the
                // actual heading text is enlarged — otherwise the marker itself
                // renders at heading size and stays as visible as a plain "#".
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
                styleInline(line, lineRange: lineRange, in: storage, emphasisFontSize: headingFont(level: level).pointSize)
            } else if isHorizontalRule(line) {
                storage.addAttribute(.foregroundColor, value: markerColor, range: lineRange)
            } else if line.hasPrefix(">") {
                storage.addAttributes([
                    .foregroundColor: quoteColor,
                    .font: NSFont.systemFont(ofSize: 14),
                ], range: lineRange)
                // Quoted text can still carry emphasis, code, etc. — style it
                // the same as a normal line so it isn't silently dropped.
                styleInline(line, lineRange: lineRange, in: storage)
            } else {
                styleListMarker(line, lineRange: lineRange, in: storage)
                styleInline(line, lineRange: lineRange, in: storage)
            }
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

    /// Live inline markdown: **bold**, *italic* / _italic_, `code`.
    /// The surrounding syntax markers are dimmed rather than hidden, so the
    /// text stays plain markdown while reading like the rendered result.
    private static func styleInline(
        _ line: String,
        lineRange: NSRange,
        in storage: NSTextStorage,
        emphasisFontSize: CGFloat = bodyFont.pointSize
    ) {
        let full = NSRange(location: 0, length: (line as NSString).length)
        let emphasisBoldFont = boldFont(ofSize: emphasisFontSize)
        let emphasisItalicFont = italicFont(ofSize: emphasisFontSize)

        codeRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttributes([.font: codeFont, .foregroundColor: quoteColor], range: range)
            dimEdges(of: range, width: 1, in: storage)
        }
        boldRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttribute(.font, value: emphasisBoldFont, range: range)
            dimEdges(of: range, width: 2, in: storage)
        }
        italicRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttribute(.font, value: emphasisItalicFont, range: range)
            dimEdges(of: range, width: 1, in: storage)
        }
        strikethroughRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            dimEdges(of: range, width: 2, in: storage)
        }
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func dimEdges(of range: NSRange, width: Int, in storage: NSTextStorage) {
        guard range.length >= width * 2 else { return }
        storage.addAttribute(
            .foregroundColor, value: syntaxColor,
            range: NSRange(location: range.location, length: width)
        )
        storage.addAttribute(
            .foregroundColor, value: syntaxColor,
            range: NSRange(location: range.location + range.length - width, length: width)
        )
    }
}
#endif
