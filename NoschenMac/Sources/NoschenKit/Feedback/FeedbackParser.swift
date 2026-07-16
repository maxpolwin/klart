import Foundation

/// Turns raw model output into feedback items. Models — especially small
/// local ones — wrap JSON in prose or code fences, so the parser is
/// deliberately forgiving: it finds the JSON, salvages what it can, and
/// never throws garbage at the UI.
public enum FeedbackParser {
    private struct Payload: Decodable {
        let feedback: [RawItem]
    }

    private struct RawItem: Decodable {
        let type: String?
        let text: String?
        let suggestion: String?
        let section: String?
    }

    /// Parses model output into feedback items. Returns an empty array when
    /// no usable JSON is found.
    public static func parse(_ raw: String) -> [FeedbackItem] {
        guard let jsonString = extractJSONObject(from: raw),
              let data = jsonString.data(using: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        var rawItems: [RawItem] = []
        if let payload = try? decoder.decode(Payload.self, from: data) {
            rawItems = payload.feedback
        } else if let array = try? decoder.decode([RawItem].self, from: data) {
            // Some models return a bare array of items.
            rawItems = array
        }

        return rawItems.compactMap { item in
            guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            let suggestion = item.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines)
            return FeedbackItem(
                kind: FeedbackKind.fromModelString(item.type ?? ""),
                text: text,
                suggestion: (suggestion?.isEmpty ?? true) ? nil : suggestion,
                section: item.section
            )
        }
    }

    /// Extracts the first balanced JSON object or array from arbitrary text,
    /// ignoring code fences and surrounding prose. Handles strings and
    /// escapes so braces inside values don't fool the scanner.
    static func extractJSONObject(from raw: String) -> String? {
        var text = raw
        // Strip code fences if the whole payload is fenced.
        if let fenceStart = text.range(of: "```") {
            let afterFence = text[fenceStart.upperBound...]
            if let fenceEnd = afterFence.range(of: "```") {
                var inner = String(afterFence[..<fenceEnd.lowerBound])
                // Drop a leading language tag like "json".
                if let newline = inner.firstIndex(of: "\n") {
                    let firstLine = inner[..<newline].trimmingCharacters(in: .whitespaces)
                    if firstLine.lowercased() == "json" {
                        inner = String(inner[inner.index(after: newline)...])
                    }
                }
                text = inner
            }
        }

        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opener = text[start]
        let closer: Character = opener == "{" ? "}" : "]"

        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if inString {
                if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else {
                switch char {
                case "\"": inString = true
                case opener: depth += 1
                case closer:
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }

        // Unbalanced (model was cut off): try to close open structures so we
        // can salvage complete items.
        return salvageTruncated(String(text[start...]))
    }

    /// Best-effort repair of truncated JSON: cut back to the last complete
    /// object inside a "feedback" array and close the wrappers.
    private static func salvageTruncated(_ fragment: String) -> String? {
        guard fragment.first == "{" || fragment.first == "[" else { return nil }
        // Find the last "}," or "}" that closes an item object.
        guard let lastBrace = fragment.lastIndex(of: "}") else { return nil }
        let head = String(fragment[...lastBrace])
        // Try progressively closing wrappers.
        for suffix in ["]}", "]", "}"] {
            let candidate = head + suffix
            if let data = candidate.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return candidate
            }
        }
        return nil
    }
}
