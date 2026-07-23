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

Klårt is a **thinking coach that lives in your notes** — a minimal, native macOS app for structuring your thinking in markdown. As you write, a local or cloud LLM reads the section you're working on (in the context of the whole document) and coaches you: it points out gaps, overlapping categories, vague claims, and structural problems, and can ask Socratic questions instead of writing your notes for you.

### 1.2 Key Value Propositions

- **Coaching, not ghostwriting** — the AI critiques and questions; it never edits the document without an explicit accept.
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
└── Tests/KlartKitTests/
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

### 3.2 AI Feedback ("coaching")

**Trigger:** after a configurable pause (default 2.5 s) when Auto is on, or on demand with `⌘R`. Analysis targets the section the cursor is in, with the document outline as context. A new keystroke cancels the in-flight request.

**Feedback kinds** (`FeedbackKind`):

| Kind | Label | On by default | Purpose |
|------|-------|:---:|---------|
| `gap` | Gap | ✅ | A missing perspective, consideration, or analysis |
| `mece` | MECE | ✅ | Non-mutually-exclusive or non-exhaustive categories |
| `structure` | Structure | ✅ | Organization / flow / ordering |
| `clarity` | Clarity | ✅ | Vague or ambiguous claims |
| `question` | Question | ✅ | A probing Socratic question |
| `source` | Source | ⬜ | Missing citations / evidence |
| `other` | Note | ⬜ | Uncategorized — never requested, but the parser's fallback for a `type` Klårt doesn't recognize |

Default enabled set is `[gap, mece, structure, clarity, question]`.

**Item actions:** **Insert** (adds the suggestion into the note as a `> ✎ <label>:` blockquote at the end of the section the cursor is in — `NoteEditing.insertSuggestion`, not necessarily the section the tip names) or **Dismiss** (hidden permanently for that note). Dismissals are remembered by a content **fingerprint** (FNV-1a over `kind + normalized text`), so regeneration doesn't resurface them.

### 3.3 Coach actions

Four one-tap actions (`CoachAction`), also in the **Editor** menu, that stream a response (< 250 words) into the classic layout's coach popover:

| Action | Label |
|--------|-------|
| `askQuestions` | Ask me questions (three numbered Socratic questions) |
| `challenge` | Challenge my thinking (weakest assumptions + counter-arguments) |
| `summarize` | Mirror my argument (reflect the claim + unsupported points) |
| `nextSteps` | Suggest next steps (three specific next actions) |

### 3.4 Section control

Any heading tagged `[no-ai]` (case-insensitive, e.g. `## Private notes [no-ai]`) excludes that section from analysis. Any note can be marked **sensitive** (toolbar shield in the classic layout, the shield beside the pinned title in the Teleprompter; **File ▸ Mark Sensitive** in either layout); sensitive notes refuse all non-local AI requests in code (see §4.3).

### 3.5 Interface modes (`TeleprompterView.swift`, `ContentView.swift`)

Two layouts, switched in **Settings → Interface** (`settings.teleprompterMode`, default **on**):

**Teleprompter (default).** One centered column (max 720 pt) of text in a chromeless window (hidden title bar, full-size content view); monochrome — no accent hue anywhere on the surface (see §6). Requirements:

- **Left edge — notes.** Nothing visible while writing. Pointer at the left edge (≤ 26 pt) reveals a spine of dots, one per note (max 14, newest first; current note in full ink; click switches directly). Dwelling on the dots for **0.8 s** expands the panel: note title, last-modified date, shield mark when sensitive, search field (`⌘F` opens it directly), delete via context menu, New Note + Settings in the footer. Typing collapses dots and panel immediately.
- **The editor (AI) is summoned, never ambient.** Analysis runs in the background as always, but its results appear only on demand: the **¶** button above the panel's search field ("Show editor" on hover, with a count when suggestions wait), `⌘E`, or typing **`/editor`** in the note (the command text is stripped before the note is saved — `MarkdownEditor.onCommand`).
- **Right margin rail.** Each suggestion renders as a card vertically **anchored to the section it refers to** (heading line position via the AppKit layout manager through `EditorBridge`, live on scroll/edit, single downward collision pass so cards never overlap), in a rail as wide as its widest current note needs — `EditorRailMetrics` measures the text, clamped to 200–264 pt — so a short round of notes reserves less margin than a long one. Cards carry a monochrome kind glyph (§6) instead of a colored pill, the observation, **Insert** (when content exists) and **Dismiss** (permanent, fingerprint recorded) — and nothing else, so a card that is only read costs no decision. A handled card slides out toward the right edge as it leaves. A chevron at the rail's near edge, level with the pinned title, closes it — the one control on the rail itself, so putting the notes away doesn't mean reaching for `⌘E` or the panel at the far edge.
- **Reading pulse.** While the editor is actually working on the note (`AppState.editorIsReading` — analysing, or a coach action streaming), the ¶ summons glyph and the rail card's contents (glyph, "Reading…", message) breathe between full ink and 42% on `KlartPulse.period` — the same 1 s beat the caret blinks on, so the surface has one pulse rather than two clocks. No spinner and no new object on screen; the card's frame and the button's seat hold still underneath. Reduce Motion holds both at full ink.
- **Fade-out.** If the user keeps typing, the rail fades after **5 minutes over 20 seconds** (Reduce Motion: near-instant at the same moment) and the surface returns to focus mode. Hovering the rail, or fresh suggestions, restores it and resets the countdown; an untouched rail with no typing stays.
- **Pinned title.** The note's derived title stays visible at the top (under a background-fog gradient), with a shield beside it: outlined normally, filled when the note is sensitive, and clicking it toggles the mark — so it stays discoverable instead of appearing only once set.
- **Word count (optional).** `settings.showWordCount` (default off) shows "N words · M min read" at the foot (`NoteMetrics`, §5 — markdown-aware, 200 wpm).

