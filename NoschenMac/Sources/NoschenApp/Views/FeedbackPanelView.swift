#if os(macOS)
import SwiftUI
import NoschenKit

/// The coaching panel: live feedback cards plus one-tap coach actions.
struct FeedbackPanelView: View {
    @EnvironmentObject var state: AppState

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
        }
        .background(Theme.surface)
    }

    private var header: some View {
        HStack {
            Label("Thinking Coach", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if state.feedbackPhase == .analyzing || state.coachRunning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var coachActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(CoachAction.allCases) { action in
                Button {
                    state.runCoach(action)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16)
                        Text(action.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        state.coachAction == action ? Theme.accent.opacity(0.12) : Theme.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 8)
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
            banner(text: message, systemImage: "exclamationmark.triangle", color: .orange)
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
            VStack(alignment: .leading, spacing: 10) {
                Text("SUGGESTIONS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textTertiary)
                ForEach(state.feedbackItems) { item in
                    FeedbackCard(item: item)
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

private struct FeedbackCard: View {
    @EnvironmentObject var state: AppState
    let item: FeedbackItem
    @State private var showSuggestion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                KindBadge(kind: item.kind)
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
                        .foregroundStyle(Theme.accent.opacity(0.9))
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
        .padding(11)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.color(for: item.kind).opacity(0.25), lineWidth: 1)
        )
    }
}
#endif
