#if os(macOS)
import SwiftUI
import KlartKit

/// The coach popover: suggestions, one-tap coach actions, and coach output.
/// Rendered inside an NSPopover, so the system material is the background.
struct FeedbackPanelView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                coachActions
                phaseBanner
                feedbackList
                coachOutputSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(
                reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.25),
                value: state.feedbackItems
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Coach", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if state.feedbackPhase == .analyzing || state.coachRunning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            StatusDot(status: state.connection)
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("AI provider settings")
        }
    }

    private var coachActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CoachAction.allCases) { action in
                Button {
                    state.runCoach(action)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16)
                            .symbolEffect(.bounce, value: state.coachAction == action)
                        Text(action.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        state.coachAction == action ? Theme.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.coachRunning)
            }
        }
    }

    @ViewBuilder
    private var phaseBanner: some View {
        switch state.feedbackPhase {
        case .error(let message):
            banner(text: message, systemImage: "exclamationmark.triangle", color: Theme.color(for: .structure))
        case .skipped(let reason):
            banner(text: reason, systemImage: "moon.zzz", color: Theme.textTertiary)
        case .waiting:
            banner(text: "Watching for a pause in your typing…", systemImage: "ellipsis", color: Theme.textTertiary)
        case .analyzing, .idle:
            EmptyView()
        }
    }

    private func banner(text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var feedbackList: some View {
        if !state.feedbackItems.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("SUGGESTIONS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 6)
                ForEach(state.feedbackItems) { item in
                    FeedbackRow(item: item)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.97))
                        ))
                    if item.id != state.feedbackItems.last?.id {
                        Divider().overlay(Theme.border)
                    }
                }
            }
        } else if state.feedbackPhase == .idle && state.coachOutput.isEmpty {
            banner(
                text: "Write, then pause — I'll point out gaps, overlaps, and sharper structure. Mark a section [no-ai] to keep me out of it.",
                systemImage: "lightbulb",
                color: Theme.textTertiary
            )
        }
    }

    @ViewBuilder
    private var coachOutputSection: some View {
        if let action = state.coachAction {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(action.label.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button {
                        state.coachAction = nil
                        state.coachOutput = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Text(coachOutputText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var coachOutputText: AttributedString {
        let raw = state.coachOutput.isEmpty && state.coachRunning ? "Thinking…" : state.coachOutput
        if let parsed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(raw)
    }
}

/// One suggestion as a quiet row: kind label, observation, hairline
/// separation — no card chrome.
private struct FeedbackRow: View {
    @EnvironmentObject var state: AppState
    let item: FeedbackItem
    @State private var showSuggestion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                KindBadge(kind: item.kind)
                if let section = item.section, !section.isEmpty {
                    Text(section)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let suggestion = item.suggestion {
                DisclosureGroup(isExpanded: $showSuggestion) {
                    Text(suggestion)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } label: {
                    Text("Suggested content")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }

            HStack(spacing: 8) {
                Button {
                    state.accept(item)
                } label: {
                    Label("Insert", systemImage: "text.insert")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                .help("Insert this into the current section as a quoted block")

                Button {
                    state.reject(item)
                } label: {
                    Label("Dismiss", systemImage: "hand.thumbsdown")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textTertiary)
                .help("Hide this tip and don't show it again for this note")

                Spacer()
            }
        }
        .padding(.vertical, 9)
    }
}
#endif
