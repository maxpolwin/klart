# Klårt for macOS (Swift-native)

**A thinking coach that lives in your notes.**

Klårt is a minimal, native macOS app for structuring your thinking in markdown. As you write, a local or cloud LLM reads the section you're working on — in the context of your whole document — and coaches you: it points out gaps, overlapping categories, vague claims, and better structure, and it can ask you Socratic questions instead of giving answers.

This is the native Swift/SwiftUI rebuild of the original Electron prototype. It is faster, lighter (~5 MB app, no bundled browser), and integrates flexibly with **Ollama**, **LM Studio**, **OpenRouter**, and any OpenAI-compatible endpoint.

---

## Highlights

- **Native SwiftUI, "Teleprompter" design** — the default surface is one centered, monochrome column and nothing else: no sidebar, no toolbar, no persistent AI chrome. Notes wait behind the left edge (move the pointer there for a spine of dots; dwell 0.8 s for the full panel with titles, dates, and search). The AI editor works in the background and appears only when summoned (`⌘E`, the ¶ icon in the panel, or typing `//show`; `//editor` reads the current section at once): margin notes on the right, matched to the text sections they refer to, marked with glyphs (◇ ⧉ ≡ ◎ ❝ ⊢ ⇒ ⇄ ?) instead of colored pills — and they fade back out while you keep writing; when they outgrow the window the rail scrolls rather than stacking them. The classic "Quiet" layout (sidebar, accent color, toolbar pill) is a toggle in Settings → Interface. No Electron, no web view.
- **Markdown-ready editor** — headings resize live as you type (`#`, `##`, `###`), list markers are tinted and quote lines dimmed, `- [x]` items strike through, and `**bold**`, `*italic*`, `` `code` ``, and `~~strikethrough~~` style inline while the text stays plain markdown. The syntax markers are hidden on every line except the one you're editing, and Return continues a `- ` or `1. ` list — pressing it on an empty item ends the list instead.
- **Local-first** — notes are plain JSON-wrapped markdown files in `~/Library/Application Support/Klart/Notes`. Nothing leaves your machine unless you choose a cloud provider.
- **Any LLM** — Ollama (native API), LM Studio, OpenRouter, or any OpenAI-compatible server (llama.cpp, vLLM, LocalAI, corporate gateways). Model lists are fetched live from the provider.
- **Coaching, not ghostwriting** — an opinionated editor: no praise, no hedging, no "consider". It reads a section when you *finish* it (you move on, open a new heading beneath it, or stop for a while — default 20 s), not on every pause in typing. Every note quotes the exact words it is about, states what is wrong, says what it costs the argument, and carries a severity (`!` weakens it, `‼` breaks it). Nine lenses, drawn from Paul–Elder's intellectual standards and Toulmin's anatomy of an argument: **Gap**, **MECE**, **Structure**, **Clarity**, **Evidence**, **Assumption**, **Warrant**, **Counter**, **Question**. Plus one-tap coach actions: *Ask me questions*, *Challenge my thinking*, *Mirror my argument*, *Suggest next steps* (streamed live).
- **Offline checks first** — uncited empirical claims, hedge-word density, undefined acronyms, thin sections, and overlapping headings are caught locally in microseconds, with no model configured at all; each names the rule that fired. The model is told what they found and spends its budget on judgment instead.
- **You write the fix** — **Respond** drops a note into the section it is about as a `> ✎` prompt block and puts the caret on the empty line beneath it; nothing the model wrote ever becomes your text. Or judge it with two glyphs, ✓ (fair) and ✗ (wrong — and it never comes back for those words in that note). A judged note stays put and greys out rather than vanishing, so the rail reads as a record of what you've dealt with; a fresh read replaces only its own section's notes. Tune tone, detail, language, notes-per-read, and add your own standing guidance.
- **A coach that can learn** — verdicts go to a local **learning log**, so recurring blind spots and the effect of a system-prompt edit are measurable. It always records the verdict, the feedback type, and which model and prompt produced the tip — never your writing, unless you switch that on in Settings → Coaching. Notes marked sensitive never contribute their text. The log is encrypted alongside your notes, and only leaves the machine if you export it (with or without note text).
- **Context-aware** — the editor reads the finished section against your whole document, so MECE, gap and counter-argument notes are about the *document*, not the paragraph. Mark any section `[no-ai]` to exclude it: it is never read, and its body is replaced by "(omitted)" in the context sent with every other section.
- **Secure by default** — API keys live in the macOS Keychain, never in settings files. Plain HTTP is enforced in code to local hosts only (loopback, RFC 1918/link-local addresses, `.local`/`.lan` names) and Settings shows a notice whenever an endpoint is unencrypted; every remote endpoint must be HTTPS. Packaged builds are signed with the **Hardened Runtime** and run in the **App Sandbox** (outgoing network only, plus files the user explicitly picks for export/import) — `make-app.sh` verifies both flags are present in the signature and fails the build otherwise.
- **Optional note encryption + app lock** — Settings → Security encrypts every note file at rest with **AES-256-GCM** (FIPS-approved) under a **per-note subkey** derived via HKDF-SHA256 from a random master key, with the note's identity as AAD — a sealed file copied under another note's name fails to decrypt instead of impersonating it — and file sizes padded to 4 KiB buckets so they don't reveal note sizes. The master key is wrapped by your password via **Argon2id** (memory-hard: 128 MiB, 3 passes, 4 lanes, NFC-normalized — the vendored, hash-pinned PHC reference implementation, see `Sources/CArgon2/THIRD_PARTY.md`; legacy PBKDF2 vaults upgrade automatically on the next password unlock) and held in **mlocked, zeroized-on-lock memory** while unlocked. Optional Touch ID unlock: on Apple Silicon / T2 the key copy is encrypted to a **Secure Enclave** P-256 key that demands user presence on every decrypt; older Macs fall back to a user-presence Keychain control. The app starts locked, locks with `⌘L`, **auto-locks** on screen sleep/lock and after a configurable idle timeout, and repeated wrong passwords throttle with growing delays. A **key rotation** action re-encrypts the library under a fresh master key (crash-safe and resumable). Legacy v1/v2 (ChaCha20-Poly1305) files stay readable and upgrade on save. There is no recovery backdoor: a forgotten password (with Touch ID off) means the notes are gone — keep a markdown export. FIDO2 hardware keys (YubiKey) are not supported: macOS exposes no public API to derive stable encryption secrets from a security key for app-local vaults.
- **Sensitive notes never touch the cloud** — mark any note via **File ▸ Mark Sensitive** (or the shield beside the note's title — the toolbar shield in the classic layout) and every AI request for it is refused *in code* unless the resolved endpoint is local (Ollama, LM Studio, or another on-machine/LAN server). A "Custom" provider pointed at a remote host counts as cloud. The block is enforced at request time, not just hidden in the UI.
- **Ambient anti-exposure** — the window is excluded from screenshots, screen recordings, and screen sharing by default, protection or not (the toggle appears in Settings → Security once protection is set up); copies from a protected library clear the clipboard after 45 seconds unless something else was copied; core dumps are disabled and release builds deny debugger attachment; a hash-chained local **audit log** (`audit.log`) records lock/unlock/rotation events — never content — and any tampering with it is detectable.
- **Markdown export/import** — File → Export Notes as Markdown… writes every note as a plain `.md` file to a folder you pick (your manual, provider-independent backup); Import Markdown Notes… brings them back, recognizing its own export headers so re-imports update instead of duplicate.
- **Fast** — actor-based file I/O, debounced autosave (atomic writes), per-paragraph editor styling, cancellation-aware feedback pipeline (a keystroke inside the section being read cancels the read; one elsewhere lets it finish).

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

## TestFlight (primary distribution)

Klårt's primary distribution channel is **TestFlight**, via the Mac App Store — the DMG above is the ad-hoc fallback for people who'd rather not go through App Store Connect. TestFlight uploads happen manually from Xcode; nothing in CI does this (it needs an interactive Apple ID sign-in). The app is already TestFlight-ready as-is: `project.yml` sets `CODE_SIGN_STYLE: Automatic` and `Scripts/Klart.entitlements` only requests sandbox-safe entitlements (App Sandbox, outgoing network, user-selected file access), so no project changes are needed to submit — just the one-time App Store Connect setup below.

**One-time setup (developer.apple.com / appstoreconnect.apple.com):**

1. Confirm the `com.klart.mac` App ID is registered under **Certificates, Identifiers & Profiles** — Xcode registers it automatically the first time you archive with your Team selected, so you can usually skip this.
2. In **App Store Connect → Apps → +**, create a new app: platform **macOS**, bundle ID `com.klart.mac`, a name, primary language, and SKU (the SKU is internal-only, e.g. `klart-mac`).
3. When you first upload a build, App Store Connect asks for **export compliance**. Klårt only uses standard HTTPS/TLS for cloud providers plus the vendored Argon2id/AES-256-GCM for local-only note encryption (never transmitted) — most apps in this shape qualify for the standard exemption, but confirm the exact answer yourself since it's a legal attestation, not something this repo can decide for you.

**Every release, from Xcode:**

1. `cd KlartMac && bash Scripts/generate-xcodeproj.sh` to (re)generate `Klart.xcodeproj`.
2. Open it, select the **Klart** target → **Signing & Capabilities**, pick your Team.
3. Bump `CURRENT_PROJECT_VERSION` in `project.yml` (App Store Connect rejects re-uploading a build number that's already been used for the current `MARKETING_VERSION`) and re-run `generate-xcodeproj.sh`.
4. Set the run destination to **My Mac**, then **Product → Archive**.
5. In the **Organizer** window that opens, select the archive → **Distribute App** → **App Store Connect** → **Upload**. Xcode handles Apple Distribution signing and the App Store provisioning profile automatically under Automatic signing.
6. Once Apple finishes processing the build (usually a few minutes to an hour, emailed when ready), go to **App Store Connect → your app → TestFlight**:
   - **Internal testers** (up to 100, must be users on your App Store Connect team) get the build immediately, no review.
   - **External testers** need a **Test Information** page filled in first and go through a short **Beta App Review** (typically faster than full App Review) before their first build.

## Using Klårt

1. First launch opens a seven-screen tour (Help ▸ Welcome Tour… brings it back) and offers *Second location for Nordbrot*, a sample note with an uncited rule of thumb, a hedged risk section, overlapping groups and a decision resting on one number — open it and the editor reads it at once, offline checks first.
2. Create a note (`⌘N`). Give it a `# Topic` heading and `## Sub-question` sections.
3. Write. When you finish a section — move on to another, open a new `##` beneath it, or stop for a while (configurable, default 20 s) — the editor reads it, silently, in the background. Nothing appears mid-screen.
4. Summon the editor with `⌘E`, by typing `//show`, or via the ¶ icon in the notes panel (`//editor` or `⌘R` reads the section under the cursor at once): its notes appear in the right margin, each aligned with the section it refers to. **Respond** puts a note into that section as a `> ✎` prompt block and puts the cursor beneath it for your own answer; the **✓** and **✗** glyphs judge it — ✓ says the editor is right, ✗ says it is wrong and hides it permanently for those words in this note. Either way the card stays and greys out, so you can see what you've already dealt with. `⌘E` again — or the chevron at the rail's near edge, right where the writing column ends — puts the margin notes away; otherwise keep writing and they fade out on their own (after 5 more minutes of typing, over 20 seconds).
5. Your notes live behind the left edge: move the pointer there for the dot spine, rest on it for 0.8 s for the full panel (titles, last edited, shield marks, search — `⌘F` jumps straight there).
6. Use the coach actions any time from the **Editor** menu — their reply streams into the coach popover, which only the classic layout puts on screen. `⌘R` analyzes on demand; auto-analysis can be turned off entirely in Settings → Editor.
7. Add `[no-ai]` to a heading (e.g. `## Private notes [no-ai]`) to keep the coach out of that section.
8. Prefer the classic sidebar-and-toolbar layout, or want word count and reading time at the foot of the page? Settings → Interface.

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
│   │   └── Feedback/             PromptBuilder, robust FeedbackParser, FeedbackEngine, LocalChecks, SectionCompletion
│   └── KlartApp/               SwiftUI app (macOS-only)
│       ├── AppState.swift        Single source of truth, section-finished trigger, cancellation
│       └── Views/                Teleprompter surface, sidebar, NSTextView markdown editor, coach panel, settings
├── Tests/KlartKitTests/        Outline, parser, prompts, engine, storage, settings, vault crypto
├── Tests/KlartAppTests/        The writing surface: caret geometry, typewriter centring, focus
└── Scripts/make-app.sh           Release build → signed Klart.app
```

Design decisions worth knowing:

- **The parser is forgiving.** Small local models wrap JSON in prose and code fences, or get truncated mid-answer. The feedback parser extracts the first balanced JSON value (string-and-escape aware) and can salvage complete items from a truncated array.
- **Rejections are fingerprinted.** A rejected tip is remembered by a normalized content hash per note, so regeneration doesn't resurface it.
- **The learning log is tiered.** Its signal half (verdict, kind, model, system-prompt hash) is always written; note text is opt-in and never recorded for a sensitive note. The prompt hash is what makes a prompt edit measurable: verdicts stay attributable to the prompt that produced them.
- **The editor is plain text.** Markdown stays markdown; headings and quote blocks are styled live (per-paragraph, so large notes stay fast), not converted.

## Data & privacy

| What | Where |
|---|---|
| Notes | `…/Application Support/Klart/Notes/*.json` |
| Settings | `…/Application Support/Klart/settings.json` (never contains keys) |
| Security log | `…/Application Support/Klart/audit.log` (lock, unlock, rotation events — never content) |
| Learning log | `…/Application Support/Klart/recommendations.json` (your ✓/✗ verdicts; note text only if you opt in — Settings → Coaching, where you can also export or clear it) |
| API keys | macOS Keychain (`com.klart.mac`) |
| Telemetry | none — the learning log is local, and nothing is ever sent anywhere |

The `…` base depends on how you run Klårt: the sandboxed packaged app resolves to its container (`~/Library/Containers/com.klart.mac/Data/Library/Application Support/…`), while an unsandboxed `swift run` dev build uses `~/Library/Application Support/…` directly. If you move from a dev build to the packaged app, copy the `Klart` folder across once.

**Reinstalls:** deleting the app does *not* delete your notes — the container (and the unsandboxed path) survive uninstall/reinstall, including App Store reinstalls, as long as the bundle ID stays `com.klart.mac`. Only manually deleting `~/Library/Containers/com.klart.mac` (or an "app cleaner" tool doing it for you) removes them. For belt-and-braces, File → Export Notes as Markdown… gives you a plaintext backup you can re-import on any machine.

When you finish a section, that section and the rest of the document (with every `[no-ai]` section's body replaced by "(omitted)") are sent to the provider you configured, so the editor can read the section against the whole; a coach action sends the whole note likewise. Both are clipped to a character budget before they leave. The offline checks never leave at all. With Ollama or LM Studio, everything stays on your machine.

## License

MIT — same as the repository.
