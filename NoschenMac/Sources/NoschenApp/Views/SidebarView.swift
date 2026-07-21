#if os(macOS)
import SwiftUI
import NoschenKit

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @State private var noteToDelete: Note?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.selectedNoteID) {
                ForEach(state.filteredNotes) { note in
                    NoteRow(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button("Delete Note", role: .destructive) {
                                noteToDelete = note
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.sidebar)

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
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if note.isSensitive {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accent)
                        .help("Sensitive — local AI only")
                }
                Text(note.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
#endif
