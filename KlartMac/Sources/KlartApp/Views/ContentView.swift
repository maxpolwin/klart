#if os(macOS)
import SwiftUI
import AppKit
import KlartKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pillPulse = false

    var body: some View {
        Group {
            if state.isLocked {
                LockView()
            } else {
                mainInterface
            }
        }
        .background(WindowConfigurator(
            excludeFromCapture: state.settings.excludeFromCapture,
            chromeless: state.settings.teleprompterMode && !state.isLocked
        ))
    }

    /// Teleprompter (the default): one centered column, no persistent chrome,
    /// monochrome. Classic: sidebar + toolbar + coach pill. Switchable in
    /// Settings → Interface.
    @ViewBuilder
    private var mainInterface: some View {
        if state.settings.teleprompterMode {
            TeleprompterView()
        } else {
            classicInterface
        }
    }

    private var classicInterface: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            detail
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                sensitiveToggle

                Button {
                    state.requestFeedback(manual: true)
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                        .symbolEffect(.bounce, value: state.feedbackPhase == .analyzing)
                }
                .help("Ask the Editor to analyze this note now (⌘R)")
                .disabled(state.selectedNoteID == nil)

                coachPill
            }
        }
        .onChange(of: state.feedbackItems.count) { old, new in
            // A small, springy nudge when fresh suggestions land — the pill is
            // the only place the AI is allowed to wave.
            guard new > old, !reduceMotion else { return }
            withAnimation(.spring(duration: 0.3, bounce: 0.6)) { pillPulse = true }
            withAnimation(.spring(duration: 0.35, bounce: 0.3).delay(0.3)) { pillPulse = false }
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

    /// Marks the current note sensitive: it will only ever use local AI,
    /// enforced in code against the resolved endpoint, never a cloud model.
    private var sensitiveToggle: some View {
        Button {
            state.toggleSensitive()
        } label: {
            Label(
                "Sensitive",
                systemImage: state.selectedNote?.isSensitive == true ? "shield.fill" : "shield"
            )
            .symbolEffect(.bounce, value: state.selectedNote?.isSensitive == true)
            .foregroundStyle(state.selectedNote?.isSensitive == true ? Theme.accent : Color.secondary)
        }
        .help(
            state.selectedNote?.isSensitive == true
                ? "Sensitive: only local AI ever sees this note. Click to unmark."
                : "Mark sensitive: keeps this note on local AI only, never the cloud."
        )
        .disabled(state.selectedNoteID == nil)
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
                    .scaleEffect(pillPulse ? 1.6 : 1.0)
                Text(pillText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: pillText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.surfaceRaised, in: Capsule())
            .scaleEffect(pillPulse ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .help("Editor suggestions — click to open (⌘.)")
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
        return "Editor"
    }
}

/// Applies window-level settings SwiftUI has no modifier for:
/// `sharingType = .none` removes the window from screenshots, recordings,
/// and screen sharing; `chromeless` melts the title bar into the content
/// for the Teleprompter's zero-chrome surface.
private struct WindowConfigurator: NSViewRepresentable {
    let excludeFromCapture: Bool
    var chromeless = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        window.sharingType = excludeFromCapture ? .none : .readOnly
        window.titleVisibility = chromeless ? .hidden : .visible
        window.titlebarAppearsTransparent = chromeless
        if chromeless {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.7))
                .scaleEffect(appeared || reduceMotion ? 1.0 : 0.6)
                .opacity(appeared || reduceMotion ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(duration: 0.5, bounce: 0.45)) { appeared = true }
                }
            Text("Think in writing.")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Start a note with a `# Topic` heading and `## Questions`.\nKlårt helps you think more clearly and completely as you write.")
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
