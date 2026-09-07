import Foundation

/// Everything the model needs to know about where the author currently is
/// in their document.
public struct PromptContext: Equatable, Sendable {
    public var topic: String?
    public var currentSectionTitle: String?
    public var currentSectionBody: String
    /// The whole document as the model may see it: sections tagged `[no-ai]`
    /// reduced to their heading and an "(omitted)" line, fenced code kept.
    /// The model reads the section it critiques against this.
    public var documentText: String

    public init(
        topic: String? = nil,
        currentSectionTitle: String? = nil,
        currentSectionBody: String,
        documentText: String = ""
    ) {
        self.topic = topic
        self.currentSectionTitle = currentSectionTitle
        self.currentSectionBody = currentSectionBody
        self.documentText = documentText
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
            documentText: redacted(text, outline: outline)
        )
    }

    /// The document with every `[no-ai]` section's body removed. The heading
    /// stays so the model still sees the shape of the document; the words
    /// under it never leave the machine.
    static func redacted(_ text: String, outline: DocumentOutline) -> String {
        let excluded = outline.sections.filter(\.excludedFromAI)
        guard !excluded.isEmpty else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        // Excluded sections may nest (an excluded H2 containing H3s, each
        // also listed); walk them in order and skip any that start inside a
        // range already removed.
        for section in excluded.sorted(by: { $0.headingStart < $1.headingStart }) {
            guard section.headingStart >= cursor else { continue }
            let headEnd = min(section.bodyStart, ns.length)
            result += ns.substring(with: NSRange(location: cursor, length: headEnd - cursor))
            if !result.hasSuffix("\n") { result += "\n" }
            result += "(omitted)\n\n"
            cursor = min(section.bodyEnd, ns.length)
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
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
            return "Ask exactly three questions the author cannot answer without thinking harder about the current section. Number them. Ask — do not answer, and do not soften them."
        case .challenge:
            return "Find the two or three weakest assumptions or claims in the notes and attack each one with the strongest concrete counter-argument or counter-example you can make. Argue as the author's best-informed opponent would. Honest, not polite."
        case .summarize:
            return "Reflect the author's argument back to them: state the core claim in one sentence, then the supporting points as a short list, then name anything that is asserted but not yet supported. Do not add new ideas."
        case .nextSteps:
            return "Name the three most valuable next steps for this document (things to find out, sections to write, decisions to make). Be specific to this content, not generic."
        }
    }
}

/// One editable placeholder token in a system-prompt template. `required`
/// tokens are load-bearing — the app warns when the user removes one.
public struct PromptPlaceholder: Sendable, Identifiable {
    /// The literal token as it appears in the template, e.g. `{{JSON_SHAPE}}`.
    public let token: String
    /// One line explaining what the app substitutes for this token.
    public let summary: String
    /// When true, removing the token breaks the feature (parsing, dispatch).
    public let required: Bool

    public var id: String { token }

    public init(token: String, summary: String, required: Bool) {
        self.token = token
        self.summary = summary
        self.required = required
    }
}

/// Builds chat messages for the feedback engine and the coach.
/// Pure functions — easy to test, no I/O.
///
/// The two system prompts are templates: the app owns a canonical default for
/// each, the user may override it, and the dynamic, per-request pieces stay as
/// `{{TOKENS}}` that `render` substitutes at build time. This keeps a
/// customised prompt in sync with the other settings (enabled feedback types,
/// tips-per-round, tone/detail/language) and lets the UI flag a template that
/// has dropped a load-bearing token.
public enum PromptBuilder {
    /// Character budget for the current section body sent to the model.
    static let sectionBudget = 8000
    /// Character budget for the whole (redacted) document the section is read
    /// against. Over budget, the middle is dropped; the current section is
    /// sent separately and in full regardless.
    static let documentBudget = 16000
    /// Character budget for coach actions, which see the document only.
    static let coachBudget = 12000

    /// The exact JSON structure `FeedbackParser` expects back. Removing this
    /// from the feedback template breaks parsing — hence a required token.
    public static let feedbackJSONShape = #"{"feedback":[{"type":"gap","anchor":"exact words from the section","text":"...","why":"...","severity":2}]}"#

    /// Canonical default for the live-feedback ("Editor") system prompt.
    /// Rendering it with the default substitutions reproduces the prompt
    /// verbatim, so users who never touch it see no change in behaviour.
    ///
    /// Opinionated by design. The app exists to make the author's thinking
    /// harder to fault, and an editor who hedges, praises, or drafts for the
    /// author does none of that: the author has to produce the fix, or nothing
    /// is learned.
    public static let defaultFeedbackTemplate = """
    You are the author's editor: a sharp, opinionated reader whose only job is to make their \
    thinking harder to fault. You never write their text for them. You say what is wrong, where, \
    and why it matters — plainly. No praise. No padding. No hedging. Never "consider" or "you might \
    want to": state the problem as a claim and stand behind it.

    Allowed feedback types:
    {{FEEDBACK_TYPES}}

    Rules:
    - Return at most {{MAX_TIPS}} items, only the ones a demanding reader would actually raise. Fewer beats filler; an empty list is a valid answer.
    - Every item is about THIS section. Never give generic advice ("add more detail", "think about your audience").
    - "anchor": the exact words the item is about, copied verbatim from the current section, at most fifteen words. Omit it only when the item is about the section as a whole.
    - "text": the observation — what is wrong, as a claim. Do not draft replacement prose, and do not tell the author what to write.
    - "why": one sentence on what the flaw costs the argument.
    - "severity": 1 if worth fixing, 2 if it weakens the argument, 3 if the argument fails until it is fixed.
    - Do not repeat anything already flagged by the checks listed in the request.
    - {{STYLE}}

    Respond with ONLY valid JSON in exactly this shape:
    {{JSON_SHAPE}}
    """

