# Noschen — Product Requirements Document

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

Noschen is a **thinking coach that lives in your notes** — a minimal, native macOS app for structuring your thinking in markdown. As you write, a local or cloud LLM reads the section you're working on (in the context of the whole document) and coaches you: it points out gaps, overlapping categories, vague claims, and structural problems, and can ask Socratic questions instead of writing your notes for you.

### 1.2 Key Value Propositions

- **Coaching, not ghostwriting** — the AI critiques and questions; it never edits the document without an explicit accept.
- **Local-first & private** — notes are plain markdown files on your machine; API keys live in the macOS Keychain; no telemetry. Optional at-rest encryption with app lock.
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

`Package.swift` declares one package (`Noschen`) with:

**Products**
- `.library("NoschenKit")` — platform-independent, unit-tested core
- `.executable("Noschen")` — the SwiftUI app

**Targets**
- **`CArgon2`** — plain C target (`Sources/CArgon2`): vendored, hash-pinned PHC reference Argon2, compiled in-tree (nothing fetched at build time). Public headers in `include/`.
- **`NoschenKit`** — depends on `CArgon2`. Core models, markdown parsing, storage, LLM clients, feedback engine.
- **`Noschen`** — executable, depends on `NoschenKit`. SwiftUI app (`Sources/NoschenApp`). Embeds `Resources/Info.plist` into the binary via a linker `-sectcreate` flag so `swift run` gets App Transport Security exceptions for localhost providers.
- **`NoschenKitTests`** — XCTest suite against `NoschenKit`.

```
NoschenMac/
├── Package.swift
├── Sources/
│   ├── CArgon2/                  Vendored Argon2 (C)
│   ├── NoschenKit/               Core (library, unit-tested)
│   │   ├── Models/               Note, Settings, Feedback
│   │   ├── Markdown/             Outline parser (UTF-16 offsets ↔ cursor)
│   │   ├── Storage/              NoteStore (actor), SettingsStore, Keychain, VaultCrypto
│   │   ├── LLM/                  LLMClient, Ollama + OpenAI-compatible clients
│   │   └── Feedback/             PromptBuilder, FeedbackParser, FeedbackEngine
│   └── NoschenApp/               SwiftUI app (macOS-only)
│       ├── AppState.swift        Single source of truth, debounce/cancellation
│       ├── Theme.swift           Design tokens
│       └── Views/                Sidebar, editor, coach panel, settings, lock
└── Tests/NoschenKitTests/
```

### 2.3 Data flow

The renderer/main-process split of the old Electron build is gone. `AppState` (an observable object) is the single source of truth; it debounces edits, cancels in-flight analyses on new keystrokes, and calls into `NoschenKit` (`NoteStore` actor for I/O, `FeedbackEngine` for coaching). Views are pure SwiftUI except the editor, which bridges to an `NSTextView` for markdown styling.

---

## 3. Core Features

### 3.1 Note Management

| Feature | Description |
|---------|-------------|
| Create | New note (`⌘N`); UUID identity |
| Edit | Plain-text markdown with live styling |
| Save | Debounced autosave (atomic writes); `⌘S` to save now |
| Delete | Remove note |
| Title | Computed: first non-empty line, leading `#` stripped, ≤80 chars, else "Untitled" |
| Preview | Computed: first non-heading line after the title, ≤120 chars |
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
| `other` | Note | ⬜ | Uncategorized (filtered out of results) |

Default enabled set is `[gap, mece, structure, clarity, question]`.

**Item actions:** **Insert** (adds the suggestion into the note as a `> ✎ <label>:` blockquote at the section end) or **Dismiss** (hidden permanently for that note). Dismissals are remembered by a content **fingerprint** (FNV-1a over `kind + normalized text`), so regeneration doesn't resurface them.

### 3.3 Coach actions

Four one-tap actions (`CoachAction`), also in the **Coach** menu, that stream a response (< 250 words) into the popover:

| Action | Label |
|--------|-------|
| `askQuestions` | Ask me questions (three numbered Socratic questions) |
| `challenge` | Challenge my thinking (weakest assumptions + counter-arguments) |
| `summarize` | Mirror my argument (reflect the claim + unsupported points) |
| `nextSteps` | Suggest next steps (three specific next actions) |

### 3.4 Section control

