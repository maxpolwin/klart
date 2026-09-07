# Klårt

**A thinking coach that lives in your notes.** Native macOS, Swift/SwiftUI.

Klårt is a minimal, native macOS app for structuring your thinking in markdown. When you finish a section, a local or cloud LLM reads it against your whole document and tells you, plainly, where the thinking fails a demanding reader: gaps, unstated assumptions, claims with nothing behind them, the objection you haven't met, categories that overlap, an order that hides the argument. It never writes your text — you answer its notes in your own words.

It's fast and light (~5 MB app, no bundled browser) and talks to **Ollama**, **LM Studio**, **OpenRouter**, or any OpenAI-compatible endpoint. Notes are JSON-wrapped markdown on your machine, exportable as plain `.md` at any time; nothing leaves it unless you choose a cloud provider.

> **The app lives in [`KlartMac/`](KlartMac/).** See **[KlartMac/README.md](KlartMac/README.md)** for the full guide — highlights, build & distribution, provider setup, architecture, and the security/encryption model. This page is the short version.

---

## Highlights

- **Native SwiftUI, "Teleprompter" design** — by default one centered, monochrome column and nothing else on screen: notes wait behind the left edge (dots → hover 0.8 s → full panel with search), the AI editor's notes appear in the right margin — matched to the text sections they refer to, marked with glyphs instead of colored pills — when summoned via `⌘E` or by typing `//show` (`//editor` reads the section now), and fade away again while you keep writing. Optional word count/reading time at the foot; the classic sidebar + accent-color layout is one toggle away in Settings → Interface.
- **Live markdown editor** — headings resize as you type (`#`, `##`, `###`), list markers are tinted and quote lines dimmed, `- [ ]` task items get a dimmed checkbox and strike through once checked, and fenced code blocks and `**bold**` / `*italic*` / `` `code` `` / `~~strike~~` style inline — the syntax markers themselves are hidden on every line but the one the cursor is on, so a note reads like the rendered result while the text stays plain markdown. Lists continue on <kbd>Enter</kbd>.
- **Coaching, not ghostwriting** — an opinionated editor that reads a section when you finish it. Every note quotes the words it is about, says what is wrong and what it costs the argument, and carries a severity. Nine lenses: **Gap**, **MECE**, **Structure**, **Clarity**, **Evidence**, **Assumption**, **Warrant**, **Counter**, **Question**. **Respond** drops a note into the text as a prompt for your own answer; it never inserts the model's prose. Offline checks (uncited claims, hedging, undefined terms, thin sections, overlapping headings) run on every read with or without a model. Plus one-tap coach actions (*Ask me questions*, *Challenge my thinking*, *Mirror my argument*, *Suggest next steps*).
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

CI builds, tests, and packages the app on every push to `main` or a `claude/**` branch that touches `KlartMac/` — see [`.github/workflows/macos-app.yml`](.github/workflows/macos-app.yml). Full build, signing, and notarization instructions are in [KlartMac/README.md](KlartMac/README.md#build--run).

## Repository layout

```
KlartMac/     The macOS app (SwiftPM: KlartKit library + Klart app)
build/          Shared app icon (icon.png master → icon.icns used by the build)
scripts/        generate-icon.sh — regenerate build/icon.icns from the PNG master
docs/           Product requirements and design-direction documents
.github/        CI workflows (macOS build/test/package; security scan)
```

## Documentation

- **[KlartMac/README.md](KlartMac/README.md)** — the complete guide (start here)
- [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) — product requirements
- [docs/DESIGN_ALTERNATIVES.md](docs/DESIGN_ALTERNATIVES.md) — design directions

## License

MIT.
