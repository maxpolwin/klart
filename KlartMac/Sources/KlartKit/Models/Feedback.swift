import Foundation

/// The kinds of editorial note Klårt can raise.
///
/// The set is a critical-thinking lens, not a style guide: Paul–Elder's
/// intellectual standards (clarity, accuracy, precision, relevance, depth,
/// breadth, logic, fairness) crossed with Toulmin's anatomy of an argument
/// (claim, grounds, warrant, rebuttal). Each kind names one way an argument
/// fails a demanding reader.
public enum FeedbackKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A consideration, perspective, or piece of analysis the argument needs
    /// and does not have. (Depth, breadth.)
    case gap
    /// Categories that overlap or leave something uncovered. (Logic.)
    case mece
    /// An ordering or grouping that hides the argument. (Logic.)
    case structure
    /// A sentence a careful reader cannot pin down — vague, ambiguous, or
    /// doing two jobs at once. Language only; evidence is `evidence`.
    /// (Clarity, precision.)
    case clarity
    /// A claim stated as fact with nothing behind it. (Accuracy — Toulmin's
    /// grounds.)
    case evidence
    /// A premise the argument depends on but never states. (Toulmin's
    /// implicit warrant / backing; the first thing a hostile reader attacks.)
    case assumption
    /// Claim and evidence both present, but why this evidence should convince
    /// is never said. (Toulmin's warrant.)
    case warrant
    /// The strongest objection or opposing view the author has not engaged.
    /// (Fairness — Toulmin's rebuttal; "consider the opposite".)
    case counter
    /// One probing question the author cannot answer without thinking harder.
    case question
    /// Parser fallback for a type the model named that Klårt doesn't know.
    /// Never requested.
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .gap: return "Gap"
        case .mece: return "MECE"
        case .structure: return "Structure"
        case .clarity: return "Clarity"
        case .evidence: return "Evidence"
        case .assumption: return "Assumption"
        case .warrant: return "Warrant"
        case .counter: return "Counter"
        case .question: return "Question"
        case .other: return "Note"
        }
    }

    /// Instruction text handed to the model for this feedback type.
    public var instruction: String {
        switch self {
        case .gap:
            return "gap — a consideration, perspective, or piece of analysis the argument needs and does not have"
        case .mece:
            return "mece — categories that overlap or leave something uncovered (not mutually exclusive / collectively exhaustive)"
        case .structure:
            return "structure — an ordering or grouping that hides the argument; say what should come first and why"
        case .clarity:
            return "clarity — a sentence whose meaning a careful reader cannot pin down: vague, ambiguous, or doing two jobs at once (language only — a claim lacking support is 'evidence')"
        case .evidence:
            return "evidence — a claim stated as fact with nothing behind it; say what evidence would settle it"
        case .assumption:
            return "assumption — a premise the argument depends on but never states; name it, and say what happens if it is false"
        case .warrant:
            return "warrant — claim and evidence are both present, but why this evidence should convince is never said; name the missing link"
        case .counter:
            return "counter — the strongest objection or opposing view the author has not engaged; state it as its best advocate would"
        case .question:
            return "question — one probing question the author cannot answer without thinking harder; ask, do not answer"
        case .other:
            return "note — any other observation that makes the thinking harder to fault"
        }
    }

    /// Kinds that are on by default for new users: every lens except the
    /// fallback.
    public static var defaultEnabled: [FeedbackKind] {
        allCases.filter { $0 != .other }
    }

    /// Maps loose model output ("gaps", "MECE check", "socratic question", …)
    /// onto a concrete kind.
    public static func fromModelString(_ raw: String) -> FeedbackKind {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = FeedbackKind(rawValue: s) { return exact }
        if s == "source" || s.contains("citation") || s.contains("literature") || s.contains("reference") { return .evidence }
        if s.contains("evidence") || s.contains("unsupported") || s.contains("support") { return .evidence }
        if s.contains("assum") || s.contains("premise") || s.contains("presuppos") { return .assumption }
        if s.contains("warrant") || s.contains("link") || s.contains("inference") { return .warrant }
        if s.contains("counter") || s.contains("objection") || s.contains("opposing") || s.contains("rebut") || s.contains("steel") { return .counter }
        if s.contains("gap") || s.contains("missing") { return .gap }
        if s.contains("mece") || s.contains("overlap") || s.contains("exclusive") { return .mece }
        if s.contains("structur") || s.contains("organiz") || s.contains("reorder") { return .structure }
        if s.contains("clarity") || s.contains("clarif") || s.contains("vague") || s.contains("ambig") { return .clarity }
        if s.contains("question") || s.contains("socratic") { return .question }
        return .other
    }

    /// Lenient decode: a settings file or learning log written by an older
    /// build may carry `source` (now folded into `evidence`) or a kind this
    /// build doesn't know. Neither may take the whole file down.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FeedbackKind(rawValue: raw) ?? FeedbackKind.fromModelString(raw)
    }
}

