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

    /// Register only — every tone stays opinionated. "Encouraging" is the one
    /// that names what the section is trying to do before saying where it
    /// fails, and praises method, never the author: person-praise makes
    /// feedback worse, process-praise does not (Mueller & Dweck).
    var promptFragment: String {
        switch self {
        case .neutral: return "Plain, professional register. Still no softeners."
        case .academic: return "Precise academic register; name the standard a reviewer would hold the section to."
        case .direct: return "Blunt. The problem goes in the first clause. No softeners, no compliments, no 'consider'."
        case .encouraging: return "Firm but warm: say what the section is trying to do before saying where it falls short. If you credit anything, credit the method, never the author."
        }
    }
}

public enum FeedbackDetail: String, Codable, CaseIterable, Sendable, Identifiable {
    case brief, standard, detailed
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    var promptFragment: String {
        switch self {
        case .brief: return "One sentence per field."
        case .standard: return "Keep each field concise but complete."
        case .detailed: return "Be thorough: say what a fix would have to achieve — still without drafting it."
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
        tone: FeedbackTone = .direct,
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
        tone = try c.decodeIfPresent(FeedbackTone.self, forKey: .tone) ?? .direct
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
    /// Seconds of typing inactivity that count as "done with this section
    /// for now" — the pause trigger. Leaving the section fires regardless.
    public var debounceSeconds: Double
    /// Whether the editor reads a section on its own when the writer finishes
    /// it (leaves it, or pauses), vs. only on demand (⌘R, `//editor`).
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
    /// User override for the live-feedback ("Editor") system prompt. `nil`
    /// means "use the app's current default" — so Revert clears this and a
    /// future default improvement flows through automatically. Stored as a
    /// `{{TOKEN}}` template; see `PromptBuilder`.
    public var feedbackSystemPrompt: String?
    /// User override for the Quiet-coach system prompt. `nil` = current default.
    public var coachSystemPrompt: String?
    /// Include note text (title, section, the paragraph a tip reacted to, and
    /// the tip's own prose) in the local learning log. Off by default: the
    /// signal tier — outcome, kind, model, system-prompt hash — is always
    /// recorded, but note content is opt-in. See `RecommendationRecord`.
    public var logRecommendationContent: Bool

    public init(
        activeProvider: ProviderKind = .ollama,
        providers: [ProviderKind: ProviderConfig] = [:],
        enabledFeedbackKinds: [FeedbackKind] = FeedbackKind.defaultEnabled,
        tipStyle: TipStyle = TipStyle(),
        debounceSeconds: Double = 20,
        autoFeedback: Bool = true,
        temperature: Double = 0.4,
        maxTokens: Int = 1024,
        vault: VaultConfig? = nil,
        autoLockMinutes: Int = 15,
        lockOnScreenSleep: Bool = true,
        excludeFromCapture: Bool = true,
        teleprompterMode: Bool = true,
        showWordCount: Bool = false,
        feedbackSystemPrompt: String? = nil,
        coachSystemPrompt: String? = nil,
        logRecommendationContent: Bool = false
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
        self.feedbackSystemPrompt = feedbackSystemPrompt
        self.coachSystemPrompt = coachSystemPrompt
        self.logRecommendationContent = logRecommendationContent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        activeProvider = try c.decodeIfPresent(ProviderKind.self, forKey: .activeProvider) ?? defaults.activeProvider
        providers = try c.decodeIfPresent([ProviderKind: ProviderConfig].self, forKey: .providers) ?? [:]
        enabledFeedbackKinds = try c.decodeIfPresent([FeedbackKind].self, forKey: .enabledFeedbackKinds) ?? defaults.enabledFeedbackKinds
        tipStyle = try c.decodeIfPresent(TipStyle.self, forKey: .tipStyle) ?? TipStyle()
        // A pause shorter than five seconds is a keystroke debounce from an
        // older build, not a "done with this section" signal; lift it.
        debounceSeconds = min(120, max(5, try c.decodeIfPresent(Double.self, forKey: .debounceSeconds) ?? defaults.debounceSeconds))
        autoFeedback = try c.decodeIfPresent(Bool.self, forKey: .autoFeedback) ?? defaults.autoFeedback
        temperature = min(2, max(0, try c.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature))
        maxTokens = min(8192, max(64, try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? defaults.maxTokens))
        vault = try c.decodeIfPresent(VaultConfig.self, forKey: .vault)
        autoLockMinutes = min(240, max(0, try c.decodeIfPresent(Int.self, forKey: .autoLockMinutes) ?? defaults.autoLockMinutes))
        lockOnScreenSleep = try c.decodeIfPresent(Bool.self, forKey: .lockOnScreenSleep) ?? defaults.lockOnScreenSleep
        excludeFromCapture = try c.decodeIfPresent(Bool.self, forKey: .excludeFromCapture) ?? defaults.excludeFromCapture
        teleprompterMode = try c.decodeIfPresent(Bool.self, forKey: .teleprompterMode) ?? defaults.teleprompterMode
        showWordCount = try c.decodeIfPresent(Bool.self, forKey: .showWordCount) ?? defaults.showWordCount
        feedbackSystemPrompt = try c.decodeIfPresent(String.self, forKey: .feedbackSystemPrompt)
        coachSystemPrompt = try c.decodeIfPresent(String.self, forKey: .coachSystemPrompt)
        logRecommendationContent = try c.decodeIfPresent(Bool.self, forKey: .logRecommendationContent) ?? defaults.logRecommendationContent
    }

    /// The live-feedback system prompt actually sent to the model: the user's
    /// override when set, otherwise the app's current default.
    public var effectiveFeedbackPrompt: String {
        feedbackSystemPrompt ?? PromptBuilder.defaultFeedbackTemplate
    }

    /// The Quiet-coach system prompt actually sent to the model.
    public var effectiveCoachPrompt: String {
        coachSystemPrompt ?? PromptBuilder.defaultCoachTemplate
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
