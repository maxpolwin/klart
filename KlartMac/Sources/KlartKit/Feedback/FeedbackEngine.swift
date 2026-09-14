import Foundation

/// Orchestrates one analysis round: derive context from the document, run
/// the offline checks, build the prompt, call the model, parse, verify, and
/// merge. Stateless between calls — triggering and cancellation live in the
/// app layer via Task cancellation.
public struct FeedbackEngine: Sendable {
    /// Minimum content length before analysis is worth running.
    public static let minimumContentLength = 80

    public init() {}

    public enum SkipReason: Equatable, Sendable {
        case tooShort
        case sectionExcluded
        case noKindsEnabled
    }

    public enum Outcome: Sendable {
        case skipped(SkipReason)
        case items([FeedbackItem])
    }

    /// The offline pass alone: instant, no provider needed. The app shows
    /// these while the model is still reading, and lists them in the prompt
    /// so the model does not repeat them.
    public func localItems(
        text: String,
        cursorUTF16: Int,
        rejectedFingerprints: Set<String>
    ) -> [FeedbackItem] {
        LocalChecks.run(text: text, cursorUTF16: cursorUTF16)
            .filter { !rejectedFingerprints.contains($0.fingerprint) }
    }

    /// The model pass. `local` is what `localItems` produced for the same
    /// text, merged into the result ahead of the model's notes.
    public func analyze(
        text: String,
        cursorUTF16: Int,
        settings: AppSettings,
        rejectedFingerprints: Set<String>,
        local: [FeedbackItem] = [],
        client: any LLMClient
    ) async throws -> Outcome {
        let kinds = settings.enabledFeedbackKinds.filter { $0 != .other }
        guard !kinds.isEmpty else { return .skipped(.noKindsEnabled) }
        guard let context = PromptContext.from(text: text, cursorUTF16: cursorUTF16) else {
            return .skipped(.sectionExcluded)
        }
        guard context.currentSectionBody.count >= Self.minimumContentLength else {
            return .skipped(.tooShort)
        }

        let messages = PromptBuilder.feedbackMessages(
            context: context,
            kinds: kinds,
            style: settings.tipStyle,
            alreadyFlagged: local,
            template: settings.effectiveFeedbackPrompt
        )
        let options = CompletionOptions(
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            jsonMode: true
        )
        let raw = try await client.complete(
            messages,
            model: settings.activeConfig.model,
            options: options
        )
        try Task.checkCancellation()

        // Every item the model returns is about the section it was asked
        // about, but the JSON shape never asks it to say so and it almost
        // never volunteers it. Left nil, the margin rail has no anchor to
        // align a card against. Stamp the section we already know rather
        // than asking the model to echo a title back: a hallucinated or
        // paraphrased heading fails the outline lookup and lands the card at
        // the top of the window. `id` is carried across so a re-stamped item
        // is the same card to SwiftUI.
        //
        // The anchor is verified the same way: a quote that is not in the
        // section is dropped rather than shown, so the writer never hunts
        // for words the model made up.
        let modelItems = FeedbackParser.parse(raw)
            .map { item -> FeedbackItem in
                var out = item
                let named = item.section?.trimmingCharacters(in: .whitespacesAndNewlines)
                if named?.isEmpty ?? true { out = out.stamped(section: context.currentSectionTitle) }
                if let anchor = out.anchor, !Self.contains(context.currentSectionBody, anchor) {
                    out = out.withoutAnchor()
                }
                return out
            }
            .filter { !rejectedFingerprints.contains($0.fingerprint) }
            .prefix(settings.tipStyle.maxTips)

        return .items(Self.ordered(local + modelItems))
    }

    /// Local notes first within a severity, most severe first overall. The
    /// rail lays cards out by section anyway; this decides the order within
    /// one.
    public static func ordered(_ items: [FeedbackItem]) -> [FeedbackItem] {
        items.enumerated().sorted { a, b in
            if a.element.severity != b.element.severity { return a.element.severity > b.element.severity }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Whitespace-insensitive, case-insensitive containment — the model
    /// normalizes spacing and quotes when it copies.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        func fold(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "[“”\"'‘’`]", with: "", options: .regularExpression)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        let n = fold(needle)
        guard !n.isEmpty else { return false }
        return fold(haystack).contains(n)
    }
}

/// Pure text edit helpers shared by the app (kept here so they're testable).
public enum NoteEditing {
    /// Where a response block landed and where the caret should go.
    public struct Response: Equatable, Sendable {
        public let text: String
        /// UTF-16 offset of the empty line under the block, for the caret.
        public let caretUTF16: Int
    }

    /// Drops the note into the section it refers to as a quoted prompt and
    /// leaves an empty line under it for the writer's own words. The block
    /// carries the observation, never a fix: the writer answers in their own
    /// words, which is what the app is for.
    ///
    /// Lands at the end of the section the note names; falls back to the
    /// cursor's section, then the end of the document.
    public static func respond(to item: FeedbackItem, in text: String, cursorUTF16: Int) -> Response {
        var lines = ["> ✎ \(item.kind.label)"]
        if let anchor = item.anchor { lines[0] += " — “\(anchor)”" }
        lines[0] += ": " + item.text.replacingOccurrences(of: "\n", with: " ")
        if let why = item.why { lines.append("> " + why.replacingOccurrences(of: "\n", with: " ")) }
        let block = lines.joined(separator: "\n")

        let outline = DocumentOutline.parse(text)
        let named = item.section?.trimmingCharacters(in: .whitespaces).lowercased()
        let target = outline.sections.first { named != nil && $0.title.lowercased() == named }
            ?? outline.section(atUTF16Offset: cursorUTF16)

        let ns = text as NSString
        let insertAt = target.map { min($0.bodyEnd, ns.length) } ?? ns.length
        let before = ns.substring(to: insertAt)
        let after = ns.substring(from: insertAt)

        // One blank line between the section's last line and the block.
        let separator: String
        if before.isEmpty || before.hasSuffix("\n\n") { separator = "" }
        else if before.hasSuffix("\n") { separator = "\n" }
        else { separator = "\n\n" }

        // The block, a line break, then the empty line the caret lands on.
        // A section end sits on the next heading's line, so when something
        // follows, one more blank line keeps the heading clear of the answer.
        let head = before + separator + block + "\n"
        let tail = after.isEmpty ? "" : "\n" + after
        return Response(text: head + tail, caretUTF16: head.utf16.count)
    }
}
