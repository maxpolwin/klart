#if os(macOS)
import SwiftUI
import AppKit
import KlartKit

/// The Teleprompter surface: one centered column of text and nothing else on
/// screen. Monochrome — every hue collapses to ink. Everything the classic
/// layout keeps visible lives behind an edge or a key here:
///
/// - Notes wait behind the left edge. Moving the pointer there reveals a
///   spine of dots (one per note); a click on the spine (not on a dot itself,
///   which switches notes) expands the full panel immediately, and dwelling
///   there for 2 s expands it without needing to click at all — titles,
///   last-edited dates, shield marks, search — which retires again the
///   moment writing resumes.
/// - The editor (the AI coach) works in the background. Its suggestions
///   appear in a right margin rail only when summoned — via the ¶ icon in
///   the panel, ⌘E, or typing /editor — each aligned to the section of text
///   it refers to, wearing a glyph instead of a colored pill. Dismiss retires
///   a note for good; otherwise just keep writing and the whole rail fades
///   away on its own.
/// - The note's title stays pinned at the top; an optional word-count line
///   (Settings → Interface) sits at the bottom.
///
/// One spring drives every motion in this file — the left edge's dots→panel
/// expand, the right rail's slide-in/reflow, and each suggestion card
/// settling into its anchored position — so nothing here can drift out of
/// sync with anything else the way `calmAnimation` and `EditorRail`'s own
/// literal spring once quietly had.
private enum TeleprompterMotion {
    /// Deliberately slow: the chrome arriving and leaving is meant to read as
    /// calm, never as a snap. Long enough that the spring's settle is legible
    /// rather than a flicker you only half-see.
    static let duration: Double = 2.0
    static let bounce: Double = 0.18
}

