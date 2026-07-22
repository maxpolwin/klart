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
    /// Sensitive notes never leave the machine: any AI request for them is
    /// refused in code unless the active provider is local.
    public var isSensitive: Bool

    public init(
        id: UUID = UUID(),
        content: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        rejectedFingerprints: [String] = [],
        isSensitive: Bool = false
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rejectedFingerprints = rejectedFingerprints
        self.isSensitive = isSensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        rejectedFingerprints = try c.decodeIfPresent([String].self, forKey: .rejectedFingerprints) ?? []
        isSensitive = try c.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
    }

    /// Human-readable title derived from the first non-empty line, with a
    /// leading markdown heading marker stripped — but only when the line is
    /// actually a valid heading (`# `–`###### `). A "#" used as plain text
    /// ("#idea", "C# notes", "#1 priority") is left exactly as typed.
    public var title: String {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let line: String
            if let level = MarkdownHeading.level(of: trimmed) {
                line = Substring(trimmed).dropFirst(level).trimmingCharacters(in: .whitespaces)
            } else {
                line = trimmed
            }
            guard !line.isEmpty else { continue }
            return String(line.prefix(80))
        }
        return "Untitled"
    }

    /// Short body preview for list rows (first non-heading, non-empty line
    /// after the title). Only a real heading line is skipped — a line that
    /// merely starts with "#" without being valid heading syntax counts as
    /// body text, same as in the title above.
    public var preview: String {
        var sawTitle = false
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if !sawTitle {
                sawTitle = true
                continue
            }
            if MarkdownHeading.level(of: line) != nil { continue }
            return String(line.prefix(120))
        }
        return ""
    }
}
