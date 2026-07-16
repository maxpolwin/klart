import Foundation

/// A single markdown note. Notes are plain markdown text; the title is always
/// derived from the content so there is exactly one source of truth.
public struct Note: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Fingerprints of AI feedback items the user has dismissed for this note,
    /// so the same tip is not shown again.
    public var rejectedFingerprints: [String]

    public init(
        id: UUID = UUID(),
        content: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        rejectedFingerprints: [String] = []
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rejectedFingerprints = rejectedFingerprints
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        rejectedFingerprints = try c.decodeIfPresent([String].self, forKey: .rejectedFingerprints) ?? []
    }

    /// Human-readable title derived from the first non-empty line,
    /// with markdown heading markers stripped.
    public var title: String {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return String(line.prefix(80))
        }
        return "Untitled"
    }

    /// Short body preview for list rows (first non-heading, non-empty line).
    public var preview: String {
        var sawTitle = false
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if !sawTitle {
                sawTitle = true
                continue
            }
            if line.hasPrefix("#") { continue }
            return String(line.prefix(120))
        }
        return ""
    }
}