Any heading tagged `[no-ai]` (case-insensitive, e.g. `## Private notes [no-ai]`) excludes that section from analysis. Any note can be marked **sensitive** (toolbar shield); sensitive notes refuse all non-local AI requests in code (see §4.3).

---

## 4. AI Integration

### 4.1 Providers

`ProviderKind` and its defaults (`Sources/NoschenKit/Models/Settings.swift`):

| Provider | Display name | Default endpoint | Default model | API key | Insecure HTTP allowed |
|----------|-------------|------------------|---------------|:---:|:---:|
| `ollama` | Ollama | `http://localhost:11434` | `llama3.2` | — | ✅ (local) |
| `lmstudio` | LM Studio | `http://localhost:1234/v1` | — | — | ✅ (local) |
| `openrouter` | OpenRouter | `https://openrouter.ai/api/v1` | `anthropic/claude-haiku-4.5` | Keychain | ❌ |
| `custom` | Custom (OpenAI-compatible) | `http://localhost:8080/v1` | — | optional | ✅ (local) |

**Clients** (`Sources/NoschenKit/LLM/`):
- **`OllamaClient`** — native Ollama API. `listModels()` → GET `api/tags`; chat → POST `api/chat` with `options.num_predict`, `format: "json"` in JSON mode; newline-delimited JSON streaming.
- **`OpenAICompatClient`** — LM Studio, OpenRouter, custom. `listModels()` → GET `models`; chat → POST `chat/completions` with `max_tokens`, SSE streaming; API key as `Authorization: Bearer …`.
- **`ProviderFactory`** builds the right client. OpenRouter adds `HTTP-Referer` / `X-Title` headers. **Test Connection** in Settings fetches the live model list.

### 4.2 Prompting & parsing

- **`PromptBuilder`** — assembles the coaching prompt from the current section plus the outline; budgets: `sectionBudget = 8000`, `coachBudget = 12000` chars (over-budget text is head+tail clipped with `[…]`). The system prompt demands strict JSON: `{"feedback":[{"type":"gap","text":"…","suggestion":"…"}]}`.
- **`FeedbackParser`** — forgiving: strips code fences, extracts the first balanced JSON value (string/escape aware), and salvages complete items from a truncated array. Loose `type` strings are mapped onto `FeedbackKind` by substring.
- **`FeedbackEngine`** — skips content under 80 chars (`SkipReason.tooShort`), excluded sections, or when no kinds are enabled; runs in JSON mode; caps results at `tipStyle.maxTips`; filters rejected fingerprints and drops `.other`.

### 4.3 Transport security & sensitive-note enforcement

`LLMHTTP` (in `LLMClient.swift`) normalizes every base URL:
- HTTPS is always accepted; plain `http` is accepted **only** for local hosts (`localhost`, loopback, RFC 1918 / CGNAT / link-local ranges, IPv6 ULA/link-local, single-label hostnames, and `.local`/`.lan`/`.internal`/`.home.arpa` suffixes). A remote `http` URL throws `LLMError.insecureURL`.
- **`ProviderFactory.isLocal`** decides local-vs-cloud by the **resolved endpoint host**, not the provider label — a Custom provider pointed at a remote host counts as cloud. Sensitive notes are refused whenever the resolved endpoint is not local. This is enforced at request time, not just hidden in the UI.

---

## 5. Editor & Markdown

The editor (`Sources/NoschenApp/Views/EditorView.swift`) is a plain-text `NSTextView` (`NoschenTextView`) with live, per-paragraph styling — markdown stays markdown, it is never converted to rich text. It re-styles per paragraph while typing and fully on paste / note-switch. A fresh editor (and undo stack) is created per note.

**Constructs styled/handled** (`EditorStyler`):

