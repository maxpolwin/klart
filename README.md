# Noschen

**AI-Coached Research Note-Taking App**

Noschen is a privacy-first, local-first research note-taking application that coaches academic researchers, consultants, and students as they write. **You write it — Noschen questions it, privately, on your machine.**

Instead of generating text for you, the AI (by default) asks Socratic questions that make you produce the answer yourself, challenges your reasoning on demand, and turns your own notes into spaced recall prompts so what you research actually sticks. Writing it yourself is what builds understanding (the generation effect); Noschen is built around that principle — AI as supporter, not ghostwriter. A legacy "Draft" mode and an explicit per-suggestion "Draft it for me" escape hatch remain available, always logged as AI-authored.

---

## Table of Contents

- [Features](#features)
- [Screenshots](#screenshots)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage Guide](#usage-guide)
- [AI Feedback System](#ai-feedback-system)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [Architecture](#architecture)
- [Data Storage](#data-storage)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [License](#license)

---

## Features

### Core Features

- **Coach Mode (default)**: The AI asks questions you answer in your own words — your answer, not AI prose, goes into the note. Hints nudge you where to look without giving answers.
- **Thinking Partner**: A Socratic sparring panel with three stances (Socratic questioner, devil's advocate, graduated hints) and on-demand critical lenses ("Challenge my reasoning", "Reviewer 2", "Is this MECE?").
- **Spaced Review**: Turn a note's sections into recall cards (SM-2 scheduling). The reveal is always *your own* writing — attempt first, then grade Again/Hard/Good/Easy.
- **Offline Checks (no LLM)**: Deterministic, named heuristics flag uncited empirical claims, hedge-word density, undefined acronyms, thin sections, and overlapping section titles — even with AI disconnected.
- **Coaching Memory & Balance**: Every answered question, AI draft (provenance-logged), and sparring exchange persists per note; a "coaching balance" insight keeps your respond-vs-draft ratio visible.
- **Local-First Privacy**: All notes, coaching logs, and review cards are stored locally. Built-in local LLM (Qwen 0.5B), Ollama, or Mistral API.
- **Hierarchical Note Structure**: Organize research with H1 headings (main topic) and H2 headings (sub-questions/aspects).
- **Dark Mode Interface**: Clean, distraction-free dark theme designed for extended research sessions.
- **Auto-Save**: Never lose your work—notes save automatically after 1 second of inactivity.
- **Full-Text Search**: Instantly search across all your notes.

### AI Analysis Types

| Type | Description |
|------|-------------|
| **MECE Validation** | Checks if your structure is Mutually Exclusive and Collectively Exhaustive. Suggests missing categories or better groupings. |
| **Gap Identification** | Flags aspects, considerations, or perspectives not yet addressed in your research. |
| **Source Suggestions** | Recommends types of literature or domains to explore (e.g., "Consider literature on institutional economics"). |
| **Structural Improvements** | Proposes reorganization for clearer argumentation or logical flow. |

### Additional Features

- Respond/Dismiss workflow for coach questions (Accept/Reject in legacy Draft mode)
- "Draft it for me" per suggestion — gated behind writing your own take first, and logged as AI-authored
- Metacognitive scaffolds: brief plan/monitor/evaluate prompts as your note grows
- Review previously dismissed suggestions
- Contextual feedback aware of your document hierarchy
- Keyboard-driven workflow with Apple-appropriate shortcuts

---

## Screenshots

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Noschen                              │                    AI Connected │
├───────────────────┬─────────────────────────────────────────────────────┤
│                   │                                                     │
│  🔍 Search notes  │  # Impact of Remote Work on Productivity           │
│                   │  ─────────────────────────────────────────────────  │
│  ┌─────────────┐  │                                                     │
│  │ Research    │  │  ## Communication Patterns                         │
│  │ Paper Draft │  │                                                     │
│  │ Jan 19      │  │  Remote work has fundamentally changed how teams   │
│  └─────────────┘  │  communicate. Asynchronous communication has       │
│                   │  become the norm, replacing spontaneous office     │
│  ┌─────────────┐  │  conversations...                                  │
│  │ Literature  │  │                                                     │
│  │ Review      │  │  ┌──────────────────────────────────────────────┐  │
│  │ Jan 18      │  │  │ AI Suggestions (2)                           │  │
│  └─────────────┘  │  │                                              │  │
│                   │  │ [GAP] Consider addressing time zone          │  │
│  + New Note       │  │ challenges in distributed teams    [✓] [✗]  │  │
│                   │  │                                              │  │
│  ⚙ Settings       │  │ [MECE] Your analysis covers sync vs async   │  │
│                   │  │ but misses hybrid approaches      [✓] [✗]  │  │
│                   │  └──────────────────────────────────────────────┘  │
└───────────────────┴─────────────────────────────────────────────────────┘
```

---

## Installation

### Prerequisites

- **Node.js** 18 or higher
- **npm** 9 or higher
- **Ollama** (recommended) or Mistral API key

### Quick Start

```bash
# Clone the repository
git clone https://github.com/maxpolwin/Noschen.git
cd Noschen

# Switch to the development branch
git checkout claude/noschen-research-notes-app-SCU8k

# Install dependencies
npm install

# Start in development mode
npm run dev
```

### Build for Production

```bash
# Build the application
npm run build

# Package as a desktop app (macOS, Windows, Linux)
npm run package
```

### Installing Ollama (Recommended)

For the best privacy-first experience, install Ollama to run AI models locally:

1. Download Ollama from [ollama.ai](https://ollama.ai)
2. Install and launch Ollama
3. Pull a recommended model:

```bash
# Recommended for M2 MacBook (good balance of speed and quality)
ollama pull llama3.2

# Alternative lightweight models
ollama pull phi3
ollama pull mistral
```

---

## Configuration

### AI Provider Setup

Launch Noschen and click the **Settings** icon in the sidebar to configure your AI provider.

#### Option 1: Ollama (Local LLM) — Recommended

Best for privacy and offline use. Runs entirely on your machine.

| Setting | Default | Description |
|---------|---------|-------------|
| Ollama URL | `http://localhost:11434` | Ollama server address |
| Model | `llama3.2` | The model to use for analysis |

**Recommended models by hardware:**

| Hardware | Recommended Model | Notes |
|----------|-------------------|-------|
| M2/M3 MacBook | `llama3.2`, `phi3` | Fast, good quality |
| M1 MacBook | `phi3`, `mistral` | Lighter weight |
| 16GB+ RAM | `llama3.2:8b` | Higher quality |
| 8GB RAM | `phi3` | Optimized for lower memory |

#### Option 2: Mistral API (Cloud)

Best for users without powerful local hardware or who prefer cloud processing.

1. Create an account at [console.mistral.ai](https://console.mistral.ai)
2. Generate an API key
3. Enter the key in Noschen settings

| Setting | Description |
|---------|-------------|
| API Key | Your Mistral API key (starts with `sk-`) |

---

## Usage Guide

### Creating Your First Note

1. Click **+ New Note** in the sidebar
2. Start with an **H1 heading** for your main research topic:
   - Type `# ` followed by your topic
   - Example: `# The Impact of AI on Creative Industries`
3. Add **H2 headings** for sub-questions or aspects:
   - Type `## ` followed by the sub-topic
   - Example: `## Economic Disruption`
4. Write your content under each heading
5. AI feedback will appear automatically after 2 seconds of inactivity

### Document Structure Best Practices

```markdown
# Main Research Question (H1)
Your overarching research topic or thesis question.

## Sub-Question 1 (H2)
First major aspect to investigate.

### Supporting Point (H3)
Detailed evidence or argument.

## Sub-Question 2 (H2)
Second major aspect to investigate.

## Sub-Question 3 (H2)
Third major aspect to investigate.
```

**Why this structure matters:**
- The AI uses H1 to understand your overall research intent
- H2 headings define the scope of analysis
- Feedback relates primarily to the current H2 section while considering the broader context

### Working with the Coach

When coach feedback appears (default Coach mode):

1. **Read the question** in the Coach panel below your text — each item asks something specific about what you wrote
2. **Respond** (✎ or ⌘+Enter) — a composer opens; answer in your own words, and *your* answer is inserted near the relevant passage
3. **Show hint** if you're stuck — a nudge that points where to look without giving the answer
4. **Dismiss** (✗ or ⌘+⌫) to hide a question; reconsider later via "Show rejected"
5. **Draft it for me…** (quiet link) if you truly want AI prose: write your own one-line take first (≥30 characters), then the draft builds on it and is logged as AI-authored in your coaching history

In legacy **Draft mode** (Settings → Prompts → AI Role), suggestions arrive as insertable content with the old Accept/Reject flow.

### Sparring with the Thinking Partner

Click **Partner** in the editor header to open a floating dialogue panel. Pick a stance — Socratic, Devil's advocate, or Hints — or pull a lens: "Challenge my reasoning", "Strongest counterargument", "Is this MECE?", "Reviewer 2", "I'm stuck". You always write first; the partner questions and challenges but never writes your content. Exchanges are saved to the note's coaching history.

### Reviewing What You Know

1. In a note, click **Make review cards** — each substantial H2 section becomes 2 recall questions plus one "explain it simply" card
2. Open **Review** in the sidebar (the badge shows how many cards are due)
3. For each card: **attempt recall in writing first** — the reveal unlocks only after a genuine try — then compare against your own note excerpt and grade **Again / Hard / Good / Easy**
4. Cards are rescheduled by an SM-2 spaced-repetition scheduler; the done screen shows your **coaching balance** (questions answered in your own words vs AI drafts requested)

### Excluding Sections from AI Feedback

If you want to exclude certain sections from AI analysis (e.g., personal notes, drafts):

1. Add `[no-ai]` tag after your H2 heading
2. Example: `## Personal Notes [no-ai]`

---

## AI Feedback System

### Coach vs Draft

| | **Coach (default)** | **Draft (legacy)** |
|---|---|---|
| The AI returns | Questions anchored to quoted spans, plus optional hints | Ready-to-insert prose |
| Primary action | **Respond** — your own words are inserted | **Accept** — AI text is inserted |
| AI-written prose | Only via the explicit, commit-gated "Draft it for me…" (provenance-logged) | Default behavior |
| Why | Producing the answer yourself builds durable understanding (generation effect) | Faster polish, weaker learning |

Switch modes in **Settings → Prompts → AI Role**. Each mode has its own editable system prompt.

### How It Works

1. **Trigger**: Feedback generates after 2 seconds of typing inactivity
2. **Context**: AI considers:
   - The current H2 section you're working in
   - Relationship to other H2 sections
   - The overarching H1 topic
3. **Display**: Colored inline badges appear in the Coach panel
4. **Guardrails**: In Coach mode the app strips any prose the model tries to insert and guarantees every item carries a question (curated per-type question stems keep the tiny local model reliable). Deterministic offline checks and metacognitive scaffolds run without any LLM at all.

### Feedback Types Explained

#### MECE Validation (Purple)
Checks if your research structure is:
- **Mutually Exclusive**: No overlapping categories
- **Collectively Exhaustive**: No missing categories

*Example feedback:*
> "Your analysis of market segments overlaps between 'Enterprise' and 'Large Business'. Consider consolidating or clarifying the distinction."

#### Gap Identification (Blue)
Identifies missing perspectives, considerations, or aspects.

*Example feedback:*
> "Consider addressing the ethical implications of this technology, which is absent from your current analysis."

#### Source Suggestions (Green)
Recommends types of literature or domains to explore.

*Example feedback:*
> "Consider literature on behavioral economics, particularly work by Kahneman and Thaler, for the decision-making section."

#### Structural Improvements (Orange)
Suggests reorganization for clarity and logical flow.

*Example feedback:*
> "Consider moving the 'Historical Context' section before 'Current State' for better chronological flow."

### Feedback Quality Tips

For best AI feedback:
- Write clear, descriptive H1 and H2 headings
- Include enough content (50+ characters) before expecting feedback
- Be specific in your writing—vague text produces vague feedback
- Use consistent terminology throughout your document

---

## Keyboard Shortcuts

### Global Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd + S` | Force save current note |
| `Cmd + N` | Create new note |
| `Cmd + F` | Focus search |

### Feedback Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd + Enter` | Respond to first coach question (Accept in Draft mode) |
| `Cmd + Delete` | Dismiss first active suggestion |

### Editor Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd + B` | Bold text |
| `Cmd + I` | Italic text |
| `Cmd + Shift + 1` | Heading 1 |
| `Cmd + Shift + 2` | Heading 2 |
| `Cmd + Shift + 3` | Heading 3 |
| `Cmd + Z` | Undo |
| `Cmd + Shift + Z` | Redo |

---

## Architecture

### Project Structure

```
noschen/
├── src/
│   ├── main/                    # Electron main process
│   │   ├── main.ts              # App entry, window management, IPC handlers
│   │   └── preload.ts           # Context bridge for renderer
│   │
│   ├── renderer/                # React frontend
│   │   ├── components/
│   │   │   ├── Editor.tsx       # TipTap editor with feedback integration
│   │   │   ├── Sidebar.tsx      # Note list and search
│   │   │   ├── FeedbackPanel.tsx # AI suggestions display
│   │   │   ├── SettingsModal.tsx # AI configuration
│   │   │   └── EmptyState.tsx   # Welcome screen
│   │   │
│   │   ├── styles/
│   │   │   └── global.css       # Dark theme and all styles
│   │   │
│   │   ├── App.tsx              # Main app component
│   │   ├── main.tsx             # React entry point
│   │   └── index.html           # HTML template
│   │
│   └── shared/
│       └── types.ts             # Shared TypeScript interfaces
│
├── package.json
├── tsconfig.json
├── vite.config.ts               # Vite bundler configuration
└── README.md
```

### Technology Stack

| Layer | Technology |
|-------|------------|
| Framework | Electron 28 |
| Frontend | React 18 + TypeScript |
| Editor | TipTap (ProseMirror) |
| Bundler | Vite 5 |
| Styling | CSS Custom Properties |
| Icons | Lucide React |
| Local AI | Ollama API |
| Cloud AI | Mistral API |

### Data Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Editor    │────▶│  Debounce   │────▶│  AI Engine  │
│  (TipTap)   │     │  (2 sec)    │     │  (Ollama/   │
└─────────────┘     └─────────────┘     │   Mistral)  │
                                        └──────┬──────┘
                                               │
┌─────────────┐     ┌─────────────┐            │
│  Feedback   │◀────│   Parse &   │◀───────────┘
│   Panel     │     │   Display   │
└─────────────┘     └─────────────┘
```

---

## Data Storage

### Storage Location

Notes are stored as JSON files in your system's application data folder:

| OS | Path |
|----|------|
| macOS | `~/Library/Application Support/noschen/notes/` |
| Windows | `%APPDATA%/noschen/notes/` |
| Linux | `~/.config/noschen/notes/` |

Coaching data lives beside them, also local-only:

| Data | Path | Contents |
|------|------|----------|
| Coaching memory | `<app data>/noschen/coaching/<noteId>.json` | Questions answered (your words), AI drafts (exact text, provenance), sparring exchanges |
| Review cards | `<app data>/noschen/review/cards.json` | Recall prompts, SM-2 scheduling state, grade history |

### Note Format

Each note is stored as a separate JSON file:

```json
{
  "id": "note_1705678900000",
  "title": "Research on AI Ethics",
  "content": "<h1>Research on AI Ethics</h1><p>Content here...</p>",
  "createdAt": "2024-01-19T12:00:00.000Z",
  "updatedAt": "2024-01-19T14:30:00.000Z",
  "excludedSections": ["Personal Notes"]
}
```

### Settings Storage

AI settings are stored in:

| OS | Path |
|----|------|
| macOS | `~/Library/Application Support/noschen/settings.json` |
| Windows | `%APPDATA%/noschen/settings.json` |
| Linux | `~/.config/noschen/settings.json` |

### Backup

To backup your notes, simply copy the entire `noschen` folder from your application data directory.

---

## Troubleshooting

### Common Issues

#### "AI Disconnected" Status

**Cause**: Cannot connect to Ollama or Mistral API.

**Solutions**:
1. For Ollama:
   - Ensure Ollama is running: `ollama serve`
   - Check the URL in settings (default: `http://localhost:11434`)
   - Verify a model is installed: `ollama list`
2. For Mistral:
   - Verify your API key is correct
   - Check your internet connection
   - Ensure you have API credits

#### No Feedback Appearing

**Possible causes**:
1. Content is too short (minimum ~50 characters needed)
2. AI provider not configured
3. Still within the 2-second debounce period

**Solutions**:
1. Write more content
2. Check AI connection status
3. Wait for the debounce timer

#### Electron Won't Start

**Solution**:
```bash
# Clear node_modules and reinstall
rm -rf node_modules
npm install

# If Electron download fails, use a mirror
ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/" npm install
```

#### High Memory Usage

**Solution**: Use a lighter Ollama model:
```bash
ollama pull phi3
```
Then update the model in Noschen settings.

### Getting Help

- **GitHub Issues**: [github.com/maxpolwin/Noschen/issues](https://github.com/maxpolwin/Noschen/issues)
- **Discussions**: [github.com/maxpolwin/Noschen/discussions](https://github.com/maxpolwin/Noschen/discussions)

---

## Development

### Development Mode

```bash
# Start with hot reload
npm run dev
```

### Building

```bash
# Build renderer (Vite)
npm run build:renderer

# Build main process (TypeScript)
npm run build:main

# Build everything
npm run build
```

### Type Checking

```bash
npx tsc --noEmit
```

### Project Scripts

| Script | Description |
|--------|-------------|
| `npm run dev` | Start development server with hot reload |
| `npm run build` | Build for production |
| `npm run package` | Package as desktop app |
| `npm run lint` | Run ESLint |
| `npm run typecheck` | Run TypeScript type checking |

---

## Roadmap

### Planned Features

- [x] Coach mode: Socratic questions instead of generated prose
- [x] Thinking partner with devil's-advocate and hint-ladder stances
- [x] Counter-arguments and alternative perspectives (on-demand lenses)
- [x] Spaced-repetition review of your own notes (SM-2)
- [ ] FSRS scheduler upgrade (swap-in behind the same scheduler signature)
- [ ] Local related-notes panel (on-device embeddings over your own notes)
- [ ] Calibration loop: predict the gap before the reveal; track calibration over time
- [ ] Per-skill profile with fading scaffolds (credit only for human-authored text)
- [ ] Export to Markdown and PDF
- [ ] Web search integration for concrete source recommendations
- [ ] AI learning from rejected suggestions
- [ ] Cross-referencing across multiple notes
- [ ] Terminology clarification prompts
- [ ] Collaborative editing (optional cloud sync)

---

## License

MIT License

Copyright (c) 2024

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

**Made with care for researchers, by researchers.**
