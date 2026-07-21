import Foundation

/// Errors from the in-process llama.cpp runtime.
public enum LlamaBridgeError: Error, LocalizedError, Equatable {
    /// This build was compiled without the vendored llama.xcframework.
    case runtimeUnavailable
    case modelLoadFailed(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "This build doesn't include the built-in model runtime. Build with the vendored llama.xcframework (see NoschenMac/Docs/BUILTIN_MODEL.md) or pick another provider in Settings."
        case .modelLoadFailed(let detail):
            return "Couldn't load the built-in model. \(detail)"
        case .generationFailed(let detail):
            return "The built-in model failed while generating. \(detail)"
        }
    }
}

#if canImport(llama)
import llama

/// One loaded GGUF model. Weights stay resident for the lifetime of the
/// instance; a fresh llama context is created per `generate` call, which
/// keeps calls independent without relying on KV-cache management APIs.
///
/// Not internally synchronized — callers (BuiltinModelRuntime) must serialize
/// access. @unchecked: the underlying C pointers are only touched from one
/// caller at a time by that contract.
public final class LlamaInstance: @unchecked Sendable {
    public static let isRuntimeAvailable = true

    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let contextTokens: Int32

    /// - Parameters:
    ///   - modelPath: absolute path to a .gguf file
    ///   - contextTokens: n_ctx for generation contexts
    ///   - gpuOffload: offload all layers to Metal (false on Intel: CPU only)
    public init(modelPath: String, contextTokens: Int, gpuOffload: Bool) throws {
        llama_backend_init()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuOffload ? 999 : 0
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaBridgeError.modelLoadFailed("llama.cpp rejected \(modelPath).")
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            throw LlamaBridgeError.modelLoadFailed("Model has no vocabulary.")
        }
        self.model = model
        self.vocab = vocab
        self.contextTokens = Int32(contextTokens)
    }

    deinit {
        llama_model_free(model)
    }

    /// Runs one completion over a fully templated prompt.
    ///
    /// `onToken` receives each decoded text chunk; return false to stop
    /// generation early (cancellation). Returns the full generated text.
    public func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        grammar: String?,
        onToken: (String) -> Bool
    ) throws -> String {
        var tokens = try tokenize(prompt)

        // Leave room for at least a short answer; PromptBuilder's clipping
        // keeps real prompts well inside n_ctx, so this only trips on abuse.
        let reserved: Int32 = 64
        guard Int32(tokens.count) < contextTokens - reserved else {
            throw LlamaBridgeError.generationFailed(
                "Prompt is too long for the model's context window (\(tokens.count) tokens, limit \(contextTokens))."
            )
        }
        let budget = min(Int32(max(1, maxTokens)), contextTokens - Int32(tokens.count) - 8)

        let batchSize = 512
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextTokens)
        contextParams.n_batch = UInt32(batchSize)
        guard let context = llama_init_from_model(model, contextParams) else {
            throw LlamaBridgeError.generationFailed("Couldn't create an inference context (out of memory?).")
        }
        defer { llama_free(context) }

        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw LlamaBridgeError.generationFailed("Couldn't create the sampler chain.")
        }
        defer { llama_sampler_free(sampler) }
        if let grammar {
            guard let grammarSampler = llama_sampler_init_grammar(vocab, grammar, "root") else {
                throw LlamaBridgeError.generationFailed("The JSON grammar was rejected by llama.cpp.")
            }
            llama_sampler_chain_add(sampler, grammarSampler)
        }
        if temperature <= 0.01 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(temperature)))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: .min ... .max)))
        }

        // Feed the prompt in n_batch-sized chunks (llama_decode rejects
        // batches larger than n_batch), then decode one token at a time.
        var offset = 0
        while offset < tokens.count {
            let count = min(batchSize, tokens.count - offset)
            let status = tokens[offset..<(offset + count)].withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard status == 0 else {
                throw LlamaBridgeError.generationFailed("Prompt evaluation failed (llama_decode status \(status)).")
            }
            offset += count
        }

        var accumulator = UTF8Accumulator()
        var output = ""
        var generated: Int32 = 0
        while generated < budget {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            let chunk = accumulator.append(pieceBytes(for: token))
            if !chunk.isEmpty {
                output += chunk
                if !onToken(chunk) { return output }
            }

            var next = token
            let status = withUnsafeMutablePointer(to: &next) { pointer in
                llama_decode(context, llama_batch_get_one(pointer, 1))
            }
            guard status == 0 else {
                throw LlamaBridgeError.generationFailed("Decoding failed mid-generation (llama_decode status \(status)).")
            }
            generated += 1
        }
        let tail = accumulator.flush()
        if !tail.isEmpty {
            output += tail
            _ = onToken(tail)
        }
        return output
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 16)
        var written = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), true, true)
        if written < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-written))
            written = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), true, true)
        }
        guard written >= 0 else {
            throw LlamaBridgeError.generationFailed("Tokenization failed.")
        }
        return Array(tokens[0..<Int(written)])
    }

    /// Raw UTF-8 bytes for one token. Pieces can split multi-byte characters,
    /// so callers must reassemble via UTF8Accumulator rather than decoding
    /// each piece independently.
    private func pieceBytes(for token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        guard written > 0 else { return [] }
        return buffer[0..<Int(written)].map { UInt8(bitPattern: $0) }
    }
}

#else

/// Stub used when the vendored llama.xcframework isn't part of the build
/// (CI, non-Mac tooling, or a checkout without the binary artifact). Keeps
/// the package compiling; every entry point reports the runtime as missing.
public final class LlamaInstance: @unchecked Sendable {
    public static let isRuntimeAvailable = false

    public init(modelPath: String, contextTokens: Int, gpuOffload: Bool) throws {
        throw LlamaBridgeError.runtimeUnavailable
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        grammar: String?,
        onToken: (String) -> Bool
    ) throws -> String {
        throw LlamaBridgeError.runtimeUnavailable
    }
}

#endif
