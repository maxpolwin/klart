#if os(macOS)
import SwiftUI
import NoschenKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ProviderSettingsView()
                .tabItem { Label("AI Provider", systemImage: "cpu") }
            CoachingSettingsView()
                .tabItem { Label("Coaching", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - Provider tab

private struct ProviderSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKey = ""

    private var kind: ProviderKind { state.settings.activeProvider }

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
                    if newKind == .builtin {
                        state.refreshBuiltinModelStates()
                    }
                }

                if kind != .builtin {
                    TextField("Server URL", text: config.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                if kind.usesAPIKey {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { _, newValue in
                            state.setAPIKey(newValue, for: kind)
                        }
                    Text("Stored in the macOS Keychain — never written to settings files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(providerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                if kind == .builtin {
                    ForEach(ModelRegistry.models) { model in
                        BuiltinModelRow(
                            model: model,
                            state: state.builtinModelStates[model.id] ?? .notInstalled,
                            isActive: config.wrappedValue.model == model.id,
                            select: { config.wrappedValue.model = model.id },
                            download: { state.downloadBuiltinModel(model) },
                            cancel: { state.cancelBuiltinDownload(model) },
                            delete: { state.deleteBuiltinModel(model) }
                        )
                    }
                } else {
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
        .onAppear {
            apiKey = state.apiKey(for: kind)
            if kind == .builtin {
                state.refreshBuiltinModelStates()
            }
        }
    }

    private var providerHint: String {
        switch kind {
        case .builtin:
            return "Runs entirely inside Noschen — no server, no account, nothing leaves your Mac. The model is a one-time download stored in Application Support."
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

// MARK: - Built-in model row

private struct BuiltinModelRow: View {
    let model: BuiltinModel
    let state: ModelDownloadState
    let isActive: Bool
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    @State private var confirmingDelete = false

    init(
        model: BuiltinModel,
        state: ModelDownloadState,
        isActive: Bool,
        select: @escaping () -> Void,
        download: @escaping () -> Void,
        cancel: @escaping () -> Void,
        delete: @escaping () -> Void
    ) {
        self.model = model
        self.state = state
        self.isActive = isActive
        self.select = select
        self.download = download
        self.cancel = cancel
        self.delete = delete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if case .installed = state {
                    Button(action: select) {
                        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Use this model")
                }
                Text(model.displayName)
                    .fontWeight(isActive ? .semibold : .regular)
                Text(model.sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                trailingControl
            }
            Text(model.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .downloading(let bytes, let total) = state {
                progressBar(bytes: bytes, total: total)
            }
            if case .failed(let message) = state {
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Remove the downloaded model? This frees \(model.sizeLabel) of disk space. You can download it again anytime.",
            isPresented: $confirmingDelete
        ) {
            Button("Remove Download", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .notInstalled:
            Button("Download") { download() }
        case .downloading:
            Button("Cancel") { cancel() }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying…").font(.caption).foregroundStyle(.secondary)
            }
        case .installed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Remove Download") { confirmingDelete = true }
                    .controlSize(.small)
            }
        case .failed:
            Button("Retry") { download() }
        }
    }

    @ViewBuilder
    private func progressBar(bytes: Int64, total: Int64?) -> some View {
        if let total, total > 0 {
            HStack(spacing: 8) {
                ProgressView(value: Double(bytes), total: Double(total))
                Text("\(Int(Double(bytes) / Double(total) * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Coaching tab

private struct CoachingSettingsView: View {
    @EnvironmentObject var state: AppState

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
                    "Extra guidance for the coach (optional)",
                    text: $state.settings.tipStyle.customGuidance,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
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
#endif