| Construct | Behavior |
|-----------|----------|
| ATX headings `#`–`######` | Leading marker kept body-size and dimmed; only heading text enlarged. H1 26 / H2 20 / H3 17 / H4–H6 15 pt, semibold |
| Fenced code blocks ` ``` ` / `~~~` | Rendered verbatim in code font; contents never parsed as headings/lists/emphasis. Open-fence state scanned from top of document |
| Lists `-` `*` `+` `1.` `1)` | Markers tinted; continue on <kbd>Enter</kbd> (ordered numbers increment, indent preserved); empty item + Enter exits the list; suppressed inside code fences and on horizontal rules |
| Task lists `- [ ]` / `- [x]` | Checkbox dimmed; checked items struck through and dimmed |
| Inline `**bold**` / `*italic*` / `_italic_` / `` `code` `` | Styled inline; syntax markers dimmed at the edges |
| Strikethrough `~~text~~` | Single strikethrough; edge markers dimmed |
| Blockquote `>` | Dimmed 14 pt; inline emphasis still applied inside |
| Horizontal rules `---` / `***` / `___` | Dimmed |
| Escaped `\*` `` \` `` `\_` | Not treated as emphasis/code |

**Outline** (`Sources/NoschenKit/Markdown/Outline.swift`): `DocumentOutline.parse` builds `OutlineSection`s with **UTF-16 offsets** (matching the `NSTextView` cursor) — `level`, `title`, `headingStart`, `bodyStart`, `bodyEnd`, `excludedFromAI`. Headings inside code fences are ignored; a trailing `[no-ai]` marks a section excluded. This is the structure the coach uses to know your topic (first H1), which section you're editing, and what the other sections cover.

---

## 6. Design System

`Sources/NoschenApp/Theme.swift` — the "Quiet" palette: system-adaptive light/dark via dynamic `NSColor`s, one accent color, hairline borders, no glass/glow chrome.

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

---

## 7. Data Models

`Sources/NoschenKit/Models/`. All types are `Codable, Sendable`, with lenient decoding (every field falls back to a default).

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
| Notes | `~/Library/Application Support/Noschen/Notes/<UUID>.json` (pretty JSON, atomic) |
| Settings | `~/Library/Application Support/Noschen/settings.json` |
| API keys | macOS Keychain, service `com.noschen.mac`, account `noschen.apikey.<provider>` |
| Telemetry | none |

`NoteStore` is a Swift `actor`; it refuses writes while the vault is locked. The sandboxed packaged app resolves the base path to its container; an unsandboxed `swift run` build uses `~/Library/Application Support` directly.

---

## 9. Settings & Configuration

Settings UI (`Sources/NoschenApp/Views/SettingsView.swift`) covers:

1. **AI Provider** — active provider (Ollama / LM Studio / OpenRouter / Custom), endpoint, model (with live **Test Connection** model list), API key (stored in Keychain), temperature, max tokens.
2. **Coaching** — enabled feedback kinds, tip style (tone, detail, max tips, language, custom guidance), auto-analysis toggle and debounce.
3. **Security** — enable/disable the encrypted vault, Touch ID unlock, auto-lock timeout, lock-on-sleep, exclude-from-capture, key rotation.

Out-of-range values are clamped on decode (see §7.3).

---

## 10. Build & Distribution

### 10.1 Commands

```bash
cd NoschenMac
swift run                  # development
swift test                 # unit tests (NoschenKitTests)
bash Scripts/make-app.sh   # release build → dist/Noschen.app (verifies Hardened Runtime + App Sandbox)
bash Scripts/make-dmg.sh   # package → dist/Noschen.dmg
bash Scripts/notarize-app.sh   # submit to Apple + staple
```

### 10.2 Distribution

- **Format:** signed `Noschen.app` and `Noschen.dmg`. Single platform: **macOS** (universal, per Xcode toolchain).
- **Signing:** Developer ID + **Hardened Runtime** + **App Sandbox** (outgoing network only, plus user-picked files for export/import). `make-app.sh` fails the build if either flag is missing from the signature.
- **CI:** `.github/workflows/macos-app.yml` builds, tests, and packages on every push; uploads `Noschen.app` and (ad-hoc or Developer-ID-signed) `Noschen.dmg` artifacts. Full signing/notarization secrets are documented in `NoschenMac/README.md`.

### 10.3 Tests

`Tests/NoschenKitTests/` (XCTest) covers: Argon2id KAT + vault KDF upgrades (`Argon2Tests`), forgiving JSON parsing (`FeedbackParserTests`), v3 crypto / padding / rotation / audit chain / provider locality (`HardeningTests`), transport security (`LLMHTTPTests`), outline parsing incl. code fences and `[no-ai]` (`OutlineTests`), prompt/engine/insertion (`PromptAndEngineTests`), storage & settings round-trips and clamps (`StorageAndSettingsTests`), vault crypto (`VaultCryptoTests`), and end-to-end vault lifecycle (`VaultLifecycleTests`).

---

*Document reflects the native Swift/SwiftUI implementation in `NoschenMac/`. For narrative setup and distribution detail, see [NoschenMac/README.md](../NoschenMac/README.md).*
