import Foundation

/// Renders chat turns into the ChatML prompt format used by the Qwen family
/// (both built-in registry models). Kept as a pure function in Swift instead
/// of calling llama.cpp's template engine: one less piece of C API surface,
/// and it's unit-testable without model weights.
public enum ChatMLTemplate {
    public struct Turn: Equatable, Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Full prompt ending with an open assistant turn for generation.
    public static func render(_ turns: [Turn]) -> String {
        var prompt = ""
        for turn in turns {
            prompt += "<|im_start|>\(turn.role)\n\(turn.content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}
