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
                Button {
                    state.requestFeedback(manual: true)
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                }
                .help("Ask the coach to analyze this note now (⌘R)")
                .disabled(state.selectedNoteID == nil)

                coachPill
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if state.selectedNoteID != nil {
            EditorView()
        } else {
            EmptyStateView()
        }
    }

    /// The one visible trace of AI while writing: a small pill that reports
    /// readiness and opens the coach popover only when asked.
    private var coachPill: some View {
        Button {
            state.showCoachPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(pillDotColor)
                    .frame(width: 6, height: 6)
                Text(pillText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.surfaceRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Coach suggestions — click to open (⌘.)")
        .disabled(state.selectedNoteID == nil)
        .popover(isPresented: $state.showCoachPopover, arrowEdge: .bottom) {
            FeedbackPanelView()
                .frame(width: 360)
                .frame(maxHeight: 520)
        }
    }

    private var pillDotColor: Color {
        if case .failed = state.connection { return Theme.color(for: .question) }
        if state.feedbackPhase == .analyzing || state.coachRunning { return Theme.color(for: .structure) }
        if !state.feedbackItems.isEmpty { return Theme.accent }
        return Theme.textTertiary
    }

    private var pillText: String {
        if case .failed = state.connection { return "Offline" }
        if state.feedbackPhase == .analyzing || state.coachRunning { return "Thinking…" }
        let count = state.feedbackItems.count
        if count > 0 { return count == 1 ? "1 ready" : "\(count) ready" }
        return "Coach"
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text("Think in writing.")
                .font(.system(size: 22, weight: .semibold))
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
            .tint(Theme.accent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
#endif