/// How much the flaw costs the argument. The rail orders cards by this.
public enum FeedbackSeverity: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Worth fixing; the argument survives without it.
    case minor = 1
    /// Weakens the argument.
    case major = 2
    /// The argument fails until this is fixed.
    case critical = 3

    public static func < (lhs: FeedbackSeverity, rhs: FeedbackSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Maps loose model output (`3`, `"3"`, `"critical"`, `"high"`, …).
    public static func fromModelValue(_ raw: String?) -> FeedbackSeverity {
        guard let raw else { return .major }
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(s), let exact = FeedbackSeverity(rawValue: min(3, max(1, n))) { return exact }
        if s.contains("crit") || s.contains("high") || s.contains("fatal") || s.contains("severe") { return .critical }
        if s.contains("minor") || s.contains("low") || s.contains("nit") { return .minor }
        return .major
    }
}

/// Who raised the note: the model, or one of the deterministic offline
/// checks in `LocalChecks`.
public enum FeedbackSource: String, Codable, Sendable {
    case model
    case local
}

/// One editorial note shown in the rail or the coach panel.
///
/// The shape follows what feedback research says gets acted on: it is
/// anchored to the exact words it is about (localized feedback is implemented
/// far more often than section-level feedback), it says what is wrong as a
/// claim, and it says why that matters. It never contains replacement prose —
/// the writer produces the fix, which is the point.
public struct FeedbackItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: FeedbackKind
    /// The words in the section the note is about, verbatim. Nil when the
    /// note is about the section as a whole (or the model quoted words that
    /// are not in the text — a fabricated anchor is dropped, never shown).
    public let anchor: String?
    /// The observation itself — what is wrong, stated plainly.
    public let text: String
    /// What the flaw costs the argument. One sentence.
    public let why: String?
    public let severity: FeedbackSeverity
    public let source: FeedbackSource
    /// For local checks: the heuristic that fired, so the rule itself is
    /// learnable ("uncited-claim", "hedge-density", …).
    public let rule: String?
    /// Title of the section the note refers to.
    public let section: String?

    public init(
        id: UUID = UUID(),
        kind: FeedbackKind,
        anchor: String? = nil,
        text: String,
        why: String? = nil,
        severity: FeedbackSeverity = .major,
        source: FeedbackSource = .model,
        rule: String? = nil,
        section: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.anchor = anchor
        self.text = text
        self.why = why
        self.severity = severity
        self.source = source
        self.rule = rule
        self.section = section
    }

    /// Stable identity for "don't show this again" across regenerations.
    ///
    /// Keyed on the *anchor* when there is one: rejecting a note means "no
    /// note of this kind on these words", and the model rewords its
    /// observation every round, so keying on the observation let rejected
    /// notes resurface. A local check without an anchor (hedge density,
    /// a thin section) keys on its rule and section instead, since its text
    /// carries counts that change with every edit.
    public var fingerprint: String {
        let subject: String
        if let anchor, !anchor.isEmpty {
            subject = anchor
        } else if source == .local, let rule {
            subject = rule + "|" + (section ?? "")
        } else {
            subject = text
        }
        let normalized = kind.rawValue + "|" + subject.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return StableHash.fnv1a(normalized)
    }

    /// A copy with a different section stamp; everything else, including the
    /// identity SwiftUI animates on, is carried across.
    public func stamped(section: String?) -> FeedbackItem {
        FeedbackItem(
            id: id, kind: kind, anchor: anchor, text: text, why: why,
            severity: severity, source: source, rule: rule, section: section
        )
    }

    /// A copy with the anchor removed — what a note becomes when the words
    /// it quoted are not in the text.
    public func withoutAnchor() -> FeedbackItem {
        FeedbackItem(
            id: id, kind: kind, anchor: nil, text: text, why: why,
            severity: severity, source: source, rule: rule, section: section
        )
    }
}
