import Foundation
import Dispatch
import LlamaBridge

/// Seam between NoschenKit and the llama.cpp engine, so tests can run the
/// full client/runtime plumbing without model weights.
public protocol BuiltinEngine: AnyObject, Sendable {
    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        grammar: String?,
        onToken: (String) -> Bool
    ) throws -> String
}

extension LlamaInstance: BuiltinEngine {}

/// Process-wide owner of the loaded built-in model.
///
/// `ProviderFactory.makeClient` builds a fresh client on every feedback
/// round, so clients must be cheap — the expensive part (model weights)
/// lives here, loaded lazily and kept resident between requests. Inference
/// runs strictly one at a time; concurrent callers queue.
public actor BuiltinModelRuntime {
    public static let shared = BuiltinModelRuntime()

    /// How long the model stays resident after the last request.
    private let idleUnloadInterval: Duration

    private let makeEngine: @Sendable (String, Int) throws -> any BuiltinEngine
    private var engine: (any BuiltinEngine)?
    private var loadedModelID: String?
    private var inference: Task<String, Error>?
    private var idleUnloadTask: Task<Void, Never>?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    public init(
        makeEngine: @escaping @Sendable (String, Int) throws -> any BuiltinEngine = { path, contextTokens in
            #if arch(x86_64)
            let gpuOffload = false  // ggml's Metal backend needs an Apple GPU
            #else
            let gpuOffload = true
            #endif
            return try LlamaInstance(modelPath: path, contextTokens: contextTokens, gpuOffload: gpuOffload)
        },
        idleUnloadInterval: Duration = .seconds(15 * 60)
    ) {
        self.makeEngine = makeEngine
        self.idleUnloadInterval = idleUnloadInterval
    }

    /// Whether this build can run the built-in model at all (i.e. was
    /// compiled with the vendored llama.xcframework).
    public static var isRuntimeAvailable: Bool { LlamaInstance.isRuntimeAvailable }

    /// Runs one completion. Serialized: a request that arrives while another
    /// runs waits its turn. Cancellation of the calling task stops decoding
    /// at the next token boundary.
    public func generate(
        model: BuiltinModel,
        modelsDirectory: URL,
        messages: [ChatMessage],
        options: CompletionOptions,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard ModelRegistry.isInstalled(model, in: modelsDirectory) else {
            throw LLMError.modelNotInstalled(model.sizeLabel)
        }

        let engine = try loadedEngine(for: model, in: modelsDirectory)
        idleUnloadTask?.cancel()

        let prompt = ChatMLTemplate.render(messages.map {
            ChatMLTemplate.Turn(role: $0.role.rawValue, content: $0.content)
        })
        let grammar = options.jsonMode ? JSONGrammar.object : nil
        let temperature = options.temperature
        let maxTokens = options.maxTokens

        // Chain onto the previous inference so runs never overlap, without
        // blocking the actor while the C decode loop spins.
        let previous = inference
        let work = Task.detached(priority: .userInitiated) { () async throws -> String in
            _ = await previous?.result
            try Task.checkCancellation()
            return try engine.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                temperature: temperature,
                grammar: grammar
            ) { chunk in
                onToken(chunk)
                return !Task.isCancelled
            }
        }
        inference = work

        defer {
            if inference == work { inference = nil }
            scheduleIdleUnload()
        }
        return try await withTaskCancellationHandler {
            let output = try await work.value
            try Task.checkCancellation()
            return output
        } onCancel: {
            work.cancel()
        }
    }

    /// Frees the resident model (weights and all).
    public func unload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        engine = nil
        loadedModelID = nil
    }

    /// Unloads if the given model is the resident one (used after deleting
    /// its weights from disk).
    public func unloadIfLoaded(modelID: String) {
        if loadedModelID == modelID {
            unload()
        }
    }

    // MARK: - Internals

    private func loadedEngine(for model: BuiltinModel, in directory: URL) throws -> any BuiltinEngine {
        if let engine, loadedModelID == model.id {
            return engine
        }
        // Switching models: drop the old weights before loading new ones.
        engine = nil
        loadedModelID = nil
        let path = ModelRegistry.fileURL(for: model, in: directory).path
        do {
            let fresh = try makeEngine(path, model.contextLength)
            engine = fresh
            loadedModelID = model.id
            installMemoryPressureSourceIfNeeded()
            return fresh
        } catch let error as LlamaBridgeError {
            throw LLMError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [idleUnloadInterval] in
            try? await Task.sleep(for: idleUnloadInterval)
            guard !Task.isCancelled else { return }
            await self.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard inference == nil else { return }
        unload()
    }

    private func installMemoryPressureSourceIfNeeded() {
        #if os(macOS)
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.unloadIfIdle() }
        }
        source.resume()
        memoryPressureSource = source
        #endif
    }
}
