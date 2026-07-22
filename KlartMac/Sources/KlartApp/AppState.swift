#if os(macOS)
import SwiftUI
import AppKit
import KlartKit

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
    /// Bumped by the ⌘F menu command; the currently-visible surface
    /// (Teleprompter's notes panel or the classic sidebar) observes this and
    /// reveals/focuses its own search field — the menu has no view of which
    /// surface is on screen, so it can't focus a `@FocusState` directly.
    @Published var searchRequested = 0
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
    /// Teleprompter: whether the editor's margin rail (suggestions on the
    /// right) is on screen. Analysis runs in the background either way; the
    /// rail only appears when the user summons the editor — via the icon in
    /// the notes panel, ⌘E, or typing /editor — and retires again when the
    /// suggestions fade out.
    @Published var editorRailVisible = false

    // MARK: Settings / provider

    @Published var settings: AppSettings {
        didSet {
            persistSettings()
            Theme.monochrome = settings.teleprompterMode
        }
    }
    @Published var connection: ConnectionStatus = .unknown
    @Published var availableModels: [String] = []

    // MARK: Vault / app lock

    /// True while note protection is enabled and the master key has not been
    /// produced this session. The UI shows the lock screen; no notes are in
    /// memory and none can be loaded.
    @Published private(set) var isLocked = false
    /// Unlock throttling: after repeated failures, attempts are refused
    /// until this moment. In-memory only — offline attackers aren't slowed
    /// by UI throttling anyway; the KDF is the real defense there.
    @Published private(set) var lockoutUntil: Date?
    private var failedUnlockCount = 0
    /// The vault master key while unlocked, in mlocked zeroized-on-release
    /// memory; nil when locked or unprotected.
    private var vaultKey: SecureBytes?
    /// Tamper-evident local log of security events (never content).
    let auditLog: AuditLog
    private var idleLockTask: Task<Void, Never>?
    private var activityMonitor: Any?
    private var lastActivity = Date()

    /// Raw master key behind a user-presence Keychain ACL — the fallback
    /// biometric path on Macs without a Secure Enclave.
    static let vaultKeychainAccount = "klart.vault.masterkey"
    /// Master key encrypted to the Secure Enclave key — the preferred path.
    static let vaultSEKeychainAccount = "klart.vault.masterkey.se"

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
        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings
        // didSet doesn't fire during init; seed the monochrome flag here so
        // the very first editor styles under the right palette.
        Theme.monochrome = loadedSettings.teleprompterMode
        self.auditLog = AuditLog(
            fileURL: settingsStore.fileURL.deletingLastPathComponent().appendingPathComponent("audit.log")
        )

        if settings.vault != nil {
            isLocked = true          // notes stay sealed until the user unlocks
            Task { await noteStore.lock() }   // and the store refuses writes
        } else {
            Task { await loadNotes() }
        }
        installAutoLockMonitors()
    }

    // MARK: - Auto-lock

    /// Locks on screen sleep/lock/screensaver and after an idle timeout —
    /// an unlocked vault on a walked-away Mac is the most common real-world
    /// exposure. Handlers are installed once and check settings at fire time.
    private func installAutoLockMonitors() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lockForScreenEventIfEnabled() }
        }
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lockForScreenEventIfEnabled() }
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.lockForScreenEventIfEnabled() }
            }
        }

        // Any local user event counts as activity for the idle timer.
        // Event monitors fire on the main thread; assumeIsolated makes that
        // visible to the compiler.
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.lastActivity = Date()
            }
            return event
        }

        idleLockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                let minutes = self.settings.autoLockMinutes
                if self.settings.vault != nil, !self.isLocked, minutes > 0,
                   Date().timeIntervalSince(self.lastActivity) > Double(minutes) * 60 {
                    self.lockNow()
                }
            }
        }
    }

    private func lockForScreenEventIfEnabled() {
        if settings.vault != nil, !isLocked, settings.lockOnScreenSleep {
            lockNow()
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
        guard !isLocked else { return }
        saveNow()
        let note = Note(content: "# ")
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        persist(note)
    }

    /// Asks whichever surface is on screen to reveal and focus its search
    /// field (⌘F).
    func requestSearch() {
        searchRequested += 1
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
        editorRailVisible = false
        editorText = selectedNote?.content ?? ""
        cursorUTF16 = 0
    }

    /// Summons the editor (Teleprompter): shows the margin rail and, when no
    /// suggestions are waiting yet, asks for an analysis right away.
    func activateEditor() {
        guard selectedNoteID != nil else { return }
        editorRailVisible = true
        if feedbackItems.isEmpty {
            requestFeedback(manual: true)
        }
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

    /// Sensitive notes never reach a cloud model — enforced here in code,
    /// not just in the UI, against the resolved endpoint.
    private var sensitiveNoteBlocked: Bool {
        selectedNote?.isSensitive == true && !ProviderFactory.isLocal(
            kind: settings.activeProvider,
            config: settings.activeConfig
        )
    }

    static let sensitiveBlockedMessage =
        "This note is marked sensitive, so it only ever uses local AI. "
        + "The current provider is a cloud service — switch to Ollama or "
        + "LM Studio in Settings to use the Editor on this note."

    func toggleSensitive() {
        guard let id = selectedNoteID, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isSensitive.toggle()
        persist(notes[index])
        if notes[index].isSensitive {
            // Nothing already fetched leaves the machine, but stop anything
            // in flight to a cloud provider immediately.
            if !ProviderFactory.isLocal(kind: settings.activeProvider, config: settings.activeConfig) {
                feedbackTask?.cancel()
                coachTask?.cancel()
                coachRunning = false
                feedbackItems = []
                feedbackPhase = .skipped(Self.sensitiveBlockedMessage)
            }
        } else if feedbackPhase == .skipped(Self.sensitiveBlockedMessage) {
            feedbackPhase = .idle
        }
    }

    private func runFeedback() async {
        guard !sensitiveNoteBlocked else {
            feedbackPhase = .skipped(Self.sensitiveBlockedMessage)
            feedbackItems = []
            return
        }
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

    /// Rejects a suggestion for good: its fingerprint is remembered per note
    /// and it will not be shown again.
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
        guard !sensitiveNoteBlocked else {
            coachAction = action
            coachOutput = Self.sensitiveBlockedMessage
            coachRunning = false
            return
        }
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
        guard settings.vault?.biometricUnlock == true,
              // The biometric copy holds only the current key; an interrupted
              // rotation needs the password path, which can recover both.
              settings.vault?.previousWrappedMasterKey == nil,
              let keychain = secrets as? KeychainSecretStore else { return false }
        return keychain.data(for: Self.vaultSEKeychainAccount) != nil
            || keychain.hasProtectedData(for: Self.vaultKeychainAccount)
    }

    /// Stores the biometric-unlock copy of the master key: wrapped by the
    /// Secure Enclave where available, else raw behind a user-presence ACL.
    private func storeBiometricKey(_ masterKey: Data) {
        guard let keychain = secrets as? KeychainSecretStore else { return }
        if let blob = SecureEnclaveWrap.wrap(masterKey) {
            keychain.setData(blob, for: Self.vaultSEKeychainAccount)
            keychain.setProtectedData(nil, for: Self.vaultKeychainAccount)
        } else {
            keychain.setProtectedData(masterKey, for: Self.vaultKeychainAccount)
        }
    }

    private func removeBiometricKey() {
        guard let keychain = secrets as? KeychainSecretStore else { return }
        keychain.setData(nil, for: Self.vaultSEKeychainAccount)
        keychain.setProtectedData(nil, for: Self.vaultKeychainAccount)
        SecureEnclaveWrap.deleteKey()
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
    /// Key derivation (Argon2id, 128 MiB) runs off the main actor.
    func enableProtection(password: String, biometricUnlock: Bool) async throws {
        await flushEditorToStoreNow()
        let (masterKey, config) = try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.createVault(password: password, biometricUnlock: biometricUnlock)
        }.value
        // Persist the wrapped key BEFORE sealing any file: if the app dies
        // mid-migration the vault config already exists, the app relaunches
        // locked, and unlock handles the mixed plaintext/sealed state — the
        // reverse order would seal notes under a key persisted nowhere.
        vaultKey = SecureBytes(masterKey)
        settings.vault = config
        if biometricUnlock {
            storeBiometricKey(masterKey)
        }
        try await noteStore.encryptAllOnDisk(masterKey: masterKey)
        await auditLog.record(.vaultEnabled)
    }

    /// Recovers the master key, finishing any interrupted key rotation first
    /// so every caller afterwards deals with exactly one key.
    private func resolveMasterKey(password: String) async throws -> Data {
        guard let config = settings.vault else { throw VaultError.wrongPassword }
        let (current, previous) = try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.unlockBoth(config: config, password: password)
        }.value
        if let previous {
            try await noteStore.rotateAllOnDisk(oldKey: previous, newKey: current)
            settings.vault = VaultCrypto.completeRotation(config)
        }
        return current
    }

    /// Turns protection off after verifying the password; notes are rewritten
    /// as plaintext and the biometric key copy is removed.
    func disableProtection(password: String) async throws {
        guard settings.vault != nil else { return }
        let masterKey = try await resolveMasterKey(password: password)
        await flushEditorToStoreNow()
        try await noteStore.decryptAllOnDisk(masterKey: masterKey)
        removeBiometricKey()
        vaultKey = nil
        settings.vault = nil
        isLocked = false
        await auditLog.record(.vaultDisabled)
        // Disabling from the lock screen means nothing is in memory yet.
        if notes.isEmpty {
            await loadNotes()
        }
    }

    /// Rewraps the master key under a new password. Notes on disk are
    /// untouched — only the wrapping in settings.json changes.
    func changeVaultPassword(current: String, new: String) async throws {
        guard settings.vault != nil else { return }
        let masterKey = try await resolveMasterKey(password: current)
        guard let config = settings.vault else { return }
        settings.vault = try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.rewrap(config: config, masterKey: masterKey, newPassword: new)
        }.value
    }

    /// Rotates to a fresh master key: every note is re-encrypted, the wrap
    /// and biometric copies are refreshed. Crash-safe — the old key stays in
    /// the config (wrapped) until every file is confirmed re-encrypted, and
    /// an interrupted rotation resumes on the next password unlock.
    func rotateMasterKey(password: String) async throws {
        guard settings.vault != nil else { return }
        _ = try await resolveMasterKey(password: password)   // finish any pending rotation
        guard let config = settings.vault else { return }
        let (oldKey, newKey, pending) = try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.beginRotation(config: config, password: password)
        }.value
        await flushEditorToStoreNow()
        settings.vault = pending                              // resumable from here
        try await noteStore.rotateAllOnDisk(oldKey: oldKey, newKey: newKey)
        settings.vault = VaultCrypto.completeRotation(pending)
        vaultKey = SecureBytes(newKey)
        if settings.vault?.biometricUnlock == true {
            storeBiometricKey(newKey)
        }
        await auditLog.record(.keyRotated)
    }

    /// Enables or disables the Touch ID unlock path. Enabling needs the
    /// password once, to obtain the key that gets stored behind user presence.
    func setBiometricUnlock(_ enabled: Bool, password: String?) async throws {
        guard var config = settings.vault else { return }
        if enabled {
            guard let password else { throw VaultError.wrongPassword }
            let masterKey = try await Self.deriveMasterKey(config: config, password: password)
            storeBiometricKey(masterKey)
        } else {
            removeBiometricKey()
        }
        config.biometricUnlock = enabled
        settings.vault = config
    }

    private static func deriveMasterKey(config: VaultConfig, password: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.unlock(config: config, password: password)
        }.value
    }

    /// Seconds until another unlock attempt is allowed (0 = now).
    var lockoutRemaining: Int {
        guard let until = lockoutUntil else { return 0 }
        return max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
    }

    @discardableResult
    func unlock(password: String) async -> Bool {
        guard settings.vault != nil else { return true }
        if lockoutRemaining > 0 {
            await auditLog.record(.unlockThrottled)
            return false
        }
        guard let masterKey = try? await resolveMasterKey(password: password) else {
            failedUnlockCount += 1
            if failedUnlockCount >= 5 {
                // 30s, 60s, 120s… capped at 5 minutes.
                let delay = min(300.0, 30.0 * pow(2, Double(failedUnlockCount - 5)))
                lockoutUntil = Date().addingTimeInterval(delay)
            }
            await auditLog.record(.unlockFailure)
            return false
        }
        failedUnlockCount = 0
        lockoutUntil = nil
        await auditLog.record(.unlockSuccess)
        // Transparent KDF upgrade: legacy PBKDF2 vaults rewrap under Argon2id
        // the first time the password is available. Notes are untouched; a
        // failure just leaves the working legacy config in place.
        if let config = settings.vault, config.kdf != VaultCrypto.kdfArgon2id,
           config.previousWrappedMasterKey == nil {
            let upgraded = try? await Task.detached(priority: .userInitiated) {
                try VaultCrypto.rewrap(config: config, masterKey: masterKey, newPassword: password)
            }.value
            if let upgraded {
                settings.vault = upgraded
            }
        }
        await finishUnlock(masterKey: masterKey)
        return true
    }

    /// Touch ID / Apple Watch / login-password unlock. Preferred path:
    /// decrypt the enclave-wrapped key (the enclave enforces user presence).
    /// Fallback path: read the user-presence-protected raw key. Either way
    /// the system authentication prompt appears off the main actor.
    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        guard settings.vault?.biometricUnlock == true,
              let keychain = secrets as? KeychainSecretStore else { return false }
        let seAccount = Self.vaultSEKeychainAccount
        let legacyAccount = Self.vaultKeychainAccount
        let masterKey = await Task.detached(priority: .userInitiated) { () -> Data? in
            if let blob = keychain.data(for: seAccount) {
                return SecureEnclaveWrap.unwrap(blob, prompt: "unlock your notes")
            }
            return keychain.protectedData(for: legacyAccount, prompt: "unlock your notes")
        }.value
        guard let masterKey else {
            await auditLog.record(.biometricUnlockFailure)
            return false
        }
        await auditLog.record(.biometricUnlockSuccess)
        await finishUnlock(masterKey: masterKey)
        return true
    }

    private func finishUnlock(masterKey: Data) async {
        let secured = SecureBytes(masterKey)
        vaultKey = secured
        await noteStore.setEncryptionKey(secured)
        await loadNotes()
        lastActivity = Date()
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
            await self.noteStore.lock()
            self.vaultKey = nil
            self.notes = []
            self.selectedNoteID = nil
            self.editorText = ""
            self.feedbackItems = []
            self.coachOutput = ""
            self.coachAction = nil
            self.showCoachPopover = false
            self.editorRailVisible = false
            self.isLocked = true
            await self.auditLog.record(.locked)
        }
    }

    // MARK: - Export / import (markdown backup)

    /// Writes every note as a plain .md file into a user-chosen folder.
    /// This is the manual backup path: plaintext by design, user-invoked only.
    func exportAllNotesAsMarkdown() {
        guard !isLocked else { return }
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
            let header = "<!-- klart:id=\(note.id.uuidString) created=\(formatter.string(from: note.createdAt)) -->\n"
            let url = folder.appendingPathComponent(name)
            try? (header + note.content).data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    /// Imports .md / .txt files as new notes (or updates the existing note
    /// when the file carries a klart:id header from a previous export).
    func importMarkdownNotes() {
        guard !isLocked else { return }
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
            if text.hasPrefix("<!-- klart:"), let headerEnd = text.range(of: "-->\n") {
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
