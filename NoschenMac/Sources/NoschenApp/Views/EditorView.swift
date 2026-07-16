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
        textView.insertionPointColor = NSColor(Theme.accent)
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
    static let textColor = NSColor(Theme.textPrimary)
    static let quoteColor = NSColor(Theme.textSecondary)
    static let markerColor = NSColor(Theme.accent).withAlphaComponent(0.85)

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
        case 1: return .systemFont(ofSize: 25, weight: .bold)
        case 2: return .systemFont(ofSize: 19, weight: .semibold)
        case 3: return .systemFont(ofSize: 16.5, weight: .semibold)
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
            }
        }
        storage.endEditing()
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
