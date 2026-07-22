import Foundation

/// Everything the model needs to know about where the author currently is
/// in their document.
public struct PromptContext: Equatable, Sendable {
    public var topic: String?
    public var currentSectionTitle: String?
    public var currentSectionBody: String
    public var otherSectionTitles: [String]

    public init(
        topic: String? = nil,
        currentSectionTitle: String? = nil,
        currentSectionBody: String,
        otherSectionTitles: [String] = []
    ) {
        self.topic = topic
        self.currentSectionTitle = currentSectionTitle
        self.currentSectionBody = currentSectionBody
        self.otherSectionTitles = otherSectionTitles
    }

    /// Derives context from a document and the cursor position. Returns nil
    /// when the relevant section is excluded from AI analysis.
    public static func from(text: String, cursorUTF16: Int) -> PromptContext? {
        let outline = DocumentOutline.parse(text)
        let current = outline.section(atUTF16Offset: cursorUTF16)
        if let current, current.excludedFromAI { return nil }

        let body: String
        if let current {
            body = DocumentOutline.body(of: current, in: text)
        } else {
            body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return PromptContext(
            topic: outline.topic,
            currentSectionTitle: current.map(\.title),
            currentSectionBody: body,
            otherSectionTitles: outline.otherSectionTitles(excluding: current)
        )
    }
}

/// One-tap coaching actions in the thinking panel.
public enum CoachAction: String, CaseIterable, Sendable, Identifiable {
    case askQuestions
    case challenge
    case summarize
    case nextSteps

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .askQuestions: return "Ask me questions"
        case .challenge: return "Challenge my thinking"
        case .summarize: return "Mirror my argument"
        case .nextSteps: return "Suggest next steps"
        }
    }

    public var systemImage: String {
        switch self {
        case .askQuestions: return "questionmark.bubble"
        case .challenge: return "bolt.shield"
        case .summarize: return "text.alignleft"
        case .nextSteps: return "arrow.turn.down.right"
        }
    }

    var instruction: String {
        switch self {
        case .askQuestions:
            return "Ask exactly three Socratic questions that would most advance the author's thinking on the current section. Number them. Ask — do not answer."
        case .challenge:
            return "Identify the two or three weakest assumptions or claims in the notes and challenge each one with a concrete counter-argument or counter-example. Be constructive but honest."
        case .summarize:
            return "Reflect the author's argument back to them: state the core claim in one sentence, then the supporting points as a short list, then name anything that is asserted but not yet supported. Do not add new ideas."
        case .nextSteps:
            return "Suggest the three most valuable next steps for this document (things to research, sections to write, decisions to make). Be specific to this content, not generic."
        }
    }
}

/// Builds chat messages for the feedback engine and the coach.
/// Pure functions — easy to test, no I/O.
public enum PromptBuilder {
    /// Character budget for the current section body sent to the model.
    static let sectionBudget = 8000
    /// Character budget for coach actions, which see more of the document.
    static let coachBudget = 12000

    static func clip(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        // Keep the end (usually where the author is working) and the start,
        // dropping the middle.
        let head = String(text.prefix(budget / 3))
        let tail = String(text.suffix(budget - budget / 3))
        return head + "\n[…]\n" + tail
    }

    public static func feedbackMessages(
        context: PromptContext,
        kinds: [FeedbackKind],
        style: TipStyle
    ) -> [ChatMessage] {
        let kindList = kinds.map { "- \($0.instruction)" }.joined(separator: "\n")

        var styleLines: [String] = [style.tone.promptFragment, style.detail.promptFragment]
        if !style.language.isEmpty {
            styleLines.append("Write all feedback in \(style.language).")
        } else {
            styleLines.append("Write feedback in the same language as the notes.")
        }
        if !style.customGuidance.isEmpty {
            styleLines.append(style.customGuidance)
        }

        let system = """
        You are a rigorous thinking coach embedded in a note-taking app. The author is structuring \
        their thinking in markdown notes. Your job is not to write for them — it is to make their \
        thinking clearer, more complete, and better structured.

        Allowed feedback types:
        \(kindList)

        Rules:
        - Return at most \(style.maxTips) feedback items, only the ones genuinely worth the author's attention.
        - Each item must be specific to THIS text. Never give generic advice like "add more detail".
        - "text" states the observation. "suggestion" (optional) contains concrete, ready-to-insert content or a concrete rewrite.
        - \(styleLines.joined(separator: "\n- "))

        Respond with ONLY valid JSON in exactly this shape:
        {"feedback":[{"type":"gap","text":"...","suggestion":"..."}]}
        """

        var user = ""
        if let topic = context.topic {
            user += "Overall topic (H1): \(topic)\n"
        }
        if let section = context.currentSectionTitle {
            user += "The author is currently working on the section: \"\(section)\"\n"
        }
        if !context.otherSectionTitles.isEmpty {
            user += "Other sections in the document: \(context.otherSectionTitles.joined(separator: "; "))\n"
        }
        user += "\nCurrent section content:\n\"\"\"\n\(clip(context.currentSectionBody, to: sectionBudget))\n\"\"\"\n"
        user += "\nAnalyze the current section in the context of the whole document and respond with JSON only."

        return [.system(system), .user(user)]
    }

    public static func coachMessages(action: CoachAction, documentText: String) -> [ChatMessage] {
        let system = """
        You are a rigorous, warm thinking coach. The author shares their working notes in markdown. \
        \(action.instruction)
        Respond in plain prose / short markdown, in the same language as the notes. Keep it under 250 words.
        """
        let user = "My notes:\n\"\"\"\n\(clip(documentText, to: coachBudget))\n\"\"\""
        return [.system(system), .user(user)]
    }
}
