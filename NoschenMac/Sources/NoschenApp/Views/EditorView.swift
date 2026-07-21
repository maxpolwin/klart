#if os(macOS)
import SwiftUI
import AppKit
import NoschenKit

struct EditorView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        MarkdownEditor(
            text: $state.editorText,
            onTextChange: { state.editorTextChanged() },
            onCursorChange: { state.cursorUTF16 = $0 }
        )
        .background(Theme.background)
        .id(state.selectedNoteID) // fresh editor (and undo stack) per note
    }
}

/// Plain-text markdown editor with live, lightweight styling: headings get
/// larger fonts, quote lines are dimmed. Styling is applied per edited
/// paragraph, so typing stays fast in large documents.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var onTextChange: () -> Void
    var onCursorChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

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

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.string = text
        EditorStyler.restyleAll(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
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
            isEditing = true
            parent.text = textView.string
            isEditing = false
            EditorStyler.restyleParagraph(around: textView.selectedRange(), in: textView)
            parent.onCursorChange(textView.selectedRange().location)
            parent.onTextChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onCursorChange(textView.selectedRange().location)
        }
    }
}

enum EditorStyler {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let boldFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let italicFont: NSFont = {
        let descriptor = NSFont.systemFont(ofSize: 15).fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 15) ?? .systemFont(ofSize: 15)
    }()
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    static let textColor = Theme.nsTextPrimary
    static let quoteColor = Theme.nsTextSecondary
    static let syntaxColor = Theme.nsTextTertiary
    static let markerColor = Theme.nsAccentMuted

    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: #"^\s{0,8}(?:[-*+]|\d{1,3}[.)])(?=\s)"#
    )
    private static let boldRegex = try! NSRegularExpression(
        pattern: #"\*\*(?!\s)(?:[^*\n]|\*(?!\*))+?(?<!\s)\*\*"#
    )
    private static let italicRegex = try! NSRegularExpression(
        pattern: #"(?<![\w*_])[*_](?![\s*_])[^*_\n]+?(?<![\s*_])[*_](?![\w*_])"#
    )
    private static let codeRegex = try! NSRegularExpression(
        pattern: #"`[^`\n]+`"#
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
        ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = ns.substring(with: lineRange)
            if let level = headingLevel(of: line) {
                storage.addAttribute(.font, value: headingFont(level: level), range: lineRange)
                // Dim the leading # markers so headings read as headings.
                let markerLength = min(level + 1, lineRange.length)
                storage.addAttribute(
                    .foregroundColor,
                    value: markerColor,
                    range: NSRange(location: lineRange.location, length: markerLength)
                )
            } else if line.hasPrefix(">") {
                storage.addAttributes([
                    .foregroundColor: quoteColor,
                    .font: NSFont.systemFont(ofSize: 14),
                ], range: lineRange)
            } else {
                styleListMarker(line, lineRange: lineRange, in: storage)
                styleInline(line, lineRange: lineRange, in: storage)
            }
        }
        storage.endEditing()
    }

    /// Tints `- ` / `* ` / `+ ` / `1. ` markers so lists read as lists.
    private static func styleListMarker(_ line: String, lineRange: NSRange, in storage: NSTextStorage) {
        let full = NSRange(location: 0, length: (line as NSString).length)
        guard let match = listMarkerRegex.firstMatch(in: line, range: full) else { return }
        storage.addAttribute(
            .foregroundColor,
            value: markerColor,
            range: NSRange(location: lineRange.location + match.range.location, length: match.range.length)
        )
    }

    /// Live inline markdown: **bold**, *italic* / _italic_, `code`.
    /// The surrounding syntax markers are dimmed rather than hidden, so the
    /// text stays plain markdown while reading like the rendered result.
    private static func styleInline(_ line: String, lineRange: NSRange, in storage: NSTextStorage) {
        let full = NSRange(location: 0, length: (line as NSString).length)

        codeRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttributes([.font: codeFont, .foregroundColor: quoteColor], range: range)
            dimEdges(of: range, width: 1, in: storage)
        }
        boldRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttribute(.font, value: boldFont, range: range)
            dimEdges(of: range, width: 2, in: storage)
        }
        italicRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            let range = shifted(match.range, by: lineRange.location)
            storage.addAttribute(.font, value: italicFont, range: range)
            dimEdges(of: range, width: 1, in: storage)
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

    private static func headingLevel(of line: String) -> Int? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard level >= 1, level <= 6, rest.first == " " || rest.isEmpty else { return nil }
        return level
    }
}
#endif
