#if os(macOS)
import SwiftUI
import Foundation
import NoschenKit

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @State private var noteToDelete: Note?

    /// Column width the dot + connecting line reserve on the leading edge of
    /// every row; the line's background rectangle and each dot's frame both
    /// key off this so they stay centered on one another.
    private let dotColumnWidth: CGFloat = 16

    var body: some View {
        let notes = state.filteredNotes
        let gaps = timelineGaps(for: notes)

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(notes) { note in
                        ConstellationRow(
                            note: note,
                            isSelected: note.id == state.selectedNoteID,
                            isRecent: Calendar.current.isDateInToday(note.updatedAt),
                            dotColumnWidth: dotColumnWidth
                        ) {
                            state.selectedNoteID = note.id
                        }
                        .padding(.top, gaps[note.id] ?? 0)
                        .contextMenu {
                            Button("Delete Note", role: .destructive) {
                                noteToDelete = note
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1)
                        .padding(.leading, dotColumnWidth / 2 - 0.5)
                }
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)

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
        }
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "Search notes")
        .navigationTitle("Noschen")
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

    /// For every note after the first (notes are already newest-first),
    /// how much extra space should open up above its row — proportional to
    /// the real time elapsed since the previous, more recent note.
    /// Log-compressed so a months-old note doesn't push the list off-screen,
    /// and clamped on both ends so near-simultaneous notes never collide
    /// and old notes never blow out the scroll height. A large gap on the
    /// spine reads as "nothing happened here," not just "next row."
    private func timelineGaps(for notes: [Note]) -> [UUID: CGFloat] {
        var gaps: [UUID: CGFloat] = [:]
        for index in notes.indices.dropFirst() {
            let minutes = max(0, notes[index - 1].updatedAt.timeIntervalSince(notes[index].updatedAt)) / 60
            let value = 6 + 11 * log10(1 + minutes)
            gaps[notes[index].id] = CGFloat(min(max(value, 6), 56))
        }
        return gaps
    }
}

/// A single note on the sidebar's timeline: a dot on the vertical spine,
/// sized and colored by recency, with the note's title and its exact
/// last-modified date and time (not a relative "4d ago" string).
private struct ConstellationRow: View {
    let note: Note
    let isSelected: Bool
    let isRecent: Bool
    let dotColumnWidth: CGFloat
    let onSelect: () -> Void

    private var dotColor: Color {
        isSelected || isRecent ? Theme.accent : Theme.textTertiary
    }

    private var dotSize: CGFloat {
        isSelected ? 10 : (isRecent ? 9 : 7)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)
                    .padding(.top, 5)
                    .frame(width: dotColumnWidth, alignment: .top)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if note.isSensitive {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Theme.accent)
                                .help("Sensitive — local AI only")
                        }
                        Text(note.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected || isRecent ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .frame(minHeight: 44, alignment: .top)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
