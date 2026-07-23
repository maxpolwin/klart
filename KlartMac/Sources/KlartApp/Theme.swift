#if os(macOS)
import SwiftUI
import AppKit
import KlartKit

/// The one beat in the app. The caret blinks on it; the editor breathes on
/// it while it is reading. Two things pulsing at two rates read as two
/// clocks — at one rate they read as the same surface being alive.
enum KlartPulse {
    /// Seconds per half-cycle: caret on → caret off, full ink → dimmed.
    static let period: TimeInterval = 1.0
    /// How far the reading pulse dims. Deep enough to be unmistakably
    /// moving, shallow enough that the words stay readable throughout.
    static let dimmedOpacity: Double = 0.42
}

/// Klårt's "Quiet" palette: system-adaptive light/dark, one accent,
/// hairlines and air instead of chrome. Colors are dynamic NSColors so
/// both SwiftUI views and the AppKit editor re-resolve on appearance
/// changes.
enum Theme {
    static func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: NSColor variants (editor)

    static let nsBackground = dynamicNSColor(
        light: rgb(0.961, 0.961, 0.953),          // #F5F5F3
        dark: rgb(0.118, 0.118, 0.125)            // #1E1E20
    )
    static let nsTextPrimary = dynamicNSColor(
        light: rgb(0.114, 0.114, 0.122),          // #1D1D1F
        dark: rgb(0.961, 0.961, 0.969)            // #F5F5F7
    )
    static let nsTextSecondary = dynamicNSColor(
        light: rgb(0.525, 0.525, 0.545),          // #86868B
        dark: rgb(0.596, 0.596, 0.616)            // #98989D
    )
    static let nsTextTertiary = dynamicNSColor(
        light: NSColor.black.withAlphaComponent(0.32),
        dark: NSColor.white.withAlphaComponent(0.35)
    )
    static let nsAccent = dynamicNSColor(
        light: rgb(0.169, 0.373, 0.678),          // #2B5FAD
        dark: rgb(0.435, 0.627, 0.918)            // #6FA0EA
    )
    /// Accent at 85% for markdown syntax markers. Defined as its own dynamic
    /// color: withAlphaComponent on a dynamic NSColor freezes its variant.
    static let nsAccentMuted = dynamicNSColor(
        light: rgb(0.169, 0.373, 0.678, 0.85),
        dark: rgb(0.435, 0.627, 0.918, 0.85)
    )

    // MARK: Monochrome (Teleprompter)

    /// True while the Teleprompter surface is active: every hue collapses to
    /// ink. Kept in sync with settings by AppState, *before* any view builds,
    /// and read at styling time — switching modes rebuilds the editor, so
    /// text is always restyled under the right value.
    static var monochrome = false

    /// Markdown syntax markers (#, -, >, ``` …): accent normally, mid-gray
    /// in monochrome so nothing in the editor carries a hue. Each branch is
    /// still a dynamic color, so light/dark keeps adapting live.
    static var nsMarker: NSColor {
        monochrome ? nsTextSecondary : nsAccentMuted
    }

    /// Insertion point: accent normally, full ink in monochrome.
    static var nsInsertionPoint: NSColor {
        monochrome ? nsTextPrimary : nsAccent
    }

    // MARK: SwiftUI colors

    static let background = Color(nsColor: nsBackground)
    static let textPrimary = Color(nsColor: nsTextPrimary)
    static let textSecondary = Color(nsColor: nsTextSecondary)
    static let textTertiary = Color(nsColor: nsTextTertiary)
    static let accent = Color(nsColor: nsAccent)

    /// Subtle raised surface: black-on-light, white-on-dark.
    static let surfaceRaised = Color.primary.opacity(0.055)
    /// Hairline.
    static let border = Color.primary.opacity(0.08)

    /// Monochrome stand-in for the kind colors: a geometric glyph drawn from
    /// what the kind means. Glyph + label is the signal (never hue), so the
    /// set also reads correctly for color-blind users in the classic UI.
    static func glyph(for kind: FeedbackKind) -> String {
        switch kind {
        case .gap: return "◇"        // something missing — an unfilled shape
        case .mece: return "⧉"       // two frames colliding — overlap
        case .source: return "❝"     // a citation to add
        case .structure: return "≡"  // stacked, level rules — order
        case .clarity: return "◎"    // a mark resolving into focus
        case .question: return "?"   // an open, Socratic ask
        case .other: return "·"
        }
    }

    static func color(for kind: FeedbackKind) -> Color {
        switch kind {
        case .gap: return dynamic(rgb(0.145, 0.376, 0.722), rgb(0.451, 0.678, 1.0))
        case .mece: return dynamic(rgb(0.424, 0.247, 0.659), rgb(0.761, 0.549, 0.988))
        case .source: return dynamic(rgb(0.118, 0.478, 0.275), rgb(0.4, 0.831, 0.6))
        case .structure: return dynamic(rgb(0.604, 0.353, 0.09), rgb(0.961, 0.663, 0.361))
        case .clarity: return dynamic(rgb(0.059, 0.463, 0.475), rgb(0.361, 0.82, 0.831))
        case .question: return dynamic(rgb(0.686, 0.227, 0.333), rgb(0.969, 0.549, 0.659))
        case .other: return textSecondary
        }
    }
}

struct KindBadge: View {
    let kind: FeedbackKind

    var body: some View {
        Text(kind.label.uppercased())
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(Theme.color(for: kind))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.color(for: kind).opacity(0.12), in: Capsule())
    }
}

struct StatusDot: View {
    let status: ConnectionStatus

    private var color: Color {
        switch status {
        case .connected: return Theme.color(for: .source)
        case .failed: return Theme.color(for: .question)
        case .checking: return Theme.color(for: .structure)
        case .unknown: return Theme.textTertiary
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}
#endif
