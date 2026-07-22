import Foundation

/// The kinds of coaching feedback Klårt can give.
public enum FeedbackKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case gap
    case mece
    case source
    case structure
    case clarity
    case question
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .gap: return "Gap"
        case .mece: return "MECE"
        case .source: return "Source"
        case .structure: return "Structure"
        case .clarity: return "Clarity"
        case .question: return "Question"
        case .other: return "Note"
        }
    }

    /// Instruction text handed to the model for this feedback type.
    public var instruction: String {
        switch self {
        case .gap:
            return "gap — a missing perspective, consideration, or piece of analysis the notes should address"
        case .mece:
            return "mece — categories that overlap or leave something uncovered (not mutually exclusive / collectively exhaustive)"
        case .source:
            return "source — a concrete type of literature, dataset, or domain worth consulting for this section"
        case .structure:
            return "structure — a reorganization that would make the argument clearer or flow more logically"
        case .clarity:
            return "clarity — a vague, ambiguous, or unsupported claim that should be sharpened or evidenced"
        case .question:
            return "question — one probing Socratic question that pushes the author's thinking further"
        case .other:
            return "note — any other observation that helps the author think more clearly"
        }
    }

    /// Kinds that are on by default for new users.
    public static var defaultEnabled: [FeedbackKind] {
        [.gap, .mece, .structure, .clarity, .question]
    }

    /// Maps loose model output ("gaps", "MECE check", "socratic question", …)
    /// onto a concrete kind.
    public static func fromModelString(_ raw: String) -> FeedbackKind {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = FeedbackKind(rawValue: s) { return exact }
        if s.contains("gap") || s.contains("missing") { return .gap }
        if s.contains("mece") || s.contains("overlap") || s.contains("exclusive") { return .mece }
        if s.contains("source") || s.contains("literature") || s.contains("reference") { return .source }
        if s.contains("structur") || s.contains("organiz") || s.contains("reorder") { return .structure }
        if s.contains("clarity") || s.contains("clarif") || s.contains("vague") { return .clarity }
        if s.contains("question") || s.contains("socratic") { return .question }
        return .other
    }
}

/// One actionable piece of AI feedback shown in the coaching panel.
public struct FeedbackItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: FeedbackKind
    /// The observation itself — what the model noticed.
    public let text: String
    /// Optional concrete content the user can insert into the note.
    public let suggestion: String?
    /// Title of the section the feedback refers to, when the model names one.
    public let section: String?

    public init(
        id: UUID = UUID(),
        kind: FeedbackKind,
        text: String,
        suggestion: String? = nil,
        section: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.suggestion = suggestion
        self.section = section
    }

    /// Stable identity for "don't show this again" across regenerations.
    /// FNV-1a over the normalized kind + text, hex-encoded.
    public var fingerprint: String {
        let normalized = kind.rawValue + "|" + text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
