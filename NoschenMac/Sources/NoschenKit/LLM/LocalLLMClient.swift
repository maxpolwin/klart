import Foundation

/// The built-in provider: runs a small model in-process via llama.cpp.
/// No server, no port, no account — the model file is the whole dependency.
/// @unchecked: all stored state is immutable; the actor-based runtime
/// serializes the mutable parts.
public final class LocalLLMClient: LLMClient, @unchecked Sendable {
    public let providerName = "Built-in"

    private let modelsDirectory: URL
    private let runtime: BuiltinModelRuntime

    public init(
        modelsDirectory: URL = ModelRegistry.modelsDirectory(),
        runtime: BuiltinModelRuntime = .shared
    ) {
        self.modelsDirectory = modelsDirectory
        self.runtime = runtime
    }

    /// Installed models. Doubles as the "Test Connection" check: with
    /// nothing downloaded it throws an actionable error instead of
    /// returning an empty list.
    public func listModels() async throws -> [String] {
        let installed = ModelRegistry.installedModels(in: modelsDirectory)
        guard !installed.isEmpty else {
            throw LLMError.modelNotInstalled(ModelRegistry.model(id: ModelRegistry.defaultModelID)?.sizeLabel ?? "")
        }
        return installed.map(\.id)
    }

    public func complete(_ messages: [ChatMessage], model: String, options: CompletionOptions) async throws -> String {
        let resolved = resolve(model)
        let output = try await runtime.generate(
            model: resolved,
            modelsDirectory: modelsDirectory,
            messages: messages,
            options: options,
            onToken: { _ in }
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMError.emptyResponse
        }
        return output
    }

    public func stream(_ messages: [ChatMessage], model: String, options: CompletionOptions) -> AsyncThrowingStream<String, Error> {
        let resolved = resolve(model)
        let runtime = runtime
        let modelsDirectory = modelsDirectory
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await runtime.generate(
                        model: resolved,
                        modelsDirectory: modelsDirectory,
                        messages: messages,
                        options: options,
                        onToken: { chunk in _ = continuation.yield(chunk) }
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Registry ids are what settings store; fall back to the default model
    /// for unknown values (e.g. a hand-edited settings file).
    private func resolve(_ modelID: String) -> BuiltinModel {
        ModelRegistry.model(id: modelID)
            ?? ModelRegistry.model(id: ModelRegistry.defaultModelID)!
    }
}
