import Foundation

/// Renders coach output for display.
///
/// Coach output is model text, and the model is not trusted: a compromised
/// endpoint, or a note that carries pasted instructions, can make it emit
/// `[a harmless label](x-some-app://payload)`. Inline markdown keeps its
/// emphasis and code styling, but every link and image target is removed, so
/// nothing in the panel can open a URL.
public enum CoachText {
    public static func render(_ raw: String) -> AttributedString {
        var text = (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
        let targets = text.runs
            .filter { $0.link != nil || $0.imageURL != nil }
            .map(\.range)
        for range in targets {
            text[range].link = nil
            text[range].imageURL = nil
        }
        return text
    }
}
