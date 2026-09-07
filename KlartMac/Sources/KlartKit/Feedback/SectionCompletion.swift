import Foundation

/// Decides when a section is worth reading: not on every pause in typing,
/// but when the writer is done with it.
///
/// Gap and structure critique is higher-order feedback, and the evidence on
/// timing says higher-order feedback lands better delayed than immediate —
/// and a note on a half-written section mostly flags what the writer was
/// about to write next. So the editor reads a section when the caret leaves
/// it after editing it (moving on, or opening a new heading beneath it), or
/// after a long pause; the app layer owns the pause timer, this tracker owns
/// "was it edited, and did the caret leave".
///
/// Pure value type so the rule is testable without an editor.
public struct SectionCompletionTracker: Equatable, Sendable {
    /// The section being edited, identified by its heading start; nil when
    /// nothing has been typed since the last read, or the edit was outside
    /// any heading.
    public private(set) var editedSectionStart: Int?
    /// Which section the caret was in on the last cursor report.
    private var caretSectionStart: Int?
    /// Fingerprints of section bodies as they stood when last read, keyed by
    /// heading start, so re-entering a section and leaving it unchanged does
    /// not read it again.
    private var readBodies: [Int: String] = [:]

    public init() {}

    /// A section the writer has just finished with, and where to point the
    /// analysis (a UTF-16 offset inside it).
    public struct Completed: Equatable, Sendable {
        public let headingStart: Int
        public let cursorUTF16: Int
    }

    /// The writer typed at `cursorUTF16`.
    public mutating func noteEdit(at cursorUTF16: Int, in text: String) {
        let outline = DocumentOutline.parse(text)
        let section = outline.section(atUTF16Offset: cursorUTF16)
        editedSectionStart = section?.headingStart ?? -1
        caretSectionStart = editedSectionStart
    }

    /// The caret moved to `cursorUTF16`. Returns the section just left when
    /// it was edited since it was last read and its body actually changed.
    public mutating func caretMoved(to cursorUTF16: Int, in text: String) -> Completed? {
        let outline = DocumentOutline.parse(text)
        let now = outline.section(atUTF16Offset: cursorUTF16)?.headingStart ?? -1
        defer { caretSectionStart = now }
        guard let edited = editedSectionStart, edited != now else { return nil }
        return complete(edited, in: outline, text: text)
    }

    /// The pause timer fired: the section under the caret is done for now.
    public mutating func pauseElapsed(at cursorUTF16: Int, in text: String) -> Completed? {
        guard let edited = editedSectionStart else { return nil }
        let outline = DocumentOutline.parse(text)
        return complete(edited, in: outline, text: text)
    }

    /// The editor read this section on demand; remember its body so the next
    /// signal for it is not a repeat.
    public mutating func markRead(at cursorUTF16: Int, in text: String) {
        let outline = DocumentOutline.parse(text)
        let section = outline.section(atUTF16Offset: cursorUTF16)
        let start = section?.headingStart ?? -1
        readBodies[start] = fingerprint(of: section, in: text)
        if editedSectionStart == start { editedSectionStart = nil }
    }

    /// Forget everything — a different note is in the editor.
    public mutating func reset() {
        self = SectionCompletionTracker()
    }

    private mutating func complete(_ start: Int, in outline: DocumentOutline, text: String) -> Completed? {
        editedSectionStart = nil
        let section = outline.sections.first { $0.headingStart == start }
        // The section was deleted out from under the caret (heading removed):
        // nothing to read.
        if start >= 0, section == nil { return nil }
        let body = fingerprint(of: section, in: text)
        guard readBodies[start] != body else { return nil }
        readBodies[start] = body
        let cursor = section.map { min($0.bodyStart, max(0, text.utf16.count)) } ?? 0
        return Completed(headingStart: start, cursorUTF16: cursor)
    }

    private func fingerprint(of section: OutlineSection?, in text: String) -> String {
        let body = section.map { DocumentOutline.body(of: $0, in: text) } ?? text
        return StableHash.fnv1a(body)
    }
}
