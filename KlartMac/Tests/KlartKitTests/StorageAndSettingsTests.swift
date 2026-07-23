import XCTest
@testable import KlartKit

final class NoteStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klart-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveLoadDeleteRoundtrip() async throws {
        let store = NoteStore(directory: tempDir)
        var note = Note(content: "# Hello\n\nWorld")
        note.rejectedFingerprints = ["abc123"]
        try await store.save(note)

        var loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, note.id)
        XCTAssertEqual(loaded[0].content, note.content)
        XCTAssertEqual(loaded[0].rejectedFingerprints, ["abc123"])
        XCTAssertEqual(loaded[0].title, "Hello")

        try await store.delete(id: note.id)
        loaded = try await store.loadAll()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testCorruptFileSkipped() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: tempDir.appendingPathComponent("bad.json"))
        let store = NoteStore(directory: tempDir)
        try await store.save(Note(content: "# Good"))
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Good")
    }

    func testSortedByUpdatedAtDescending() async throws {
        let store = NoteStore(directory: tempDir)
        let old = Note(content: "# Old", updatedAt: Date(timeIntervalSinceNow: -1000))
        let new = Note(content: "# New", updatedAt: Date())
        try await store.save(old)
        try await store.save(new)
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.map(\.title), ["New", "Old"])
    }
}

final class SettingsTests: XCTestCase {
    func testRoundtrip() throws {
        var settings = AppSettings()
        settings.activeProvider = .openrouter
        settings.setConfig(ProviderConfig(baseURL: "https://openrouter.ai/api/v1", model: "meta-llama/llama-3.3-70b-instruct"), for: .openrouter)
        settings.tipStyle.tone = .direct
        settings.debounceSeconds = 4
        settings.enabledFeedbackKinds = [.gap, .question]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.activeConfig.model, "meta-llama/llama-3.3-70b-instruct")
    }

    func testLenientDecodingFromPartialJSON() throws {
        let json = #"{"activeProvider":"lmstudio"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.activeProvider, .lmstudio)
        XCTAssertEqual(decoded.tipStyle.maxTips, 3)
        XCTAssertEqual(decoded.config(for: .lmstudio).baseURL, "http://localhost:1234/v1")
        XCTAssertTrue(decoded.autoFeedback)
        // Interface settings introduced later: settings files from older
        // builds fall back to Teleprompter on, word count off.
        XCTAssertTrue(decoded.teleprompterMode)
        XCTAssertFalse(decoded.showWordCount)
    }

    func testInterfaceSettingsRoundtrip() throws {
        var settings = AppSettings()
        settings.teleprompterMode = false
        settings.showWordCount = true
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings)
        )
        XCTAssertFalse(decoded.teleprompterMode)
        XCTAssertTrue(decoded.showWordCount)
    }

    func testSystemPromptOverrideRoundtripAndOmittedWhenNil() throws {
        var settings = AppSettings()
        // Defaults: no override, effective prompts are the built-in templates.
        XCTAssertNil(settings.feedbackSystemPrompt)
        XCTAssertNil(settings.coachSystemPrompt)
        XCTAssertEqual(settings.effectiveFeedbackPrompt, PromptBuilder.defaultFeedbackTemplate)
        XCTAssertEqual(settings.effectiveCoachPrompt, PromptBuilder.defaultCoachTemplate)

        // Nil overrides are omitted from the JSON, keeping settings.json clean.
        let nilJSON = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(nilJSON.contains("feedbackSystemPrompt"))
        XCTAssertFalse(nilJSON.contains("coachSystemPrompt"))

        // A custom override survives a round-trip and drives the effective prompt.
        settings.feedbackSystemPrompt = "Custom feedback {{JSON_SHAPE}}"
        settings.coachSystemPrompt = "Custom coach {{ACTION_INSTRUCTION}}"
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.effectiveFeedbackPrompt, "Custom feedback {{JSON_SHAPE}}")
        XCTAssertEqual(decoded.effectiveCoachPrompt, "Custom coach {{ACTION_INSTRUCTION}}")
    }

    func testOldSettingsWithoutPromptFieldsDecodeToDefaults() throws {
        let json = #"{"activeProvider":"ollama"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertNil(decoded.feedbackSystemPrompt)
        XCTAssertNil(decoded.coachSystemPrompt)
        XCTAssertEqual(decoded.effectiveFeedbackPrompt, PromptBuilder.defaultFeedbackTemplate)
    }

    func testDecodingClampsOutOfRangeValues() throws {
        let json = #"{"debounceSeconds":9999,"temperature":-5,"maxTokens":1,"tipStyle":{"maxTips":50}}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.debounceSeconds, 15)
        XCTAssertEqual(decoded.temperature, 0)
        XCTAssertEqual(decoded.maxTokens, 64)
        XCTAssertEqual(decoded.tipStyle.maxTips, 6)
    }

    func testSettingsStorePersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klart-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))

        // Missing file → defaults.
        XCTAssertEqual(store.load(), AppSettings())

        var settings = AppSettings()
        settings.activeProvider = .lmstudio
        try store.save(settings)
        XCTAssertEqual(store.load().activeProvider, .lmstudio)
    }

    func testSecretStoreInMemory() {
        let store = InMemorySecretStore()
        XCTAssertNil(store.secret(for: "a"))
        store.setSecret("key123", for: "a")
        XCTAssertEqual(store.secret(for: "a"), "key123")
        store.setSecret(nil, for: "a")
        XCTAssertNil(store.secret(for: "a"))
        store.setSecret("x", for: "a")
        store.setSecret("", for: "a")
        XCTAssertNil(store.secret(for: "a"))
    }

    func testBaseURLValidation() throws {
        XCTAssertNoThrow(try LLMHTTP.normalizeBaseURL("http://localhost:11434/", allowInsecure: true))
        XCTAssertThrowsError(try LLMHTTP.normalizeBaseURL("http://openrouter.ai/api/v1", allowInsecure: false)) { error in
            XCTAssertEqual(error as? LLMError, .insecureURL("http://openrouter.ai/api/v1"))
        }
        XCTAssertThrowsError(try LLMHTTP.normalizeBaseURL("ftp://x", allowInsecure: true))
        XCTAssertThrowsError(try LLMHTTP.normalizeBaseURL("not a url", allowInsecure: true))
        let normalized = try LLMHTTP.normalizeBaseURL("https://openrouter.ai/api/v1//", allowInsecure: false)
        XCTAssertEqual(normalized.absoluteString, "https://openrouter.ai/api/v1")
    }

    func testProviderDefaults() {
        XCTAssertFalse(ProviderKind.ollama.usesAPIKey)
        XCTAssertFalse(ProviderKind.lmstudio.usesAPIKey)
        XCTAssertTrue(ProviderKind.openrouter.usesAPIKey)
        XCTAssertFalse(ProviderKind.openrouter.allowsInsecureHTTP)
        XCTAssertEqual(ProviderKind.ollama.defaultBaseURL, "http://localhost:11434")
        XCTAssertEqual(ProviderKind.lmstudio.defaultBaseURL, "http://localhost:1234/v1")
    }
}
