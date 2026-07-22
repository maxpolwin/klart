# Noschen

**AI-Powered Research Note-Taking App**

Noschen is a privacy-first, local-first research note-taking application that provides live AI feedback to support academic researchers, consultants, and students. The AI analyzes your notes in real-time and suggests improvements, identifies gaps, and enhances research quality.

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

- **Local-First Privacy**: All notes are stored locally on your machine. No cloud sync, no data leaving your device.
- **AI-Powered Feedback**: Real-time intelligent suggestions powered by a built-in local LLM (Qwen2.5-0.5B or Phi-3-mini-128k), Ollama, or Mistral API.
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

- Accept/Reject workflow for AI suggestions
- Review previously rejected suggestions
- Contextual feedback aware of your document hierarchy
- Section exclusion from AI feedback
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

#### Option 0: Built-in AI (Default, No Setup Required)

Runs entirely on-device via `node-llama-cpp`, no external server or account needed. Pick between
two bundled models in Settings → AI Provider → Built-in Model; whichever one isn't yet downloaded
gets an in-app "Download" button with a progress bar.

| Model | Size | Practical Context | Notes |
|-------|------|--------------------|-------|
| Qwen2.5-0.5B | ~400MB | up to 32K tokens | Small, fast, works on any hardware. Default. |
| Phi-3-mini-128k | ~2.4GB | up to 32K tokens (practical ceiling — see below) | Bigger, higher-quality, noticeably more RAM/CPU |

Both models can natively address large context windows (Qwen: 32K, Phi-3-mini: 128K), but the
Context Size setting is capped at 32768 for both — Phi-3-mini's KV cache costs roughly 32x more
per token than Qwen's (it lacks grouped-query attention), so its *architectural* 128K window isn't
practically usable on consumer hardware even though the model supports it.

You can also pre-fetch either model from the command line before first launch:

```bash
npm run download-model        # Qwen2.5-0.5B (default)
npm run download-model:phi3   # Phi-3-mini-128k
```

#### Option 1: Ollama (Local LLM)

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

### Working with AI Suggestions

When AI feedback appears:

1. **Review** the suggestion in the feedback panel below your text
2. **Accept** (✓) to add a TODO reminder in your text
3. **Reject** (✗) to hide the suggestion
4. **Reconsider** previously rejected suggestions by clicking "Show rejected"

### Excluding Sections from AI Feedback

If you want to exclude certain sections from AI analysis (e.g., personal notes, drafts):

1. Add `[no-ai]` tag after your H2 heading
2. Example: `## Personal Notes [no-ai]`

---

## AI Feedback System

### How It Works

1. **Trigger**: Feedback generates after 2 seconds of typing inactivity
2. **Context**: AI considers:
   - The current H2 section you're working in
   - Relationship to other H2 sections
   - The overarching H1 topic
3. **Display**: Colored inline badges appear in the feedback panel

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
| `Cmd + Enter` | Accept first active suggestion |
| `Cmd + Delete` | Reject first active suggestion |

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
| `npm run download-model` | Download the built-in Qwen2.5-0.5B model (default) |
| `npm run download-model:phi3` | Download the built-in Phi-3-mini-128k model (bigger-context alternative) |
| `npm run download-compressor` | Download the LLMLingua-2 prompt-compression model (optional) |
| `npm run lint` | Run ESLint |
| `npm run typecheck` | Run TypeScript type checking |

### Prompt Compression (Token Optimization)

Long notes are semantically compressed with **[LLMLingua-2](https://llmlingua.com/llmlingua2.html)** (via the
pure-JS [`@atjsh/llmlingua-2`](https://www.npmjs.com/package/@atjsh/llmlingua-2) port) so the most important
content fits the model's token budget instead of being truncated at the end. It applies to all providers and runs
fully on-device (a MobileBERT ONNX model, ~99MB).

```bash
# One-time download of the compressor model
npm run download-compressor
```

Compression is enabled by default and can be toggled in **Settings → AI Provider → Prompt Compression**. If the
model isn't downloaded, the app silently falls back to simple truncation, so this step is optional.

---

## Roadmap

### Planned Features

- [ ] Export to Markdown and PDF
- [ ] Web search integration for concrete source recommendations
- [ ] AI learning from rejected suggestions
- [ ] Cross-referencing across multiple notes
- [ ] Counter-arguments and alternative perspectives
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
