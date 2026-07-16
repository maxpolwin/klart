#if os(macOS)
import SwiftUI
import NoschenKit

enum FeedbackPhase: Equatable {
    case idle
    case waiting      // debounce running
    case analyzing
    case error(String)
    case skipped(String)
}

enum ConnectionStatus: Equatable {
    case unknown
    case checking
    case connected(String)   // provider display name
    case failed(String)      // error message
}

/// Single source of truth for the UI. Owns persistence, the feedback loop,
/// and provider access. Everything here runs on the main actor; file and
/// network I/O is delegated to the actor-based stores and URLSession.
@MainActor
final class AppState: ObservableObject {
    // MARK: Notes

    @Published private(set) var notes: [Note] = []
    @Published var selectedNoteID: UUID? {
        didSet { if oldValue != selectedNoteID { noteSelectionChanged(from: oldValue) } }
    }
    @Published var searchText = ""
    /// Live editor buffer for the selected note.
    @Published var editorText = ""

    /// Cursor position (UTF-16) in the editor. Deliberately not @Published:
    /// it changes on every keystroke and nothing needs to re-render for it.
    var cursorUTF16 = 0

    // MARK: Feedback / coach

    @Published var feedbackItems: [FeedbackItem] = []
    @Published var feedbackPhase: FeedbackPhase = .idle
    @Published var coachOutput = ""
    @Published var coachAction: CoachAction? = nil
    @Published var coachRunning = false
    @Published var showInspector = true

    // MARK: Settings / provider

    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    @Published var connection: ConnectionStatus = .unknown
    @Published var availableModels: [String] = []

    let secrets: SecretStore
    private let noteStore: NoteStore
    private let settingsStore: SettingsStore

    private var autosaveTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var coachTask: Task<Void, Never>?
    private let engine = FeedbackEngine()

    init(
        noteStore: NoteStore = NoteStore(directory: NoteStore.defaultDirectory()),
        settingsStore: SettingsStore = SettingsStore(fileURL: SettingsStore.defaultFileURL()),
        secrets: SecretStore = KeychainSecretStore()
    ) {
        self.noteStore = noteStore
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.settings = settingsStore.load()

        Task { await loadNotes() }
    }

    // MARK: - Note lifecycle

    var selectedNote: Note? {
        guard let id = selectedNoteID else { return nil }
        return notes.first { $0.id == id }
    }

    var filteredNotes: [Note] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.content.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func loadNotes() async {
        do {
            notes = try await noteStore.loadAll()
            if selectedNoteID == nil {
                selectedNoteID = notes.first?.id
            }
        } catch {
            notes = []
        }
    }

    func createNote() {
        saveNow()
        let note = Note(content: "# ")
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        persist(note)
    }

    func deleteNote(id: UUID) {
        // Remove from the list first: if this is the selected note, the
        // selection change below must NOT flush the editor buffer back to
        // disk for a note we are about to delete.
        notes.removeAll { $0.id == id }
        if selectedNoteID == id {
            autosaveTask?.cancel()
            feedbackTask?.cancel()
            selectedNoteID = notes.first?.id
        }
        Task { try? await noteStore.delete(id: id) }
    }

    private func noteSelectionChanged(from oldID: UUID?) {
        // Flush the previous note before switching buffers.
        if let oldID, let index = notes.firstIndex(where: { $0.id == oldID }) {
            flushEditor(into: index)
        }
        autosaveTask?.cancel()
        feedbackTask?.cancel()
        coachTask?.cancel()
        feedbackItems = []
        feedbackPhase = .idle
        coachOutput = ""
        coachAction = nil
        coachRunning = false
        editorText = selectedNote?.content ?? ""
        cursorUTF16 = 0
    }

    /// Called by the editor on every text change.
    func editorTextChanged() {
        scheduleAutosave()
        if settings.autoFeedback {
            requestFeedback(manual: false)
        }
    }

    private func flushEditor(into index: Int) {
        guard notes[index].content != editorText else { return }
        notes[index].content = editorText
        notes[index].updatedAt = Date()
        persist(notes[index])
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        autosaveTask?.cancel()
        guard let id = selectedNoteID, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        flushEditor(into: index)
    }

    private func persist(_ note: Note) {
        Task { try? await noteStore.save(note) }
    }

    // MARK: - Feedback loop

