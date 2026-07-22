#if os(macOS)
import SwiftUI
import Foundation
import KlartKit

/// The "Constellation" sidebar: the note list read as a timeline rather than a
/// file browser. A borderless, underline-only search field keeps the header
/// almost invisible; a deliberate gap opens onto a thin vertical spine. Notes
/// are dots along it — size and opacity fade with age — and the vertical gap
/// between two dots is proportional (log-compressed) to the real time between
/// those two notes, so a large empty stretch of spine is itself information:
/// "nothing happened here."
///
/// Accessibility fallback: the proportional layout conveys recency through
/// position and whitespace, which is invisible to VoiceOver. Every dot's age
/// is therefore *also* stated in a text label, recency is carried by dot size
/// (not colour alone), and when Reduce Motion is on — or a search is active —
/// the spacing collapses to a plain, evenly-spaced list.
struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var noteToDelete: Note?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            timeline
            footer
        }
        .navigationTitle("Klårt")
        // ⌘F (the Find menu command) focuses the search field, replacing the
        // Find shortcut the system search field used to provide.
        .onChange(of: state.searchRequested) { _, _ in searchFocused = true }
        .confirmationDialog(
            "Delete “\(noteToDelete?.title ?? "")”?",
            isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let note = noteToDelete {
                    state.deleteNote(id: note.id)
                }
                noteToDelete = nil
            }
            Button("Cancel", role: .cancel) { noteToDelete = nil }
        } message: {
            Text("This permanently removes the note file from disk.")
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search notes", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
                .padding(.horizontal, 12)
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        // One timestamp for the whole render so every dot ages against the
        // same "now".
        let now = Date()
        let notes = sortedTimeline
        return ScrollViewReader { proxy in
            ScrollView {
                if notes.isEmpty {
                    emptyHint
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                            ConstellationRow(
                                note: note,
                                now: now,
                                selected: state.selectedNoteID == note.id,
                                onSelect: { state.selectedNoteID = note.id },
                                onDelete: { noteToDelete = note }
                            )
                            .id(note.id)

                            if index < notes.count - 1 {
                                // The empty spine between two dots, sized to the
                                // real time elapsed between the notes.
                                Color.clear
                                    .frame(height: gapHeight(from: note, to: notes[index + 1]))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .topLeading) { spine }
                    .padding(.horizontal, ConstellationMetrics.contentInset)
                    .padding(.top, ConstellationMetrics.headerGap)
                    .padding(.bottom, 16)
                    .focusable()
                    .focusEffectDisabled()
                    .onMoveCommand { moveSelection($0, in: notes) }
                }
            }
            .onChange(of: state.selectedNoteID) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// The continuous hairline the dots hang on. Drawn as a background of the
    /// note stack so it spans exactly from the first dot to the last.
    private var spine: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1)
            .padding(.leading, ConstellationMetrics.spineX - 0.5)
            .padding(.top, ConstellationMetrics.dotCenterY)
            .padding(.bottom, ConstellationMetrics.rowHeight - ConstellationMetrics.dotCenterY)
    }

    private var emptyHint: some View {
        Text(state.searchText.isEmpty ? "No notes yet" : "No matches")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.border)
            Button {
                state.createNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Create a new note")
        }
    }

    // MARK: Layout helpers

    /// Notes newest-first — the axis the constellation is organised around.
    private var sortedTimeline: [Note] {
        state.filteredNotes.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Empty spine height between two consecutive notes. Proportional to the
    /// elapsed time, log-compressed so a months-old gap doesn't push the list
    /// off-screen, and clamped so a dense burst of notes can't collide.
    /// Collapses to a uniform gap under Reduce Motion or an active search —
    /// the strict accessibility / non-timeline fallback.
    private func gapHeight(from newer: Note, to older: Note) -> CGFloat {
        guard !reduceMotion, state.searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ConstellationMetrics.uniformGap
        }
        let delta = max(0, newer.updatedAt.timeIntervalSince(older.updatedAt))
        let minutes = delta / 60
        let raw = ConstellationMetrics.gapBase + ConstellationMetrics.gapScale * log10(1 + minutes)
        return CGFloat(min(ConstellationMetrics.gapMax, max(ConstellationMetrics.gapMin, raw)))
    }

    private func moveSelection(_ direction: MoveCommandDirection, in notes: [Note]) {
        guard !notes.isEmpty else { return }
        guard let current = state.selectedNoteID,
              let idx = notes.firstIndex(where: { $0.id == current }) else {
            state.selectedNoteID = notes.first?.id
            return
        }
        switch direction {
        case .up where idx > 0: state.selectedNoteID = notes[idx - 1].id
        case .down where idx < notes.count - 1: state.selectedNoteID = notes[idx + 1].id
        default: break
        }
    }
}