    /// Canonical default for the Quiet-coach system prompt.
    public static let defaultCoachTemplate = """
    You are the author's editor: sharp, honest, on their side. The author shares their working notes in markdown. \
    {{ACTION_INSTRUCTION}}
    Respond in plain prose / short markdown, in the same language as the notes. Keep it under 250 words. No praise, no preamble.
    """

    /// Tokens available in the feedback template, for the editor's legend and
    /// its missing-token warning.
    public static let feedbackPlaceholders: [PromptPlaceholder] = [
        PromptPlaceholder(token: "{{FEEDBACK_TYPES}}", summary: "The feedback types you enabled, one per line.", required: false),
        PromptPlaceholder(token: "{{MAX_TIPS}}", summary: "Your “notes per round” number.", required: false),
        PromptPlaceholder(token: "{{STYLE}}", summary: "Your tone, detail, language, and any extra guidance.", required: false),
        PromptPlaceholder(token: "{{JSON_SHAPE}}", summary: "The exact JSON the app parses — leave this in.", required: true),
    ]

    /// Tokens available in the coach template.
    public static let coachPlaceholders: [PromptPlaceholder] = [
        PromptPlaceholder(token: "{{ACTION_INSTRUCTION}}", summary: "The chosen coach action (ask questions, challenge, …).", required: false),
    ]

    /// Substitutes every `{{TOKEN}}` in `template` in a single pass. Values are
    /// not re-scanned, so a substitution that happens to contain braces is safe.
    public static func render(_ template: String, _ substitutions: [String: String]) -> String {
        var result = template
        for (token, value) in substitutions {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }

    /// The `required` tokens missing from `template` — what the editor warns about.
    public static func missingRequiredPlaceholders(
        in template: String,
        placeholders: [PromptPlaceholder]
    ) -> [String] {
        placeholders.filter { $0.required && !template.contains($0.token) }.map(\.token)
    }

    static func clip(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        // Keep the end (usually where the author is working) and the start,
        // dropping the middle.
        let head = String(text.prefix(budget / 3))
        let tail = String(text.suffix(budget - budget / 3))
        return head + "\n[…]\n" + tail
    }

    /// Builds the two messages for one analysis round. `alreadyFlagged` are
    /// the local checks' notes for this section, listed so the model spends
    /// its budget elsewhere.
    public static func feedbackMessages(
        context: PromptContext,
        kinds: [FeedbackKind],
        style: TipStyle,
        alreadyFlagged: [FeedbackItem] = [],
        template: String? = nil
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

        let system = render(template ?? defaultFeedbackTemplate, [
            "{{FEEDBACK_TYPES}}": kindList,
            "{{MAX_TIPS}}": String(style.maxTips),
            "{{STYLE}}": styleLines.joined(separator: "\n- "),
            "{{JSON_SHAPE}}": feedbackJSONShape,
        ])

        var user = ""
        if let topic = context.topic {
            user += "Overall topic (H1): \(topic)\n"
        }
        let document = context.documentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !document.isEmpty, document != context.currentSectionBody {
            user += "\nThe whole document, for context (sections marked [no-ai] are omitted):\n\"\"\"\n"
            user += clip(document, to: documentBudget)
            user += "\n\"\"\"\n"
        }
        if let section = context.currentSectionTitle {
            user += "\nThe author has just finished the section \"\(section)\". Every item must be about this section:\n"
        } else {
            user += "\nThe author has just finished this text. Every item must be about it:\n"
        }
        user += "\"\"\"\n\(clip(context.currentSectionBody, to: sectionBudget))\n\"\"\"\n"
        if !alreadyFlagged.isEmpty {
            user += "\nAlready flagged by deterministic checks — do not repeat these:\n"
            for item in alreadyFlagged {
                user += "- [\(item.kind.rawValue)] \(item.text)\n"
            }
        }
        user += "\nRead the section against the whole document and respond with JSON only."

        return [.system(system), .user(user)]
    }

    public static func coachMessages(
        action: CoachAction,
        documentText: String,
        template: String? = nil
    ) -> [ChatMessage] {
        let system = render(template ?? defaultCoachTemplate, [
            "{{ACTION_INSTRUCTION}}": action.instruction,
        ])
        let user = "My notes:\n\"\"\"\n\(clip(documentText, to: coachBudget))\n\"\"\""
        return [.system(system), .user(user)]
    }
}
