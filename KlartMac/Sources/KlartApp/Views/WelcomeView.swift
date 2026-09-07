#if os(macOS)
import SwiftUI
import KlartKit

// MARK: - The pages

/// One screen of the first-launch tour. Copy and art are data so the set is
/// easy to reorder or cut down; `WelcomeArt` draws each `art` case.
struct WelcomePage: Identifiable, Equatable {
    enum Art: Equatable {
        case column, leftEdge, editorReads, anatomy, respond, privacy, sample
    }

    let id: Int
    let art: Art
    let title: String
    let body: String

    static let all: [WelcomePage] = [
        WelcomePage(
            id: 0, art: .column,
            title: "Think in writing.",
            body: "Klårt is one column of text and an editor who reads it. There is no toolbar and no sidebar; the page is the interface.\n\n⌘N starts a note. A line beginning with # is its title, ## starts a section. Markdown styles itself as you type and stays plain text on disk."
        ),
        WelcomePage(
            id: 1, art: .leftEdge,
            title: "Your notes wait behind the left edge.",
            body: "Move the pointer to the left edge and a spine of dots appears, one per note. Rest there a moment, or click, for the full panel with titles, dates and search. ⌘F opens it with search focused.\n\nStart typing and it all goes away again."
        ),
        WelcomePage(
            id: 2, art: .editorReads,
            title: "The editor reads when you finish a section.",
            body: "Leave a section, start the next heading, or pause for twenty seconds, and the editor reads what you wrote with the whole document in mind. Its notes appear in the right margin beside the text they are about.\n\nType //editor to make it read now. ⌘E or //show shows and hides the notes. Two slashes, so a path or a fraction never summons it by accident."
        ),
        WelcomePage(
            id: 3, art: .anatomy,
            title: "Opinionated on purpose. It never writes for you.",
            body: "Every note quotes the words it is about, says what is wrong, and why that costs the argument. A ! marks a note that matters; ‼ one that undermines the piece.\n\nNine lenses: Gap ◇, MECE ⧉, Structure ≡, Clarity ◎, Evidence ❝, Assumption ⊢, Warrant ⇒, Counter ⇄, Question ?. Some checks run on this Mac with no model at all: uncited claims, hedging, undefined terms, thin sections."
        ),
        WelcomePage(
            id: 4, art: .respond,
            title: "Answer it, or judge it.",
            body: "Respond drops the note into your text as a ✎ prompt and puts the caret beneath it. The answer is yours to write.\n\n✓ says the editor was right. ✗ says it was wrong, and that note never returns for this note. Verdicts go to a local learning log so recurring blind spots become visible. Your writing stays out of it unless you opt in."
        ),
        WelcomePage(
            id: 5, art: .privacy,
            title: "Private by default.",
            body: "Notes are markdown files on this Mac. The editor talks to Ollama or LM Studio locally, or to OpenRouter and other cloud endpoints; choose in Settings → AI Provider (⌘,).\n\nMark a note Sensitive and it never leaves the machine, whatever the provider. Encryption at rest, app lock and Touch ID live in Settings → Security."
        ),
        WelcomePage(
            id: 6, art: .sample,
            title: "Try it on a note with problems.",
            body: "Nordbrot is deciding whether to open a second bakery: five hundred words with an uncited rule of thumb, overlapping customer groups, a hedged risk section and a decision that leans on one number.\n\nOpen it and the editor reads it straight away. Its local checks work before any model is set up; add a provider and it reads the argument too."
        ),
    ]
}

// MARK: - The tour

