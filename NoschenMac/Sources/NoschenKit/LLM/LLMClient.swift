import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ChatRole: String, Codable, Sendable {
    case system, user, assistant
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public let role: ChatRole
    public let content: String

    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { ChatMessage(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { ChatMessage(role: .user, content: content) }
}

public struct CompletionOptions: Sendable {
    public var temperature: Double
    public var maxTokens: Int
    /// Ask the backend to constrain output to JSON where the API supports it
    /// (Ollama's `format: "json"`). Prompts must still demand JSON — this is
    /// belt and suspenders for small local models.
    public var jsonMode: Bool

    public init(temperature: Double = 0.4, maxTokens: Int = 1024, jsonMode: Bool = false) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.jsonMode = jsonMode
    }
}

public enum LLMError: Error, LocalizedError, Equatable {
    case invalidBaseURL(String)
    case insecureURL(String)
    case http(status: Int, message: String)
    case emptyResponse
    case cannotConnect(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "Invalid server URL: \(url)"
        case .insecureURL(let url):
            return "This provider requires HTTPS: \(url)"
        case .http(let status, let message):
            return message.isEmpty ? "Server returned HTTP \(status)" : "HTTP \(status): \(message)"
        case .emptyResponse:
            return "The model returned an empty response"
        case .cannotConnect(let detail):
            return "Cannot reach the server. \(detail)"
        }
    }
}

/// A chat-capable LLM backend. All Noschen features go through this protocol,
/// so any provider that can complete a chat works everywhere in the app.
public protocol LLMClient: Sendable {
    var providerName: String { get }
    /// Models the server currently offers (used for pickers and as a
    /// connection test).
    func listModels() async throws -> [String]
    /// One-shot completion; returns the assistant message content.
    func complete(_ messages: [ChatMessage], model: String, options: CompletionOptions) async throws -> String
    /// Streaming completion; yields content deltas as they arrive.
    func stream(_ messages: [ChatMessage], model: String, options: CompletionOptions) -> AsyncThrowingStream<String, Error>
}

enum LLMHTTP {
    /// Validates and normalizes a user-entered base URL. Plain HTTP is only
    /// ever accepted for hosts on the local machine or network (`allowInsecure`
    /// merely opts a provider into that local exception) — a remote provider
    /// over HTTP would leak notes and API keys in cleartext.
    static func normalizeBaseURL(_ raw: String, allowInsecure: Bool) throws -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host else {
            throw LLMError.invalidBaseURL(raw)
        }
        guard scheme == "https" || scheme == "http" else {
            throw LLMError.invalidBaseURL(raw)
        }
        if scheme == "http" && !(allowInsecure && isLocalHost(host)) {
            throw LLMError.insecureURL(raw)
        }
        return url
    }

    /// True for hosts that stay on this machine or the local network:
    /// loopback, RFC 1918 / link-local / CGNAT IPv4, loopback / link-local /
    /// unique-local IPv6, single-label hostnames, and mDNS-style suffixes.
    static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }

        // IPv4 private / loopback / link-local / CGNAT ranges.
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }

        // IPv6 loopback / link-local / unique-local.
        if host.contains(":") {
            return host.hasPrefix("fe80:") || host.hasPrefix("fd") || host.hasPrefix("fc")
        }

        // Single-label hostnames ("mymac") and local-only DNS suffixes.
        if !host.contains(".") { return true }
        for suffix in [".local", ".lan", ".internal", ".home.arpa"] where host.hasSuffix(suffix) {
            return true
        }
        return false
    }

    static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpAdditionalHeaders = ["User-Agent": "Noschen/1.0 (macOS)"]
        return URLSession(configuration: config)
    }

    static func jsonRequest(url: URL, body: some Encodable, headers: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Extracts a human-readable error message from a JSON error body.
    static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8) ?? ""
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let error = object["error"] as? String {
            return error
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? ""
    }

    static func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, message: errorMessage(from: data))
        }
    }
}
