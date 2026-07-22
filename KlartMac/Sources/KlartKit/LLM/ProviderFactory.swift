import Foundation

/// Builds a concrete `LLMClient` from the user's settings and secret store.
public enum ProviderFactory {
    /// True when this provider configuration keeps requests on the local
    /// machine or network. Sensitive notes only ever talk to local providers,
    /// and the check is by resolved endpoint, not provider label — a "Custom"
    /// provider pointed at a remote host counts as cloud.
    public static func isLocal(kind: ProviderKind, config: ProviderConfig) -> Bool {
        guard kind != .openrouter else { return false }
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host else { return false }
        return LLMHTTP.isLocalHost(host)
    }

    public static func makeClient(
        kind: ProviderKind,
        config: ProviderConfig,
        secrets: SecretStore
    ) throws -> any LLMClient {
        switch kind {
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
                    "HTTP-Referer": "https://github.com/maxpolwin/Klart",
                    "X-Title": "Klårt",
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
