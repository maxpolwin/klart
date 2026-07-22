#if os(macOS)
import SwiftUI
import AppKit
import Darwin
import KlartKit

@main
struct KlartApp: App {
    @StateObject private var state = AppState()

    init() {
        Self.hardenProcess()
        // Make sure windows come to the front when launched via `swift run`
        // (outside a .app bundle the activation policy isn't set for us).
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Process-level hardening: no core dumps (a crash must never write key
    /// material to disk), and in release builds deny debugger attachment —
    /// bypassable by root, but it stops casual memory dumping.
    private static func hardenProcess() {
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &noCore)

        #if !DEBUG
        // ptrace(PT_DENY_ATTACH) isn't exposed to Swift; resolve it at runtime.
        typealias PtraceFn = @convention(c) (CInt, pid_t, CInt, CInt) -> CInt
        if let sym = dlsym(dlopen(nil, RTLD_NOW), "ptrace") {
            let ptrace = unsafeBitCast(sym, to: PtraceFn.self)
            _ = ptrace(31 /* PT_DENY_ATTACH */, 0, 0, 0)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(state: state)
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { state.createNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(state.isLocked)
        }
        CommandGroup(after: .saveItem) {
            Button("Save Now") { state.saveNow() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(state.selectedNoteID == nil)
            Divider()
            Button("Find") { state.requestSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            // The Teleprompter surface has no toolbar, so the sensitive
            // toggle needs a menu home that works in both layouts.
            Button(
                state.selectedNote?.isSensitive == true
                    ? "Unmark Sensitive (Allow Cloud AI)"
                    : "Mark Sensitive (Local AI Only)"
            ) { state.toggleSensitive() }
                .disabled(state.selectedNoteID == nil)
            Divider()
            Button("Export Notes as Markdown…") { state.exportAllNotesAsMarkdown() }
                .disabled(state.isLocked || state.notes.isEmpty)
            Button("Import Markdown Notes…") { state.importMarkdownNotes() }
                .disabled(state.isLocked)
            Divider()
            Button("Lock Notes") { state.lockNow() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(state.settings.vault == nil || state.isLocked)
        }
        CommandMenu("Editor") {
            Button("Analyze Note") { state.requestFeedback(manual: true) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.selectedNoteID == nil)
            Button("Editor Suggestions") {
                // Teleprompter: the same key summons/hides the editor's
                // margin rail; classic: the popover behind the toolbar pill.
                if state.settings.teleprompterMode {
                    if state.editorRailVisible {
                        state.editorRailVisible = false
                    } else {
                        state.activateEditor()
                    }
                } else {
                    state.showCoachPopover.toggle()
                }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(state.selectedNoteID == nil)
            Divider()
            ForEach(CoachAction.allCases) { action in
                Button(action.label) { state.runCoach(action) }
                    .disabled(state.selectedNoteID == nil)
            }
        }
    }
}
#else
@main
struct KlartApp {
    static func main() {
        fatalError("Klårt is a macOS app; build it on macOS.")
    }
}
#endif
