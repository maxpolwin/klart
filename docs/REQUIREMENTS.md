# Noschen - Product Requirements Document

**Version:** 1.0.0
**Last Updated:** January 2026
**Status:** Active Development

---

## Table of Contents

1. [Product Overview](#1-product-overview)
2. [Technical Architecture](#2-technical-architecture)
3. [Core Features](#3-core-features)
4. [AI Integration](#4-ai-integration)
5. [Current Design System](#5-current-design-system)
6. [Planned Design: Liquid Glass](#6-planned-design-liquid-glass)
7. [Data Models](#7-data-models)
8. [Settings & Configuration](#8-settings--configuration)
9. [Build & Distribution](#9-build--distribution)

---

## 1. Product Overview

### 1.1 Purpose

Noschen is an **AI-powered research note-taking application** designed for academics, researchers, and knowledge workers who need intelligent feedback on their writing. The app provides real-time suggestions for improving research notes, identifying gaps, ensuring logical consistency (MECE), and suggesting citations.

### 1.2 Key Value Propositions

- **Privacy-First AI**: Built-in local LLM (Qwen2.5-0.5B, or Phi-3-mini-128k for bigger context) runs entirely offline
- **Real-Time Feedback**: AI analyzes notes as you type with 2-second debounce
- **Customizable**: Editable prompts, custom feedback types, adjustable AI parameters
- **Cross-Platform**: macOS (Intel & Apple Silicon), Windows, Linux

### 1.3 Target Users

- Academic researchers
- Graduate students
- Technical writers
- Knowledge workers managing complex information

---

## 2. Technical Architecture

### 2.1 Technology Stack

| Layer | Technology | Version |
|-------|------------|---------|
| Desktop Framework | Electron | 34.0.0 |
| UI Framework | React | 18.3.1 |
| Language | TypeScript | 5.7.2 |
| Build Tool | Vite | 6.0.0 |
| Rich Text Editor | TipTap | 2.11.0 |
| Local LLM Runtime | node-llama-cpp | 3.x |
| Icons | Lucide React | 0.469.0 |

### 2.2 Project Structure

```
src/
├── main/                    # Electron main process
│   ├── main.ts             # Entry point, IPC handlers, AI orchestration
│   ├── preload.ts          # Context bridge (secure IPC)
│   └── llm/
│       └── localLLM.ts     # Local LLM wrapper (node-llama-cpp)
├── renderer/               # React frontend
│   ├── App.tsx             # Root component
│   ├── main.tsx            # Entry point
│   ├── components/
│   │   ├── Editor.tsx      # TipTap editor + AI analysis trigger
│   │   ├── FeedbackPanel.tsx   # AI feedback display
│   │   ├── SettingsModal.tsx   # Configuration UI
│   │   ├── Sidebar.tsx         # Note list + search
│   │   └── EmptyState.tsx      # Welcome screen
│   └── styles/
│       └── global.css      # Design system + component styles
├── shared/
│   └── types.ts            # Shared TypeScript interfaces
└── models/                 # LLM model files (GGUF format)
```

### 2.3 Process Communication

```
┌─────────────────────────────────────────────────────────┐
│                    Renderer Process                      │
│  ┌─────────┐  ┌──────────┐  ┌───────────────────────┐  │
│  │ Sidebar │  │  Editor  │  │    FeedbackPanel      │  │
│  └────┬────┘  └────┬─────┘  └───────────┬───────────┘  │
│       │            │                     │              │
│       └────────────┴─────────────────────┘              │
│                         │                               │
│                    window.api                           │
└─────────────────────────┬───────────────────────────────┘
                          │ IPC (contextBridge)
┌─────────────────────────┴───────────────────────────────┐
│                     Main Process                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Notes CRUD   │  │  Settings    │  │  AI Engine   │  │
│  │ (File I/O)   │  │  Manager     │  │  (LLM)       │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## 3. Core Features

### 3.1 Note Management

| Feature | Description |
|---------|-------------|
| Create | New note with auto-generated UUID |
| Edit | Rich text with headings (H1-H6), lists, formatting |
| Save | Auto-save after 1 second of inactivity |
| Delete | Remove note with confirmation |
| Search | Full-text search across title and content |

**Note Structure:**
- **Title**: Extracted from first H1 heading or first line
- **Content**: HTML output from TipTap editor
- **Sections**: H2 headings define sections for AI analysis

### 3.2 Rich Text Editor

Built on TipTap with extensions:

- **Headings**: H1 (topic), H2 (sections), H3-H6 (subsections)
- **Text Formatting**: Bold, italic, underline, strikethrough
- **Lists**: Ordered and unordered
- **Code**: Inline code and code blocks
- **Blockquotes**: For citations

### 3.3 AI Feedback System

**Trigger**: 2-second debounce after user stops typing

**Default Feedback Types:**

| Type | Color | Purpose |
|------|-------|---------|
| MECE | Purple | Non-mutually exclusive or non-exhaustive categories |
| Gap | Blue | Missing information, perspectives, or analysis |
| Source | Green | Missing citations, references, or evidence |
| Structure | Orange | Organization, flow, or formatting issues |

**Feedback Item Actions:**
- **Accept**: Apply suggestion (future: auto-insert)
- **Reject**: Dismiss feedback (can reconsider later)

### 3.4 Adaptive Chunking

When AI responses exceed a time threshold:
- **Default**: 3000ms
- **Behavior**: Subsequent requests analyze only the current H2 section
- **Purpose**: Maintain responsiveness on slower hardware

---

## 4. AI Integration

### 4.1 Provider Options

#### Built-in AI (Default)

Two selectable models, both running fully offline via `node-llama-cpp` (ESM). GPU layers
are auto-fit ("max") to available VRAM/unified memory on Apple Silicon (Metal), CPU-only
elsewhere. The user picks between them in Settings → AI Provider → Built-in Model; the
selected model's file is either bundled with the app, downloaded on first use via an
in-app download button, or pre-fetched with `npm run download-model[:phi3]`.

```
Qwen2.5-0.5B-Instruct (Q4_K_M quantization)
  Size: ~400MB
  Native context: up to 32768 tokens

Phi-3-mini-128k-instruct (Q4_K_M quantization)
  Size: ~2.4GB
  Native context: up to 131072 tokens (architectural max; see practical ceiling below)
```

**Configuration Parameters:**

| Parameter | Range | Default | Description |
|-----------|-------|---------|-------------|
| Context Size | 512-32768 | 2048 (Qwen) / 8192 (Phi-3-mini) | Input tokens capacity |
| Max Tokens | 256-4096 | 1536 (Qwen) / 2048 (Phi-3-mini) | Output length limit |
| Batch Size | 128-2048 | 512 | Processing batch size |
| Chunking Threshold | 500-10000ms | 3000ms | Time before adaptive chunking |

The Context Size ceiling is capped at 32768 for both models in the UI, even though
Phi-3-mini's architecture supports up to 131072 — its KV cache costs roughly 32x more
per token than Qwen's (no grouped-query attention, more/larger attention heads), so its
*practical* usable context on consumer hardware is far below its architectural maximum.

**Recommended for Qwen2.5-0.5B:**
- Context Size: 2048
- Max Tokens: 1536
- Batch Size: 512

**Recommended for Phi-3-mini-128k:**
- Context Size: 8192
- Max Tokens: 2048
- Batch Size: 512

#### Ollama (Local HTTP)

```
Endpoint: http://localhost:11434 (configurable)
Models: llama3.2, mistral, phi3, etc.
Setup: User must install Ollama separately
```

#### Mistral API (Cloud)

```
Endpoint: https://api.mistral.ai/v1/chat/completions
Model: mistral-small-latest
Auth: API key from console.mistral.ai
```

### 4.2 Prompt System

**Template Variables:**

| Variable | Value |
|----------|-------|
| `{{topic}}` | H1 heading (research topic) |
| `{{section}}` | Current H2 heading |
| `{{otherSections}}` | List of other H2s (max 5) |
| `{{feedbackTypes}}` | Enabled feedback type descriptions |

**Example System Prompt:**

```
You are a research assistant helping improve academic notes on "{{topic}}".
Current section: "{{section}}"
Other sections in the document: {{otherSections}}

Analyze the content and provide feedback using these categories:
{{feedbackTypes}}

Rules:
- Be SPECIFIC - reference actual content from the notes
- Provide DETAILED suggestions with actual text to add
- Give 2-3 feedback items maximum
- Output ONLY valid JSON array
```

**Expected Output Format:**

```json
[
  {
    "type": "gap",
    "text": "The section on methodology lacks specific sample size information.",
    "suggestion": "Add: 'The study included 150 participants (n=150), recruited from three universities.'",
    "relevantText": "methodology section"
  }
]
```

### 4.3 Response Processing Pipeline

```
Raw LLM Response
    │
    ▼
Strip Markdown Code Blocks (```json ... ```)
    │
    ▼
Extract JSON Array (find [ ... ])
    │
    ▼
Validate Each Item (type, text required)
    │
    ▼
Filter by Enabled Types
    │
    ▼
Add Default Suggestions if Missing
    │
    ▼
Return FeedbackItem[]
```

---

## 5. Current Design System

### 5.1 Design Tokens

#### Typography Scale (1.25 ratio)

```css
--font-size-xs: 0.64rem;    /* 10px - micro labels */
--font-size-sm: 0.8rem;     /* 13px - captions, hints */
--font-size-base: 1rem;     /* 16px - body text */
--font-size-md: 1.125rem;   /* 18px - emphasized */
--font-size-lg: 1.25rem;    /* 20px - small headings */
--font-size-xl: 1.563rem;   /* 25px - section headings */
--font-size-2xl: 1.953rem;  /* 31px - page titles */
```

#### Spacing Scale (4px base)

```css
--space-1: 0.25rem;   /* 4px */
--space-2: 0.5rem;    /* 8px */
--space-3: 0.75rem;   /* 12px */
--space-4: 1rem;      /* 16px */
--space-5: 1.25rem;   /* 20px */
--space-6: 1.5rem;    /* 24px */
--space-8: 2rem;      /* 32px */
```

#### Border Radius

```css
--radius-sm: 6px;     /* badges, chips */
--radius-md: 10px;    /* inputs, buttons */
--radius-lg: 14px;    /* panels, modals */
```

#### Colors

**Backgrounds:**
```css
--bg-primary: #09090b;      /* Main background */
--bg-secondary: #18181b;    /* Cards, modals */
--bg-tertiary: #27272a;     /* Inputs, hover states */
--bg-hover: #3f3f46;        /* Hover highlights */
```

**Text:**
```css
--text-primary: #fafafa;    /* Headings, important */
--text-secondary: #a1a1aa;  /* Body text */
--text-muted: #71717a;      /* Hints, captions */
```

**Accent:**
```css
--accent-color: #9333ea;    /* Primary purple */
--accent-hover: #7c3aed;    /* Hover state */
--accent-glow: rgba(147, 51, 234, 0.25);
```

**Feedback Badge Colors:**

| Type | Background | Text | Border |
|------|------------|------|--------|
| MECE | `rgba(147, 51, 234, 0.08)` | `#c084fc` | `rgba(147, 51, 234, 0.3)` |
| Gap | `rgba(99, 102, 241, 0.08)` | `#a5b4fc` | `rgba(99, 102, 241, 0.3)` |
| Source | `rgba(16, 185, 129, 0.08)` | `#6ee7b7` | `rgba(16, 185, 129, 0.3)` |
| Structure | `rgba(217, 119, 6, 0.08)` | `#fcd34d` | `rgba(217, 119, 6, 0.3)` |

### 5.2 Current Component Styles

#### Sidebar Active State
```css
.note-item.active {
  background: linear-gradient(90deg,
    rgba(147, 51, 234, 0.12) 0%,
    var(--bg-tertiary) 100%);
  border-color: var(--border-color);
  box-shadow: inset 0 0 0 1px rgba(147, 51, 234, 0.08);
}

.note-item.active::before {
  width: 4px;
  background: var(--accent-color);
  box-shadow: 0 0 8px var(--accent-glow);
}
```

#### Feedback Badges
```css
.feedback-item-badge {
  padding: var(--space-2) var(--space-3);
  border-radius: var(--radius-sm);
  font-size: var(--font-size-xs);
  font-weight: 700;
  text-transform: uppercase;
  border: 1px solid var(--{type}-border);
}
```

---

## 6. Planned Design: Liquid Glass

Apple's Liquid Glass design language (iOS 26/macOS 26) requires significant updates to achieve native feel.

### 6.1 New Design Tokens

#### Glass Material System

```css
/* Glass backgrounds with variable opacity */
--glass-subtle: rgba(255, 255, 255, 0.03);
--glass-light: rgba(255, 255, 255, 0.08);
--glass-medium: rgba(255, 255, 255, 0.12);
--glass-heavy: rgba(255, 255, 255, 0.18);

/* Variable blur intensities */
--blur-subtle: blur(8px);
--blur-medium: blur(20px);
--blur-heavy: blur(40px);
--blur-saturate: saturate(180%);

/* Specular highlights (edge reflections) */
--specular-top: linear-gradient(180deg, rgba(255,255,255,0.15) 0%, transparent 50%);
--specular-edge: inset 0 0.5px 0 rgba(255,255,255,0.2);
```

#### Updated Border Radius (More Rounded)

```css
--radius-sm: 12px;      /* badges, chips */
--radius-md: 18px;      /* inputs, buttons */
--radius-lg: 24px;      /* cards, panels */
--radius-xl: 32px;      /* modals, sheets */
--radius-full: 9999px;  /* pills */
```

#### Softer Shadows

```css
/* Layered ambient shadows */
--shadow-float:
  0 2px 4px rgba(0, 0, 0, 0.04),
  0 8px 16px rgba(0, 0, 0, 0.08),
  0 24px 48px rgba(0, 0, 0, 0.12);

/* Glass drop shadow with specular */
--shadow-glass:
  0 8px 32px rgba(0, 0, 0, 0.2),
  inset 0 0.5px 0 rgba(255, 255, 255, 0.1);
```

#### Softer Accent

```css
--accent-color: #a855f7;    /* Lighter, more luminous purple */
--accent-tint: rgba(168, 85, 247, 0.2);
```

### 6.2 Component Transformations

#### Sidebar (Before → After)

**Before:**
```css
.sidebar {
  background: var(--glass-bg);
  backdrop-filter: blur(20px);
  border-right: 1px solid var(--border-subtle);
}
```

**After (Liquid Glass):**
```css
.sidebar {
  background: var(--glass-light);
  backdrop-filter: var(--blur-heavy) var(--blur-saturate);
  -webkit-backdrop-filter: var(--blur-heavy) var(--blur-saturate);
  border-right: none;
  box-shadow: var(--shadow-float);
}
```

#### Buttons (Before → After)

**Before:**
```css
.btn-primary {
  background: var(--accent-gradient);
  border-radius: var(--radius-md);
  box-shadow: var(--shadow-md);
}
```

**After (Liquid Glass):**
```css
.btn-primary {
  background: var(--glass-medium);
  backdrop-filter: var(--blur-medium);
  -webkit-backdrop-filter: var(--blur-medium);
  border-radius: var(--radius-full);
  border: none;
  box-shadow:
    var(--shadow-float),
    var(--specular-edge);
}

.btn-primary:hover {
  background: var(--glass-heavy);
  transform: scale(1.02);
}
```

#### Feedback Panel (Before → After)

**Before:**
```css
.feedback-panel {
  background: var(--glass-bg);
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius-lg);
}
```

**After (Liquid Glass):**
```css
.feedback-panel {
  background: var(--glass-light);
  backdrop-filter: var(--blur-heavy) var(--blur-saturate);
  -webkit-backdrop-filter: var(--blur-heavy) var(--blur-saturate);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-glass);
}
```

#### Modal (Before → After)

**Before:**
```css
.modal {
  background: var(--bg-secondary);
  border: 1px solid var(--border-color);
  border-radius: var(--radius-lg);
}
```

**After (Liquid Glass):**
```css
.modal {
  background: var(--glass-medium);
  backdrop-filter: var(--blur-heavy) var(--blur-saturate);
  -webkit-backdrop-filter: var(--blur-heavy) var(--blur-saturate);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: var(--radius-xl);
  box-shadow:
    0 24px 80px rgba(0, 0, 0, 0.4),
    var(--specular-edge);
}
```

### 6.3 Liquid Glass Principles Summary

| Principle | Current | Liquid Glass |
|-----------|---------|--------------|
| Borders | Solid 1px borders | Minimal/none, use shadow separation |
| Backgrounds | Semi-opaque fills | Highly translucent with blur |
| Corner Radius | 6-14px | 12-32px (more rounded) |
| Shadows | Hard drop shadows | Layered ambient + specular |
| Buttons | Gradient fills | Glass material with backdrop blur |
| Active States | Color change | Glow + slight scale transform |
| Separation | Borders/dividers | Depth via blur intensity |

### 6.4 Implementation Priority

1. **Phase 1**: Update `:root` CSS variables
2. **Phase 2**: Sidebar glass treatment
3. **Phase 3**: Feedback panel floating glass
4. **Phase 4**: Modal sheet-style redesign
5. **Phase 5**: Button pill-shape conversion
6. **Phase 6**: Remove hard borders throughout

---

## 7. Data Models

### 7.1 Note

```typescript
interface Note {
  id: string;                    // UUID v4
  title: string;                 // From H1 or first line
  content: string;               // HTML from TipTap
  createdAt: string;             // ISO 8601 timestamp
  updatedAt: string;             // ISO 8601 timestamp
  excludedSections: string[];    // Section IDs excluded from AI
}
```

### 7.2 Feedback

```typescript
interface FeedbackItem {
  id: string;                    // UUID v4
  type: string;                  // 'gap' | 'mece' | 'source' | 'structure' | custom
  text: string;                  // Feedback description
  suggestion?: string;           // Suggested text to add
  relevantText?: string;         // Referenced content
  status: 'active' | 'accepted' | 'rejected';
  sectionId?: string;            // H2 section reference
}

interface FeedbackTypeConfig {
  id: string;                    // Unique identifier
  label: string;                 // Display name
  description: string;           // What this type checks for
  color: string;                 // Hex color for badge
  enabled: boolean;              // Include in analysis
}
```

### 7.3 Settings

```typescript
interface AISettings {
  // Provider
  provider: 'builtin' | 'ollama' | 'mistral';
  ollamaModel: string;
  ollamaUrl: string;
  mistralApiKey: string;

  // Spellcheck
  spellcheckEnabled: boolean;
  spellcheckLanguages: string[];

  // LLM Parameters
  builtinModel: 'qwen2.5-0.5b' | 'phi-3-mini-128k'; // Which bundled model to use
  chunkingThresholdMs: number;   // 500-10000
  llmContextSize: number;        // 512-32768
  llmMaxTokens: number;          // 256-4096
  llmBatchSize: number;          // 128-2048

  // Prompts
  promptConfig: PromptConfig;
}

interface PromptConfig {
  systemPrompt: string;          // Template with {{variables}}
  feedbackTypes: FeedbackTypeConfig[];
}
```

---

## 8. Settings & Configuration

### 8.1 Settings Modal Tabs

1. **AI Provider**
   - Provider selection (Built-in / Ollama / Mistral)
   - Built-in model selection (Qwen2.5-0.5B / Phi-3-mini-128k), with an in-app
     download button and progress bar for whichever model isn't yet present
   - Provider-specific configuration
   - Chunking threshold
   - Advanced LLM parameters (expandable)

2. **Prompts**
   - System prompt editor (textarea)
   - Feedback type management
     - Add/remove custom types
     - Edit label, description, color
     - Enable/disable types
   - Reset to defaults button

3. **Spellcheck**
   - Enable/disable toggle
   - Multi-language selection (30+ languages)

### 8.2 Data Storage Locations

| Data | Path |
|------|------|
| Notes | `~/.config/Noschen/notes/*.json` |
| Settings | `~/.config/Noschen/settings.json` |
| LLM Model (bundled/dev) | `{app}/models/qwen2.5-0.5b-instruct-q4_k_m.gguf` or `phi-3-mini-128k-instruct-q4_k_m.gguf` |
| LLM Model (in-app download) | `~/.config/Noschen/models/<filename>` |

---

## 9. Build & Distribution

### 9.1 NPM Scripts

```bash
npm run dev          # Development mode (hot reload)
npm run build        # Production build
npm run package      # Create distributable installers
npm run download-model       # Download Qwen2.5-0.5B (default builtin model)
npm run download-model:phi3  # Download Phi-3-mini-128k (bigger-context alternative)
```

### 9.2 Distribution Formats

| Platform | Format | Architecture |
|----------|--------|--------------|
| macOS | DMG, ZIP | Intel (x64), Apple Silicon (arm64) |
| Windows | NSIS, Portable | x64 |
| Linux | AppImage, DEB | x64 |

### 9.3 Code Signing

- macOS: Developer ID signing enabled
- Notarization: Requires Apple Developer credentials

---

## Appendix: File Reference

| File | Purpose |
|------|---------|
| `src/main/main.ts` | Main process entry, IPC handlers |
| `src/main/preload.ts` | Secure context bridge |
| `src/main/llm/localLLM.ts` | Local LLM wrapper |
| `src/renderer/App.tsx` | Root React component |
| `src/renderer/components/Editor.tsx` | TipTap editor + AI trigger |
| `src/renderer/components/FeedbackPanel.tsx` | Feedback display |
| `src/renderer/components/SettingsModal.tsx` | Settings UI |
| `src/renderer/components/Sidebar.tsx` | Note navigation |
| `src/renderer/styles/global.css` | All CSS styles |
| `src/shared/types.ts` | TypeScript interfaces |

---

*Document generated from codebase analysis. For implementation details, refer to source files.*
