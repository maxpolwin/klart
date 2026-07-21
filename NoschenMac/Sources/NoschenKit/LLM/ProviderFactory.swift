import Foundation

/// Builds a concrete `LLMClient` from the user's settings and secret store.
public enum ProviderFactory {
    public static func makeClient(
        kind: ProviderKind,
        config: ProviderConfig,
        secrets: SecretStore
    ) throws -> any LLMClient {
        switch kind {
        case .builtin:
            return LocalLLMClient()
        case .ollama:
            return try OllamaClient(baseURL: config.baseURL)
        case .lmstudio:
            return try OpenAICompatClient(
                providerName: "LM Studio",
                baseURL: config.baseURL,
                allowInsecure: true
            )
        case .openrouter:
            return try OpenAICompatClient(
                providerName: "OpenRouter",
                baseURL: config.baseURL,
                apiKey: secrets.secret(for: kind.keychainAccount),
                extraHeaders: [
                    "HTTP-Referer": "https://github.com/maxpolwin/Noschen",
                    "X-Title": "Noschen",
                ],
                allowInsecure: false
            )
        case .custom:
            return try OpenAICompatClient(
                providerName: "Custom",
                baseURL: config.baseURL,
                apiKey: secrets.secret(for: kind.keychainAccount),
                allowInsecure: true
            )
        }
    }
}
