import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for Ollama's native API (`/api/chat`, `/api/tags`).
/// @unchecked: all state is immutable and URLSession is thread-safe.
public final class OllamaClient: LLMClient, @unchecked Sendable {
    public let providerName = "Ollama"

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: String, timeout: TimeInterval = 120) throws {
        self.baseURL = try LLMHTTP.normalizeBaseURL(baseURL, allowInsecure: true)
        self.session = LLMHTTP.session(timeout: timeout)
    }

    // MARK: - Wire types

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private struct ChatRequest: Encodable {
        struct Options: Encodable {
            let temperature: Double
            let num_predict: Int
        }
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let format: String?
        let options: Options
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message?
        let done: Bool?
    }

    // MARK: - LLMClient

    public func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        do {
            let (data, response) = try await session.data(from: url)
            try LLMHTTP.checkResponse(response, data: data)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            return tags.models.map(\.name).sorted()
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.cannotConnect("Is Ollama running? (\(error.localizedDescription))")
        }
    }

    private func chatRequest(_ messages: [ChatMessage], model: String, options: CompletionOptions, stream: Bool) throws -> URLRequest {
        let body = ChatRequest(
            model: model,
            messages: messages,
            stream: stream,
            format: options.jsonMode ? "json" : nil,
            options: .init(temperature: options.temperature, num_predict: options.maxTokens)
        )
        return try LLMHTTP.jsonRequest(url: baseURL.appendingPathComponent("api/chat"), body: body, headers: [:])
    }

    public func complete(_ messages: [ChatMessage], model: String, options: CompletionOptions) async throws -> String {
        let request = try chatRequest(messages, model: model, options: options, stream: false)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.cannotConnect("Is Ollama running? (\(error.localizedDescription))")
        }
        try LLMHTTP.checkResponse(response, data: data)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.message?.content, !content.isEmpty else {
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
                    // Ollama streams newline-delimited JSON objects.
                    for try await line in bytes.lines {
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        guard let chunk = try? JSONDecoder().decode(ChatResponse.self, from: data) else { continue }
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(content)
                        }
                        if chunk.done == true { break }
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
