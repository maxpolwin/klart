#if os(macOS)
import SwiftUI
import KlartKit

struct SettingsView: View {
    var body: some View {
        TabView {
            InterfaceSettingsView()
                .tabItem { Label("Interface", systemImage: "rectangle.center.inset.filled") }
            ProviderSettingsView()
                .tabItem { Label("AI Provider", systemImage: "cpu") }
            CoachingSettingsView()
                .tabItem { Label("Editor", systemImage: "sparkles") }
            SecuritySettingsView()
                .tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - Interface tab

private struct InterfaceSettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Writing surface") {
                Toggle("Teleprompter mode", isOn: $state.settings.teleprompterMode)
                Text(
                    "One centered, monochrome column and nothing else on screen. "
                    + "Your notes wait behind the left edge; the editor's suggestions "
                    + "appear in the right margin when you summon them (⌘E or type /editor) "
                    + "and fade away again while you keep writing. "
                    + "Turn off for the classic sidebar layout."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("At the bottom") {
                Toggle("Show word count and estimated reading time", isOn: $state.settings.showWordCount)
                Text("A quiet line at the foot of the page, e.g. “512 words · 3 min read”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Provider tab

private struct ProviderSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKey = ""
    @State private var showKeyInfo = false

    private var kind: ProviderKind { state.settings.activeProvider }

    private var usesPlainHTTP: Bool {
        state.settings.activeConfig.baseURL
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .hasPrefix("http:")
    }

    private var config: Binding<ProviderConfig> {
        Binding(
            get: { state.settings.activeConfig },
            set: { state.settings.setConfig($0, for: state.settings.activeProvider) }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $state.settings.activeProvider) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: state.settings.activeProvider) { _, newKind in
                    apiKey = state.apiKey(for: newKind)
                    state.availableModels = []
                    state.connection = .unknown
                }

                TextField("Server URL", text: config.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                if usesPlainHTTP {
                    Label {
                        Text("Unencrypted connection — fine for this Mac; on a shared network other devices can read this traffic. Klårt only allows http:// to local hosts.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                if kind.usesAPIKey {
                    HStack(spacing: 6) {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: apiKey) { _, newValue in
                                state.setAPIKey(newValue, for: kind)
                            }
                        Button {
                            showKeyInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Where is this key stored?")
                        .popover(isPresented: $showKeyInfo, arrowEdge: .trailing) {
                            Text("Paste your key here — that's all. Klårt saves it straight to the macOS Keychain (service “com.klart.mac”) and reads it from there on every request. It is never written to settings files or notes. To remove it, clear this field; to inspect it, search for “klart” in Keychain Access.")
                                .font(.caption)
                                .frame(width: 260)
                                .padding(12)
                        }
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(providerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                HStack {
                    TextField("Model", text: config.model)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    if !state.availableModels.isEmpty {
                        Menu {
                            ForEach(state.availableModels, id: \.self) { model in
                                Button(model) { config.wrappedValue.model = model }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .help("Pick from models the server offers")
                    }
                }

                HStack(spacing: 10) {
                    Button("Test Connection") { state.testConnection() }
                    connectionLabel
                    Spacer()
                }
            }

            Section("Generation") {
                LabeledContent("Creativity") {
                    HStack {
                        Slider(value: $state.settings.temperature, in: 0...1.5, step: 0.1)
                        Text(String(format: "%.1f", state.settings.temperature))
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                }
                Stepper(
                    "Max response tokens: \(state.settings.maxTokens)",
                    value: $state.settings.maxTokens,
                    in: 256...8192,
                    step: 256
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = state.apiKey(for: kind) }
    }

    private var providerHint: String {
        switch kind {
        case .ollama:
            return "Local, private, free. Install from ollama.com and run `ollama pull llama3.2`."
        case .lmstudio:
            return "Local, private. In LM Studio, load a model and start the server (Developer → Start Server)."
        case .openrouter:
            return "Cloud gateway to hundreds of models (Claude, GPT, Llama, …). Create a key at openrouter.ai/keys. HTTPS enforced."
        case .custom:
            return "Any OpenAI-compatible endpoint: llama.cpp server, vLLM, LocalAI, a corporate gateway…"
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch state.connection {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .connected(let name):
            Label("\(name) reachable — \(state.availableModels.count) models", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

// MARK: - Coaching tab

private struct CoachingSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showPromptEditor = false
    @State private var showClearLogConfirm = false

    var body: some View {
        Form {
            Section("Live feedback") {
                Toggle("Analyze automatically while I write", isOn: $state.settings.autoFeedback)
                LabeledContent("Wait after typing") {
                    HStack {
                        Slider(value: $state.settings.debounceSeconds, in: 1...10, step: 0.5)
                        Text(String(format: "%.1fs", state.settings.debounceSeconds))
                            .monospacedDigit()
                            .frame(width: 38)
                    }
                }
                Stepper(
                    "Tips per round: \(state.settings.tipStyle.maxTips)",
                    value: $state.settings.tipStyle.maxTips,
                    in: 1...6
                )
            }

            Section("Feedback types") {
                ForEach(FeedbackKind.allCases.filter { $0 != .other }) { kind in
                    Toggle(isOn: binding(for: kind)) {
                        HStack(spacing: 8) {
                            KindBadge(kind: kind)
                            Text(description(for: kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Voice") {
                Picker("Tone", selection: $state.settings.tipStyle.tone) {
                    ForEach(FeedbackTone.allCases) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
                Picker("Detail", selection: $state.settings.tipStyle.detail) {
                    ForEach(FeedbackDetail.allCases) { detail in
                        Text(detail.label).tag(detail)
                    }
                }
                TextField("Language (empty = match my notes)", text: $state.settings.tipStyle.language)
                    .textFieldStyle(.roundedBorder)
                TextField(
                    "Extra guidance for the Editor (optional)",
                    text: $state.settings.tipStyle.customGuidance,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System prompt")
                        Text(
                            (state.settings.feedbackSystemPrompt != nil || state.settings.coachSystemPrompt != nil)
                            ? "Customised — you can always revert to the default."
                            : "Rewrite how the coach thinks. Revert to the default any time."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit System Prompt…") { showPromptEditor = true }
                }
            } footer: {
                Text("Advanced. The prompt keeps placeholder tokens (e.g. {{JSON_SHAPE}}) the app fills in for each request; leave the required ones in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Include my note text in the log",
                    isOn: $state.settings.logRecommendationContent
                )
                HStack {
                    Text("Export")
                    Spacer()
                    Menu("Export Log…") {
                        Button("Without note text") {
                            state.exportRecommendationLog(includeContent: false)
                        }
                        Button("With note text") {
                            state.exportRecommendationLog(includeContent: true)
                        }
                    }
                    .fixedSize()
                    Button("Clear…") { showClearLogConfirm = true }
                }
                if let result = state.recommendationExportResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Learning log")
            } footer: {
                Text("Which editor notes you confirm or reject is recorded locally so coaching can improve. The record always keeps the verdict, the note type, and which model and system prompt produced it — never your writing, unless you switch that on above. Notes marked sensitive never contribute their text. The log is encrypted with your notes when protection is on, and only leaves this Mac if you export it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPromptEditor) {
            SystemPromptEditorSheet()
        }
        .confirmationDialog(
            "Delete the learning log?",
            isPresented: $showClearLogConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Log", role: .destructive) {
                state.clearRecommendationLog()
                state.recommendationExportResult = "Learning log cleared."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every recorded verdict is removed. This cannot be undone.")
        }
    }

    private func binding(for kind: FeedbackKind) -> Binding<Bool> {
        Binding(
            get: { state.settings.enabledFeedbackKinds.contains(kind) },
            set: { enabled in
                if enabled {
                    if !state.settings.enabledFeedbackKinds.contains(kind) {
                        state.settings.enabledFeedbackKinds.append(kind)
                    }
                } else {
                    state.settings.enabledFeedbackKinds.removeAll { $0 == kind }
                }
            }
        )
    }

    private func description(for kind: FeedbackKind) -> String {
        switch kind {
        case .gap: return "Missing perspectives or considerations"
        case .mece: return "Overlapping or incomplete categories"
        case .source: return "Literature and data worth consulting"
        case .structure: return "Clearer organization of the argument"
        case .clarity: return "Vague or unsupported claims"
        case .question: return "Socratic questions that push further"
        case .other: return ""
        }
    }
}

// MARK: - System prompt editor

/// Full-text editor for the two AI system prompts, each with independent
/// revert-to-default. Writes straight through `state.settings`, so persistence
/// is automatic; storing `nil` when the text matches the current default keeps
/// "revert" and "the current default" one and the same thing.
private struct SystemPromptEditorSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Target: String, CaseIterable, Identifiable {
        case feedback, coach
        var id: String { rawValue }
        var label: String { self == .feedback ? "Editor feedback" : "Quiet coach" }
    }

    @State private var target: Target = .feedback

    private var placeholders: [PromptPlaceholder] {
        target == .feedback ? PromptBuilder.feedbackPlaceholders : PromptBuilder.coachPlaceholders
    }

    private var isCustomised: Bool {
        target == .feedback
            ? state.settings.feedbackSystemPrompt != nil
            : state.settings.coachSystemPrompt != nil
    }

    private var promptText: Binding<String> {
        Binding(
            get: {
                target == .feedback
                    ? state.settings.effectiveFeedbackPrompt
                    : state.settings.effectiveCoachPrompt
            },
            set: { newValue in
                switch target {
                case .feedback:
                    state.settings.feedbackSystemPrompt =
                        newValue == PromptBuilder.defaultFeedbackTemplate ? nil : newValue
                case .coach:
                    state.settings.coachSystemPrompt =
                        newValue == PromptBuilder.defaultCoachTemplate ? nil : newValue
                }
            }
        )
    }

    private var missingTokens: [String] {
        PromptBuilder.missingRequiredPlaceholders(in: promptText.wrappedValue, placeholders: placeholders)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System prompt")
                .font(.system(size: 15, weight: .semibold))

            Picker("", selection: $target) {
                ForEach(Target.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextEditor(text: promptText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 240)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )

            if !missingTokens.isEmpty {
                Label(
                    "\(missingTokens.joined(separator: ", ")) is missing — feedback can't be parsed without it.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Placeholders the app fills in:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(placeholders) { placeholder in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(placeholder.token)
                            .font(.system(.caption, design: .monospaced))
                        Text(placeholder.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Revert to Default", role: .destructive) {
                    switch target {
                    case .feedback: state.settings.feedbackSystemPrompt = nil
                    case .coach: state.settings.coachSystemPrompt = nil
                    }
                }
                .disabled(!isCustomised)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
    }
}

// MARK: - Security tab

private struct SecuritySettingsView: View {
    @EnvironmentObject var state: AppState

    private enum ActiveSheet: Identifiable {
        case setup, changePassword, disable, enableBiometric, rotateKey
        var id: Int { hashValue }
    }

    @State private var activeSheet: ActiveSheet?

    private var vaultEnabled: Bool { state.settings.vault != nil }

    var body: some View {
        Form {
            Section {
                if vaultEnabled {
                    Label {
                        Text("Notes are encrypted on disk")
                            .font(.system(size: 13, weight: .medium))
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                    Text("Every note file is sealed with ChaCha20-Poly1305. The key is derived from your password and never stored in plain form. Lock any time with ⌘L; the app starts locked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Unlock with Touch ID", isOn: biometricBinding)

                    Toggle("Lock when the screen sleeps or locks", isOn: $state.settings.lockOnScreenSleep)
                    Picker("Auto-lock when inactive", selection: $state.settings.autoLockMinutes) {
                        Text("Never").tag(0)
                        Text("After 5 minutes").tag(5)
                        Text("After 15 minutes").tag(15)
                        Text("After 30 minutes").tag(30)
                        Text("After 1 hour").tag(60)
                    }
                    Toggle("Exclude window from screenshots & screen sharing", isOn: $state.settings.excludeFromCapture)

                    HStack(spacing: 10) {
                        Button("Change Password…") { activeSheet = .changePassword }
                        Button("Rotate Encryption Key…") { activeSheet = .rotateKey }
                        Button("Turn Off Protection…") { activeSheet = .disable }
                    }
                } else {
                    Text("Encrypt your notes on disk and require a password (optionally Touch ID) to open Klårt. Recommended if your notes hold anything personal or critical.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Set Up Protection…") { activeSheet = .setup }
                }
            } header: {
                Text("Note protection")
            } footer: {
                if vaultEnabled {
                    Text("If you forget the password and Touch ID unlock is off, your notes cannot be recovered — there is no backdoor. Keep a markdown export (File → Export Notes as Markdown…) somewhere safe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .setup:
                SetupProtectionSheet()
            case .changePassword:
                ChangePasswordSheet()
            case .disable:
                DisableProtectionSheet()
            case .enableBiometric:
                EnableBiometricSheet()
            case .rotateKey:
                RotateKeySheet()
            }
        }
    }

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { state.settings.vault?.biometricUnlock ?? false },
            set: { enable in
                if enable {
                    activeSheet = .enableBiometric   // needs the password once
                } else {
                    Task { try? await state.setBiometricUnlock(false, password: nil) }
                }
            }
        )
    }
}

/// Shared scaffolding for the password sheets: title, fields, error line,
/// busy state, cancel/confirm.
private struct VaultSheetChrome<Fields: View>: View {
    let title: String
    let confirmLabel: String
    let confirmDisabled: Bool
    let busy: Bool
    let error: String?
    let onConfirm: () -> Void
    @ViewBuilder let fields: Fields

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            fields
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    onConfirm()
                } label: {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(confirmLabel)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(confirmDisabled || busy)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct SetupProtectionSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var useBiometrics = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VaultSheetChrome(
            title: "Protect your notes",
            confirmLabel: "Encrypt Notes",
            confirmDisabled: password.count < 8 || password != confirm,
            busy: busy,
            error: error,
            onConfirm: run
        ) {
            SecureField("Password (min. 8 characters)", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("Repeat password", text: $confirm)
                .textFieldStyle(.roundedBorder)
            Toggle("Also allow Touch ID to unlock", isOn: $useBiometrics)
            Text("All note files are encrypted with this password. If you forget it (and Touch ID is off), the notes are unrecoverable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func run() {
        busy = true
        error = nil
        Task {
            do {
                try await state.enableProtection(password: password, biometricUnlock: useBiometrics)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct ChangePasswordSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VaultSheetChrome(
            title: "Change vault password",
            confirmLabel: "Change Password",
            confirmDisabled: current.isEmpty || newPassword.count < 8 || newPassword != confirm,
            busy: busy,
            error: error,
            onConfirm: run
        ) {
            SecureField("Current password", text: $current)
                .textFieldStyle(.roundedBorder)
            SecureField("New password (min. 8 characters)", text: $newPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("Repeat new password", text: $confirm)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func run() {
        busy = true
        error = nil
        Task {
            do {
                try await state.changeVaultPassword(current: current, new: newPassword)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct DisableProtectionSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VaultSheetChrome(
            title: "Turn off protection?",
            confirmLabel: "Decrypt Notes",
            confirmDisabled: password.isEmpty,
            busy: busy,
            error: error,
            onConfirm: run
        ) {
            Text("Notes will be rewritten as plain, unencrypted files and Klårt will no longer ask for a password.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func run() {
        busy = true
        error = nil
        Task {
            do {
                try await state.disableProtection(password: password)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct RotateKeySheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VaultSheetChrome(
            title: "Rotate encryption key",
            confirmLabel: "Rotate Key",
            confirmDisabled: password.isEmpty,
            busy: busy,
            error: error,
            onConfirm: run
        ) {
            Text("Generates a fresh master key and re-encrypts every note under it. Your password stays the same. Do this periodically, or if you suspect a device compromise.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func run() {
        busy = true
        error = nil
        Task {
            do {
                try await state.rotateMasterKey(password: password)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct EnableBiometricSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VaultSheetChrome(
            title: "Enable Touch ID unlock",
            confirmLabel: "Enable",
            confirmDisabled: password.isEmpty,
            busy: busy,
            error: error,
            onConfirm: run
        ) {
            Text("Your password is needed once to store the key behind Touch ID. Reading it back always requires you to authenticate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func run() {
        busy = true
        error = nil
        Task {
            do {
                try await state.setBiometricUnlock(true, password: password)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
#endif