struct TeleprompterView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var bridge = EditorBridge()

    // Left edge: hover/dwell (or a click) → panel. Hover state is tracked per
    // zone because enter/leave callbacks between adjacent zones arrive
    // unordered — a collapse only goes through when the pointer is in none.
    @State private var panelExpanded = false
    @State private var hoveringStrip = false
    @State private var hoveringPanel = false
    /// The right edge's own approach state, for the rail's handle.
    @State private var hoveringRightStrip = false
    @State private var dwellTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    // Right rail: fades back out while the user keeps writing.
    @State private var railOpacity: Double = 1
    @State private var railFadeTask: Task<Void, Never>?
    @State private var typedSinceRailShown = false

    // Left panel: the same treatment, so neither edge outstays the other.
    @State private var panelOpacity: Double = 1
    @State private var panelFadeTask: Task<Void, Never>?
    @State private var typedSincePanelShown = false

    @State private var noteToDelete: Note?
    /// Reveals the "Show/Hide editor" label next to the ¶ icon — the label
    /// only exists on hover, so the quiet chrome stays quiet at rest.
    @State private var hoveringEditorSummons = false
    /// The search field's own hover, for the same treatment on its label.
    @State private var hoveringSearch = false

    private enum Metrics {
        static let columnMaxWidth: CGFloat = 720
        /// The rail hugs its widest current note's text between these two —
        /// never so narrow it can't hold a card's chrome, never wider than
        /// the old fixed rail used to be.
        static let railMinWidth: CGFloat = 200
        static let railMaxWidth: CGFloat = 264
        static let panelWidth: CGFloat = 268
        static let edgeStripWidth: CGFloat = 26
        /// How far the waiting cards lean into the window when the pointer
        /// nears the edge — enough to read as "these are here", not enough to
        /// be mistaken for the panel actually opening.
        static let peekAmount: CGFloat = 26
        static let titleBarHeight: CGFloat = 46
        /// Both fogs — under the pinned title and above the word count — run
        /// opaque across their own band, then fade over roughly five body
        /// lines (15 pt text on ~22 pt leading), so text dissolves gradually
        /// on its way past rather than sliding out from behind a hard edge,
        /// and never shares pixels with the text pinned there.
        static let fogFadeHeight: CGFloat = 110
        static let wordCountBarHeight: CGFloat = 34
        /// Dwell on the dots before the panel expands on its own — a click
        /// expands it immediately, without waiting.
        static let dwellSeconds: Double = 2.0
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
                // Offset-driven for the same reason as the notes panel: a
                // conditional `if` + `.transition` did not animate here at
                // all, so the rail popped into place while the writing
                // column's mirrored padding (a plain numeric spring) glided —
                // which is exactly the asymmetry the shared constant was
                // supposed to remove.
                rail
                    .offset(x: railOffset)
                    .allowsHitTesting(state.editorRailVisible)
                    .animation(handleSpring, value: hoveringRightStrip)
                    .animation(calmAnimation, value: state.editorRailVisible)
                    .animation(calmAnimation, value: railWidth)
            } else {
                emptyState
            }

            titleBandBackdrop
            titleBar
            if state.settings.showWordCount, state.selectedNoteID != nil {
                wordCountBar
            }
            leftEdge
            rightEdge
        }
        .animation(calmAnimation, value: state.editorRailVisible)
        .onDisappear {
            dwellTask?.cancel()
            collapseTask?.cancel()
            railFadeTask?.cancel()
            panelFadeTask?.cancel()
        }
        .onChange(of: state.searchRequested) { _, _ in
            // There is no visible search field while writing — ⌘F (the
            // Find menu command) opens the notes panel with it focused.
            revealPanel()
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
        .padding(.trailing, state.editorRailVisible ? railWidth : 0)
        .animation(calmAnimation, value: state.editorRailVisible)
        .animation(calmAnimation, value: railWidth)
    }

    /// The shared spring behind every slide in the Teleprompter chrome — the
    /// dots→panel expand and the editor's margin rail — so both always move
    /// at exactly the same curve. See `TeleprompterMotion`.
    private var calmAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: TeleprompterMotion.duration, bounce: TeleprompterMotion.bounce)
    }

    /// How wide the rail needs to be to hold its widest current note without
    /// wrapping unnecessarily — clamped to `Metrics.railMinWidth...railMaxWidth`
    /// so a short note doesn't reserve as much margin as a long one, but a
    /// long one still wraps exactly as it did with the old fixed width.
    private var railWidth: CGFloat {
        let widestText = state.feedbackItems.isEmpty
            ? EditorRailMetrics.naturalWidth(for: EditorRailMetrics.emptyStateText(for: state.feedbackPhase))
            : (state.feedbackItems.map { EditorRailMetrics.naturalWidth(for: $0.text) }.max() ?? 0)
        return min(max(widestText + EditorRailMetrics.cardHorizontalChrome, Metrics.railMinWidth), Metrics.railMaxWidth)
    }

    /// The note's topic, pinned. Text scrolls under a fog of background color
    /// so the title never competes with a hairline. The title itself stays
    /// click-through (so clicks land in the editor beneath); the sensitivity
    /// shield beside it is the one real control in this band.
    private var titleBar: some View {
        HStack(spacing: 6) {
            Text(state.selectedNote?.title ?? "Klårt")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .allowsHitTesting(false)
            if state.selectedNoteID != nil {
                sensitiveToggle
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.titleBarHeight, alignment: .center)
        .background(alignment: .top) {
            fog(bandHeight: Metrics.titleBarHeight, from: .top)
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// Everything above the pinned title: the chromeless window's title-bar
    /// strip, which sits *outside* the safe area the title and the fog are
    /// laid out in. Solid ink, edge to edge, so the strip is never a window
    /// onto the desktop and prose can never surface crisply in it on its way
    /// up. Flexible container + `ignoresSafeArea` on purpose — a fixed-height
    /// view would simply be placed inside the inset instead of covering it.
    private var titleBandBackdrop: some View {
        VStack(spacing: 0) {
            Theme.background
                .frame(height: Metrics.titleBarHeight)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    /// A band of background that is fully opaque across `bandHeight` — so the
    /// pinned text there can never be shared with scrolling prose — and then
    /// fades out over five lines. Used at both ends of the column.
    private func fog(bandHeight: CGFloat, from edge: VerticalEdge) -> some View {
        let solidStop = bandHeight / (bandHeight + Metrics.fogFadeHeight)
        return LinearGradient(
            stops: [
                .init(color: Theme.background, location: 0),
                .init(color: Theme.background, location: solidStop),
                .init(color: Theme.background.opacity(0), location: 1),
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: bandHeight + Metrics.fogFadeHeight)
        .allowsHitTesting(false)
    }

    /// Sits to the right of the title so sensitivity reads as an attribute of
    /// *this* note, not a global app setting. Always visible (outline when
    /// off, filled when on) so it's discoverable, not just an indicator that
    /// only appears once already set.
    private var sensitiveToggle: some View {
        Button {
            state.toggleSensitive()
        } label: {
            Image(systemName: state.selectedNote?.isSensitive == true ? "shield.fill" : "shield")
                .font(.system(size: 9.5))
                .foregroundStyle(state.selectedNote?.isSensitive == true ? Theme.textSecondary : Theme.textTertiary)
        }
        .buttonStyle(.plain)
        .help(state.selectedNote?.isSensitive == true
              ? "Sensitive: only local AI ever sees this note. Click to unmark."
              : "Mark sensitive: keeps this note on local AI only, never the cloud.")
        .accessibilityLabel(state.selectedNote?.isSensitive == true ? "Sensitive note. Click to unmark." : "Mark note sensitive.")
    }

    private var wordCountBar: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(NoteMetrics.summary(for: state.editorText))
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.wordCountBarHeight, alignment: .bottom)
                // The mirror of the title's fog: prose dissolves on its way
                // down instead of running under the word count.
                .background(alignment: .bottom) {
                    fog(bandHeight: Metrics.wordCountBarHeight, from: .bottom)
                }
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
                        startDwell()
                    } else {
                        dwellTask?.cancel()
                        scheduleCollapse()
                    }
                }
                // A click skips the dwell entirely — a confident click right
                // at the window edge opens the notes at once.
                .onTapGesture { revealPanel() }

            // Always mounted (never inserted/removed) and driven by offset
            // instead of `.transition`: a conditional `if` + `.transition`
            // here did not animate at all inside the chromeless window, so
            // the panel appeared fully-formed with no slide. An always-present
            // view with an animated offset has no insertion to race against,
            // so the spring always runs.
            notesPanel
                .offset(x: panelOffset)
                .opacity(panelOpacity)
                .allowsHitTesting(panelExpanded)
                // Two springs, keyed separately: the peek bounces (it's an
                // invitation), the open glides (it's the real motion).
                .animation(handleSpring, value: hoveringStrip)
                .animation(edgeAnimation, value: panelExpanded)
        }
    }

    /// The panel's slide — same calm speed as the editor's margin rail.
    private var edgeAnimation: Animation? { calmAnimation }

    // MARK: - Edge handles

    /// Labels that only exist on hover — the editor's "Show editor" and the
    /// search field's "Search notes" — appear in place, never sliding, at one
    /// shared pace so the panel's two pieces of text behave identically.
    private var labelFade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.7)
    }

    /// Livelier than the panels themselves, on purpose: this is an
    /// invitation, and a hint that doesn't visibly spring doesn't read as
    /// one. The panels stay calm; only the 4 pt lip is allowed to bounce.
    private var handleSpring: Animation? {
        reduceMotion ? nil : .spring(duration: 1.0, bounce: 0.5)
    }

    /// Where the notes panel sits: open, leaning in because the pointer is
    /// near, or parked off-screen. The lean is the affordance — the actual
    /// note cards nudge into view rather than a stand-in handle.
    private var panelOffset: CGFloat {
        if panelExpanded { return 0 }
        if hoveringStrip { return -(Metrics.panelWidth - Metrics.peekAmount) }
        return -(Metrics.panelWidth + 40)
    }

    /// The rail's mirror of `panelOffset` — the waiting suggestion cards lean
    /// in from the right on approach.
    private var railOffset: CGFloat {
        if state.editorRailVisible { return 0 }
        if hoveringRightStrip { return railWidth - Metrics.peekAmount }
        return railWidth + 40
    }

    /// The right edge's mirror of `leftEdge`: the same approach zone, summoning the
    /// editor's rail instead of the notes. Inert while the rail is open so it
    /// can never swallow a click meant for a suggestion card.
    private var rightEdge: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Color.clear
                .frame(width: Metrics.edgeStripWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hoveringRightStrip = $0 }
                .onTapGesture { state.activateEditor() }
                .allowsHitTesting(!state.editorRailVisible)
        }
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
        .background(Theme.background)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 18, x: 6, y: 0)
        // Same reasoning as the dot spine: no opacity fade, so the spring
        // actually carries the panel's 268 pt slide instead of hiding most
        // of it behind translucency. (Offset-driven, see the call site.)
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

    /// The editor lives behind this one quiet mark — just the glyph at rest.
    /// Hovering names its purpose (and a count, when suggestions are already
    /// waiting) so the chrome stays quiet until someone actually asks.
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
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                if hoveringEditorSummons {
                    Text(editorSummonsLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        // Appears, never travels: a label sliding out from
                        // under the glyph reads as a second moving object in
                        // a surface whose whole point is stillness.
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.selectedNoteID == nil)
        .onHover { inside in
            withAnimation(labelFade) {
                hoveringEditorSummons = inside
            }
        }
        .help(state.editorRailVisible
              ? "Hide the editor's notes (⌘E)"
              : "Show editor — margin notes on this text (⌘E or type /editor)")
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
            TextField("", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                .overlay(alignment: .leading) {
                    // The same treatment as the editor's label: the word only
                    // exists on hover and fades in place, so the panel carries
                    // no standing text at rest.
                    if hoveringSearch, state.searchText.isEmpty {
                        Text("Search notes")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .onHover { inside in
            withAnimation(labelFade) { hoveringSearch = inside }
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
                Text(Self.modifiedStamp(note.updatedAt))
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
            "\(note.isSensitive ? "Sensitive note. " : "")\(note.title). Edited \(Self.modifiedStamp(note.updatedAt))"
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
            revealPanel()
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            // Enter/leave events between adjacent zones arrive unordered;
            // only collapse when the pointer has really left all of them.
            guard !hoveringStrip, !hoveringPanel else { return }
            collapseEdge()
        }
    }

    private func collapseEdge() {
        dwellTask?.cancel()
        collapseTask?.cancel()
        panelFadeTask?.cancel()
        searchFocused = false
        hoveringStrip = false
        hoveringPanel = false
        withAnimation(edgeAnimation) {
            panelExpanded = false
        }
        // The countdown is over, but the panel must come back at full ink
        // next time it is summoned — mid-fade opacity would otherwise stick.
        panelOpacity = 1
    }

    /// Expands straight to the full panel — from the dwell timer completing,
    /// a click at the edge, or ⌘F. All three converge here so they can never
    /// leave the state machine's flags out of sync with each other.
    private func revealPanel() {
        dwellTask?.cancel()
        collapseTask?.cancel()
        withAnimation(edgeAnimation) {
            panelExpanded = true
        }
        wakePanel()
        searchFocused = true
    }

    /// Typing is the strongest signal of intent: put the notes panel away
    /// and let the rail's fade countdown know writing continued.
    private func writingResumed() {
        if panelExpanded {
            typedSincePanelShown = true
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
                .frame(width: railWidth)
                // The writing column's mirrored trailing padding (railWidth,
                // above) already springs on width changes; without this the
                // rail's own edge would snap to the new width instead of
                // moving with it whenever the widest note changes mid-session.
                .animation(calmAnimation, value: railWidth)
                .overlay(alignment: .topLeading) { hideRailButton }
                // Applied over the close button too, so the whole rail
                // retreats as one thing — the button used to stay at full ink
                // while the cards it belongs to dissolved out from under it.
                .opacity(railOpacity)
                // Reaching for the notes restores them and resets the fade.
                .onHover { inside in
                    if inside { wakeRail() }
                }
        }
    }

    /// Sits at the rail's near (left) edge, right where the writing column
    /// ends — the one spot on the rail itself that closes it, rather than
    /// only ⌘E or the far-away notes panel.
    private var hideRailButton: some View {
        Button {
            state.editorRailVisible = false
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 22, height: 22)
                .background(Theme.surfaceRaised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, (Metrics.titleBarHeight - 22) / 2)
        .padding(.leading, 6)
        .help("Hide the editor's notes (⌘E)")
        .accessibilityLabel("Hide editor notes")
    }

    /// The notes panel's mirror of `wakeRail()` — same opacity, same delay,
    /// same twenty-second fade, so both edges retire on one schedule instead
    /// of the left simply vanishing while the right dissolves.
    private func wakePanel() {
        panelFadeTask?.cancel()
        withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.2)) { panelOpacity = 1 }
        typedSincePanelShown = false
        panelFadeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Metrics.railFadeDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if typedSincePanelShown { break }
            }
            guard !Task.isCancelled else { return }
            let duration = reduceMotion ? 0.25 : Metrics.railFadeDuration
            withAnimation(.linear(duration: duration)) { panelOpacity = 0 }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            panelExpanded = false
            panelOpacity = 1
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
    /// The exact moment a note was last modified — "23.07.2026 08:41".
    /// Deliberately absolute rather than relative ("3m ago"): a fixed
    /// timestamp is the same fact every time it is read, where a relative one
    /// silently goes stale the moment the panel stops being redrawn.
    ///
    /// The format is fixed, not localized: it is the format asked for, and a
    /// locale-driven one would reorder day and month per machine.
    private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    static func modifiedStamp(_ date: Date) -> String {
        modifiedFormatter.string(from: date)
    }
}

