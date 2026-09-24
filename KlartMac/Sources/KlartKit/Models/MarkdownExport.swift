import Foundation

/// The plain-markdown backup format: one `.md` file per note, led by a
/// one-line HTML comment that carries the note's identity so a re-import
/// updates the note instead of duplicating it.
///
///     <!-- klart:id=<UUID> created=<ISO 8601> sensitive=true -->
///
/// `sensitive=true` is written only for notes marked sensitive. It matters
/// because the markdown export is the recommended backup: a restore must
/// never silently turn a local-only note into one the cloud may read.
public enum MarkdownExport {
    /// What an imported file says about the note it came from.
    public struct Parsed: Equatable, Sendable {
        public var id: UUID?
        public var createdAt: Date?
        public var isSensitive: Bool
        public var body: String
    }

    private static let prefix = "<!-- klart:"
    private static let terminator = "-->\n"

    public static func header(for note: Note) -> String {
        let created = ISO8601DateFormatter().string(from: note.createdAt)
        let sensitive = note.isSensitive ? " sensitive=true" : ""
        return "\(prefix)id=\(note.id.uuidString) created=\(created)\(sensitive) \(terminator)"
    }

    public static func fileContents(for note: Note) -> String {
        header(for: note) + note.content
    }

    /// Reads our own export header, if present, and strips it from the body.
    /// Files without a header import as plain markdown.
    public static func parse(_ text: String) -> Parsed {
        guard text.hasPrefix(prefix), let headerEnd = text.range(of: terminator) else {
            return Parsed(id: nil, createdAt: nil, isSensitive: false, body: text)
        }
        let header = String(text[..<headerEnd.lowerBound])
        var fields: [String: String] = [:]
        for token in header.dropFirst(prefix.count).split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            fields[String(pair[0])] = String(pair[1])
        }
        return Parsed(
            id: fields["id"].flatMap(UUID.init(uuidString:)),
            createdAt: fields["created"].flatMap { ISO8601DateFormatter().date(from: $0) },
            isSensitive: fields["sensitive"] == "true",
            body: String(text[headerEnd.upperBound...])
        )
    }

    /// Builds the note an import should store. When the file matches a note
    /// already in the library, that note's local-only state carries over:
    /// an import can mark a note sensitive but can never clear the mark,
    /// and dismissed tips stay dismissed.
    public static func note(from parsed: Parsed, existing: Note?, now: Date = Date()) -> Note {
        Note(
            id: parsed.id ?? UUID(),
            content: parsed.body,
            createdAt: parsed.createdAt ?? existing?.createdAt ?? now,
            updatedAt: now,
            rejectedFingerprints: existing?.rejectedFingerprints ?? [],
            isSensitive: (existing?.isSensitive ?? false) || parsed.isSensitive
        )
    }
}
