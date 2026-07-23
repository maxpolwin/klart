import Foundation

/// FNV-1a over UTF-8, hex-encoded. Small, stable, and dependency-free — the
/// same identity scheme `FeedbackItem.fingerprint` has always used, lifted out
/// so prompt versions can be fingerprinted the same way.
public enum StableHash {
    public static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

/// What the writer did with a coaching recommendation.
public enum RecommendationOutcome: String, Codable, Sendable, CaseIterable {
    /// Inserted into the note as an editor note (`> ✎` block).
    case inserted
    /// Marked as good advice, without inserting it.
    case confirmed
    /// Marked as wrong — the coach missed.
    case rejected
    /// Left undecided when the writer moved on. Deliberately weak signal:
    /// logged, but not meant for user-facing summaries.
    case dismissed
}

/// One judged recommendation, kept in a local learning log so coaching quality
/// and the system prompt can be improved over time.
///
/// Fields are split into two tiers. The **signal** tier is always recorded and
/// derives nothing from the note or the model's prose. The **content** tier
/// (everything Optional below the divider) is only filled in when the writer
/// opts in via `AppSettings.logRecommendationContent`, and is always empty for
/// notes marked sensitive.
public struct RecommendationRecord: Identifiable, Codable, Equatable, Sendable {
    // MARK: Signal — always recorded

    public let id: UUID
    public let outcome: RecommendationOutcome
    public let createdAt: Date
    public let kind: FeedbackKind
    /// Stable identity of the tip itself, so the same advice can be correlated
    /// across rounds and outcomes.
    public let fingerprint: String
    public let model: String?
    public let provider: String?
    /// Identifies the system prompt that produced this tip, so confirm/reject
    /// rates stay attributable after the prompt is edited.
    public let systemPromptHash: String
    public let usesDefaultPrompt: Bool
    /// Opaque note identity — a random UUID, so it groups records per note
    /// without revealing anything about the note.
    public let noteID: UUID?
    /// Content is withheld for sensitive notes even when content logging is on.
    public let fromSensitiveNote: Bool

    // MARK: Content — only with `logRecommendationContent`

    public let noteTitle: String?
    public let documentTopic: String?
    public let sectionTitle: String?
    /// The section body the advice was reacting to.
    public let contextParagraph: String?
    /// The observation the model made (`FeedbackItem.text`).
    public let observation: String?
    public let suggestion: String?

    /// Longest context paragraph kept. Enough to judge whether a tip was fair,
    /// short enough that the log stays small.
    public static let maxContextLength = 2000

    public init(
        id: UUID = UUID(),
        outcome: RecommendationOutcome,
        createdAt: Date = Date(),
        kind: FeedbackKind,
        fingerprint: String,
        model: String? = nil,
        provider: String? = nil,
        systemPromptHash: String,
        usesDefaultPrompt: Bool,
        noteID: UUID? = nil,
        fromSensitiveNote: Bool = false,
        noteTitle: String? = nil,
        documentTopic: String? = nil,
        sectionTitle: String? = nil,
        contextParagraph: String? = nil,
        observation: String? = nil,
        suggestion: String? = nil
    ) {
        self.id = id
        self.outcome = outcome
        self.createdAt = createdAt
        self.kind = kind
        self.fingerprint = fingerprint
        self.model = model
        self.provider = provider
        self.systemPromptHash = systemPromptHash
        self.usesDefaultPrompt = usesDefaultPrompt
        self.noteID = noteID
        self.fromSensitiveNote = fromSensitiveNote
        self.noteTitle = noteTitle
        self.documentTopic = documentTopic
        self.sectionTitle = sectionTitle
        self.contextParagraph = contextParagraph
        self.observation = observation
        self.suggestion = suggestion
    }

    /// Forgiving decode, like `Note`: a log written by an older build must
    /// still load rather than taking the whole file down.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        outcome = try c.decodeIfPresent(RecommendationOutcome.self, forKey: .outcome) ?? .dismissed
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        kind = try c.decodeIfPresent(FeedbackKind.self, forKey: .kind) ?? .other
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        systemPromptHash = try c.decodeIfPresent(String.self, forKey: .systemPromptHash) ?? ""
        usesDefaultPrompt = try c.decodeIfPresent(Bool.self, forKey: .usesDefaultPrompt) ?? true
        noteID = try c.decodeIfPresent(UUID.self, forKey: .noteID)
        fromSensitiveNote = try c.decodeIfPresent(Bool.self, forKey: .fromSensitiveNote) ?? false
        noteTitle = try c.decodeIfPresent(String.self, forKey: .noteTitle)
        documentTopic = try c.decodeIfPresent(String.self, forKey: .documentTopic)
        sectionTitle = try c.decodeIfPresent(String.self, forKey: .sectionTitle)
        contextParagraph = try c.decodeIfPresent(String.self, forKey: .contextParagraph)
        observation = try c.decodeIfPresent(String.self, forKey: .observation)
        suggestion = try c.decodeIfPresent(String.self, forKey: .suggestion)
    }

    /// True when any content-tier field is present.
    public var carriesContent: Bool {
        noteTitle != nil || documentTopic != nil || sectionTitle != nil
            || contextParagraph != nil || observation != nil || suggestion != nil
    }

    /// A copy with every content-tier field stripped — what a signal-only
    /// export ships, and what a sensitive note always contributes.
    public func redactingContent() -> RecommendationRecord {
        RecommendationRecord(
            id: id,
            outcome: outcome,
            createdAt: createdAt,
            kind: kind,
            fingerprint: fingerprint,
            model: model,
            provider: provider,
            systemPromptHash: systemPromptHash,
            usesDefaultPrompt: usesDefaultPrompt,
            noteID: noteID,
            fromSensitiveNote: fromSensitiveNote
        )
    }

    /// Clips a section body to `maxContextLength`, on a word boundary where
    /// one is close by, so stored context stays bounded.
    public static func clipContext(_ text: String) -> String {
        guard text.count > maxContextLength else { return text }
        let cut = text.index(text.startIndex, offsetBy: maxContextLength)
        let head = text[..<cut]
        if let lastSpace = head.lastIndex(where: { $0 == " " || $0 == "\n" }),
           head.distance(from: lastSpace, to: head.endIndex) < 200 {
            return String(head[..<lastSpace]) + "…"
        }
        return String(head) + "…"
    }
}

/// The envelope written by "Export recommendation log…" — self-describing, so
/// a shared file explains its own shape and whether content was included.
public struct RecommendationExport: Codable, Sendable {
    public static let currentSchema = "klart.recommendations.v1"

    public let schema: String
    public let exportedAt: Date
    public let includesContent: Bool
    public let recordCount: Int
    public let records: [RecommendationRecord]

    public init(records: [RecommendationRecord], includesContent: Bool, exportedAt: Date = Date()) {
        self.schema = Self.currentSchema
        self.exportedAt = exportedAt
        self.includesContent = includesContent
        self.recordCount = records.count
        self.records = records
    }

    /// Builds the payload for an export. Without `includeContent`, every record
    /// is redacted; with it, records from sensitive notes are redacted anyway.
    public static func make(from records: [RecommendationRecord], includeContent: Bool) -> RecommendationExport {
        let prepared = records.map { record -> RecommendationRecord in
            (includeContent && !record.fromSensitiveNote) ? record : record.redactingContent()
        }
        return RecommendationExport(records: prepared, includesContent: includeContent)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
