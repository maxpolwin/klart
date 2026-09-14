# Klårt — Product Requirements Document

**Version:** 2.0.0 (Swift-native)
**Last Updated:** July 2026
**Status:** Active Development
**Platform:** macOS 14 (Sonoma) or later — native Swift/SwiftUI

---

## Table of Contents

1. [Product Overview](#1-product-overview)
2. [Technical Architecture](#2-technical-architecture)
3. [Core Features](#3-core-features)
4. [AI Integration](#4-ai-integration)
5. [Editor & Markdown](#5-editor--markdown)
6. [Design System](#6-design-system)
7. [Data Models](#7-data-models)
8. [Security & Encryption](#8-security--encryption)
9. [Settings & Configuration](#9-settings--configuration)
10. [Build & Distribution](#10-build--distribution)

---

## 1. Product Overview

### 1.1 Purpose

Klårt is a **thinking coach that lives in your notes** — a minimal, native macOS app for structuring your thinking in markdown. When you finish a section, a local or cloud LLM reads it against the whole document and tells you, plainly, where the thinking fails a demanding reader: gaps, unstated assumptions, claims with nothing behind them, evidence whose bearing on the claim is never said, the objection you haven't met, categories that overlap, an order that hides the argument. It never writes your text: you answer its notes in your own words.

### 1.2 Key Value Propositions

- **Coaching, not ghostwriting** — the editor critiques and questions; it never puts its own prose in the document. The one thing it can add is its note, as a prompt block for the writer to answer. Feedback that the writer has to act on is what changes the writer, not just the text.
- **Opinionated by design** — no praise, no hedging, no "consider". Each note says what is wrong, on which words, and what it costs the argument.
- **Local-first & private** — notes are plain JSON-wrapped markdown files on your machine; API keys live in the macOS Keychain; no telemetry. Optional at-rest encryption with app lock.
- **Any LLM** — Ollama, LM Studio, OpenRouter, or any OpenAI-compatible endpoint; model lists fetched live from the provider.
- **Native & light** — ~5 MB app, no bundled browser; follows the system light/dark appearance.

### 1.3 Target Users

- Academic researchers and graduate students
- Consultants and analysts structuring arguments
- Technical writers and knowledge workers managing complex information

---

## 2. Technical Architecture

### 2.1 Technology

| Layer | Technology |
|-------|-----------|
| Language | Swift (swift-tools 5.9) |
| UI | SwiftUI + AppKit (`NSViewRepresentable` editor) |
| Build | Swift Package Manager |
| Minimum OS | macOS 14 (Sonoma) |
| Crypto (KDF) | Vendored PHC reference Argon2 (`CArgon2`, compiled in-tree) |
| Networking | `URLSession` (ephemeral sessions) |

No Node, npm, Electron, or web view. The app is a single SwiftPM package.

### 2.2 Package structure

`Package.swift` declares one package (`Klart`) with:

**Products**
- `.library("KlartKit")` — platform-independent, unit-tested core
- `.executable("Klart")` — the SwiftUI app

**Targets**
- **`CArgon2`** — plain C target (`Sources/CArgon2`): vendored, hash-pinned PHC reference Argon2, compiled in-tree (nothing fetched at build time). Public headers in `include/`.
- **`KlartKit`** — depends on `CArgon2`. Core models, markdown parsing, storage, LLM clients, feedback engine.
- **`Klart`** — executable, depends on `KlartKit`. SwiftUI app (`Sources/KlartApp`). Embeds `Resources/Info.plist` into the binary via a linker `-sectcreate` flag so `swift run` gets App Transport Security exceptions for localhost providers.
- **`KlartKitTests`** — XCTest suite against `KlartKit`.
- **`KlartAppTests`** — XCTest suite against the app itself. Depends on the `Klart` executable target, which SwiftPM supports: it emits the app's `@main` entry point under a renamed symbol when a test target links it, so there is no duplicate `main` and no library/executable split is needed.

```
KlartMac/
├── Package.swift
├── Sources/
│   ├── CArgon2/                  Vendored Argon2 (C)
│   ├── KlartKit/               Core (library, unit-tested)
│   │   ├── Models/               Note, Settings, Feedback
│   │   ├── Markdown/             Outline parser (UTF-16 offsets ↔ cursor)
│   │   ├── Storage/              NoteStore (actor), SettingsStore, Keychain, VaultCrypto
│   │   ├── LLM/                  LLMClient, Ollama + OpenAI-compatible clients
│   │   └── Feedback/             PromptBuilder, FeedbackParser, FeedbackEngine
│   └── KlartApp/               SwiftUI app (macOS-only)
│       ├── AppState.swift        Single source of truth, debounce/cancellation
│       ├── Theme.swift           Design tokens
│       └── Views/                Teleprompter surface, sidebar, editor, coach panel, settings, lock
└── Tests/
    ├── KlartKitTests/            Core (no UI)
    └── KlartAppTests/            The writing surface, in a real window
```

### 2.3 Data flow

The renderer/main-process split of the old Electron build is gone. `AppState` (an observable object) is the single source of truth; it debounces edits, cancels in-flight analyses on new keystrokes, and calls into `KlartKit` (`NoteStore` actor for I/O, `FeedbackEngine` for coaching). Views are pure SwiftUI except the editor, which bridges to an `NSTextView` for markdown styling.

---

## 3. Core Features

### 3.1 Note Management

| Feature | Description |
|---------|-------------|
| Create | New note (`⌘N`); UUID identity |
| Edit | Plain-text markdown with live styling |
| Save | Debounced autosave (atomic writes); `⌘S` to save now |
| Delete | Remove note |
| Title | Computed: first non-empty line, leading heading marker (`#`–`######`, valid ATX only) stripped, ≤80 chars, else "Untitled" |
| Preview | Computed: first non-heading, non-empty line after the title (a "#" not followed by a space/tab is body text, not a heading), ≤120 chars |
| Export / Import | File menu → Export Notes as Markdown… / Import Markdown Notes… (round-trips its own export headers so re-imports update rather than duplicate) |

Notes are stored as markdown (not HTML). See §7 for the model.

### 3.2 AI Feedback ("the editor")

**When it reads.** A section is read when the writer is *finished* with it, not on every pause in typing — gap, assumption and structure critique is higher-order feedback, which lands better delayed than immediate, and a note on a half-written section mostly flags what the writer was about to write next. `SectionCompletionTracker` (pure, tested) decides:

- **Leaving an edited section** — the caret moves to a different section after typing in this one (moving on, or typing a new `##` heading beneath it) → read it now, pointed at the finished section, not the caret.
- **A long pause** — `settings.debounceSeconds` (default 20 s, clamped 5…120) with no keystroke → read the section under the caret.
- **On demand** — `⌘R`, the Analyze button (classic), or typing **`//editor`** → read the section under the caret and show the notes. `//show` only summons the rail.
- A section whose body has not changed since it was last read is not read again. A keystroke *inside* the section being read cancels the read (its notes would be about text that no longer exists); a keystroke elsewhere lets it finish.

With `autoFeedback` off, only the on-demand paths run.

**What it reads.** The finished section in full, plus the **whole document** for context (every `[no-ai]` section reduced to its heading and `(omitted)`; clipped head+tail to `PromptBuilder.documentBudget`). The model is told every note must be about the finished section.

**Two passes per read** (`FeedbackEngine`):

1. **Local checks** (`LocalChecks`, offline, instant, no provider needed): uncited empirical claims (`uncited-claim` → `evidence`), hedge-word density (`hedge-density` → `clarity`), recurring undefined acronyms (`undefined-term` → `clarity`) on the finished section; thin sections (`thin-section` → `gap`) and overlapping heading words (`title-overlap` → `mece`) across the document. Each note names the rule that fired, so the rule is learnable. They appear at once and stay whatever the model does next.
2. **The model**, given the local notes as "already flagged — do not repeat", so its budget goes to judgment.

**Feedback kinds** (`FeedbackKind`) — a critical-thinking lens: Paul–Elder's intellectual standards crossed with Toulmin's anatomy of an argument. All on by default.

| Kind | Label | Glyph | Names |
|------|-------|:---:|-------|
| `gap` | Gap | ◇ | A consideration or analysis the argument needs and does not have |
| `mece` | MECE | ⧉ | Categories that overlap or leave something uncovered |
| `structure` | Structure | ≡ | An order or grouping that hides the argument |
| `clarity` | Clarity | ◎ | A sentence a careful reader cannot pin down — language only |
| `evidence` | Evidence | ❝ | A claim stated as fact with nothing behind it (Toulmin: grounds) |
| `assumption` | Assumption | ⊢ | A premise the argument rests on but never states |
| `warrant` | Warrant | ⇒ | Claim and evidence present; why the evidence should convince is not |
| `counter` | Counter | ⇄ | The strongest objection the author has not engaged ("consider the opposite") |
| `question` | Question | ? | One question the author cannot answer without thinking harder |
| `other` | Note | · | Never requested; the parser's fallback for a `type` Klårt doesn't recognize. `source` from older builds decodes as `evidence`. |

**Shape of a note** (`FeedbackItem`): `kind`, **`anchor`** (the exact words it is about, verbatim from the section — verified by the engine; a quote not in the text is dropped, never shown), **`text`** (the observation, as a claim — never replacement prose), **`why`** (one sentence on what it costs the argument), **`severity`** (1 minor / 2 major / 3 critical — the rail orders by it and marks 2 as `!`, 3 as `‼`), `source` (`model` / `local`), `rule` (local only), `section`. There is no suggestion field: the prompt forbids drafting, and the parser drops a `suggestion` key if a model emits one anyway.

**Item actions:** **Respond** (`NoteEditing.respond`) puts the note into the section it names as a `> ✎ <Kind> — “anchor”: observation` / `> why` block, adds an empty line beneath it, and moves the caret there — the writer answers in their own words; nothing the model wrote becomes the writer's text. Plus an icon-only verdict: **✓ Confirm** (the editor is right; a signal only) and **✗ Reject** (wrong; never raised here again). Rejections are remembered by **fingerprint** — FNV-1a over `kind + normalized anchor` when there is one (rejecting means "no note of this kind on these words", and the model rewords its observation every round), else `kind + text`; a local note without an anchor keys on `kind + rule + section`. A judged item stays in place at reduced opacity with its controls inert.

**A read replaces only its section's notes.** Notes about other sections stay; notes the round re-raises elsewhere (a thin section, an overlapping title) replace their earlier selves by fingerprint, keeping the earlier card's identity and verdict. Whatever a read displaces unjudged is logged as `dismissed`.

**Learning log:** every verdict — `responded`, `confirmed`, `rejected`, and `dismissed` (the writer moved on) — is appended to `RecommendationLog` (`recommendations.json`) so coaching quality and the system prompt can be improved over time. Records are two-tiered: the **signal** tier (outcome, kind, severity, source, rule, fingerprint, model, provider — "Local checks" for local notes — `systemPromptHash`, `usesDefaultPrompt`, opaque note id) is always written; the **content** tier (note title, topic, section title, the section body the note reacted to, the anchor, the observation, the why) only when `AppSettings.logRecommendationContent` is on, and never for a note marked sensitive. The file is sealed under the vault master key with the rest of the library, and participates in enable / disable / rotate. Settings → Editor can export it as JSON (schema `klart.recommendations.v2`; with or without note text; sensitive notes are redacted either way) or clear it. A log from the previous build (`source` kind, `inserted` outcome, `suggestion` field) still loads.

### 3.3 Coach actions

Four one-tap actions (`CoachAction`), also in the **Editor** menu, that stream a response (< 250 words) into the classic layout's coach popover:

| Action | Label |
|--------|-------|
| `askQuestions` | Ask me questions (three numbered Socratic questions) |
| `challenge` | Challenge my thinking (weakest assumptions + counter-arguments) |
| `summarize` | Mirror my argument (reflect the claim + unsupported points) |
| `nextSteps` | Suggest next steps (three specific next actions) |

### 3.4 Section control

Any heading tagged `[no-ai]` (case-insensitive, e.g. `## Private notes [no-ai]`) excludes that section from analysis: it is never read, never checked locally, and its body is replaced by `(omitted)` in the document context sent with every other section's read. Any note can be marked **sensitive** (toolbar shield in the classic layout, the shield beside the pinned title in the Teleprompter; **File ▸ Mark Sensitive** in either layout); sensitive notes refuse all non-local AI requests in code (see §4.3).

### 3.5 Interface modes (`TeleprompterView.swift`, `ContentView.swift`)

Two layouts, switched in **Settings → Interface** (`settings.teleprompterMode`, default **on**):

**Teleprompter (default).** One centered column (max 720 pt) of text in a chromeless window (hidden title bar, full-size content view); monochrome — no accent hue anywhere on the surface (see §6). Requirements:

- **Left edge — notes.** Nothing visible while writing. Pointer at the left edge (≤ 26 pt) reveals a spine of dots, one per note (max 14, newest first; current note in full ink; click switches directly). Dwelling on the dots for **0.8 s** expands the panel: note title, last-modified date, shield mark when sensitive, search field (`⌘F` opens it directly), delete via context menu, New Note + Settings in the footer. Typing collapses dots and panel immediately.
- **The editor (AI) is summoned, never ambient.** Reading happens in the background as always, but its notes appear only on demand: the **¶** button above the panel's search field ("Show editor" on hover, with a count when notes wait), `⌘E`, or typing **`//show`** in the note; typing **`//editor`** reads the section under the caret at once and shows the notes. Typed commands are stripped before the note is saved (`MarkdownEditor.onCommand`) and only fire at a word boundary, so a URL never triggers one.
- **Right margin rail.** Each suggestion renders as a card vertically **anchored to the section it refers to** (heading line position via the AppKit layout manager through `EditorBridge`, live on scroll/edit, single downward collision pass so cards never overlap), in a rail as wide as its widest current note needs — `EditorRailMetrics` measures the text, clamped to 200–264 pt — so a short round of notes reserves less margin than a long one. With no notes yet the rail is fixed at the maximum: the empty card's message changes while the rail is still arriving (a read starts and, for a short section, finishes within a frame), and a width that followed it ran the text swap inside the arrival spring — the old words slid across the page into the card (`RailOpeningTests` samples the presentation layer through the slide to keep it out). The empty card's content also sits under `.transaction { $0.animation = nil }` for the same reason. The rail is a scroll view: when the packed stack fits, the layout is the anchored one; when it cannot fit even edge to edge, cards keep their heading anchors, the content grows to the last card's foot, and the rail scrolls to the rest — it never folds cards over each other (`RailOverflowTests`; each card reports its frame into `EditorBridge` so the test can measure the real rail). Cards carry a monochrome kind glyph (§6) instead of a colored pill, a severity mark (`!` / `‼`; minor notes carry none), the rule name for a local check, the anchored words in italic, the observation, the why in secondary ink, **Respond** and a right-aligned two-glyph verdict, **✓** and **✗** (the latter permanent, fingerprint recorded) — and nothing else, so a card that is only read costs no decision. The verdict glyphs are quiet until the card is hovered. A judged card stays in the rail at half opacity with only its chosen glyph legible, rather than sliding out: the rail should show what has been attended to. A chevron at the rail's near edge, level with the pinned title, closes it — the one control on the rail itself, so putting the notes away doesn't mean reaching for `⌘E` or the panel at the far edge.
- **Reading pulse.** While the editor is actually working on the note (`AppState.editorIsReading` — analysing, or a coach action streaming), the ¶ summons glyph and the rail card's contents (glyph, "Reading…", message) breathe between full ink and 42% on `KlartPulse.period` — the same 1 s beat the caret blinks on, so the surface has one pulse rather than two clocks. No spinner and no new object on screen; the card's frame and the button's seat hold still underneath. Reduce Motion holds both at full ink.
- **Fade-out.** If the user keeps typing, the rail fades after **5 minutes over 20 seconds** (Reduce Motion: near-instant at the same moment) and the surface returns to focus mode. Hovering the rail, or fresh suggestions, restores it and resets the countdown; an untouched rail with no typing stays.
- **Pinned title.** The note's derived title stays visible at the top (under a background-fog gradient), with a shield beside it: outlined normally, filled when the note is sensitive, and clicking it toggles the mark — so it stays discoverable instead of appearing only once set.
- **Word count (optional).** `settings.showWordCount` (default off) shows "N words · M min read" at the foot (`NoteMetrics`, §5 — markdown-aware, 200 wpm).

**Classic.** The pre-Teleprompter layout: Constellation sidebar, unified toolbar (Analyze, shield, coach pill), coach popover. `//show` opens the popover, `//editor` reads and opens it. Otherwise unchanged.

### 3.6 Item dialogue (planned — not yet built)

The one thing a card cannot do today is be argued with. Feedback research is unambiguous that dialogic feedback — the learner can push back and get a refined answer — is taken up far more than one-shot feedback, and an editor who cannot be answered teaches only by assertion. Planned for the release after the note shape and trigger have settled, so the discussion is about notes that are already worth discussing.

**Interaction.** A third quiet action on every card, **Discuss**. Teleprompter: the card expands in place into a thread — the note at the top, the writer's reply field beneath, the editor's replies streaming into the same card, the rail widening to `railMaxWidth` for the duration; the writing column stays where it is, so the thread sits beside the words it is about. Nothing else on screen moves. `Esc` or the card's chevron folds it back to a card that now carries a small count (`3 ↩`). Classic: the same thread opens as a sheet from the popover row. A thread never edits the note; the only way out of it into the text is the existing **Respond**, which then quotes the *conclusion* of the thread rather than the original observation.

**Prompting.** A discussion turn sends the system prompt (coach template, with a new `{{DISCUSSION}}` instruction: "defend the note, concede when the author is right, and say so plainly"), the anchored section, the note, and the thread so far. The editor may end a turn with `[withdrawn]` — the note was wrong — which the app records as `rejected` with reason `argued`, or `[stands]`, recorded as `confirmed`.

**Storage: the writer's knowledge base.** Threads are appended to `discussions.json` beside `recommendations.json`, sealed under the same vault key, one record per thread: opaque note id, note fingerprint, kind, section title, the turns (role, text, time), and the outcome. From it and the learning log the app derives a bounded **writer profile** (`WriterProfile`, ≤ 600 characters, regenerated locally and deterministically, never by a model): recurring kinds by acceptance rate ("assumption notes accepted 80%, counter notes rejected 70%"), stated standing preferences the writer gave in threads ("I hedge in introductions on purpose"), and the three most recent conceded points. The profile renders into the feedback prompt as `{{WRITER_PROFILE}}` — an optional placeholder, empty by default, so a user who never discusses sees no change — and lets the editor say "you conceded this in *Pricing* on 12 Aug" when the same weakness recurs, which is the memory a human editor has and a fresh prompt does not. Sensitive notes contribute threads with the content tier stripped, exactly as the learning log does; the profile is exportable and clearable from Settings → Editor beside the log.

**Not in scope.** Spaced recall of the writer's own claims (the old Noschen SM-2 scheduler) stays out until the feedback itself is right; it would schedule prompts built from notes, so it inherits every flaw the notes still have.

### 3.7 Welcome tour and sample note (`WelcomeView.swift`, `SampleNote.swift`)

A fresh install opens on a seven-screen tour over the writing surface (`WelcomePage.all`; copy and art are data, `WelcomeArt` draws each): the column, the notes behind the left edge, when the editor reads, the anatomy of a note and the nine lenses, Respond and the verdicts, privacy, and an offer to open a sample note. `settings.welcomeSeen` records that it has been seen or skipped; it never shows itself twice, and **Help ▸ Welcome Tour…** (or Settings → Interface) brings it back.

The sample note — *Second location for Nordbrot*, `SampleNote.english` — is a real 500-word argument written to trip every lens: an uncited rule of thumb, a hedge-dense risk section, overlapping customer groups, a decision that leans on one footfall number, an unstated staffing assumption, an objection nobody raises, a `[no-ai]` section that must never be read, and a fenced SQL block whose `#` comments must not become headings. Opening it from the tour creates the note and reads `SampleNote.readSection` at once, so the offline checks show something before any provider is configured (`WelcomeTests`, `SampleNoteTests`). German and Spanish translations of the same note, for testing the lenses in other languages, sit in `docs/samples/` as importable markdown.

---

## 4. AI Integration

### 4.1 Providers

`ProviderKind` and its defaults (`Sources/KlartKit/Models/Settings.swift`):

| Provider | Display name | Default endpoint | Default model | API key | Insecure HTTP allowed |
|----------|-------------|------------------|---------------|:---:|:---:|
| `ollama` | Ollama | `http://localhost:11434` | `llama3.2` | — | ✅ (local) |
| `lmstudio` | LM Studio | `http://localhost:1234/v1` | — | — | ✅ (local) |
| `openrouter` | OpenRouter | `https://openrouter.ai/api/v1` | `anthropic/claude-haiku-4.5` | Keychain | ❌ |
| `custom` | Custom (OpenAI-compatible) | `http://localhost:8080/v1` | — | optional | ✅ (local) |

**Clients** (`Sources/KlartKit/LLM/`):
- **`OllamaClient`** — native Ollama API. `listModels()` → GET `api/tags`; chat → POST `api/chat` with `options.num_predict`, `format: "json"` in JSON mode; newline-delimited JSON streaming.
- **`OpenAICompatClient`** — LM Studio, OpenRouter, custom. `listModels()` → GET `models`; chat → POST `chat/completions` with `max_tokens`, SSE streaming; API key as `Authorization: Bearer …`.
- **`ProviderFactory`** builds the right client. OpenRouter adds `HTTP-Referer` / `X-Title` headers. **Test Connection** in Settings fetches the live model list.

### 4.2 Prompting & parsing

- **`PromptBuilder`** — assembles the editor's prompt from the finished section plus the whole redacted document; budgets: `sectionBudget = 8000`, `documentBudget = 16000`, `coachBudget = 12000` chars (over-budget text is head+tail clipped with `[…]`). The default system prompt is opinionated on purpose — "a sharp, opinionated reader whose only job is to make their thinking harder to fault… No praise. No padding. No hedging." — forbids drafting replacement prose, and demands strict JSON: `{"feedback":[{"type":"gap","anchor":"…","text":"…","why":"…","severity":2}]}`. Tone fragments (`FeedbackTone`, default `direct`) change register only; every tone stays opinionated, and `encouraging` credits method, never the author. Local notes are listed in the user turn as "already flagged — do not repeat".
- **Editable system prompts** — both system prompts (live feedback and Quiet coach) are templates the user can rewrite in **Settings → Editor → System prompt**. The app owns a canonical default for each (`defaultFeedbackTemplate` / `defaultCoachTemplate`); `AppSettings.feedbackSystemPrompt` / `coachSystemPrompt` hold the override (`nil` = use the current default, so Revert clears the field and future default changes flow through). The per-request dynamic pieces stay as `{{TOKENS}}` — `{{FEEDBACK_TYPES}}`, `{{MAX_TIPS}}`, `{{STYLE}}`, `{{JSON_SHAPE}}` (feedback) and `{{ACTION_INSTRUCTION}}` (coach) — that `PromptBuilder.render` substitutes at build time, keeping a customised prompt in sync with the other settings. `{{JSON_SHAPE}}` is required; the editor warns (via `missingRequiredPlaceholders`) when it is removed, since `FeedbackParser` depends on it.
- **`FeedbackParser`** — forgiving: strips code fences, extracts the first balanced JSON value (string/escape aware), and salvages complete items from a truncated array. Loose `type` strings are mapped onto `FeedbackKind` by substring; `severity` may arrive as a number or a word; a stray `suggestion` key is ignored.
- **`FeedbackEngine`** — `localItems` runs `LocalChecks` (no provider). `analyze` skips content under 80 chars (`SkipReason.tooShort`), excluded sections, or when no kinds are enabled; runs in JSON mode; verifies every anchor against the section (whitespace/case/quote-insensitive) and drops the ones that are not there; stamps the section; filters rejected fingerprints; caps the model's notes at `tipStyle.maxTips`; merges the local notes in ahead (same instances, so their identity and any verdict survive) and orders the round by severity. `.other` is never among the kinds it asks the model for.

### 4.3 Transport security & sensitive-note enforcement

`LLMHTTP` (in `LLMClient.swift`) normalizes every base URL:
- HTTPS is always accepted; plain `http` is accepted **only** for local hosts (`localhost`, loopback, RFC 1918 / CGNAT / link-local ranges, IPv6 ULA/link-local, single-label hostnames, and `.local`/`.lan`/`.internal`/`.home.arpa` suffixes). A remote `http` URL throws `LLMError.insecureURL`.
- **`ProviderFactory.isLocal`** decides local-vs-cloud by the **resolved endpoint host**, not the provider label — a Custom provider pointed at a remote host counts as cloud. Sensitive notes are refused whenever the resolved endpoint is not local. This is enforced at request time, not just hidden in the UI.

---

## 5. Editor & Markdown

The editor (`Sources/KlartApp/Views/EditorView.swift`) is a plain-text `NSTextView` (`KlartTextView`) with live, per-paragraph styling — markdown stays markdown, it is never converted to rich text. It re-styles per paragraph while typing, fully on paste / note-switch, and on both sides of every cursor move. Syntax markers are hidden from layout on every line except the one the cursor is in (tagged `.klartHiddenMarker`, nulled by the layout-manager delegate), so the page reads as rendered markdown while the characters stay in the file and the line being edited stays raw. A fresh editor (and undo stack) is created per note.

**Constructs styled/handled** (`EditorStyler`):

| Construct | Behavior |
|-----------|----------|
| ATX headings `#`–`######` | Leading marker kept body-size and dimmed on the line being edited, hidden from layout on every other line; only heading text enlarged. H1 26 / H2 20 / H3 17 / H4–H6 15 pt, semibold; inline emphasis still applied inside, scaled to the heading's size. A `#` not followed by a space/tab (a hashtag, "C#", "#1") is left as plain text, not a heading |
| Fenced code blocks ` ``` ` / `~~~` | Rendered verbatim in code font; contents never parsed as headings/lists/emphasis. Open-fence state scanned from top of document |
| Lists `-` `*` `+` `1.` `1)` | Markers tinted; continue on <kbd>Enter</kbd> (ordered numbers increment, indent preserved); empty item + Enter exits the list; suppressed inside code fences and on horizontal rules |
| Task lists `- [ ]` / `- [x]` | Checkbox dimmed; checked items struck through and dimmed |
| Inline `**bold**` / `*italic*` / `_italic_` / `` `code` `` | Styled inline; syntax markers at the edges dimmed on the line being edited, hidden from layout elsewhere |
| Strikethrough `~~text~~` | Single strikethrough; edge markers dimmed on the line being edited, hidden elsewhere |
| Blockquote `>` | Dimmed 14 pt; inline emphasis still applied inside |
| Horizontal rules `---` / `***` / `___` | Dimmed |
| Escaped `\*` `` \` `` `\_` | Not treated as emphasis/code |

**Outline** (`Sources/KlartKit/Markdown/Outline.swift`): `DocumentOutline.parse` builds `OutlineSection`s with **UTF-16 offsets** (matching the `NSTextView` cursor) — `level`, `title`, `headingStart`, `bodyStart`, `bodyEnd`, `excludedFromAI`. Headings inside code fences are ignored; a trailing `[no-ai]` marks a section excluded. This is the structure the coach uses to know your topic (first H1), which section you're editing, and what the other sections cover — and the Teleprompter rail uses `headingStart` to anchor each suggestion card to its section on screen (§3.5).

**Metrics** (`Sources/KlartKit/Markdown/NoteMetrics.swift`): markdown-aware word count (heading markers, bullets, emphasis characters, and fenced code don't count as words) and estimated reading time at 200 wpm — the optional "512 words · 3 min read" line at the foot of the Teleprompter surface.

**Typewriter scrolling** (`KlartTextView.centerCaretLine`): the line being written is eased to the vertical centre of the window by a critically damped spring re-tuned each frame from the distance left to travel (1.4 s for a one-line nudge, up to 4.0 s for a jump across the note). The text container carries a **half-viewport margin above and below the text** (`textContainerInset`, never the scroll view's `contentInsets` — those shrink the scroll view's content area, and two half-viewport insets shrink it to nothing, collapsing the text view to the height of its own text so every click outside that band misses the editor), so the first line and the last can each reach the centre. A note therefore **opens already centred** (`viewDidMoveToWindow`, un-animated: there is nothing to travel from) and **claims focus if nothing else holds it**, so a new note's cursor is at writing height and ready to type before the first keystroke. Reduce Motion applies every position instantly. A trackpad scroll cancels the spring; typing re-engages it.

**Slash commands** (`MarkdownEditor.onCommand`): typing `/editor` at a word boundary summons the editor rail; the command text is removed from the note before the binding updates, so it never reaches disk.

---

## 6. Design System

`Sources/KlartApp/Theme.swift` — the "Quiet" palette: system-adaptive light/dark via dynamic `NSColor`s, one accent color, hairline borders, no glass/glow chrome.

**Monochrome (Teleprompter).** While the Teleprompter surface is active (`Theme.monochrome`, kept in sync with settings by `AppState` before any view builds), every hue collapses to ink: `nsMarker` (markdown syntax markers) resolves to `nsTextSecondary` instead of `nsAccentMuted`, `nsInsertionPoint` to `nsTextPrimary` instead of `nsAccent`, and the surface itself uses only the text/background/border tokens. Feedback kinds are distinguished by **glyph + label + tone, never hue** (which also removes the color-blind dependency):

| Kind | Glyph | Drawn from |
|------|-------|------------|
| Gap | `◇` | something missing — an unfilled shape |
| MECE | `⧉` | two frames colliding — overlap |
| Structure | `≡` | stacked, level rules — order |
| Clarity | `◎` | a mark resolving into focus |
| Evidence | `❝` | the citation that isn't there |
| Assumption | `⊢` | the premise the argument rests on |
| Warrant | `⇒` | the link from evidence to claim |
| Counter | `⇄` | the other side |
| Question | `?` | an open ask |
| Other | `·` | — |

Severity is a second glyph beside the kind, never a hue: `!` for a note that weakens the argument, `‼` for one the argument fails without; minor notes carry nothing (`Theme.severityMark(_:)`). (`Theme.glyph(for:)`; light/dark still adapts inside monochrome via the dynamic ink tokens.)

**Core tokens** (light / dark):

| Token | Light | Dark |
|-------|-------|------|
| `nsBackground` | `#F5F5F3` | `#1E1E20` |
| `nsTextPrimary` | `#1D1D1F` | `#F5F5F7` |
| `nsTextSecondary` | `#86868B` | `#98989D` |
| `nsTextTertiary` | black @ 32% | white @ 35% |
| `nsAccent` | `#2B5FAD` | `#6FA0EA` |
| `nsAccentMuted` | accent @ 85% (markdown syntax markers) | — |

`surfaceRaised` = `Color.primary.opacity(0.055)`; `border` = `Color.primary.opacity(0.08)`.

**Per-kind feedback colors** (`Theme.color(for:)`) — distinct hue per `FeedbackKind` (Gap blue, MECE purple, Source green, Structure amber, Clarity teal, Question rose, Other → secondary), each tuned for light and dark.

**Components:** `KindBadge` (uppercased 9.5 pt rounded-bold label on a 12%-tint capsule) and `StatusDot` (7×7 dot: connected → green, failed → red, checking → amber, unknown → tertiary).

**Editor type scale:** body 15, bold 15 semibold, italic 15, code 13.5 mono, quote 14, headings as above; paragraph `lineSpacing 4.5`, `paragraphSpacing 4`.

**Caret** (`KlartTextView`, drawn by hand — AppKit's own insertion point is suppressed): 2 pt wide, and **as tall as the font it stands in, ascender to descender** (≈17.7 pt in body, ≈30.6 pt in an H1) — never the line fragment's height, which carries the paragraph's `lineSpacing` and would make the mark stand taller than the letters it is setting. It springs horizontally between positions and jumps vertically (a caret arcing between lines reads as a glitch), stays solid while travelling or typing, and otherwise blinks on `KlartPulse.period`.

---

## 7. Data Models

`Sources/KlartKit/Models/`. All types are `Codable, Sendable`, with lenient decoding (every field falls back to a default).

### 7.1 Note (`Note.swift`)

```swift
public struct Note: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var content: String            // markdown
    public var createdAt: Date
    public var updatedAt: Date
    public var rejectedFingerprints: [String]   // rejected-feedback fingerprints
    public var isSensitive: Bool                 // refuses non-local AI when true
}
```
`title` and `preview` are computed from `content` (see §3.1).

### 7.2 Feedback (`Feedback.swift`)

```swift
public enum FeedbackKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case gap, mece, structure, clarity, evidence, assumption, warrant, counter, question, other
    // .label, .instruction (model guidance), .defaultEnabled (all but .other), .fromModelString(_:)
    // Lenient init(from:): "source" → .evidence, unknown → .other — an old settings file or log never fails to load.
}

public enum FeedbackSeverity: Int, Codable, Comparable { case minor = 1, major, critical }
public enum FeedbackSource: String, Codable { case model, local }

public struct FeedbackItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: FeedbackKind
    public let anchor: String?         // the exact words it is about (verified; nil = the section as a whole)
    public let text: String            // the observation, as a claim — never replacement prose
    public let why: String?            // what it costs the argument
    public let severity: FeedbackSeverity
    public let source: FeedbackSource
    public let rule: String?           // local checks: the heuristic that fired
    public let section: String?        // referenced section title
    // .fingerprint — FNV-1a over kind + normalized anchor (else text; local without anchor: rule + section)
}
```

`SectionCompletionTracker` (`Feedback/SectionCompletion.swift`) — pure value type behind the trigger in §3.2: `noteEdit(at:in:)`, `caretMoved(to:in:) -> Completed?`, `pauseElapsed(at:in:) -> Completed?`, `markRead(at:in:)`, `reset()`.

`LocalChecks` (`Feedback/LocalChecks.swift`) — `run(text:cursorUTF16:) -> [FeedbackItem]`, capped at `maxFindings` (5); the rules in §3.2.

### 7.3 Settings (`Settings.swift`)

```swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var activeProvider: ProviderKind               // default .ollama
    public var providers: [ProviderKind: ProviderConfig]
    public var enabledFeedbackKinds: [FeedbackKind]       // default FeedbackKind.defaultEnabled
    public var tipStyle: TipStyle
    public var debounceSeconds: Double                    // the pause trigger; default 20 (clamped 5…120 — an older build's keystroke debounce is lifted)
    public var autoFeedback: Bool                         // default true: read a section when the writer finishes it
    public var temperature: Double                        // default 0.4 (clamped 0…2)
    public var maxTokens: Int                             // default 1024 (clamped 64…8192)
    public var vault: VaultConfig?                        // nil = encryption off
    public var autoLockMinutes: Int                       // default 15 (clamped 0…240; 0 = never)
    public var lockOnScreenSleep: Bool                    // default true
    public var excludeFromCapture: Bool                   // default true
    public var teleprompterMode: Bool                     // default true (§3.5; off = classic layout)
    public var showWordCount: Bool                        // default false (word count + reading time)
    public var welcomeSeen: Bool                          // default false; set once the tour is finished or skipped (§3.7)
}

public struct TipStyle: Codable, Equatable, Sendable {
    public var tone: FeedbackTone        // neutral | academic | direct (default) | encouraging — register only; every tone stays opinionated
    public var detail: FeedbackDetail    // brief | standard | detailed
    public var maxTips: Int              // default 3 (clamped 1…6)
    public var language: String          // "" = match the note's language
    public var customGuidance: String    // freeform standing instruction
}
```
`ProviderConfig { baseURL, model }` with `.defaults(for:)` per `ProviderKind`.

---

## 8. Security & Encryption

Optional, off by default (`vault == nil`). Files: `Storage/VaultCrypto.swift`, `SecureBytes.swift`, `SecureEnclaveWrap.swift`, `AuditLog.swift`, `NoteStore.swift`.

### 8.1 At-rest encryption

- **Current format v3** (magic `NSCHNVLT3`): **AES-256-GCM** under a **per-note subkey** derived by **HKDF-SHA256** from the master key, with the note's UUID as both HKDF `info` and GCM AAD — a sealed file copied under another note's name fails to decrypt instead of impersonating it.
- Plaintext is length-prefixed and **zero-padded to 4 KiB buckets** so file size doesn't reveal note size.
- **Legacy v1/v2** (ChaCha20-Poly1305) files stay readable forever and upgrade to v3 on next save.

### 8.2 Key management

- **Argon2id** (vendored PHC reference in `CArgon2`) wraps the random 256-bit master key from your password: **128 MiB memory, 3 passes, 4 lanes**, password NFC-normalized. Legacy **PBKDF2-HMAC-SHA256** (600 000 iterations) vaults still unlock and upgrade to Argon2id on the next password unlock.
- The master key is held in **`mlock`-ed, zeroized-on-lock memory** (`SecureBytes`) while unlocked.
- **Touch ID / Secure Enclave** (`SecureEnclaveWrap`): on Apple Silicon / T2 a copy of the key is wrapped to a **P-256 Secure Enclave key** requiring user presence on every decrypt; older Macs fall back to a user-presence Keychain item. Degrades gracefully to password-only when no enclave.
- **Key rotation** (`beginRotation`/`completeRotation`) re-encrypts the library under a fresh master key, crash-safe and resumable.
- No recovery backdoor: a forgotten password with Touch ID off means the notes are unrecoverable — keep a markdown export.

### 8.3 App lock & ambient protection

- App starts locked; locks with `⌘L`; **auto-locks** on screen sleep and after `autoLockMinutes` idle; repeated wrong passwords throttle with growing delays.
- **`excludeFromCapture`** (default on) hides the window from screenshots, recordings, and screen sharing. Copies from a protected library clear the pasteboard after 45 s unless something else was copied.
- **Audit log** (`AuditLog`): tamper-evident, hash-chained (SHA-256) one-JSON-line-per-event log recording lock/unlock/rotation events (`vault_enabled`, `unlock_success`, `unlock_failure`, `biometric_unlock_*`, `locked`, `key_rotated`, `unlock_throttled`, …) — never content, passwords, or keys. `verifyChain` detects tampering.

### 8.4 Storage locations

| Data | Path |
|------|------|
| Notes | `~/Library/Application Support/Klart/Notes/<UUID>.json` (pretty JSON, atomic) |
| Settings | `~/Library/Application Support/Klart/settings.json` |
| API keys | macOS Keychain, service `com.klart.mac`, account `klart.apikey.<provider>` |
| Telemetry | none |

`NoteStore` is a Swift `actor`; it refuses writes while the vault is locked. The sandboxed packaged app resolves the base path to its container; an unsandboxed `swift run` build uses `~/Library/Application Support` directly.

---

## 9. Settings & Configuration

Settings UI (`Sources/KlartApp/Views/SettingsView.swift`) covers:

1. **Interface** — Teleprompter mode on/off (§3.5), word count + estimated reading time on/off, replay the welcome tour (§3.7).
2. **AI Provider** — active provider (Ollama / LM Studio / OpenRouter / Custom), endpoint, model (with live **Test Connection** model list), API key (stored in Keychain), temperature, max tokens.
3. **Editor** — read-when-finished toggle and the pause length, notes per read, enabled feedback kinds, voice (tone, detail, language, custom guidance), system prompt editor, learning log (content opt-in, export, clear).
4. **Security** — enable/disable the encrypted vault, Touch ID unlock, auto-lock timeout, lock-on-sleep, exclude-from-capture, change password, key rotation.

Out-of-range values are clamped on decode (see §7.3).

---

## 10. Build & Distribution

### 10.1 Commands

```bash
cd KlartMac
swift run                  # development
swift test                 # unit tests (KlartKitTests + KlartAppTests)
bash Scripts/make-app.sh   # release build → dist/Klart.app (verifies Hardened Runtime + App Sandbox)
bash Scripts/make-dmg.sh   # package → dist/Klart.dmg
bash Scripts/notarize-app.sh   # submit to Apple + staple
```

### 10.2 Distribution

- **Format:** signed `Klart.app` and `Klart.dmg`. Single platform: **macOS**, built for the architecture of the build machine — `make-app.sh` is a plain `swift build -c release`, so nothing here produces a universal binary.
- **Signing:** Developer ID + **Hardened Runtime** + **App Sandbox** (outgoing network only, plus user-picked files for export/import). `make-app.sh` fails the build if either flag is missing from the signature.
- **CI:** `.github/workflows/macos-app.yml` builds, tests, and packages on every push to `main` or a `claude/**` branch that touches `KlartMac/`; uploads `Klart.app` and (ad-hoc or Developer-ID-signed) `Klart.dmg` artifacts, and on `main` refreshes the `latest` GitHub release with the DMG so there is one permanent download link that needs no login. Full signing/notarization secrets are documented in `KlartMac/README.md`.

### 10.3 Tests

`Tests/KlartKitTests/` (XCTest) covers: Argon2id KAT + vault KDF upgrades (`Argon2Tests`), forgiving JSON parsing, note identity and old kind names (`FeedbackParserTests`), the offline rules firing and staying quiet (`LocalChecksTests`), when a section counts as finished (`SectionCompletionTests`), v3 crypto / padding / rotation / audit chain / provider locality (`HardeningTests`), transport security (`LLMHTTPTests`), outline parsing incl. code fences and `[no-ai]` (`OutlineTests`), prompt assembly incl. `[no-ai]` redaction, anchor verification, local/model merge, and the response block (`PromptAndEngineTests`), storage & settings round-trips and clamps (`StorageAndSettingsTests`), vault crypto (`VaultCryptoTests`), end-to-end vault lifecycle (`VaultLifecycleTests`), the shared ATX heading rule (`MarkdownHeadingTests`), word count and reading time (`NoteMetricsTests`), note titles and previews (`NoteTests`), and the sample note's outline, offline findings and read cursor (`SampleNoteTests`).

`Tests/KlartAppTests/` (XCTest) covers the writing surface, which is geometry and therefore only measurable against the real thing: a real `NSWindow`, the real layout manager, real key events through the responder chain. `CaretGeometryTests` — the caret is the font's height rather than the line box's, scales with the font it stands in, and sits on the line it is actually on (including the empty one Enter opens at the end of a note). `WritingSurfaceTests` — the half-viewport margin lives in `textContainerInset` and not in `contentInsets`, the document view keeps filling the window so every click reaches the editor, the caret's line settles at the centre from a new note / the last line of a long one / a viewport that arrives late, re-centring does not rewrite the layout per keystroke, and the rail's anchors follow the same margin. `NewNoteTests` — the whole app: a new note holds the keyboard and typing lands in it, across note switches, without ever taking focus from a control that already has it. `RailOpeningTests` — opening the rail while a read starts and finishes leaves no ghost of the empty card's text on the page (real window, frames sampled from the layer tree's presentation copy, since `cacheDisplay` draws the model tree and never sees an animation). `FeedbackVerdictTests` — judging leaves the card in place, Respond writes the prompt block and lands the caret under it, leaving an edited section starts a read whose offline notes survive a model failure, a read replaces only its section's notes, and what the learning log records (signal always, content opt-in, never for a sensitive note, local notes attributed to their rule). `RailOverflowTests` — eight cards on a short window never overlap, an overflowing rail scrolls instead of compressing, cards that fit keep their heading anchors while it overflows, and a few cards in a tall window sit on their headings. `WelcomeTests` — a fresh install shows the tour and finishing it is remembered; opening the sample note reads it without a provider. `ReadingPulseTests` — `editorIsReading` and the shared beat.

These need a window server. Without one (an SSH or daemon session) they skip rather than hang; `swift test` on a GitHub Actions runner has an Aqua session and runs them.

---

*Document reflects the native Swift/SwiftUI implementation in `KlartMac/`. For narrative setup and distribution detail, see [KlartMac/README.md](../KlartMac/README.md).*