**Classic.** The pre-Teleprompter layout: Constellation sidebar, unified toolbar (Analyze, shield, coach pill), coach popover. Unchanged behavior.

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

- **`PromptBuilder`** — assembles the coaching prompt from the current section plus the outline; budgets: `sectionBudget = 8000`, `coachBudget = 12000` chars (over-budget text is head+tail clipped with `[…]`). The system prompt demands strict JSON: `{"feedback":[{"type":"gap","text":"…","suggestion":"…"}]}`.
- **`FeedbackParser`** — forgiving: strips code fences, extracts the first balanced JSON value (string/escape aware), and salvages complete items from a truncated array. Loose `type` strings are mapped onto `FeedbackKind` by substring.
- **`FeedbackEngine`** — skips content under 80 chars (`SkipReason.tooShort`), excluded sections, or when no kinds are enabled; runs in JSON mode; caps results at `tipStyle.maxTips`; filters rejected fingerprints. `.other` is never among the kinds it asks the model for, though the parser still falls back to it when the model names a type Klårt doesn't recognize.

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

**Typewriter scrolling** (`KlartTextView.centerCaretLine`): the line being written is eased to the vertical centre of the window by a critically damped spring re-tuned each frame from the distance left to travel (1.4 s for a one-line nudge, up to 4.0 s for a jump across the note). The scroll view carries a **half-viewport content inset at both ends**, so the first line and the last can each reach the centre — a note therefore **opens already centred** (`viewDidMoveToWindow`, un-animated: there is nothing to travel from), and a new note's cursor sits at writing height before the first keystroke. Reduce Motion applies every position instantly. A trackpad scroll cancels the spring; typing re-engages it.

**Slash commands** (`MarkdownEditor.onCommand`): typing `/editor` at a word boundary summons the editor rail; the command text is removed from the note before the binding updates, so it never reaches disk.

---

## 6. Design System

`Sources/KlartApp/Theme.swift` — the "Quiet" palette: system-adaptive light/dark via dynamic `NSColor`s, one accent color, hairline borders, no glass/glow chrome.

**Monochrome (Teleprompter).** While the Teleprompter surface is active (`Theme.monochrome`, kept in sync with settings by `AppState` before any view builds), every hue collapses to ink: `nsMarker` (markdown syntax markers) resolves to `nsTextSecondary` instead of `nsAccentMuted`, `nsInsertionPoint` to `nsTextPrimary` instead of `nsAccent`, and the surface itself uses only the text/background/border tokens. Feedback kinds are distinguished by **glyph + label + tone, never hue** (which also removes the color-blind dependency):

| Kind | Glyph | Drawn from |
|------|-------|------------|
| Gap | `◇` | something missing — an unfilled shape |
| MECE | `⧉` | two frames colliding — overlap |
| Source | `❝` | a citation to add |
| Structure | `≡` | stacked, level rules — order |
| Clarity | `◎` | a mark resolving into focus |
| Question | `?` | an open, Socratic ask |
| Other | `·` | — |

(`Theme.glyph(for:)`; light/dark still adapts inside monochrome via the dynamic ink tokens.)

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
    public var rejectedFingerprints: [String]   // dismissed-feedback fingerprints
    public var isSensitive: Bool                 // refuses non-local AI when true
}
```
`title` and `preview` are computed from `content` (see §3.1).

### 7.2 Feedback (`Feedback.swift`)

```swift
public enum FeedbackKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case gap, mece, source, structure, clarity, question, other
    // .label, .instruction (model guidance), .defaultEnabled, .fromModelString(_:)
}