// MARK: - Rail width measurement

/// How wide a rail card's own chrome (padding, glyph column, action row)
/// needs beyond its text — not pixel-exact, just enough to keep the rail from
/// hugging so tight the chrome clips. `TeleprompterView.railWidth` caps the
/// result against `Metrics.railMaxWidth`, so long prose still wraps exactly
/// as it did with the old fixed-width rail.
private enum EditorRailMetrics {
    static let bodyFont = NSFont.systemFont(ofSize: 11.5)
    static let cardHorizontalChrome: CGFloat = 80

    static func emptyStateText(for phase: FeedbackPhase) -> String {
        switch phase {
        case .analyzing: return "Going through your text now."
        case .error(let message): return message
        case .skipped(let reason): return reason
        case .waiting, .idle: return "Nothing to note yet — keep writing, or ⌘R to ask again."
        }
    }

    /// The single-line width `text` would need if it never wrapped.
    static func naturalWidth(for text: String) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: bodyFont])
        let unbounded = CGFloat.greatestFiniteMagnitude
        let bounds = attributed.boundingRect(
            with: NSSize(width: unbounded, height: unbounded),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.width)
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
                            // A handled note leaves toward the margin it came
                            // from, so the eye follows it out instead of
                            // noticing a gap appear mid-rail.
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.trailing, 14)
        .onPreferenceChange(RailCardHeightKey.self) { cardHeights = $0 }
        .animation(
            reduceMotion ? nil : .spring(duration: TeleprompterMotion.duration, bounce: TeleprompterMotion.bounce),
            value: state.feedbackItems
        )
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
            // Full ink, like a real note's text: the rail is quiet because it
            // is small and off to one side, never because it is hard to read.
            // Retreating is what dims it — see `railOpacity`.
            Text(emptyMessage)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textPrimary)
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
        EditorRailMetrics.emptyStateText(for: state.feedbackPhase)
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
/// observation, then quiet actions — Insert when there is content to take,
/// and Dismiss to never see the point again. Nothing else: a card that is
/// only read costs no decision, and the whole rail retires on its own.
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
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }

            // The observation itself is prose to be read, so it carries the
            // same ink as the writing column. Nothing in the rail is dimmed
            // to signal "secondary" any more; only retreating dims it.
            Text(item.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2.5)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 10) {
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
                Button {
                    state.reject(item)
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .underline(hovering)
                }
                .buttonStyle(.plain)
                .help("Don't show this note again for this note file")
                .accessibilityLabel("Dismiss permanently")
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
