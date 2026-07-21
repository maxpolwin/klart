import XCTest
@testable import NoschenKit
import LlamaBridge

/// Real-inference smoke test. Entirely skipped unless the developer points
/// NOSCHEN_BUILTIN_MODEL_PATH at a local GGUF (any small instruct model,
/// e.g. Qwen2.5-0.5B-Instruct Q4_K_M) AND the build includes the vendored
/// llama.xcframework. Never runs in CI: no env var, no weights, no runtime.
final class BuiltinIntegrationTests: XCTestCase {
    private var modelPath: String? {
        ProcessInfo.processInfo.environment["NOSCHEN_BUILTIN_MODEL_PATH"]
    }

    func testJSONModeCompletionParsesAsFeedback() throws {
        guard let modelPath, LlamaInstance.isRuntimeAvailable else {
            throw XCTSkip("Set NOSCHEN_BUILTIN_MODEL_PATH and build with the vendored llama.xcframework to run this.")
        }

        let instance = try LlamaInstance(modelPath: modelPath, contextTokens: 4096, gpuOffload: false)
        let prompt = ChatMLTemplate.render([
            .init(
                role: "system",
                content: #"Reply with strict JSON of the shape {"feedback":[{"type":"clarity","text":"...","suggestion":"..."}]} and nothing else."#
            ),
            .init(role: "user", content: "Give one clarity tip for the sentence: Things are maybe somewhat better now."),
        ])

        var chunks = 0
        let output = try instance.generate(
            prompt: prompt,
            maxTokens: 256,
            temperature: 0,
            grammar: JSONGrammar.object
        ) { _ in
            chunks += 1
            return true
        }

        XCTAssertGreaterThan(chunks, 1, "generation should stream token by token")
        let data = try XCTUnwrap(output.data(using: .utf8))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "grammar-constrained output must be valid JSON: \(output)")
        XCTAssertNotNil(parsed["feedback"] ?? parsed.values.first, "expected some JSON object content: \(output)")
    }
}
