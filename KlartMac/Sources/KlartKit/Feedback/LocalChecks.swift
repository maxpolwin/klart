import Foundation

/// Deterministic, offline editorial checks — no model involved.
///
/// Conservative, named heuristics: each note says which rule fired, so the
/// rule itself is learnable and transfers to the writer's next document. They
/// run in microseconds, work with no provider configured, and take the cheap
/// objective findings off the model's plate so its item budget goes to
/// judgment — gaps, assumptions, warrants — rather than to counting hedges.
///
/// Kept deliberately narrow to avoid false-positive fatigue: a local note the
/// writer rejects twice is worse than no note.
public enum LocalChecks {
    /// Most local notes per round; the model has its own cap.
    public static let maxFindings = 5

    /// Words that soften a claim. High density usually means an argument the
    /// writer has not decided whether to make.
    static let hedgeWords: Set<String> = [
        "might", "may", "could", "perhaps", "possibly", "arguably", "somewhat",
        "likely", "seems", "seem", "appears", "appear", "potentially", "probably",
        "maybe", "sort", "kind", "rather", "fairly", "relatively",
    ]

    /// Acronyms no reader needs defined.
    static let acronymAllowList: Set<String> = [
        "AI", "US", "USA", "UK", "EU", "UN", "OK", "TODO", "PDF", "HTML", "CSS",
        "JSON", "API", "URL", "FAQ", "MECE", "IT", "ID", "GPS", "CEO", "CTO", "CFO",
        "GDP", "NB", "PS", "AM", "PM", "DIY", "USD", "EUR", "GBP", "LLM", "UI",
        "UX", "IO", "OS", "PR", "QA", "TBD", "ASAP", "FYI", "KPI", "ROI", "SaaS",
    ]

    static let titleStopWords: Set<String> = [
        "about", "above", "after", "again", "against", "along", "among", "analysis",
        "around", "because", "before", "being", "below", "between", "context",
        "could", "discussion", "during", "every", "first", "notes", "other",
        "overview", "review", "section", "should", "summary", "their", "there",
        "these", "thing", "things", "through", "toward", "under", "where", "which",
        "while", "would", "introduction", "conclusion", "background", "approach",
    ]

    /// Something citation-shaped nearby: `(Author, 2020)`, `(Author et al. 2020)`,
    /// `[1]`, a URL, `et al.`
    static let citationPattern = try! NSRegularExpression(
        pattern: #"\(\s*[A-Z][A-Za-z-]+(?:\s+(?:&|and)\s+[A-Z][A-Za-z-]+)?(?:\s+et\s+al\.?)?,?\s+\d{4}[a-z]?\s*\)|\[\d+\]|https?://|\bet\s+al\."#
    )

    /// An empirical claim a reviewer would want sourced: a percentage, a
    /// magnitude, "significantly higher", "most experts", "studies show".
    static let claimPattern = try! NSRegularExpression(
        pattern: #"\b\d+(?:[.,]\d+)?\s*(?:%|percent\b|per\s+cent\b)|\b(?:billion|million|trillion)\b|\bsignificant(?:ly)?\s+(?:increase|decrease|higher|lower|effect|impact|more|less)\b|\b(?:most|all|no|every)\s+(?:researchers|studies|experts|evidence|economists|scientists)\b|\b(?:studies|research|data|evidence)\s+(?:show|shows|prove|proves|demonstrate|demonstrates|confirm|confirms)\b"#,
        options: [.caseInsensitive]
    )

