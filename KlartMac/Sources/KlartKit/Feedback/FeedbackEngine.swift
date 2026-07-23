import Foundation

/// Orchestrates one analysis round: derive context from the document, build
/// the prompt, call the model, parse, and filter. Stateless between calls —
/// debouncing and cancellation live in the app layer via Task cancellation.
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

    public func analyze(
        text: String,
        cursorUTF16: Int,
        settings: AppSettings,
        rejectedFingerprints: Set<String>,
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

        let items = FeedbackParser.parse(raw)
            .filter { !rejectedFingerprints.contains($0.fingerprint) }
        return .items(Array(items.prefix(settings.tipStyle.maxTips)))
    }
}

/// Pure text edit helpers shared by the app (kept here so they're testable).
public enum NoteEditing {
    /// Inserts an accepted suggestion at the end of the section containing
    /// the cursor (or at the end of the document), as a quoted block the
    /// author can rework in their own words.
    public static func insertSuggestion(_ item: FeedbackItem, into text: String, cursorUTF16: Int) -> String {
        let content = item.suggestion ?? item.text
        let block = "\n> ✎ \(item.kind.label): " + content.replacingOccurrences(of: "\n", with: "\n> ") + "\n"

        let outline = DocumentOutline.parse(text)
        guard let section = outline.section(atUTF16Offset: cursorUTF16) else {
            return text.hasSuffix("\n") ? text + block : text + "\n" + block
        }

        let utf16 = text.utf16
        guard
            let end16 = utf16.index(utf16.startIndex, offsetBy: min(section.bodyEnd, utf16.count), limitedBy: utf16.endIndex),
            let insertAt = end16.samePosition(in: text)
        else {
            return text + block
        }
        var result = text
        result.insert(contentsOf: block, at: insertAt)
        return result
    }
}
