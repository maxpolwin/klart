import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for any OpenAI-compatible chat API: LM Studio, OpenRouter,
/// llama.cpp server, vLLM, LocalAI, and most gateways.
/// @unchecked: all state is immutable and URLSession is thread-safe.
public final class OpenAICompatClient: LLMClient, @unchecked Sendable {
    public let providerName: String

    private let baseURL: URL
    private let apiKey: String?
    private let extraHeaders: [String: String]
    private let session: URLSession

    public init(
        providerName: String,
        baseURL: String,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        allowInsecure: Bool = true,
        timeout: TimeInterval = 120
    ) throws {
        self.providerName = providerName
        self.baseURL = try LLMHTTP.normalizeBaseURL(baseURL, allowInsecure: allowInsecure)
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.extraHeaders = extraHeaders
        self.session = LLMHTTP.session(timeout: timeout)
    }

    private var headers: [String: String] {
        var headers = extraHeaders
        if let apiKey {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    // MARK: - Wire types

    private struct ModelsResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
        }
        let choices: [Choice]?
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    // MARK: - LLMClient

    public func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.cannotConnect("Is \(providerName) running / reachable? (\(error.localizedDescription))")
        }
        try LLMHTTP.checkResponse(response, data: data)
        let models = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return models.data.map(\.id).sorted()
    }

    private func chatRequest(_ messages: [ChatMessage], model: String, options: CompletionOptions, stream: Bool) throws -> URLRequest {
        let body = ChatRequest(
            model: model,
            messages: messages,
            temperature: options.temperature,
            max_tokens: options.maxTokens,
            stream: stream
        )
        return try LLMHTTP.jsonRequest(url: baseURL.appendingPathComponent("chat/completions"), body: body, headers: headers)
    }

    public func complete(_ messages: [ChatMessage], model: String, options: CompletionOptions) async throws -> String {
        let request = try chatRequest(messages, model: model, options: options, stream: false)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.cannotConnect("Is \(providerName) running / reachable? (\(error.localizedDescription))")
        }
        try LLMHTTP.checkResponse(response, data: data)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices?.first?.message?.content, !content.isEmpty else {
            throw LLMError.emptyResponse
        }
        return content
    }

    public func stream(_ messages: [ChatMessage], model: String, options: CompletionOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [session] in
                do {
                    let request = try self.chatRequest(messages, model: model, options: options, stream: true)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.utf8.count > 2000 { break }
                        }
                        throw LLMError.http(status: http.statusCode, message: LLMHTTP.errorMessage(from: Data(body.utf8)))
                    }
                    // Server-sent events: lines of `data: {json}` ending with `data: [DONE]`.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                              let content = chunk.choices?.first?.delta?.content,
                              !content.isEmpty else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
