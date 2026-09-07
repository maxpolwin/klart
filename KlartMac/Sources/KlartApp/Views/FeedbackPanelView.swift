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
            Label("Editor", systemImage: "sparkles")
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
            banner(text: "Reading this section when you finish it — or after a pause.", systemImage: "ellipsis", color: Theme.textTertiary)
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
                Text("NOTES")
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
                text: "Finish a section and I'll read it: gaps, unstated assumptions, claims with nothing behind them, the objection you haven't met. Type //editor to make me read now. Mark a section [no-ai] to keep me out of it.",
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

/// One note as a quiet row: kind badge, severity, the words it is about, the
/// observation, why it matters, hairline separation — no card chrome.
private struct FeedbackRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: FeedbackItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                KindBadge(kind: item.kind)
                if let mark = Theme.severityMark(item.severity) {
                    Text(mark)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.color(for: item.kind))
                        .accessibilityHidden(true)
                }
                if item.source == .local, let rule = item.rule {
                    Text(rule)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                } else if let section = item.section, !section.isEmpty {
                    Text(section)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            if let anchor = item.anchor {
                Text("“\(anchor)”")
                    .font(.system(size: 12).italic())
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let why = item.why {
                Text(why)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button {
                    state.respond(to: item)
                } label: {
                    Label("Respond", systemImage: "text.insert")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(outcome == nil ? Theme.accent : Theme.textTertiary)
                .disabled(outcome != nil)
                .help("Put this note into that section as a prompt, and answer it in your own words")

                Spacer()

                judgement(
                    .confirmed,
                    systemImage: "checkmark",
                    help: "Fair — the editor is right"
                ) { state.confirm(item) }

                judgement(
                    .rejected,
                    systemImage: "xmark",
                    help: "Wrong — never raise this here again"
                ) { state.reject(item) }
            }
        }
        .padding(.vertical, 9)
        // Judged tips stay put and fade back rather than disappearing, so the
        // panel reads as a record of what has been dealt with. Only the
        // controls go inert — the text stays readable and selectable.
        .opacity(outcome == nil ? 1 : 0.45)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: outcome)
    }

    private var outcome: RecommendationOutcome? { state.outcome(for: item) }

    /// A minimal icon-only verdict control. Once the tip is judged, the chosen
    /// verdict stays tinted and the other fades out, so the row still says
    /// which way it went.
    private func judgement(
        _ verdict: RecommendationOutcome,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let chosen = outcome == verdict
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(chosen ? Theme.accent : Theme.textTertiary)
        .opacity(outcome == nil || chosen ? 1 : 0.35)
        .disabled(outcome != nil)
        .help(help)
        .accessibilityLabel(verdict == .confirmed ? "Confirm note" : "Reject note")
    }
}
#endif