// MARK: - Row

private struct ConstellationRow: View {
    let note: Note
    let now: Date
    let selected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                rail
                textColumn
            }
            .padding(.leading, ConstellationMetrics.rowLeadingPad)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ConstellationMetrics.rowHeight)
            .background(rowHighlight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete Note", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The dot on the spine. Horizontally centred in the rail so it lands on
    /// the hairline; vertically fixed at `dotCenterY` to line up with the title.
    private var rail: some View {
        let dot = dotStyle
        return ZStack(alignment: .top) {
            Circle()
                .fill(dot.color)
                .opacity(dot.opacity)
                .frame(width: dot.diameter, height: dot.diameter)
                .overlay(alignment: .center) {
                    if selected {
                        Circle()
                            .stroke(Theme.accent.opacity(0.35), lineWidth: 3)
                            .frame(width: dot.diameter + 5, height: dot.diameter + 5)
                    }
                }
                .padding(.top, ConstellationMetrics.dotCenterY - dot.diameter / 2)
        }
        .frame(width: ConstellationMetrics.railWidth,
               height: ConstellationMetrics.rowHeight,
               alignment: .top)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if note.isSensitive {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accent)
                        .help("Sensitive — local AI only")
                }
                Text(note.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
            }
            Text(relativeLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary.opacity(0.6 + 0.4 * recency))
                .lineLimit(1)
        }
        .padding(.top, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowHighlight: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Theme.accent.opacity(0.12)
                           : (hovering ? Theme.surfaceRaised : Color.clear))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
    }

    // MARK: Age-driven styling

    /// 1 for a brand-new note, decaying (log) toward 0 over a month.
    private var recency: Double {
        let ageHours = max(0, now.timeIntervalSince(note.updatedAt)) / 3600
        let span = log(1 + 24.0 * 30)
        return max(0, 1 - log(1 + ageHours) / span)
    }

    private var dotStyle: (diameter: CGFloat, color: Color, opacity: Double) {
        let ageHours = max(0, now.timeIntervalSince(note.updatedAt)) / 3600
        let diameter = (selected ? 5.0 : 4.0) + 4.0 * recency        // 4…9 pt
        let isFresh = ageHours < 3                                    // the warm zone
        let color: Color = (selected || isFresh) ? Theme.accent : Theme.textSecondary
        let opacity = selected ? 1.0 : (0.35 + 0.65 * recency)
        return (CGFloat(diameter), color, opacity)
    }

    private var titleColor: Color {
        selected ? Theme.accent : Theme.textPrimary.opacity(0.55 + 0.45 * recency)
    }

    private var relativeLabel: String {
        ConstellationRow.relativeLabel(for: note.updatedAt, now: now)
    }

    private var a11yLabel: String {
        let prefix = note.isSensitive ? "Sensitive note. " : ""
        return "\(prefix)\(note.title). Edited \(relativeLabel)"
    }

    /// Compact relative time: "2m ago", "1h ago", "Yesterday", "4d ago".
    static func relativeLabel(for date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return "Just now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(max(1, hours))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let days = Int(seconds / 86400)
        if days < 7 { return "\(days)d ago" }
        if days < 28 { return "\(days / 7)w ago" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: date)
    }
}

// MARK: - Metrics

private enum ConstellationMetrics {
    static let railWidth: CGFloat = 24
    static let rowLeadingPad: CGFloat = 6
    /// x of the spine within the note stack: row inset + rail centre.
    static let spineX: CGFloat = rowLeadingPad + railWidth / 2
    static let rowHeight: CGFloat = 40
    /// y of every dot's centre within its row (aligned to the title line).
    static let dotCenterY: CGFloat = 13
    /// The deliberate gap between the search header and the first dot.
    static let headerGap: CGFloat = 32
    static let contentInset: CGFloat = 8
    /// Even spacing used in the accessibility / search fallback.
    static let uniformGap: CGFloat = 6

    // Proportional-gap curve: gap = base + scale · log10(1 + minutes), clamped.
    static let gapBase: Double = 6
    static let gapScale: Double = 9
    static let gapMin: Double = 6
    static let gapMax: Double = 54
}
#endif
