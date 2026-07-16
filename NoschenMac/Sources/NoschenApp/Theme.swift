#if os(macOS)
import SwiftUI
import NoschenKit

/// Noschen's dark, minimal palette. One accent, muted surfaces,
/// generous contrast for long reading sessions.
enum Theme {
    static let background = Color(red: 0.055, green: 0.066, blue: 0.086)   // #0E1116
    static let surface = Color(red: 0.085, green: 0.098, blue: 0.125)      // #161A20
    static let surfaceRaised = Color(red: 0.115, green: 0.13, blue: 0.165)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(red: 0.62, green: 0.68, blue: 1.0)           // soft periwinkle
    static let textPrimary = Color(red: 0.92, green: 0.93, blue: 0.95)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.32)

    static func color(for kind: FeedbackKind) -> Color {
        switch kind {
        case .gap: return Color(red: 0.45, green: 0.68, blue: 1.0)
        case .mece: return Color(red: 0.76, green: 0.55, blue: 0.99)
        case .source: return Color(red: 0.4, green: 0.83, blue: 0.6)
        case .structure: return Color(red: 0.98, green: 0.68, blue: 0.35)
        case .clarity: return Color(red: 0.35, green: 0.82, blue: 0.83)
        case .question: return Color(red: 0.97, green: 0.55, blue: 0.66)
        case .other: return Color.white.opacity(0.6)
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
            .background(Theme.color(for: kind).opacity(0.14), in: Capsule())
    }
}

struct StatusDot: View {
    let status: ConnectionStatus

    private var color: Color {
        switch status {
        case .connected: return Color(red: 0.4, green: 0.83, blue: 0.6)
        case .failed: return Color(red: 0.95, green: 0.45, blue: 0.45)
        case .checking: return .yellow
        case .unknown: return Theme.textTertiary
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}
#endif
