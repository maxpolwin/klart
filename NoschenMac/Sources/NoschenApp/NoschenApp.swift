#if os(macOS)
import SwiftUI
import NoschenKit

@main
struct NoschenApp: App {
    @StateObject private var state = AppState()

    init() {
        // Make sure windows come to the front when launched via `swift run`
        // (outside a .app bundle the activation policy isn't set for us).
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(state: state)
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { state.createNote() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .saveItem) {
            Button("Save Now") { state.saveNow() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(state.selectedNoteID == nil)
        }
        CommandMenu("Coach") {
            Button("Analyze Note") { state.requestFeedback(manual: true) }
                .keyboardShortcut("r", modifiers: .command)
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
struct NoschenApp {
    static func main() {
        fatalError("Noschen is a macOS app; build it on macOS.")
    }
}
#endif