    func requestFeedback(manual: Bool) {
        feedbackTask?.cancel()
        guard selectedNoteID != nil else { return }

        let delay = manual ? 0 : settings.debounceSeconds
        feedbackPhase = manual ? .analyzing : .waiting

        feedbackTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            await self.runFeedback()
        }
    }

    private func runFeedback() async {
        let text = editorText
        let cursor = cursorUTF16
        let currentSettings = settings
        let rejected = Set(selectedNote?.rejectedFingerprints ?? [])

        let client: any LLMClient
        do {
            client = try ProviderFactory.makeClient(
                kind: currentSettings.activeProvider,
                config: currentSettings.activeConfig,
                secrets: secrets
            )
        } catch {
            feedbackPhase = .error(error.localizedDescription)
            return
        }
        guard !currentSettings.activeConfig.model.isEmpty else {
            feedbackPhase = .error("No model selected. Pick one in Settings → AI Provider.")
            return
        }

        feedbackPhase = .analyzing
        do {
            let outcome = try await engine.analyze(
                text: text,
                cursorUTF16: cursor,
                settings: currentSettings,
                rejectedFingerprints: rejected,
                client: client
            )
            guard !Task.isCancelled else { return }
            switch outcome {
            case .skipped(.tooShort):
                feedbackPhase = .skipped("Keep writing — feedback starts at ~80 characters per section.")
                feedbackItems = []
            case .skipped(.sectionExcluded):
                feedbackPhase = .skipped("This section is marked [no-ai].")
                feedbackItems = []
            case .skipped(.noKindsEnabled):
                feedbackPhase = .skipped("All feedback types are disabled in Settings.")
                feedbackItems = []
            case .items(let items):
                feedbackItems = items
                feedbackPhase = .idle
                connection = .connected(currentSettings.activeProvider.displayName)
            }
        } catch is CancellationError {
            // superseded by a newer request
        } catch {
            guard !Task.isCancelled else { return }
            feedbackPhase = .error(error.localizedDescription)
            if case LLMError.cannotConnect = error {
                connection = .failed(error.localizedDescription)
            }
        }
    }

    func accept(_ item: FeedbackItem) {
        editorText = NoteEditing.insertSuggestion(item, into: editorText, cursorUTF16: cursorUTF16)
        feedbackItems.removeAll { $0.id == item.id }
        scheduleAutosave()
    }

    func reject(_ item: FeedbackItem) {
        feedbackItems.removeAll { $0.id == item.id }
        guard let id = selectedNoteID, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if !notes[index].rejectedFingerprints.contains(item.fingerprint) {
            notes[index].rejectedFingerprints.append(item.fingerprint)
            persist(notes[index])
        }
    }

    // MARK: - Coach

    func runCoach(_ action: CoachAction) {
        coachTask?.cancel()
        showInspector = true
        coachAction = action
        coachOutput = ""
        coachRunning = true

        let currentSettings = settings
        let text = editorText

        coachTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try ProviderFactory.makeClient(
                    kind: currentSettings.activeProvider,
                    config: currentSettings.activeConfig,
                    secrets: self.secrets
                )
                let messages = PromptBuilder.coachMessages(action: action, documentText: text)
                let options = CompletionOptions(
                    temperature: currentSettings.temperature,
                    maxTokens: currentSettings.maxTokens
                )
                let stream = client.stream(messages, model: currentSettings.activeConfig.model, options: options)
                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    self.coachOutput += chunk
                }
                self.coachRunning = false
                self.connection = .connected(currentSettings.activeProvider.displayName)
            } catch {
                guard !Task.isCancelled else { return }
                self.coachOutput = "⚠︎ \(error.localizedDescription)"
                self.coachRunning = false
            }
        }
    }

    // MARK: - Provider management

    func testConnection() {
        connection = .checking
        availableModels = []
        let currentSettings = settings
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try ProviderFactory.makeClient(
                    kind: currentSettings.activeProvider,
                    config: currentSettings.activeConfig,
                    secrets: self.secrets
                )
                let models = try await client.listModels()
                self.availableModels = models
                self.connection = .connected(currentSettings.activeProvider.displayName)
            } catch {
                self.connection = .failed(error.localizedDescription)
            }
        }
    }

    func apiKey(for kind: ProviderKind) -> String {
        secrets.secret(for: kind.keychainAccount) ?? ""
    }

    func setAPIKey(_ key: String, for kind: ProviderKind) {
        secrets.setSecret(key.trimmingCharacters(in: .whitespacesAndNewlines), for: kind.keychainAccount)
    }

    private func persistSettings() {
        try? settingsStore.save(settings)
    }
}
#endif
