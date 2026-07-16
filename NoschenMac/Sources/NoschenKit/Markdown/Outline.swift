import Foundation

/// A heading in a markdown document, with UTF-16 offsets so the app can map
/// editor cursor positions (NSTextView uses UTF-16) onto sections directly.
public struct OutlineSection: Equatable, Sendable {
    /// Heading level, 1...6.
    public let level: Int
    /// Heading text with markers and tags stripped.
    public let title: String
    /// UTF-16 offset of the first character of the heading line.
    public let headingStart: Int
    /// UTF-16 offset just past the heading line's trailing newline
    /// (i.e. where the section body starts).
    public let bodyStart: Int
    /// UTF-16 offset where the section ends (start of the next heading with
    /// level <= this one, or end of document).
    public var bodyEnd: Int
    /// True when the heading carries a `[no-ai]` tag — the section is
    /// excluded from AI analysis.
    public let excludedFromAI: Bool

    public init(level: Int, title: String, headingStart: Int, bodyStart: Int, bodyEnd: Int, excludedFromAI: Bool) {
        self.level = level
        self.title = title
        self.headingStart = headingStart
        self.bodyStart = bodyStart
        self.bodyEnd = bodyEnd
        self.excludedFromAI = excludedFromAI
    }
}

/// Structural view of a markdown note: the overall topic (first H1) and
/// every section heading with its extent.
public struct DocumentOutline: Equatable, Sendable {
    public let topic: String?
    public let sections: [OutlineSection]
    /// Total document length in UTF-16 code units.
    public let length: Int

    public static func parse(_ text: String) -> DocumentOutline {
        var sections: [OutlineSection] = []
        var topic: String? = nil
        var offset = 0
        let totalLength = text.utf16.count

        // Split preserving structure; each line's UTF-16 length + 1 newline
        // (except possibly the last line) advances the offset.
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let lineLength = line.utf16.count
            let hasNewline = index < lines.count - 1
            defer { offset += lineLength + (hasNewline ? 1 : 0) }

            guard let heading = parseHeadingLine(line) else { continue }
            let bodyStart = offset + lineLength + (hasNewline ? 1 : 0)
            if topic == nil && heading.level == 1 {
                topic = heading.title
            }
            sections.append(OutlineSection(
                level: heading.level,
                title: heading.title,
                headingStart: offset,
                bodyStart: bodyStart,
                bodyEnd: totalLength,
                excludedFromAI: heading.excluded
            ))
        }

        // Close each section at the next heading of the same or higher rank.
        for i in sections.indices {
            for j in (i + 1)..<sections.count where sections[j].level <= sections[i].level {
                sections[i].bodyEnd = sections[j].headingStart
                break
            }
        }

        return DocumentOutline(topic: topic, sections: sections, length: totalLength)
    }

    init(topic: String?, sections: [OutlineSection], length: Int) {
        self.topic = topic
        self.sections = sections
        self.length = length
    }

    private static func parseHeadingLine(_ line: String) -> (level: Int, title: String, excluded: Bool)? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard level >= 1, level <= 6 else { return nil }
        guard rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        var excluded = false
        // Strip a trailing [no-ai] tag (case-insensitive).
        if let range = title.range(of: "[no-ai]", options: [.caseInsensitive, .backwards]) {
            excluded = true
            title.removeSubrange(range)
            title = title.trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { return nil }
        return (level, title, excluded)
    }

    /// The deepest section whose extent contains the given UTF-16 offset.
    public func section(atUTF16Offset offset: Int) -> OutlineSection? {
        var best: OutlineSection? = nil
        for section in sections {
            if offset >= section.headingStart && offset <= section.bodyEnd {
                if best == nil || section.level >= best!.level {
                    best = section
                }
            }
        }
        return best
    }

    /// Titles of level-2 sections other than the given one — the "map" of
    /// the document the model sees for MECE analysis.
    public func otherSectionTitles(excluding current: OutlineSection?) -> [String] {
        sections
            .filter { $0.level == 2 && $0.title != current?.title }
            .map(\.title)
    }

    /// Extracts a section's body text (between its heading line and the next
    /// same-or-higher-level heading).
    public static func body(of section: OutlineSection, in text: String) -> String {
        let utf16 = text.utf16
        guard section.bodyStart <= section.bodyEnd, section.bodyEnd <= utf16.count else { return "" }
        guard
            let start = utf16.index(utf16.startIndex, offsetBy: section.bodyStart, limitedBy: utf16.endIndex),
            let end = utf16.index(utf16.startIndex, offsetBy: section.bodyEnd, limitedBy: utf16.endIndex),
            let startIdx = start.samePosition(in: text),
            let endIdx = end.samePosition(in: text)
        else { return "" }
        return String(text[startIdx..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
