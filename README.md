# Klårt

**A thinking coach that lives in your notes.** Native macOS, Swift/SwiftUI.

Klårt is a minimal, native macOS app for structuring your thinking in markdown. As you write, a local or cloud LLM reads the section you're working on — in the context of your whole document — and coaches you: it points out gaps, overlapping categories, vague claims, and better structure, and it can ask you Socratic questions instead of writing your notes for you.

It's fast and light (~5 MB app, no bundled browser) and talks to **Ollama**, **LM Studio**, **OpenRouter**, or any OpenAI-compatible endpoint. Notes are plain markdown on your machine; nothing leaves it unless you choose a cloud provider.

> **The app lives in [`KlartMac/`](KlartMac/).** See **[KlartMac/README.md](KlartMac/README.md)** for the full guide — highlights, build & distribution, provider setup, architecture, and the security/encryption model. This page is the short version.

---

## Highlights

- **Native SwiftUI, "quiet" design** — follows the system light/dark appearance, one accent color, a translucent sidebar, and no persistent AI chrome: suggestions wait behind a small toolbar pill ("3 ready") until you summon them with a click or `⌘.`.
- **Live markdown editor** — headings resize as you type (`#`, `##`, `###`), list markers and quotes are tinted, fenced code blocks and `**bold**` / `*italic*` / `` `code` `` style inline while the text stays plain markdown. Lists continue on <kbd>Enter</kbd>.
- **Coaching, not ghostwriting** — feedback types: **Gap**, **MECE**, **Source**, **Structure**, **Clarity**, and **Question** (Socratic), plus one-tap coach actions (*Ask me questions*, *Challenge my thinking*, *Mirror my argument*, *Suggest next steps*).
- **Local-first & private** — notes live in `~/Library/Application Support/Klart/Notes`; API keys live in the macOS Keychain; no telemetry. Optional at-rest note encryption with app lock, Touch ID unlock, and auto-lock.
- **Any LLM** — Ollama, LM Studio, OpenRouter, or any OpenAI-compatible server. Model lists are fetched live from the provider.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ command line tools (to build)
- An LLM to talk to — e.g. [Ollama](https://ollama.com) (`ollama pull llama3.2`), [LM Studio](https://lmstudio.ai), or an [OpenRouter](https://openrouter.ai) key

## Quick start

```bash
git clone <repo-url>
cd Klart/KlartMac

swift run                  # run in development
swift test                 # run the unit tests
bash Scripts/make-app.sh   # build a distributable Klart.app → dist/
```

CI builds, tests, and packages the app on every push — see [`.github/workflows/macos-app.yml`](.github/workflows/macos-app.yml). Full build, signing, and notarization instructions are in [KlartMac/README.md](KlartMac/README.md#build--run).

## Repository layout

```
KlartMac/     The macOS app (SwiftPM: KlartKit library + Klart app)
build/          Shared app icon (icon.svg source → icon.icns used by the build)
scripts/        generate-icon.sh — regenerate build/icon.icns from the SVG
docs/           Product requirements and design-direction documents
.github/        CI workflows (macOS build/test/package; security scan)
```

## Documentation

- **[KlartMac/README.md](KlartMac/README.md)** — the complete guide (start here)
- [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) — product requirements
- [docs/DESIGN_ALTERNATIVES.md](docs/DESIGN_ALTERNATIVES.md) — design directions

## License

MIT.
