#if os(macOS)
import SwiftUI
import NoschenKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            detail
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                statusPill

                Button {
                    state.requestFeedback(manual: true)
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                }
                .help("Ask the coach to analyze this note now (⌘R)")
                .disabled(state.selectedNoteID == nil)

                Button {
                    state.showInspector.toggle()
                } label: {
                    Label("Coach Panel", systemImage: "sidebar.right")
                }
                .help("Show or hide the coaching panel")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if state.selectedNoteID != nil {
            EditorView()
                .inspector(isPresented: $state.showInspector) {
                    FeedbackPanelView()
                        .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
                }
        } else {
            EmptyStateView()
        }
    }

    private var statusPill: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 6) {
                StatusDot(status: state.connection)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.surfaceRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("AI provider status — click to open Settings")
    }

    private var statusText: String {
        let model = state.settings.activeConfig.model
        let provider = state.settings.activeProvider.displayName
        switch state.connection {
        case .failed: return "\(provider) · offline"
        case .checking: return "\(provider) · checking…"
        default: return model.isEmpty ? provider : "\(provider) · \(model)"
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text("Think in writing.")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.textPrimary)
            Text("Start a note with a `# Topic` heading and `## Questions`.\nNoschen coaches you toward clearer, more complete thinking as you write.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button {
                state.createNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent.opacity(0.8))
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
#endif
