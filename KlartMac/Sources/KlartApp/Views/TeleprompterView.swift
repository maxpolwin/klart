#if os(macOS)
import SwiftUI
import AppKit
import KlartKit

/// The Teleprompter surface: one centered column of text and nothing else on
/// screen. Monochrome — every hue collapses to ink. Everything the classic
/// layout keeps visible lives behind an edge or a key here:
///
/// - Notes wait behind the left edge. Moving the pointer there reveals a
///   spine of dots (one per note); dwelling on them for 0.8 s expands the
///   full panel — titles, last-edited dates, shield marks, search — which
///   retires again the moment writing resumes.
/// - The editor (the AI coach) works in the background. Its suggestions
///   appear in a right margin rail only when summoned — via the ¶ icon in
///   the panel, ⌘., or typing /editor — each aligned to the section of text
///   it refers to, wearing a glyph instead of a colored pill, with a small ×
///   to dismiss. Keep writing and the rail fades away on its own.
/// - The note's title stays pinned at the top; an optional word-count line
///   (Settings → Interface) sits at the bottom.
struct TeleprompterView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var bridge = EditorBridge()

    // Left edge: dots → (dwell) → panel. Hover state is tracked per zone
    // because enter/leave callbacks between adjacent zones arrive unordered —
    // a collapse only goes through when the pointer is in none of them.
    @State private var dotsVisible = false
    @State private var panelExpanded = false
    @State private var hoveringStrip = false
    @State private var hoveringDots = false
    @State private var hoveringPanel = false
    @State private var dwellTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    // Right rail: fades back out while the user keeps writing.
    @State private var railOpacity: Double = 1
    @State private var railFadeTask: Task<Void, Never>?
    @State private var typedSinceRailShown = false

    @State private var noteToDelete: Note?

    private enum Metrics {
        static let columnMaxWidth: CGFloat = 720
        static let railWidth: CGFloat = 264
        static let panelWidth: CGFloat = 268
        static let edgeStripWidth: CGFloat = 26
        static let titleBarHeight: CGFloat = 46
        /// Dwell on the dots before the panel expands.
        static let dwellSeconds: Double = 0.8
        /// Continued writing for this long fades the rail…
        static let railFadeDelay: Double = 5 * 60
        /// …over this long, so focus returns gradually.
        static let railFadeDuration: Double = 20
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.background.ignoresSafeArea()

            if state.selectedNoteID != nil {
                editorColumn
                if state.editorRailVisible {
                    rail
                }
            } else {
                emptyState
            }

            titleBar
            if state.settings.showWordCount, state.selectedNoteID != nil {
                wordCountBar
            }
            leftEdge

            // Off-screen affordances: ⌘F opens the notes panel with search
            // focused (there is no visible search field while writing).
            Button("") {
                revealPanel()
            }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onDisappear {
            dwellTask?.cancel()
            collapseTask?.cancel()
            railFadeTask?.cancel()
        }
        .confirmationDialog(
            "Delete “\(noteToDelete?.title ?? "")”?",
            isPresented: Binding(
                get: { noteToDelete != nil },
                set: { if !$0 { noteToDelete = nil } }
            )
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
        .onChange(of: state.editorRailVisible) { _, visible in
            if visible {
                wakeRail()
            } else {
                railFadeTask?.cancel()
            }
        }
        .onChange(of: state.feedbackItems) { old, new in
            // Fresh suggestions restore a rail that was mid-fade.
            if state.editorRailVisible, !new.isEmpty, new != old {
                wakeRail()
            }
        }
    }

    // MARK: - Writing column

    private var editorColumn: some View {
        MarkdownEditor(
            text: $state.editorText,
            clearClipboardAfterCopy: state.settings.vault != nil,
            contentInset: NSSize(width: 40, height: 64),
            bridge: bridge,
            onCommand: { command in
                if command == "editor" { state.activateEditor() }
            },
            onTextChange: {
                state.editorTextChanged()
                writingResumed()
            },
            onCursorChange: { state.cursorUTF16 = $0 }
        )
        .id(state.selectedNoteID) // fresh editor (and undo stack) per note
        .frame(maxWidth: Metrics.columnMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.trailing, state.editorRailVisible ? Metrics.railWidth : 0)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15),
                   value: state.editorRailVisible)
    }

    /// The note's topic, pinned. Text scrolls under a fog of background color
    /// so the title never competes with a hairline.
    private var titleBar: some View {
        HStack(spacing: 6) {
            if state.selectedNote?.isSensitive == true {
                Image(systemName: "shield.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Sensitive — local AI only")
            }
            Text(state.selectedNote?.title ?? "Klårt")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.titleBarHeight, alignment: .center)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Theme.background, location: 0),
                    .init(color: Theme.background.opacity(0.85), location: 0.6),
                    .init(color: Theme.background.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
        .accessibilityAddTraits(.isHeader)
    }

    private var wordCountBar: some View {
        VStack {
            Spacer()
            Text(NoteMetrics.summary(for: state.editorText))
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("Think in writing.")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("⌘N starts a note. Your notes wait behind the left edge.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            Button("New Note") { state.createNote() }
                .buttonStyle(.bordered)
                .tint(Theme.textPrimary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left edge (dots → panel)

    private var leftEdge: some View {
        ZStack(alignment: .topLeading) {
            // The invisible strip that wakes the dots. Only pointer movement
            // reveals anything; typing puts it all away again.
            Color.clear
                .frame(width: Metrics.edgeStripWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in
                    hoveringStrip = inside
                    if inside {
                        collapseTask?.cancel()
                        guard !dotsVisible else { return }
                        withAnimation(edgeAnimation) { dotsVisible = true }
                    } else {
                        scheduleCollapse()
                    }
                }

            if dotsVisible && !panelExpanded {
                dotSpine
            }
            if panelExpanded {
                notesPanel
            }
        }
    }

    private var edgeAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)
    }

    /// One dot per note, current note in full ink. Dwelling here for 0.8 s
    /// expands the panel; a click switches notes without ever opening it.
    private var dotSpine: some View {
        VStack(spacing: 10) {
            ForEach(spineNotes) { note in
                Button {
                    state.selectedNoteID = note.id
                } label: {
                    Circle()
                        .fill(note.id == state.selectedNoteID
                              ? Theme.textPrimary
                              : Theme.textTertiary.opacity(0.55))
                        .frame(width: note.id == state.selectedNoteID ? 7 : 5,
                               height: note.id == state.selectedNoteID ? 7 : 5)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(note.title)
                .accessibilityLabel(note.title)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surfaceRaised)
        )
        .padding(.leading, 8)
        .frame(maxHeight: .infinity, alignment: .center)
        .transition(.opacity.combined(with: .move(edge: .leading)))
        .onHover { inside in
            hoveringDots = inside
            if inside {
                collapseTask?.cancel()
                startDwell()
            } else {
                dwellTask?.cancel()
                scheduleCollapse()
            }
        }
    }

    private var spineNotes: [Note] {
        Array(sortedNotes.prefix(14))
    }

    private var sortedNotes: [Note] {
        state.filteredNotes.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The expanded panel: the editor's ¶ above the search field, then the
    /// notes — title, last-edited date, shield when sensitive.
    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top padding clears the floating traffic lights of the
            // chromeless window.
            editorSummons
                .padding(.horizontal, 12)
                .padding(.top, Metrics.titleBarHeight)

            searchField
                .padding(.horizontal, 12)
                .padding(.top, 10)

            Divider().overlay(Theme.border)
                .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sortedNotes) { note in
                        panelRow(note)
                    }
                    if sortedNotes.isEmpty {
                        Text(state.searchText.isEmpty ? "No notes yet" : "No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(8)
            }

            Divider().overlay(Theme.border)
            panelFooter
        }
        .frame(width: Metrics.panelWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.surfaceRaised)
        .background(Theme.background)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 18, x: 6, y: 0)
        .transition(.move(edge: .leading).combined(with: .opacity))
        .onHover { inside in
            hoveringPanel = inside
            if inside {
                collapseTask?.cancel()
            } else {
                scheduleCollapse()
            }
        }
        .onExitCommand { collapseEdge() }
    }

    /// The editor lives behind this one quiet mark. Hover names it; a count
    /// rides along when suggestions are already waiting.
    private var editorSummons: some View {
        Button {
            collapseEdge()
            if state.editorRailVisible {
                state.editorRailVisible = false
            } else {
                state.activateEditor()
            }
        } label: {
            HStack(spacing: 7) {
                Text("¶")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                Text(editorSummonsLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if !state.feedbackItems.isEmpty {
                    Text("\(state.feedbackItems.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.selectedNoteID == nil)
        .help(state.editorRailVisible
              ? "Hide the editor's notes (⌘.)"
              : "Show editor — margin notes on this text (⌘. or type /editor)")
        .accessibilityLabel(state.editorRailVisible ? "Hide editor" : "Show editor")
    }

    private var editorSummonsLabel: String {
        if state.feedbackPhase == .analyzing || state.coachRunning { return "Editor · reading…" }
        if state.editorRailVisible { return "Hide editor" }
        return "Show editor"
    }

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
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func panelRow(_ note: Note) -> some View {
        let selected = note.id == state.selectedNoteID
        return Button {
            state.selectedNoteID = note.id
            collapseEdge()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if note.isSensitive {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textSecondary)
                            .help("Sensitive — local AI only")
                    }
                    Text(note.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textPrimary.opacity(0.78))
                        .lineLimit(1)
                }
                Text(Self.relativeDate(note.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.surfaceRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Note", role: .destructive) { noteToDelete = note }
        }
        .accessibilityLabel(
            "\(note.isSensitive ? "Sensitive note. " : "")\(note.title). Edited \(Self.relativeDate(note.updatedAt))"
        )
    }

    private var panelFooter: some View {
        HStack {
            Button {
                state.createNote()
                collapseEdge()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Create a new note (⌘N)")

            Spacer()

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    // MARK: - Edge state machine

    private func startDwell() {
        dwellTask?.cancel()
        dwellTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Metrics.dwellSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // The dots leave the hierarchy when the panel replaces them, and
            // a removed view never reports hover-exit — clear it by hand.
            hoveringDots = false
            withAnimation(edgeAnimation) { panelExpanded = true }
            searchFocused = true
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            // Enter/leave events between adjacent zones arrive unordered;
            // only collapse when the pointer has really left all of them.
            guard !hoveringStrip, !hoveringDots, !hoveringPanel else { return }
            collapseEdge()
        }
    }

    private func collapseEdge() {
        dwellTask?.cancel()
        collapseTask?.cancel()
        searchFocused = false
        hoveringStrip = false
        hoveringDots = false
        hoveringPanel = false
        withAnimation(edgeAnimation) {
            panelExpanded = false
            dotsVisible = false
        }
    }

    private func revealPanel() {
        collapseTask?.cancel()
        withAnimation(edgeAnimation) {
            dotsVisible = true
            panelExpanded = true
        }
        searchFocused = true
    }

    /// Typing is the strongest signal of intent: put the notes panel away
    /// and let the rail's fade countdown know writing continued.
    private func writingResumed() {
        if dotsVisible || panelExpanded {
            collapseEdge()
        }
        if state.editorRailVisible {
            typedSinceRailShown = true
        }
    }

    // MARK: - Right rail (the editor's notes)

    private var rail: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            EditorRail(bridge: bridge, topInset: Metrics.titleBarHeight + 8)
                .frame(width: Metrics.railWidth)
                .opacity(railOpacity)
                // Reaching for the notes restores them and resets the fade.
                .onHover { inside in
                    if inside { wakeRail() }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    /// Full opacity, and (re)start the countdown: after five more minutes of
    /// continued writing the rail fades out over twenty seconds — focus mode
    /// returns without anyone closing anything.
    private func wakeRail() {
        railFadeTask?.cancel()
        withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.2)) { railOpacity = 1 }
        typedSinceRailShown = false
        railFadeTask = Task { @MainActor in
            // Wait until five minutes have passed *with* writing in between;
            // an untouched rail (user is reading it) stays.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Metrics.railFadeDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if typedSinceRailShown { break }
            }
            guard !Task.isCancelled else { return }
            let duration = reduceMotion ? 0.25 : Metrics.railFadeDuration
            withAnimation(.linear(duration: duration)) { railOpacity = 0 }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            state.editorRailVisible = false
            railOpacity = 1
        }
    }

    // MARK: - Helpers

    /// Compact relative time for the panel rows: "2m ago", "Yesterday", "4 Jul".
    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return "Just now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(max(1, hours))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let days = Int(seconds / 86400)
        if days < 7 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: date)
    }
}

// MARK: - The editor's margin rail

/// The right-hand rail of editor notes. Each note is anchored to the section
/// of text it refers to: the section heading's on-screen line sets the card's
/// resting position, and cards yield downward when anchors collide.
private struct EditorRail: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var bridge: EditorBridge
    let topInset: CGFloat

    @State private var cardHeights: [UUID: CGFloat] = [:]

    private static let cardGap: CGFloat = 12
    private static let fallbackHeight: CGFloat = 110

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if state.feedbackItems.isEmpty {
                    emptyCard
                        .padding(.top, topInset)
                } else {
                    let placed = placements(in: geo.size.height)
                    ForEach(placed, id: \.item.id) { placement in
                        RailCard(item: placement.item)
                            .background(heightReader(for: placement.item.id))
                            .offset(y: placement.y)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.trailing, 14)
        .onPreferenceChange(RailCardHeightKey.self) { cardHeights = $0 }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1),
                   value: state.feedbackItems)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor suggestions")
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("¶")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(Theme.textSecondary)
                Text(state.feedbackPhase == .analyzing ? "Reading…" : "Editor")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(emptyMessage)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(Theme.border, lineWidth: 1)
        )
    }

    private var emptyMessage: String {
        switch state.feedbackPhase {
        case .analyzing: return "Going through your text now."
        case .error(let message): return message
        case .skipped(let reason): return reason
        case .waiting, .idle: return "Nothing to note yet — keep writing, or ⌘R to ask again."
        }
    }

    // MARK: Anchored layout

    private struct Placement {
        let item: FeedbackItem
        let y: CGFloat
    }

    /// Desired y for every suggestion (its section heading's line, or the top
    /// for unanchored ones), then a single downward pass so cards never
    /// overlap. `bridge.layoutTick` is read so scrolling and edits recompute.
    private func placements(in height: CGFloat) -> [Placement] {
        _ = bridge.layoutTick
        let outline = DocumentOutline.parse(state.editorText)

        let desired: [(item: FeedbackItem, y: CGFloat)] = state.feedbackItems.map { item in
            (item, anchorY(for: item, outline: outline) ?? topInset)
        }
        .sorted { $0.y < $1.y }

        var placed: [Placement] = []
        var nextFree = topInset
        for entry in desired {
            let y = max(entry.y, nextFree)
            placed.append(Placement(item: entry.item, y: y))
            nextFree = y + (cardHeights[entry.item.id] ?? Self.fallbackHeight) + Self.cardGap
        }

        // Keep the stack on screen: if the last card overflows, shift the
        // whole tail up (never above the title bar).
        if let last = placed.last {
            let lastHeight = cardHeights[last.item.id] ?? Self.fallbackHeight
            let overflow = last.y + lastHeight + 16 - height
            if overflow > 0 {
                placed = placed.map {
                    Placement(item: $0.item, y: max(topInset, $0.y - overflow))
                }
            }
        }
        return placed
    }

    private func anchorY(for item: FeedbackItem, outline: DocumentOutline) -> CGFloat? {
        guard let sectionTitle = item.section?.trimmingCharacters(in: .whitespaces),
              !sectionTitle.isEmpty else { return nil }
        let target = sectionTitle.lowercased()
        guard let section = outline.sections.first(where: {
            $0.title.lowercased() == target
        }) ?? outline.sections.first(where: {
            $0.title.lowercased().contains(target) || target.contains($0.title.lowercased())
        }) else { return nil }
        guard let y = bridge.lineY(atUTF16: section.headingStart) else { return nil }
        return max(topInset, y)
    }

    private func heightReader(for id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: RailCardHeightKey.self, value: [id: geo.size.height])
        }
    }
}

private struct RailCardHeightKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// One editor note: a monochrome glyph in place of the colored pill, the
/// observation, a quiet Insert when there is content to take, and an × to
/// send it away.
private struct RailCard: View {
    @EnvironmentObject var state: AppState
    let item: FeedbackItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Theme.glyph(for: item.kind))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 15, alignment: .center)
                    .accessibilityHidden(true)
                Text(item.kind.label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textSecondary)
                if let section = item.section, !section.isEmpty {
                    Text(section)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    state.reject(item)
                } label: {
                    Text("×")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss — don't show this note again")
                .accessibilityLabel("Dismiss suggestion")
            }

            Text(item.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textPrimary.opacity(0.88))
                .lineSpacing(2.5)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if item.suggestion != nil {
                Button {
                    state.accept(item)
                } label: {
                    Text("Insert")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .underline(hovering)
                }
                .buttonStyle(.plain)
                .help("Insert the suggested content into that section")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Theme.border, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // The pencil line: a hairline of ink instead of a colored bar.
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.textPrimary.opacity(hovering ? 0.5 : 0.28))
                .frame(width: 2)
                .padding(.vertical, 9)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kind.label). \(item.section.map { "Section \($0). " } ?? "")\(item.text)")
    }
}
#endif