public struct FeedbackItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: FeedbackKind
    public let text: String          // the observation
    public let suggestion: String?   // optional insertable content
    public let section: String?      // referenced section title
    // .fingerprint — FNV-1a over kind + normalized text
}
```

### 7.3 Settings (`Settings.swift`)

```swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var activeProvider: ProviderKind               // default .ollama
    public var providers: [ProviderKind: ProviderConfig]
    public var enabledFeedbackKinds: [FeedbackKind]       // default FeedbackKind.defaultEnabled
    public var tipStyle: TipStyle
    public var debounceSeconds: Double                    // default 2.5 (clamped 0.5…15)
    public var autoFeedback: Bool                         // default true
    public var temperature: Double                        // default 0.4 (clamped 0…2)
    public var maxTokens: Int                             // default 1024 (clamped 64…8192)
    public var vault: VaultConfig?                        // nil = encryption off
    public var autoLockMinutes: Int                       // default 15 (clamped 0…240; 0 = never)
    public var lockOnScreenSleep: Bool                    // default true
    public var excludeFromCapture: Bool                   // default true
    public var teleprompterMode: Bool                     // default true (§3.5; off = classic layout)
    public var showWordCount: Bool                        // default false (word count + reading time)
}

public struct TipStyle: Codable, Equatable, Sendable {
    public var tone: FeedbackTone        // neutral | academic | direct | encouraging
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

1. **Interface** — Teleprompter mode on/off (§3.5), word count + estimated reading time on/off.
2. **AI Provider** — active provider (Ollama / LM Studio / OpenRouter / Custom), endpoint, model (with live **Test Connection** model list), API key (stored in Keychain), temperature, max tokens.
3. **Editor** — enabled feedback kinds, tip style (tone, detail, max tips, language, custom guidance), auto-analysis toggle and debounce.
4. **Security** — enable/disable the encrypted vault, Touch ID unlock, auto-lock timeout, lock-on-sleep, exclude-from-capture, change password, key rotation.

Out-of-range values are clamped on decode (see §7.3).

---

## 10. Build & Distribution

### 10.1 Commands

```bash
cd KlartMac
swift run                  # development
swift test                 # unit tests (KlartKitTests)
bash Scripts/make-app.sh   # release build → dist/Klart.app (verifies Hardened Runtime + App Sandbox)
bash Scripts/make-dmg.sh   # package → dist/Klart.dmg
bash Scripts/notarize-app.sh   # submit to Apple + staple
```

### 10.2 Distribution

- **Format:** signed `Klart.app` and `Klart.dmg`. Single platform: **macOS**, built for the architecture of the build machine — `make-app.sh` is a plain `swift build -c release`, so nothing here produces a universal binary.
- **Signing:** Developer ID + **Hardened Runtime** + **App Sandbox** (outgoing network only, plus user-picked files for export/import). `make-app.sh` fails the build if either flag is missing from the signature.
- **CI:** `.github/workflows/macos-app.yml` builds, tests, and packages on every push to `main` or a `claude/**` branch that touches `KlartMac/`; uploads `Klart.app` and (ad-hoc or Developer-ID-signed) `Klart.dmg` artifacts, and on `main` refreshes the `latest` GitHub release with the DMG so there is one permanent download link that needs no login. Full signing/notarization secrets are documented in `KlartMac/README.md`.

### 10.3 Tests

`Tests/KlartKitTests/` (XCTest) covers: Argon2id KAT + vault KDF upgrades (`Argon2Tests`), forgiving JSON parsing (`FeedbackParserTests`), v3 crypto / padding / rotation / audit chain / provider locality (`HardeningTests`), transport security (`LLMHTTPTests`), outline parsing incl. code fences and `[no-ai]` (`OutlineTests`), prompt/engine/insertion (`PromptAndEngineTests`), storage & settings round-trips and clamps (`StorageAndSettingsTests`), vault crypto (`VaultCryptoTests`), end-to-end vault lifecycle (`VaultLifecycleTests`), the shared ATX heading rule (`MarkdownHeadingTests`), word count and reading time (`NoteMetricsTests`), and note titles and previews (`NoteTests`).

---

*Document reflects the native Swift/SwiftUI implementation in `KlartMac/`. For narrative setup and distribution detail, see [KlartMac/README.md](../KlartMac/README.md).*
