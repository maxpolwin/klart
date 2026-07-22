import Foundation

/// Word count and estimated reading time for a note. Markdown-aware just
/// enough to be honest: heading markers, list bullets, emphasis characters,
/// and code-fence lines don't count as words.
public enum NoteMetrics {
    /// Average adult silent-reading speed used for the estimate.
    public static let wordsPerMinute = 200

    /// Number of words in the text. A "word" is any run of characters
    /// containing at least one letter or digit, so pure punctuation tokens
    /// ("—", "*", "##", "-") are not counted.
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        var insideCodeFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isCodeFence(trimmed) {
                insideCodeFence.toggle()
                continue
            }
            if insideCodeFence { continue }
            for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                if token.contains(where: { $0.isLetter || $0.isNumber }) {
                    count += 1
                }
            }
        }
        return count
    }

    /// Estimated reading time in whole minutes; at least 1 for any non-empty
    /// text, 0 only when there is nothing to read.
    public static func readingMinutes(wordCount: Int) -> Int {
        guard wordCount > 0 else { return 0 }
        return max(1, Int((Double(wordCount) / Double(wordsPerMinute)).rounded(.up)))
    }

    /// The short status line shown at the bottom of the writing surface,
    /// e.g. "512 words · 3 min read".
    public static func summary(for text: String) -> String {
        let words = wordCount(text)
        guard words > 0 else { return "0 words" }
        let minutes = readingMinutes(wordCount: words)
        return "\(words) \(words == 1 ? "word" : "words") · \(minutes) min read"
    }

    private static func isCodeFence(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }
}
