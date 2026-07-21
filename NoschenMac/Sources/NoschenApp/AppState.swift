#if os(macOS)
import SwiftUI
import AppKit
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
    /// The Quiet coach popover — closed by default, only ever opened by the
    /// user (or by running a coach action, whose output lives inside it).
    @Published var showCoachPopover = false

    // MARK: Settings / provider

    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    @Published var connection: ConnectionStatus = .unknown
    @Published var availableModels: [String] = []

    // MARK: Vault / app lock

    /// True while note protection is enabled and the master key has not been
    /// produced this session. The UI shows the lock screen; no notes are in
    /// memory and none can be loaded.
    @Published private(set) var isLocked = false
    /// The vault master key while unlocked; nil when locked or unprotected.
    private var vaultKey: Data?

    static let vaultKeychainAccount = "noschen.vault.masterkey"

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

        if settings.vault != nil {
            isLocked = true          // notes stay sealed until the user unlocks
        } else {
            Task { await loadNotes() }
        }
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
        showCoachPopover = true
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

    // MARK: - Vault (at-rest encryption + app lock)

    var biometricUnlockAvailable: Bool {
        settings.vault?.biometricUnlock == true
            && (secrets as? KeychainSecretStore)?.hasProtectedData(for: Self.vaultKeychainAccount) == true
    }

    /// Flushes the live editor buffer straight through the actor, awaiting the
    /// write. The vault migrations below need the save strictly ordered
    /// against the key change — the usual fire-and-forget persist is not.
    private func flushEditorToStoreNow() async {
        autosaveTask?.cancel()
        guard let id = selectedNoteID, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if notes[index].content != editorText {
            notes[index].content = editorText
            notes[index].updatedAt = Date()
        }
        try? await noteStore.save(notes[index])
    }

    /// Turns protection on: encrypts every note on disk under a fresh master
    /// key wrapped by `password`. The app stays unlocked afterwards.
    /// Key derivation (600k PBKDF2 rounds) runs off the main actor.
    func enableProtection(password: String, biometricUnlock: Bool) async throws {
        await flushEditorToStoreNow()
        let (masterKey, config) = try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.createVault(password: password, biometricUnlock: biometricUnlock)
        }.value
        // Persist the wrapped key BEFORE sealing any file: if the app dies
        // mid-migration the vault config already exists, the app relaunches
        // locked, and unlock handles the mixed plaintext/sealed state — the
        // reverse order would seal notes under a key persisted nowhere.
        vaultKey = masterKey
        settings.vault = config
        if biometricUnlock {
            (secrets as? KeychainSecretStore)?.setProtectedData(masterKey, for: Self.vaultKeychainAccount)
        }
        try await noteStore.encryptAllOnDisk(masterKey: masterKey)
    }

    /// Turns protection off after verifying the password; notes are rewritten
    /// as plaintext and the biometric key copy is removed.
    func disableProtection(password: String) async throws {
        guard let config = settings.vault else { return }
        let masterKey = try await Self.deriveMasterKey(config: config, password: password)
        await flushEditorToStoreNow()
        try await noteStore.decryptAllOnDisk(masterKey: masterKey)
        (secrets as? KeychainSecretStore)?.setProtectedData(nil, for: Self.vaultKeychainAccount)
        vaultKey = nil
        settings.vault = nil
        isLocked = false
    }

    /// Rewraps the master key under a new password. Notes on disk are
    /// untouched — only the wrapping in settings.json changes.
    func changeVaultPassword(current: String, new: String) async throws {
        guard let config = settings.vault else { return }
        let masterKey = try await Self.deriveMasterKey(config: config, password: current)
        settings.vault = try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.rewrap(config: config, masterKey: masterKey, newPassword: new)
        }.value
    }

    /// Enables or disables the Touch ID unlock path. Enabling needs the
    /// password once, to obtain the key that gets stored behind user presence.
    func setBiometricUnlock(_ enabled: Bool, password: String?) async throws {
        guard var config = settings.vault else { return }
        if enabled {
            guard let password else { throw VaultError.wrongPassword }
            let masterKey = try await Self.deriveMasterKey(config: config, password: password)
            (secrets as? KeychainSecretStore)?.setProtectedData(masterKey, for: Self.vaultKeychainAccount)
        } else {
            (secrets as? KeychainSecretStore)?.setProtectedData(nil, for: Self.vaultKeychainAccount)
        }
        config.biometricUnlock = enabled
        settings.vault = config
    }

    private static func deriveMasterKey(config: VaultConfig, password: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.unlock(config: config, password: password)
        }.value
    }

    @discardableResult
    func unlock(password: String) async -> Bool {
        guard let config = settings.vault else { return true }
        guard let masterKey = try? await Self.deriveMasterKey(config: config, password: password) else {
            return false
        }
        await finishUnlock(masterKey: masterKey)
        return true
    }

    /// Touch ID / Apple Watch / login-password unlock: reading the protected
    /// Keychain item triggers the system authentication prompt.
    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        guard settings.vault?.biometricUnlock == true,
              let keychain = secrets as? KeychainSecretStore else { return false }
        let account = Self.vaultKeychainAccount
        let masterKey = await Task.detached(priority: .userInitiated) {
            keychain.protectedData(for: account, prompt: "unlock your notes")
        }.value
        guard let masterKey else { return false }
        await finishUnlock(masterKey: masterKey)
        return true
    }

    private func finishUnlock(masterKey: Data) async {
        vaultKey = masterKey
        await noteStore.setEncryptionKey(masterKey)
        await loadNotes()
        isLocked = false
    }

    /// Drops the key and all decrypted content from memory. Notes on disk
    /// are already sealed, so at-rest protection is unaffected.
    func lockNow() {
        guard settings.vault != nil, !isLocked else { return }
        autosaveTask?.cancel()
        feedbackTask?.cancel()
        coachTask?.cancel()
        // Flush the editor buffer into the model without spawning the usual
        // fire-and-forget save: the final write must happen strictly BEFORE
        // the encryption key is cleared, or it would land in plaintext.
        var pendingSave: Note?
        if let id = selectedNoteID, let index = notes.firstIndex(where: { $0.id == id }) {
            if notes[index].content != editorText {
                notes[index].content = editorText
                notes[index].updatedAt = Date()
            }
            pendingSave = notes[index]
        }
        Task { [weak self] in
            guard let self else { return }
            if let pendingSave {
                try? await self.noteStore.save(pendingSave)   // key still set
            }
            await self.noteStore.setEncryptionKey(nil)
            self.vaultKey = nil
            self.notes = []
            self.selectedNoteID = nil
            self.editorText = ""
            self.feedbackItems = []
            self.coachOutput = ""
            self.coachAction = nil
            self.showCoachPopover = false
            self.isLocked = true
        }
    }

    // MARK: - Export / import (markdown backup)

    /// Writes every note as a plain .md file into a user-chosen folder.
    /// This is the manual backup path: plaintext by design, user-invoked only.
    func exportAllNotesAsMarkdown() {
        saveNow()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the markdown export. Files are written as plain text — store them somewhere you trust."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let formatter = ISO8601DateFormatter()
        for note in notes {
            let safeTitle = note.title
                .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
                .joined()
                .trimmingCharacters(in: .whitespaces)
                .prefix(60)
            let name = "\(safeTitle.isEmpty ? "Untitled" : String(safeTitle)) — \(note.id.uuidString.prefix(8)).md"
            let header = "<!-- noschen:id=\(note.id.uuidString) created=\(formatter.string(from: note.createdAt)) -->\n"
            let url = folder.appendingPathComponent(name)
            try? (header + note.content).data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    /// Imports .md / .txt files as new notes (or updates the existing note
    /// when the file carries a noschen:id header from a previous export).
    func importMarkdownNotes() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var noteID = UUID()
            var createdAt = Date()
            // Recover identity from our own export header, if present.
            if text.hasPrefix("<!-- noschen:"), let headerEnd = text.range(of: "-->\n") {
                let header = String(text[..<headerEnd.lowerBound])
                if let idMatch = header.range(of: "id="),
                   let id = UUID(uuidString: String(header[idMatch.upperBound...].prefix(36))) {
                    noteID = id
                }
                if let createdMatch = header.range(of: "created=") {
                    let stamp = String(header[createdMatch.upperBound...].prefix(25))
                    createdAt = ISO8601DateFormatter().date(from: stamp) ?? createdAt
                }
                text.removeSubrange(..<headerEnd.upperBound)
            }
            let note = Note(id: noteID, content: text, createdAt: createdAt, updatedAt: Date())
            notes.removeAll { $0.id == note.id }
            notes.insert(note, at: 0)
            persist(note)
        }
        if selectedNoteID == nil { selectedNoteID = notes.first?.id }
    }
}
#endif