    static let acronymPattern = try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]{1,5}s?\b"#)

    /// Runs every check against the document. Notes about the section under
    /// the cursor are anchored to it; document-level notes (thin sections,
    /// overlapping titles) are anchored to the section they name. Sections
    /// tagged `[no-ai]` and fenced code are never read.
    public static func run(text: String, cursorUTF16: Int) -> [FeedbackItem] {
        let outline = DocumentOutline.parse(text)
        let current = outline.section(atUTF16Offset: cursorUTF16)
        if let current, current.excludedFromAI { return [] }

        var findings: [FeedbackItem] = []

        let currentBody: String
        if let current {
            currentBody = stripCode(DocumentOutline.body(of: current, in: text))
        } else {
            currentBody = stripCode(text)
        }
        let currentTitle = current?.title

        checkUncitedClaims(in: currentBody, section: currentTitle, into: &findings)
        checkUndefinedAcronyms(in: currentBody, section: currentTitle, into: &findings)
        checkHedgeDensity(in: currentBody, section: currentTitle, into: &findings)

        let visible = outline.sections.filter { !$0.excludedFromAI && $0.level == 2 }
        checkThinSections(visible, current: current, text: text, into: &findings)
        checkTitleOverlap(visible, into: &findings)

        return Array(findings.prefix(maxFindings))
    }

    // MARK: - Rules

    static func checkUncitedClaims(in body: String, section: String?, into findings: inout [FeedbackItem]) {
        var reported = 0
        for sentence in sentences(of: body) where reported < 2 {
            guard sentence.count >= 25 else { continue }
            let range = NSRange(sentence.startIndex..., in: sentence)
            guard let match = claimPattern.firstMatch(in: sentence, range: range),
                  citationPattern.firstMatch(in: sentence, range: range) == nil,
                  let matched = Range(match.range, in: sentence) else { continue }
            let claim = String(sentence[matched])
            findings.append(FeedbackItem(
                kind: .evidence,
                anchor: anchorText(sentence),
                text: "“\(claim)” is stated as fact with nothing behind it.",
                why: "A reader who doubts it has no way to check, so the sentence carries no weight.",
                severity: .major,
                source: .local,
                rule: "uncited-claim",
                section: section
            ))
            reported += 1
        }
    }

    static func checkHedgeDensity(in body: String, section: String?, into findings: inout [FeedbackItem]) {
        let words = body.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard words.count >= 120 else { return }
        let hedges = words.filter { hedgeWords.contains($0.trimmingCharacters(in: .punctuationCharacters)) }.count
        let per100 = Double(hedges) / Double(words.count) * 100
        guard per100 > 4 else { return }
        findings.append(FeedbackItem(
            kind: .clarity,
            text: "\(hedges) hedges in \(words.count) words — might, could, seems, perhaps.",
            why: "Hedged this often, the section never says what you actually think; a reader cannot disagree with it, and so cannot be persuaded by it.",
            severity: .minor,
            source: .local,
            rule: "hedge-density",
            section: section
        ))
    }

    static func checkUndefinedAcronyms(in body: String, section: String?, into findings: inout [FeedbackItem]) {
        let ns = body as NSString
        var counts: [String: Int] = [:]
        var order: [String] = []
        for match in acronymPattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            var acronym = ns.substring(with: match.range)
            if acronym.hasSuffix("s"), acronym.count > 2 { acronym.removeLast() }
            guard acronym.count >= 2, !acronymAllowList.contains(acronym),
                  acronym.rangeOfCharacter(from: .decimalDigits) == nil || acronym.count > 2 else { continue }
            if counts[acronym] == nil { order.append(acronym) }
            counts[acronym, default: 0] += 1
        }
        var reported = 0
        for acronym in order where reported < 2 {
            guard let count = counts[acronym], count >= 2 else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: acronym)
            let defined = body.range(of: #"\b"# + escaped + #"s?\s*\("#, options: .regularExpression) != nil
                || body.range(of: #"\(\s*"# + escaped + #"s?\s*\)"#, options: .regularExpression) != nil
            guard !defined else { continue }
            findings.append(FeedbackItem(
                kind: .clarity,
                anchor: acronym,
                text: "“\(acronym)” is used \(count)× and never defined.",
                why: "Every reader who does not already know it stops here.",
                severity: .minor,
                source: .local,
                rule: "undefined-term",
                section: section
            ))
            reported += 1
        }
    }

    static func checkThinSections(
        _ sections: [OutlineSection],
        current: OutlineSection?,
        text: String,
        into findings: inout [FeedbackItem]
    ) {
        guard sections.count >= 2 else { return }
        var reported = 0
        for section in sections where reported < 2 {
            // The section being written is thin because it is being written.
            if let current, current.headingStart == section.headingStart { continue }
            let body = stripCode(DocumentOutline.body(of: section, in: text))
            let wordCount = body.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            guard wordCount < 25 else { continue }
            findings.append(FeedbackItem(
                kind: .gap,
                text: wordCount == 0
                    ? "“\(section.title)” is a heading with nothing under it."
                    : "“\(section.title)” has \(wordCount) words — a heading, not an argument.",
                why: "A reader takes the outline as a promise; an empty section is a promise the document breaks.",
                severity: .minor,
                source: .local,
                rule: "thin-section",
                section: section.title
            ))
            reported += 1
        }
    }

    static func checkTitleOverlap(_ sections: [OutlineSection], into findings: inout [FeedbackItem]) {
        guard sections.count >= 2 else { return }
        var firstTitle: [String: String] = [:]
        for section in sections {
            let words = section.title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 4 && !titleStopWords.contains($0) }
            for word in words {
                if let earlier = firstTitle[word], earlier != section.title {
                    findings.append(FeedbackItem(
                        kind: .mece,
                        text: "“\(earlier)” and “\(section.title)” both turn on “\(word)”.",
                        why: "Two sections about the same thing either overlap or split one argument in half; the reader cannot tell which.",
                        severity: .major,
                        source: .local,
                        rule: "title-overlap",
                        section: section.title
                    ))
                    return // one MECE hint at most
                }
                if firstTitle[word] == nil { firstTitle[word] = section.title }
            }
        }
    }

    // MARK: - Text helpers

    /// Removes fenced code blocks; a `%` in a shell snippet is not a claim.
    static func stripCode(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// Splits prose into sentences on terminal punctuation followed by space
    /// or a line break. Good enough for counting; never used for display
    /// beyond the anchor.
    static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character? = nil
        for char in text {
            if let previous, ".!?".contains(previous), char.isWhitespace {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
            current.append(char)
            previous = char
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    /// The first words of a sentence, enough for the writer to find it.
    static func anchorText(_ sentence: String) -> String {
        let words = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard words.count > 15 else { return sentence }
        return words.prefix(15).joined(separator: " ")
    }
}