/// The first-launch tour: seven screens over the writing surface, each one
/// feature drawn in the app's own idiom beside three sentences about it.
/// Skippable at any point, replayable from Help, and it ends either on a
/// blank note or on a sample note the editor is already reading.
struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Int
    @FocusState private var focused: Bool

    /// - Parameter page: where to open; previews and snapshots start deeper in.
    init(startingAt page: Int = 0) {
        _page = State(initialValue: page)
    }

    private var pages: [WelcomePage] { WelcomePage.all }
    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        ZStack {
            // Dims the surface beneath and swallows clicks on it: the tour is
            // modal for as long as it is up, and Skip is always one click.
            Theme.background.opacity(0.93)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            card
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.rightArrow) { advance(); return .handled }
        .onKeyPress(.return) { advance(); return .handled }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onKeyPress(.escape) { state.finishWelcome(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome tour, page \(page + 1) of \(pages.count)")
    }

    private var card: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 0) {
                    WelcomeArt(art: pages[page].art)
                        .frame(width: 330)
                        .frame(maxHeight: .infinity)
                        .background(Theme.surfaceRaised)
                    textPane
                }
                .id(page)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
            .frame(height: 380)
            .clipped()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: page)

            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 790)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 34, y: 14)
    }

    private var textPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pages[page].title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(pages[page].body)
                .font(.system(size: 13))
                .lineSpacing(3.5)
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip") { state.finishWelcome() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("Skip the tour")

            Spacer()

            HStack(spacing: 6) {
                ForEach(pages) { candidate in
                    Circle()
                        .fill(candidate.id == page ? Theme.textPrimary : Theme.textTertiary.opacity(0.5))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)

            Spacer()

            if page > 0 {
                Button("Back") { back() }
                    .buttonStyle(.bordered)
                    .tint(Theme.textPrimary)
            }
            if isLast {
                Button("Start with a blank note") {
                    state.finishWelcome()
                    if state.selectedNoteID == nil { state.createNote() }
                }
                .buttonStyle(.bordered)
                .tint(Theme.textPrimary)
                Button("Open the sample note") { state.openSampleNote() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.textPrimary)
            } else {
                Button("Next") { advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.textPrimary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func advance() {
        if isLast { state.openSampleNote() } else { page += 1 }
    }

    private func back() {
        if page > 0 { page -= 1 }
    }
}

// MARK: - The art

/// Each page's picture, drawn from the same shapes the app is made of: a
/// column of lines for the page, a rail card for a note. Monochrome, like
/// everything else, so the tour cannot promise a colour the app never shows.
private struct WelcomeArt: View {
    let art: WelcomePage.Art

    var body: some View {
        Group {
            switch art {
            case .column: column
            case .leftEdge: leftEdge
            case .editorReads: editorReads
            case .anatomy: anatomy
            case .respond: respond
            case .privacy: privacy
            case .sample: sample
            }
        }
        .padding(28)
        .accessibilityHidden(true)
    }

    // MARK: Pages

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockPage(headingWidth: 128, lines: [180, 172, 150, 176, 96], caret: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftEdge: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 7) {
                ForEach(0..<6, id: \.self) { index in
                    Circle()
                        .fill(Theme.textPrimary.opacity(index == 1 ? 1 : 0.45))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.top, 6)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 5) {
                        Line(width: index == 1 ? 118 : 92, height: 6, tone: index == 1 ? 1 : 0.7)
                        Line(width: 44, height: 4, tone: 0.35)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Line(width: 64, height: 4, tone: 0.35)
                }
                .padding(.top, 4)
            }
            .padding(12)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            MockPage(headingWidth: 70, lines: [96, 88, 92, 60], caret: false)
                .opacity(0.45)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var editorReads: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Line(width: 88, height: 8, tone: 1)
                    Line(width: 140, height: 5, tone: 0.55)
                    Line(width: 128, height: 5, tone: 0.55)
                    Line(width: 96, height: 5, tone: 0.55)
                    Spacer().frame(height: 6)
                    Line(width: 64, height: 8, tone: 1)
                    Line(width: 134, height: 5, tone: 0.55)
                    Line(width: 120, height: 5, tone: 0.55)
                    Line(width: 138, height: 5, tone: 0.55)
                }
                .frame(width: 140, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 52)
                    MockCard(
                        kind: .evidence, severity: "!",
                        anchor: "12% of revenue",
                        text: "A rule of thumb stated as fact.",
                        why: nil, actions: false
                    )
                }
            }
            HStack(spacing: 8) {
                Text("//editor")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                Text("reads now")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                Text("⌘E")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                Text("shows the notes")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var anatomy: some View {
        VStack(alignment: .leading, spacing: 18) {
            MockCard(
                kind: .evidence, severity: "!",
                anchor: "Rent above about 12% of revenue is where independents get into trouble",
                text: "A rule of thumb stated as fact, with nothing behind it.",
                why: "The whole rent argument rests on it.",
                actions: false
            )
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(FeedbackKind.allCases.filter { $0 != .other }.chunked(3).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 4) {
                        ForEach(row) { kind in
                            HStack(spacing: 5) {
                                Text(Theme.glyph(for: kind))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(width: 14)
                                Text(kind.label)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(width: 88, alignment: .leading)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var respond: some View {
        VStack(alignment: .leading, spacing: 16) {
            MockCard(
                kind: .warrant, severity: "!",
                anchor: "So the rent is defensible",
                text: "Footfall is the only number offered for it.",
                why: nil, actions: true
            )
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(Theme.textTertiary).frame(width: 2)
                    Text("✎ Footfall is the only number offered for it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 30)
                HStack(spacing: 0) {
                    Text("Because Kastanienallee's morning count is ")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)
                    Rectangle().fill(Theme.textPrimary).frame(width: 1.5, height: 13)
                }
            }
            .padding(.leading, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 8) {
                providerRow("Ollama", place: "this Mac")
                providerRow("LM Studio", place: "this Mac")
                providerRow("OpenRouter", place: "cloud")
                providerRow("Any OpenAI-compatible server", place: "you decide")
            }
            HStack(spacing: 6) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Sensitive · local models only")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.background, in: Capsule())
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func providerRow(_ name: String, place: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text(place)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var sample: some View {
        let outline = DocumentOutline.parse(SampleNote.english)
        return VStack(alignment: .leading, spacing: 12) {
            Text(SampleNote.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(outline.sections.filter { $0.level == 2 }.enumerated()), id: \.offset) { _, section in
                    HStack(spacing: 8) {
                        Text("##")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                        Text(section.title)
                            .font(.system(size: 11.5, weight: section.title == SampleNote.readSection ? .semibold : .regular))
                            .foregroundStyle(section.excludedFromAI ? Theme.textTertiary : Theme.textPrimary)
                        if section.excludedFromAI {
                            Text("[no-ai]")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if section.title == SampleNote.readSection {
                            Text("read first")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Pieces

    /// A run of text, as a page sees it from across the room.
    private struct Line: View {
        let width: CGFloat
        let height: CGFloat
        let tone: Double
        var body: some View {
            Capsule()
                .fill(Theme.textPrimary.opacity(tone * 0.5))
                .frame(width: width, height: height)
        }
    }

    private struct MockPage: View {
        let headingWidth: CGFloat
        let lines: [CGFloat]
        let caret: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                Line(width: headingWidth, height: 10, tone: 1)
                Spacer().frame(height: 2)
                ForEach(Array(lines.enumerated()), id: \.offset) { index, width in
                    HStack(spacing: 3) {
                        Line(width: width, height: 5, tone: 0.55)
                        if caret, index == lines.count - 1 {
                            Rectangle().fill(Theme.textPrimary).frame(width: 1.5, height: 12)
                        }
                    }
                }
            }
        }
    }

    /// A rail card, drawn to the rail's own recipe so the tour shows the
    /// thing itself rather than an artist's impression of it.
    private struct MockCard: View {
        let kind: FeedbackKind
        let severity: String?
        let anchor: String?
        let text: String
        let why: String?
        let actions: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Theme.glyph(for: kind))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 15)
                    Text(kind.label.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(Theme.textSecondary)
                    if let severity {
                        Text(severity)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Spacer(minLength: 4)
                }
                if let anchor {
                    Text("“\(anchor)”")
                        .font(.system(size: 11).italic())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                if let why {
                    Text(why)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if actions {
                    HStack(spacing: 10) {
                        Text("Respond")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .underline()
                        Spacer(minLength: 4)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 17, height: 17)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 17, height: 17)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border, lineWidth: 1))
        }
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
#endif
