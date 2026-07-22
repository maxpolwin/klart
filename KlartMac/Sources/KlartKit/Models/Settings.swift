import Foundation

/// The LLM backends Klårt can talk to. Ollama uses its native API;
/// everything else speaks the OpenAI-compatible chat/completions dialect,
/// which is what LM Studio, OpenRouter, and most self-hosted gateways expose.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case ollama
    case lmstudio
    case openrouter
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .openrouter: return "OpenRouter"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434"
        case .lmstudio: return "http://localhost:1234/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return "http://localhost:8080/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .ollama: return "llama3.2"
        case .lmstudio: return ""
        case .openrouter: return "anthropic/claude-haiku-4.5"
        case .custom: return ""
        }
    }

    /// Whether this provider needs an API key (stored in the macOS Keychain).
    public var usesAPIKey: Bool {
        switch self {
        case .openrouter, .custom: return true
        case .ollama, .lmstudio: return false
        }
    }

    /// Keychain account name for this provider's API key.
    public var keychainAccount: String { "klart.apikey.\(rawValue)" }

    /// Local providers may use plain http; remote ones must use https.
    public var allowsInsecureHTTP: Bool {
        switch self {
        case .ollama, .lmstudio, .custom: return true
        case .openrouter: return false
        }
    }
}

/// Per-provider connection details (everything except the API key,
/// which lives in the Keychain).
public struct ProviderConfig: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String

    public init(baseURL: String, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    public static func defaults(for kind: ProviderKind) -> ProviderConfig {
        ProviderConfig(baseURL: kind.defaultBaseURL, model: kind.defaultModel)
    }
}

public enum FeedbackTone: String, Codable, CaseIterable, Sendable, Identifiable {
    case neutral, academic, direct, encouraging
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    var promptFragment: String {
        switch self {
        case .neutral: return "Use a neutral, professional tone."
        case .academic: return "Use a precise academic tone."
        case .direct: return "Be direct and to the point; no hedging."
        case .encouraging: return "Be encouraging and constructive."
        }
    }
}

public enum FeedbackDetail: String, Codable, CaseIterable, Sendable, Identifiable {
    case brief, standard, detailed
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    var promptFragment: String {
        switch self {
        case .brief: return "Keep each item to one or two sentences."
        case .standard: return "Keep each item concise but complete."
        case .detailed: return "Give thorough items with concrete, ready-to-insert suggestions."
        }
    }
}

/// How feedback should be phrased.
public struct TipStyle: Codable, Equatable, Sendable {
    public var tone: FeedbackTone
    public var detail: FeedbackDetail
    public var maxTips: Int
    /// Empty string = match the language of the notes.
    public var language: String
    public var customGuidance: String

    public init(
        tone: FeedbackTone = .neutral,
        detail: FeedbackDetail = .standard,
        maxTips: Int = 3,
        language: String = "",
        customGuidance: String = ""
    ) {
        self.tone = tone
        self.detail = detail
        self.maxTips = maxTips
        self.language = language
        self.customGuidance = customGuidance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tone = try c.decodeIfPresent(FeedbackTone.self, forKey: .tone) ?? .neutral
        detail = try c.decodeIfPresent(FeedbackDetail.self, forKey: .detail) ?? .standard
        maxTips = min(6, max(1, try c.decodeIfPresent(Int.self, forKey: .maxTips) ?? 3))
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        customGuidance = try c.decodeIfPresent(String.self, forKey: .customGuidance) ?? ""
    }
}

