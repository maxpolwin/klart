# Noschen for macOS (Swift-native)

**A thinking coach that lives in your notes.**

Noschen is a minimal, native macOS app for structuring your thinking in markdown. As you write, a local or cloud LLM reads the section you're working on — in the context of your whole document — and coaches you: it points out gaps, overlapping categories, vague claims, and better structure, and it can ask you Socratic questions instead of giving answers.

This is the native Swift/SwiftUI rebuild of the original Electron app (still in the repository root). It is faster, lighter (~5 MB app, no bundled browser), and integrates flexibly with **Ollama**, **LM Studio**, **OpenRouter**, and any OpenAI-compatible endpoint.

---

## Highlights

- **Native SwiftUI, "Quiet" design** — follows the system light/dark appearance, one accent color, a translucent sidebar, and no persistent AI chrome: suggestions wait behind a small pill in the toolbar ("3 ready") until summoned with a click or `⌘.`. No Electron, no web view.
- **Markdown-ready editor** — headings resize live as you type (`#`, `##`, `###`), list markers and quotes are tinted, and `**bold**`, `*italic*`, and `` `code` `` style inline while the text stays plain markdown.
- **Local-first** — notes are plain JSON-wrapped markdown files in `~/Library/Application Support/Noschen/Notes`. Nothing leaves your machine unless you choose a cloud provider.
- **Any LLM** — Ollama (native API), LM Studio, OpenRouter, or any OpenAI-compatible server (llama.cpp, vLLM, LocalAI, corporate gateways). Model lists are fetched live from the provider.
- **Coaching, not ghostwriting** — feedback types: **Gap**, **MECE**, **Source**, **Structure**, **Clarity**, and **Question** (Socratic). Plus one-tap coach actions: *Ask me questions*, *Challenge my thinking*, *Mirror my argument*, *Suggest next steps* (streamed live).
- **Feedback you control** — accept a tip to insert it as a quoted block in the right section; dismiss it and it never comes back for that note. Tune tone, detail, language, tips-per-round, and add your own standing guidance.
- **Context-aware** — the coach knows your H1 topic, which H2 section you're editing, and what the other sections cover, so MECE and gap analysis are about the *document*, not the paragraph. Mark any section `[no-ai]` to exclude it.
- **Secure by default** — API keys live in the macOS Keychain, never in settings files. Plain HTTP is enforced in code to local hosts only (loopback, RFC 1918/link-local addresses, `.local`/`.lan` names) and Settings shows a notice whenever an endpoint is unencrypted; every remote endpoint must be HTTPS. Packaged builds are signed with the **Hardened Runtime** and run in the **App Sandbox** (outgoing network only, plus files the user explicitly picks for export/import) — `make-app.sh` verifies both flags are present in the signature and fails the build otherwise.
- **Optional note encryption + app lock** — Settings → Security encrypts every note file at rest with **AES-256-GCM** (FIPS-approved) under a **per-note subkey** derived via HKDF-SHA256 from a random master key, with the note's identity as AAD — a sealed file copied under another note's name fails to decrypt instead of impersonating it — and file sizes padded to 4 KiB buckets so they don't reveal note sizes. The master key is wrapped by your password (PBKDF2-HMAC-SHA256, 600k rounds, NFC-normalized) and held in **mlocked, zeroized-on-lock memory** while unlocked. Optional Touch ID unlock: on Apple Silicon / T2 the key copy is encrypted to a **Secure Enclave** P-256 key that demands user presence on every decrypt; older Macs fall back to a user-presence Keychain control. The app starts locked, locks with `⌘L`, **auto-locks** on screen sleep/lock and after a configurable idle timeout, and repeated wrong passwords throttle with growing delays. A **key rotation** action re-encrypts the library under a fresh master key (crash-safe and resumable). Legacy v1/v2 (ChaCha20-Poly1305) files stay readable and upgrade on save. There is no recovery backdoor: a forgotten password (with Touch ID off) means the notes are gone — keep a markdown export. FIDO2 hardware keys (YubiKey) are not supported: macOS exposes no public API to derive stable encryption secrets from a security key for app-local vaults.
- **Sensitive notes never touch the cloud** — mark any note with the shield in the toolbar and every AI request for it is refused *in code* unless the resolved endpoint is local (Ollama, LM Studio, or another on-machine/LAN server). A "Custom" provider pointed at a remote host counts as cloud. The block is enforced at request time, not just hidden in the UI.
- **Ambient anti-exposure** — the window can be excluded from screenshots, screen recordings, and screen sharing (on by default with protection); copies from a protected library clear the clipboard after 45 seconds unless something else was copied; core dumps are disabled and release builds deny debugger attachment; a hash-chained local **audit log** (`audit.log`) records lock/unlock/rotation events — never content — and any tampering with it is detectable.
- **Markdown export/import** — File → Export Notes as Markdown… writes every note as a plain `.md` file to a folder you pick (your manual, provider-independent backup); Import Markdown Notes… brings them back, recognizing its own export headers so re-imports update instead of duplicate.
- **Fast** — actor-based file I/O, debounced autosave (atomic writes), per-paragraph editor styling, cancellation-aware feedback pipeline (a new keystroke cancels the in-flight analysis).

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ command line tools (to build)
- An LLM to talk to:
  - [Ollama](https://ollama.com) — `ollama pull llama3.2` (recommended local default)
  - [LM Studio](https://lmstudio.ai) — load a model, start the local server
  - [OpenRouter](https://openrouter.ai) — API key, access to hundreds of cloud models

## Build & run

```bash
cd NoschenMac

# Run directly (development)
swift run

# Run the tests
swift test

# Build a distributable app bundle → dist/Noschen.app
bash Scripts/make-app.sh
```

CI builds and tests the app on every push (see `.github/workflows/macos-app.yml`) and uploads a ready-to-run `Noschen.app` and an ad-hoc-signed `Noschen.dmg` artifact — fine for testing on your own Mac, but ad-hoc signing (no `SIGN_IDENTITY` secret is configured in CI) still shows a Gatekeeper warning for anyone else. For a DMG you can hand to other people with no warning, build and notarize it locally with your own Developer ID:

```bash
ID="Developer ID Application: Your Name (TEAM1234ID)"   # from: security find-identity -v -p codesigning

SIGN_IDENTITY="$ID" bash Scripts/make-app.sh    # build + sign Noschen.app
SIGN_IDENTITY="$ID" bash Scripts/make-dmg.sh    # package + sign dist/Noschen.dmg
bash Scripts/notarize-app.sh                    # submit to Apple, staple the ticket
```

The last step needs a paid Apple Developer Program membership and one-time notarization credentials (an app-specific password, stored via `xcrun notarytool store-credentials`) — see the comments at the top of `Scripts/notarize-app.sh` for the exact commands. Verify the result with `spctl --assess --verbose dist/Noschen.dmg`, which should print `accepted`.

## Distributing to testers (CI-signed builds)

Once the following repository secrets exist (GitHub → Settings → Secrets and variables → Actions), every CI run produces a Developer-ID-signed — and, with the notary secrets, notarized and stapled — `Noschen.dmg` artifact you can hand straight to testers, no Gatekeeper warning:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | Your Developer ID Application certificate + private key as base64. Export from Keychain Access (select the certificate → File → Export Items → `.p12`), then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | The password you set on that `.p12` export |
| `MACOS_SIGN_IDENTITY` | The identity string, e.g. `Developer ID Application: Your Name (TEAM1234ID)` — from `security find-identity -v -p codesigning` |
| `NOTARY_APPLE_ID` | Apple ID email of your developer account *(optional — enables notarization)* |
| `NOTARY_TEAM_ID` | Your team ID, from developer.apple.com → Membership |
| `NOTARY_PASSWORD` | An app-specific password from appleid.apple.com — **not** your Apple ID password |

With no secrets configured the workflow keeps working and falls back to ad-hoc signing (fine for CI checks, not for handing out). The certificate is imported into a throwaway CI keychain with a random password and never touches the repository.

## Using Noschen

1. Create a note (`⌘N`). Give it a `# Topic` heading and `## Sub-question` sections.
2. Write. After a pause (configurable, default 2.5 s), the coach analyzes the section you're in. Nothing appears mid-screen — the toolbar pill just changes to "N ready".
3. Click the pill (or press `⌘.`) to open the coach popover: **Insert** puts a suggestion into your note as a `> ✎` quote block for you to rework; **Dismiss** hides that tip permanently for this note.
4. Use the coach actions any time — they answer in a live stream in the popover, and are also in the **Coach** menu.
5. `⌘R` analyzes on demand; auto-analysis can be turned off entirely in Settings → Coaching.
6. Add `[no-ai]` to a heading (e.g. `## Private notes [no-ai]`) to keep the coach out of that section.

## Provider setup (Settings → AI Provider)

| Provider | Default endpoint | API key | Notes |
|---|---|---|---|
| Ollama | `http://localhost:11434` | — | Native Ollama API, JSON mode enforced for reliable feedback |
| LM Studio | `http://localhost:1234/v1` | — | OpenAI-compatible local server |
| OpenRouter | `https://openrouter.ai/api/v1` | Keychain | HTTPS enforced; any OpenRouter model id works |
| Custom | your URL | optional | Any OpenAI-compatible `/chat/completions` server |

**Test Connection** fetches the provider's live model list; pick a model from the dropdown or type any model id.

## Architecture

```
NoschenMac/
├── Package.swift                 SwiftPM: NoschenKit (library) + Noschen (app)
├── Sources/
│   ├── NoschenKit/               Platform-independent core (unit-tested)
│   │   ├── Models/               Note, Settings, Feedback types
│   │   ├── Markdown/             Outline parser (UTF-16 offsets ↔ editor cursor)
│   │   ├── Storage/              NoteStore (actor, atomic JSON), SettingsStore, Keychain
│   │   ├── LLM/                  LLMClient protocol, Ollama + OpenAI-compatible clients
│   │   └── Feedback/             PromptBuilder, robust FeedbackParser, FeedbackEngine
│   └── NoschenApp/               SwiftUI app (macOS-only)
│       ├── AppState.swift        Single source of truth, debounce/cancellation logic
│       └── Views/                Sidebar, NSTextView markdown editor, coach panel, settings
├── Tests/NoschenKitTests/        Outline, parser, prompts, engine, storage, settings
└── Scripts/make-app.sh           Release build → signed Noschen.app
```

Design decisions worth knowing:

- **The parser is forgiving.** Small local models wrap JSON in prose and code fences, or get truncated mid-answer. The feedback parser extracts the first balanced JSON value (string-and-escape aware) and can salvage complete items from a truncated array.
- **Dismissals are fingerprinted.** A dismissed tip is remembered by a normalized content hash per note, so regeneration doesn't resurface it.
- **The editor is plain text.** Markdown stays markdown; headings and quote blocks are styled live (per-paragraph, so large notes stay fast), not converted.

## Data & privacy

| What | Where |
|---|---|
| Notes | `…/Application Support/Noschen/Notes/*.json` |
| Settings | `…/Application Support/Noschen/settings.json` (never contains keys) |
| API keys | macOS Keychain (`com.noschen.mac`) |
| Telemetry | none |

The `…` base depends on how you run Noschen: the sandboxed packaged app resolves to its container (`~/Library/Containers/com.noschen.mac/Data/Library/Application Support/…`), while an unsandboxed `swift run` dev build uses `~/Library/Application Support/…` directly. If you move from a dev build to the packaged app, copy the `Noschen` folder across once.

**Reinstalls:** deleting the app does *not* delete your notes — the container (and the unsandboxed path) survive uninstall/reinstall, including App Store reinstalls, as long as the bundle ID stays `com.noschen.mac`. Only manually deleting `~/Library/Containers/com.noschen.mac` (or an "app cleaner" tool doing it for you) removes them. For belt-and-braces, File → Export Notes as Markdown… gives you a plaintext backup you can re-import on any machine.

Only the relevant slice of the note you're editing is sent to the provider you configured, when you pause typing or invoke the coach. With Ollama or LM Studio, everything stays on your machine.

## License

MIT — same as the repository.
