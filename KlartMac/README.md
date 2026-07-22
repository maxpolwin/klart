# Klårt for macOS (Swift-native)

**A thinking coach that lives in your notes.**

Klårt is a minimal, native macOS app for structuring your thinking in markdown. As you write, a local or cloud LLM reads the section you're working on — in the context of your whole document — and coaches you: it points out gaps, overlapping categories, vague claims, and better structure, and it can ask you Socratic questions instead of giving answers.

This is the native Swift/SwiftUI rebuild of the original Electron prototype. It is faster, lighter (~5 MB app, no bundled browser), and integrates flexibly with **Ollama**, **LM Studio**, **OpenRouter**, and any OpenAI-compatible endpoint.

---

## Highlights

- **Native SwiftUI, "Teleprompter" design** — the default surface is one centered, monochrome column and nothing else: no sidebar, no toolbar, no persistent AI chrome. Notes wait behind the left edge (move the pointer there for a spine of dots; dwell 0.8 s for the full panel with titles, dates, and search). The AI editor works in the background and appears only when summoned (`⌘E`, the ¶ icon in the panel, or typing `/editor`): margin notes on the right, matched to the text sections they refer to, marked with glyphs (◇ ⧉ ❝ ≡ ◎ ?) instead of colored pills — and they fade back out while you keep writing. The classic "Quiet" layout (sidebar, accent color, toolbar pill) is a toggle in Settings → Interface. No Electron, no web view.
- **Markdown-ready editor** — headings resize live as you type (`#`, `##`, `###`), list markers are tinted and quote lines dimmed, `- [x]` items strike through, and `**bold**`, `*italic*`, `` `code` ``, and `~~strikethrough~~` style inline while the text stays plain markdown. The syntax markers are hidden on every line except the one you're editing, and Return continues a `- ` or `1. ` list — pressing it on an empty item ends the list instead.
- **Local-first** — notes are plain JSON-wrapped markdown files in `~/Library/Application Support/Klart/Notes`. Nothing leaves your machine unless you choose a cloud provider.
- **Any LLM** — Ollama (native API), LM Studio, OpenRouter, or any OpenAI-compatible server (llama.cpp, vLLM, LocalAI, corporate gateways). Model lists are fetched live from the provider.
- **Coaching, not ghostwriting** — feedback types: **Gap**, **MECE**, **Source**, **Structure**, **Clarity**, and **Question** (Socratic). Plus one-tap coach actions: *Ask me questions*, *Challenge my thinking*, *Mirror my argument*, *Suggest next steps* (streamed live).
- **Feedback you control** — accept a tip to insert it as a quoted block at the end of the section you're writing in; dismiss it and it never comes back for that note. Tune tone, detail, language, tips-per-round, and add your own standing guidance.
- **Context-aware** — the coach knows your H1 topic, the section you're editing, and the titles of the other sections, so MECE and gap analysis are about the *document*, not the paragraph. Mark any section `[no-ai]` to exclude it.
- **Secure by default** — API keys live in the macOS Keychain, never in settings files. Plain HTTP is enforced in code to local hosts only (loopback, RFC 1918/link-local addresses, `.local`/`.lan` names) and Settings shows a notice whenever an endpoint is unencrypted; every remote endpoint must be HTTPS. Packaged builds are signed with the **Hardened Runtime** and run in the **App Sandbox** (outgoing network only, plus files the user explicitly picks for export/import) — `make-app.sh` verifies both flags are present in the signature and fails the build otherwise.
- **Optional note encryption + app lock** — Settings → Security encrypts every note file at rest with **AES-256-GCM** (FIPS-approved) under a **per-note subkey** derived via HKDF-SHA256 from a random master key, with the note's identity as AAD — a sealed file copied under another note's name fails to decrypt instead of impersonating it — and file sizes padded to 4 KiB buckets so they don't reveal note sizes. The master key is wrapped by your password via **Argon2id** (memory-hard: 128 MiB, 3 passes, 4 lanes, NFC-normalized — the vendored, hash-pinned PHC reference implementation, see `Sources/CArgon2/THIRD_PARTY.md`; legacy PBKDF2 vaults upgrade automatically on the next password unlock) and held in **mlocked, zeroized-on-lock memory** while unlocked. Optional Touch ID unlock: on Apple Silicon / T2 the key copy is encrypted to a **Secure Enclave** P-256 key that demands user presence on every decrypt; older Macs fall back to a user-presence Keychain control. The app starts locked, locks with `⌘L`, **auto-locks** on screen sleep/lock and after a configurable idle timeout, and repeated wrong passwords throttle with growing delays. A **key rotation** action re-encrypts the library under a fresh master key (crash-safe and resumable). Legacy v1/v2 (ChaCha20-Poly1305) files stay readable and upgrade on save. There is no recovery backdoor: a forgotten password (with Touch ID off) means the notes are gone — keep a markdown export. FIDO2 hardware keys (YubiKey) are not supported: macOS exposes no public API to derive stable encryption secrets from a security key for app-local vaults.
- **Sensitive notes never touch the cloud** — mark any note via **File ▸ Mark Sensitive** (or the shield beside the note's title — the toolbar shield in the classic layout) and every AI request for it is refused *in code* unless the resolved endpoint is local (Ollama, LM Studio, or another on-machine/LAN server). A "Custom" provider pointed at a remote host counts as cloud. The block is enforced at request time, not just hidden in the UI.
- **Ambient anti-exposure** — the window is excluded from screenshots, screen recordings, and screen sharing by default, protection or not (the toggle appears in Settings → Security once protection is set up); copies from a protected library clear the clipboard after 45 seconds unless something else was copied; core dumps are disabled and release builds deny debugger attachment; a hash-chained local **audit log** (`audit.log`) records lock/unlock/rotation events — never content — and any tampering with it is detectable.
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
cd KlartMac

# Run directly (development)
swift run

# Run the tests
swift test

# Build a distributable app bundle → dist/Klart.app
bash Scripts/make-app.sh
```

### Develop in Xcode

**Fastest — open the Swift package directly** (no extra tooling):

```bash
cd KlartMac
xed .            # equivalently: open Package.swift
```

Xcode indexes the package and gives you a **Klart** run scheme, breakpoints, and live rebuilds. Running this way launches the bare executable rather than a sandboxed `.app`, so notes land in `~/Library/Application Support/Klart` and the vault/Touch-ID features behave like an unsandboxed dev build.

**Full-fidelity app bundle** — to run Klårt in Xcode exactly as it ships (App Sandbox, entitlements, Keychain container), generate a real app target with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
bash Scripts/generate-xcodeproj.sh   # writes Klart.xcodeproj (git-ignored) and opens it
```

The project is described by [`project.yml`](project.yml) and regenerated on demand, so it never drifts from the sources — **edit `project.yml`, not the generated `.xcodeproj`.** On first run, open the **Klart** target's *Signing & Capabilities* tab and pick your Team (a free Apple ID works) so the sandboxed build can reach the Keychain. Unit tests still run from the command line with `swift test`.

CI (see `.github/workflows/macos-app.yml`) builds and tests the app on every push to `main` or a `claude/**` branch that touches `KlartMac/` or the workflow itself, uploads a ready-to-run `Klart.app` and `Klart.dmg` as workflow artifacts, and on pushes to `main` publishes the DMG as a rolling GitHub Release — always downloadable at:

```
https://github.com/maxpolwin/klart/releases/latest/download/Klart.dmg
```

Until the signing/notarization secrets below are configured, that DMG is only ad-hoc signed and still shows a Gatekeeper warning for anyone besides the machine that built it (the release notes on each build say which state it's in). For a DMG you can hand to other people with no warning, either configure the CI secrets (see "Distributing to testers" below) or build and notarize it locally with your own Developer ID:

```bash
ID="Developer ID Application: Your Name (TEAM1234ID)"   # from: security find-identity -v -p codesigning

SIGN_IDENTITY="$ID" bash Scripts/make-app.sh    # build + sign Klart.app
SIGN_IDENTITY="$ID" bash Scripts/make-dmg.sh    # package + sign dist/Klart.dmg
bash Scripts/notarize-app.sh                    # submit to Apple, staple the ticket
```

The last step needs a paid Apple Developer Program membership and one-time notarization credentials (an app-specific password, stored via `xcrun notarytool store-credentials`) — see the comments at the top of `Scripts/notarize-app.sh` for the exact commands. Verify the result with `spctl --assess --verbose dist/Klart.dmg`, which should print `accepted`.

## Distributing to testers (CI-signed builds)

Once the following repository secrets exist (GitHub → Settings → Secrets and variables → Actions), every CI run on `main` produces a Developer-ID-signed — and, with the notary secrets, notarized and stapled — `Klart.dmg`, published straight to the rolling release above, no Gatekeeper warning:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | Your Developer ID Application certificate + private key as base64. Export from Keychain Access (select the certificate → File → Export Items → `.p12`), then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | The password you set on that `.p12` export |
| `MACOS_SIGN_IDENTITY` | The identity string, e.g. `Developer ID Application: Your Name (TEAM1234ID)` — from `security find-identity -v -p codesigning` |
| `NOTARY_APPLE_ID` | Apple ID email of your developer account *(optional — enables notarization)* |
| `NOTARY_TEAM_ID` | Your team ID, from developer.apple.com → Membership |
| `NOTARY_PASSWORD` | An app-specific password from appleid.apple.com — **not** your Apple ID password |

With no secrets configured the workflow keeps working and falls back to ad-hoc signing (fine for CI checks, not for handing out). The certificate is imported into a throwaway CI keychain with a random password and never touches the repository.

## Using Klårt

1. Create a note (`⌘N`). Give it a `# Topic` heading and `## Sub-question` sections.
2. Write. After a pause (configurable, default 2.5 s), the editor reads the section you're in — silently, in the background. Nothing appears mid-screen.
3. Summon the editor with `⌘E`, by typing `/editor`, or via the ¶ icon in the notes panel: its notes appear in the right margin, each aligned with the section it refers to. **Insert** puts a suggestion into your note as a `> ✎` quote block for you to rework; **Dismiss** hides that tip permanently for this note. `⌘E` again — or the chevron at the rail's near edge, right where the writing column ends — puts the margin notes away; otherwise keep writing and they fade out on their own (after 5 more minutes of typing, over 20 seconds).
4. Your notes live behind the left edge: move the pointer there for the dot spine, rest on it for 0.8 s for the full panel (titles, last edited, shield marks, search — `⌘F` jumps straight there).
5. Use the coach actions any time from the **Editor** menu — their reply streams into the coach popover, which only the classic layout puts on screen. `⌘R` analyzes on demand; auto-analysis can be turned off entirely in Settings → Editor.
6. Add `[no-ai]` to a heading (e.g. `## Private notes [no-ai]`) to keep the coach out of that section.
7. Prefer the classic sidebar-and-toolbar layout, or want word count and reading time at the foot of the page? Settings → Interface.

## Provider setup (Settings → AI Provider)

| Provider | Default endpoint | API key | Notes |
|---|---|---|---|
| Ollama | `http://localhost:11434` | — | Native Ollama API, JSON mode enforced for reliable feedback |
| LM Studio | `http://localhost:1234/v1` | — | OpenAI-compatible local server |
| OpenRouter | `https://openrouter.ai/api/v1` | Keychain | HTTPS enforced; any OpenRouter model id works |
| Custom | `http://localhost:8080/v1` | optional | Any OpenAI-compatible `/chat/completions` server — the default is a starting point, edit it to your own |

**Test Connection** fetches the provider's live model list; pick a model from the dropdown or type any model id.

## Architecture

```
KlartMac/
├── Package.swift                 SwiftPM: KlartKit (library) + Klart (app)
├── Sources/
│   ├── CArgon2/                Vendored PHC reference Argon2id, compiled in-tree
│   ├── KlartKit/               Platform-independent core (unit-tested)
│   │   ├── Models/               Note, Settings, Feedback types
│   │   ├── Markdown/             Outline parser (UTF-16 offsets ↔ editor cursor), heading syntax, word count
│   │   ├── Storage/              NoteStore (actor, atomic JSON), SettingsStore, Keychain
│   │   ├── LLM/                  LLMClient protocol, Ollama + OpenAI-compatible clients
│   │   └── Feedback/             PromptBuilder, robust FeedbackParser, FeedbackEngine
│   └── KlartApp/               SwiftUI app (macOS-only)
│       ├── AppState.swift        Single source of truth, debounce/cancellation logic
│       └── Views/                Teleprompter surface, sidebar, NSTextView markdown editor, coach panel, settings
├── Tests/KlartKitTests/        Outline, parser, prompts, engine, storage, settings, vault crypto
└── Scripts/make-app.sh           Release build → signed Klart.app
```

Design decisions worth knowing:

- **The parser is forgiving.** Small local models wrap JSON in prose and code fences, or get truncated mid-answer. The feedback parser extracts the first balanced JSON value (string-and-escape aware) and can salvage complete items from a truncated array.
- **Dismissals are fingerprinted.** A dismissed tip is remembered by a normalized content hash per note, so regeneration doesn't resurface it.
- **The editor is plain text.** Markdown stays markdown; headings and quote blocks are styled live (per-paragraph, so large notes stay fast), not converted.

## Data & privacy

| What | Where |
|---|---|
| Notes | `…/Application Support/Klart/Notes/*.json` |
| Settings | `…/Application Support/Klart/settings.json` (never contains keys) |
| Security log | `…/Application Support/Klart/audit.log` (lock, unlock, rotation events — never content) |
| API keys | macOS Keychain (`com.klart.mac`) |
| Telemetry | none |

The `…` base depends on how you run Klårt: the sandboxed packaged app resolves to its container (`~/Library/Containers/com.klart.mac/Data/Library/Application Support/…`), while an unsandboxed `swift run` dev build uses `~/Library/Application Support/…` directly. If you move from a dev build to the packaged app, copy the `Klart` folder across once.

**Reinstalls:** deleting the app does *not* delete your notes — the container (and the unsandboxed path) survive uninstall/reinstall, including App Store reinstalls, as long as the bundle ID stays `com.klart.mac`. Only manually deleting `~/Library/Containers/com.klart.mac` (or an "app cleaner" tool doing it for you) removes them. For belt-and-braces, File → Export Notes as Markdown… gives you a plaintext backup you can re-import on any machine.

When you pause typing, only the section you're editing is sent to the provider you configured; a coach action sends the whole note, because mirroring or challenging an argument needs all of it. Both are clipped to a character budget before they leave. With Ollama or LM Studio, everything stays on your machine.

## License

MIT — same as the repository.
