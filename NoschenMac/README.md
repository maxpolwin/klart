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
- **Secure by default** — API keys live in the macOS Keychain, never in settings files. Plain HTTP is enforced in code to local hosts only (loopback, RFC 1918/link-local addresses, `.local`/`.lan` names); every remote endpoint must be HTTPS. Packaged builds are signed with the **Hardened Runtime** and run in the **App Sandbox** (outgoing network only, no file access beyond the app's own container) — `make-app.sh` verifies both flags are present in the signature and fails the build otherwise.
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

Only the relevant slice of the note you're editing is sent to the provider you configured, when you pause typing or invoke the coach. With Ollama or LM Studio, everything stays on your machine.

## License

MIT — same as the repository.
