#if os(macOS)
import SwiftUI
import AppKit
import KlartKit

private extension NSAttributedString.Key {
    /// Marks syntax characters (heading `#`s, emphasis `*_`` ` ``~`) that should
    /// be hidden from layout while the cursor is on another line — the
    /// live-preview effect. The layout manager delegate nulls these glyphs.
    static let klartHiddenMarker = NSAttributedString.Key("klartHiddenMarker")
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

/// Plain-text markdown editor with live styling: headings get larger fonts and
/// their `#` markers are hidden (revealed only on the line you're editing), and
/// emphasis markers dim/hide the same way — so notes read like rendered
/// markdown while the text on disk stays plain markdown. Styling is applied per
/// edited paragraph, so typing stays fast in large documents.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var clearClipboardAfterCopy = false
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
        textView.insertionPointColor = Theme.nsAccent
        textView.textContainerInset = NSSize(width: 32, height: 28)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.typingAttributes = EditorStyler.bodyAttributes

        // Accessing layoutManager pins the view to TextKit 1, whose
        // shouldGenerateGlyphs delegate is what lets us hide marker glyphs.
        textView.layoutManager?.delegate = context.coordinator

        textView.string = text
        EditorStyler.restyleAll(textView)
        context.coordinator.lastActiveParagraphStart = EditorStyler.activeParagraphRange(textView).location
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

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = textView.string
            isEditing = false
            EditorStyler.restyleParagraph(around: textView.selectedRange(), in: textView)
            lastActiveParagraphStart = EditorStyler.activeParagraphRange(textView).location
            parent.onCursorChange(textView.selectedRange().location)
            parent.onTextChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Reveal the markers on the line the cursor moved to, re-hide the
            // line it left.
            EditorStyler.refreshActiveLine(in: textView, lastActiveStart: &lastActiveParagraphStart)
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
    static let markerColor = Theme.nsAccentMuted

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
