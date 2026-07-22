import Foundation

/// The single rule for what counts as an ATX heading marker (CommonMark:
/// 1–6 `#` characters, then a space, a tab, or end of line) — shared by the
/// live editor, the AI-feedback outline, and note titles/previews so a "#"
/// used as ordinary text (a hashtag, "C#", "#1 priority", `####### too-deep`)
/// is never mistaken for a heading in one place and left alone in another.
public enum MarkdownHeading {
    /// The heading level (1...6) if `line` starts with a valid ATX heading
    /// marker, otherwise `nil`.
    public static func level(of line: String) -> Int? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard level >= 1, level <= 6, rest.first == " " || rest.first == "\t" || rest.isEmpty else {
            return nil
        }
        return level
    }
}
