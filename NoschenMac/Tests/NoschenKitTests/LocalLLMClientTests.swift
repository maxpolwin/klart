import XCTest
@testable import NoschenKit
import LlamaBridge

/// Scripted engine so client/runtime plumbing runs without model weights.
final class FakeEngine: BuiltinEngine, @unchecked Sendable {
    struct Call {
        let prompt: String
        let maxTokens: Int
        let temperature: Double
        let grammar: String?
    }

    let chunks: [String]
    private(set) var calls: [Call] = []

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        grammar: String?,
        onToken: (String) -> Bool
    ) throws -> String {
        calls.append(Call(prompt: prompt, maxTokens: maxTokens, temperature: temperature, grammar: grammar))
        var output = ""
        for chunk in chunks {
            output += chunk
            if !onToken(chunk) { break }
        }
        return output
    }
}

final class LocalLLMClientTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noschen-local-llm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A registry model whose installation can be faked with a small file
    /// (i.e. one without an exact pinned size).
    private var fakeableModel: BuiltinModel {
        ModelRegistry.models.first { $0.sizeBytes == nil } ?? ModelRegistry.models[0]
    }

    private func installFake(_ model: BuiltinModel) throws {
        if let size = model.sizeBytes {
            let url = ModelRegistry.fileURL(for: model, in: tempDir)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
        } else {
            try Data("fake weights".utf8).write(to: ModelRegistry.fileURL(for: model, in: tempDir))
        }
    }

    private func makeClient(engine: FakeEngine) -> LocalLLMClient {
        let runtime = BuiltinModelRuntime(makeEngine: { _, _ in engine })
        return LocalLLMClient(modelsDirectory: tempDir, runtime: runtime)
    }

    func testListModelsThrowsWhenNothingInstalled() async {
        let client = makeClient(engine: FakeEngine(chunks: []))
        do {
            _ = try await client.listModels()
            XCTFail("expected modelNotInstalled")
        } catch let error as LLMError {
            guard case .modelNotInstalled = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("Settings"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testListModelsReturnsInstalledIDs() async throws {
        let model = fakeableModel
        try installFake(model)
        let client = makeClient(engine: FakeEngine(chunks: []))
        let models = try await client.listModels()
        XCTAssertEqual(models, [model.id])
    }

    func testCompletePlumbsOptionsAndTemplatesChatML() async throws {
        let model = fakeableModel
        try installFake(model)
        let engine = FakeEngine(chunks: ["{\"feedback\"", ":[]}"])
        let client = makeClient(engine: engine)

        let messages: [ChatMessage] = [
            .system("You are a coach."),
            .user("My section text."),
        ]
        let options = CompletionOptions(temperature: 0.3, maxTokens: 512, jsonMode: true)
        let output = try await client.complete(messages, model: model.id, options: options)

        XCTAssertEqual(output, "{\"feedback\":[]}")
        XCTAssertEqual(engine.calls.count, 1)
        let call = engine.calls[0]
        XCTAssertEqual(call.temperature, 0.3)
        XCTAssertEqual(call.maxTokens, 512)
        XCTAssertNotNil(call.grammar, "jsonMode must attach the JSON grammar")
        XCTAssertTrue(call.prompt.contains("<|im_start|>system\nYou are a coach.<|im_end|>"))
        XCTAssertTrue(call.prompt.contains("<|im_start|>user\nMy section text.<|im_end|>"))
        XCTAssertTrue(call.prompt.hasSuffix("<|im_start|>assistant\n"))
    }

    func testCompleteWithoutJSONModeHasNoGrammar() async throws {
        let model = fakeableModel
        try installFake(model)
        let engine = FakeEngine(chunks: ["hello"])
        let client = makeClient(engine: engine)

        _ = try await client.complete([.user("hi")], model: model.id, options: CompletionOptions())
        XCTAssertNil(engine.calls[0].grammar)
    }

    func testCompleteEmptyOutputThrowsEmptyResponse() async throws {
        let model = fakeableModel
        try installFake(model)
        let client = makeClient(engine: FakeEngine(chunks: ["  \n"]))
        do {
            _ = try await client.complete([.user("hi")], model: model.id, options: CompletionOptions())
            XCTFail("expected emptyResponse")
        } catch let error as LLMError {
            XCTAssertEqual(error, .emptyResponse)
        }
    }

    func testCompleteWithoutInstalledModelThrows() async {
        let client = makeClient(engine: FakeEngine(chunks: ["x"]))
        do {
            _ = try await client.complete([.user("hi")], model: fakeableModel.id, options: CompletionOptions())
            XCTFail("expected modelNotInstalled")
        } catch let error as LLMError {
            guard case .modelNotInstalled = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStreamYieldsChunks() async throws {
        let model = fakeableModel
        try installFake(model)
        let client = makeClient(engine: FakeEngine(chunks: ["one ", "two ", "three"]))

        var received: [String] = []
        for try await chunk in client.stream([.user("go")], model: model.id, options: CompletionOptions()) {
            received.append(chunk)
        }
        XCTAssertEqual(received, ["one ", "two ", "three"])
    }

    func testUnknownModelIDFallsBackToDefault() async throws {
        let defaultModel = ModelRegistry.model(id: ModelRegistry.defaultModelID)!
        try installFake(defaultModel)
        let engine = FakeEngine(chunks: ["ok"])
        let client = makeClient(engine: engine)

        let output = try await client.complete([.user("hi")], model: "some-stale-id", options: CompletionOptions())
        XCTAssertEqual(output, "ok")
    }
}