/// All persisted app settings. Decoding is lenient: every field falls back to
/// its default so settings files survive app upgrades in both directions.
public struct AppSettings: Codable, Equatable, Sendable {
    public var activeProvider: ProviderKind
    public var providers: [ProviderKind: ProviderConfig]
    public var enabledFeedbackKinds: [FeedbackKind]
    public var tipStyle: TipStyle
    /// Seconds of typing inactivity before feedback is requested.
    public var debounceSeconds: Double
    /// Whether feedback runs automatically while typing (vs. manual only).
    public var autoFeedback: Bool
    public var temperature: Double
    public var maxTokens: Int
    /// Non-nil when at-rest note encryption is enabled. Holds only salt and
    /// the password-wrapped master key — no secret material.
    public var vault: VaultConfig?
    /// Auto-lock after this many minutes without user activity (0 = never).
    public var autoLockMinutes: Int
    /// Lock when the screen sleeps, locks, or the screensaver starts.
    public var lockOnScreenSleep: Bool
    /// Make the window invisible to screenshots, recordings, and screen sharing.
    public var excludeFromCapture: Bool
    /// Teleprompter mode: the zero-chrome, monochrome writing surface. One
    /// centered column, notes behind the left edge, the editor's suggestions
    /// in a right margin rail. Off = the classic sidebar layout.
    public var teleprompterMode: Bool
    /// Show word count and estimated reading time at the bottom of the
    /// teleprompter surface.
    public var showWordCount: Bool

    public init(
        activeProvider: ProviderKind = .ollama,
        providers: [ProviderKind: ProviderConfig] = [:],
        enabledFeedbackKinds: [FeedbackKind] = FeedbackKind.defaultEnabled,
        tipStyle: TipStyle = TipStyle(),
        debounceSeconds: Double = 2.5,
        autoFeedback: Bool = true,
        temperature: Double = 0.4,
        maxTokens: Int = 1024,
        vault: VaultConfig? = nil,
        autoLockMinutes: Int = 15,
        lockOnScreenSleep: Bool = true,
        excludeFromCapture: Bool = true,
        teleprompterMode: Bool = true,
        showWordCount: Bool = false
    ) {
        self.activeProvider = activeProvider
        self.providers = providers
        self.enabledFeedbackKinds = enabledFeedbackKinds
        self.tipStyle = tipStyle
        self.debounceSeconds = debounceSeconds
        self.autoFeedback = autoFeedback
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.vault = vault
        self.autoLockMinutes = autoLockMinutes
        self.lockOnScreenSleep = lockOnScreenSleep
        self.excludeFromCapture = excludeFromCapture
        self.teleprompterMode = teleprompterMode
        self.showWordCount = showWordCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        activeProvider = try c.decodeIfPresent(ProviderKind.self, forKey: .activeProvider) ?? defaults.activeProvider
        providers = try c.decodeIfPresent([ProviderKind: ProviderConfig].self, forKey: .providers) ?? [:]
        enabledFeedbackKinds = try c.decodeIfPresent([FeedbackKind].self, forKey: .enabledFeedbackKinds) ?? defaults.enabledFeedbackKinds
        tipStyle = try c.decodeIfPresent(TipStyle.self, forKey: .tipStyle) ?? TipStyle()
        debounceSeconds = min(15, max(0.5, try c.decodeIfPresent(Double.self, forKey: .debounceSeconds) ?? defaults.debounceSeconds))
        autoFeedback = try c.decodeIfPresent(Bool.self, forKey: .autoFeedback) ?? defaults.autoFeedback
        temperature = min(2, max(0, try c.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature))
        maxTokens = min(8192, max(64, try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? defaults.maxTokens))
        vault = try c.decodeIfPresent(VaultConfig.self, forKey: .vault)
        autoLockMinutes = min(240, max(0, try c.decodeIfPresent(Int.self, forKey: .autoLockMinutes) ?? defaults.autoLockMinutes))
        lockOnScreenSleep = try c.decodeIfPresent(Bool.self, forKey: .lockOnScreenSleep) ?? defaults.lockOnScreenSleep
        excludeFromCapture = try c.decodeIfPresent(Bool.self, forKey: .excludeFromCapture) ?? defaults.excludeFromCapture
        teleprompterMode = try c.decodeIfPresent(Bool.self, forKey: .teleprompterMode) ?? defaults.teleprompterMode
        showWordCount = try c.decodeIfPresent(Bool.self, forKey: .showWordCount) ?? defaults.showWordCount
    }

    /// Connection details for the given provider, falling back to defaults.
    public func config(for kind: ProviderKind) -> ProviderConfig {
        providers[kind] ?? .defaults(for: kind)
    }

    /// Connection details for the active provider.
    public var activeConfig: ProviderConfig { config(for: activeProvider) }

    public mutating func setConfig(_ config: ProviderConfig, for kind: ProviderKind) {
        providers[kind] = config
    }
}
