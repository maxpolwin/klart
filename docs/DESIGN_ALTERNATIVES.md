# Design Alternatives: A More Modern, Accessible AI Experience

This document ideates three design directions for how Noschen presents AI assistance.
All three follow the same cross-cutting best practices (below) and differ in *where* AI
lives in the interface and *how much attention* it is allowed to demand.

> **Status:** design-history record. This ideation predates the native Swift/SwiftUI
> rebuild. **Alternative 3 — "Ambient Focus"** is the direction that shipped: the app
> has no persistent AI chrome, only a toolbar pill ("N ready") that opens the coach on
> click or `⌘.`. Implementation references below that mention web mechanics (CSS,
> ARIA roles, ProseMirror) describe the earlier Electron prototype; the SwiftUI app
> achieves the same goals with native equivalents (see the note under each principle).

## Cross-cutting best practices (apply to every alternative)

**AI-UX principles** (drawn from HAX / people-centered AI guidelines):

1. **Visible status, honest latency** — always show whether AI is idle, thinking, or failed.
   Never block typing while analyzing. Show *why* nothing appeared ("note too short",
   "model offline"), not just silence.
2. **User control and consent** — auto-analysis must be a visible, reversible toggle
   (implemented in the editor header as the "Auto" button). On-demand "Analyze" is always
   available. AI never modifies the document without an explicit accept.
3. **Explainability and provenance** — every tip carries its type (Gap, Source, …), what
   text it refers to, and which model produced it. Users can preview and *edit* generated
   content before it enters their document (implemented in the feedback panel).
4. **Graceful error and empty states** — errors are announced via `role="alert"`, are
   dismissible, and self-expire. An empty result is a state, not a bug: say so.
5. **Local-first privacy framing** — the UI should state clearly when analysis runs
   on-device (Ollama / LM Studio) versus in the cloud (OpenRouter or a remote custom
   endpoint), e.g. a small "on-device" / "cloud" chip next to the AI status.

**Accessibility baseline (WCAG 2.2 AA):**

- Text contrast ≥ 4.5:1 (3:1 for large text); never encode meaning by color alone —
  tip badges combine color + label text.
- Full keyboard paths for every action (accept/reject/edit tips, open settings,
  navigate notes); visible focus outlines.
- Pointer targets ≥ 24×24 px (WCAG 2.2 "Target Size (Minimum)").
- Status changes announced politely and failures announced assertively; suggestions
  exposed as a list and panels as labelled regions. *(SwiftUI: `accessibilityLabel` /
  `.accessibilityAddTraits`, and an `accessibility(announcement:)`-style live region for
  the tip count — the SwiftUI analogue of the web build's `aria-live`/`role="alert"`.)*
- Respect Reduce Motion and follow the system light/dark appearance
  (Alternative 3 makes theming a first-class feature).
- Announce, don't move focus: new tips must never steal focus from the editor.

---

## Alternative 1 — "Margin Notes" (anchored review rail)

**Metaphor:** a colleague's pencil notes in the margin, Google-Docs-style.

**Layout.** The editor column stays centered. A slim annotation rail sits to its right.
Each AI tip renders as a small marker (colored dot + type label) vertically aligned with
the paragraph it refers to (`relevantText` anchoring). Hover/focus expands the marker
into a card with the tip text, an editable suggestion, and Accept / Reject / Copy.

**Interaction model.**
- Tips appear where the problem is — no scrolling to a bottom panel.
- `⌘J` / `⌘K` cycles through markers; `Enter` expands, `⌘Enter` accepts, `Esc` collapses.
- Accepted content is inserted at the anchor (not appended at the end), with a brief
  highlight-fade on the inserted range and one-step Undo.
- Anchors degrade gracefully: tips whose text can't be located dock at the top of the rail.

**Why it's modern.** Anchored, in-context assistance is the pattern users now expect
from Docs/Notion/Grammarly. It converts feedback from "a report at the bottom" into
"a conversation with the text".

**Accessibility notes.** Markers are buttons inside a `role="complementary"` rail
labelled "AI suggestions"; each card is announced with its type and target sentence;
rail is skippable via a skip-link; cards trap no focus.

**Trade-offs / effort.** Highest layout complexity (position syncing while typing);
needs ProseMirror decorations for anchor highlights. Effort: **high** — but most of the
data model (per-tip `relevantText`) already exists.

---

## Alternative 2 — "Copilot Panel" (conversational side dock)

**Metaphor:** a research assistant sitting next to you, not inside your text.

**Layout.** A collapsible right-hand dock (320–380 px) with three stacked zones:
(1) status header — model, on-device/cloud chip, auto-analyze toggle;
(2) a scrollable tip feed grouped by section (H2) with filter chips per feedback type;
(3) a refinement input at the bottom: "shorter", "more sources", "in German…" —
each refinement re-runs analysis with the user's instruction appended (the
`customGuidance` plumbing added in this change already supports this server-side).

**Interaction model.**
- The document is never overlaid; the dock can be collapsed to a badge showing the
  count of fresh tips.
- Filter chips let the user see only Source tips, only Structure tips, etc.
- Per-tip actions: Accept (insert at anchor or end), Edit-then-accept, Copy, Reject,
  and "More like this" (biases the next run toward that type).
- Session memory: rejected tips are remembered per note and not resurfaced.

**Why it's modern.** Mirrors the dominant copilot pattern (VS Code, Notion AI, Word
Copilot): assistance is persistent, glanceable, and *instructable* — the user steers
the model in their own words instead of hunting through settings.

**Accessibility notes.** Dock is a landmark (`aside` / "AI assistant"); tip count
changes announced politely; the refinement input is a normal form field, so the whole
loop (ask → result → accept) is fully keyboard/screen-reader operable; collapse state
persisted.

**Trade-offs / effort.** Takes horizontal space on small windows (must collapse
below ~1100 px). Effort: **medium** — it's a re-homing of the existing panel plus
filter/refine controls, no anchoring math.

---

## Alternative 3 — "Ambient Focus" (calm, on-demand assistance)

**Metaphor:** writing first; AI as a quiet heads-up display.

**Layout.** No persistent AI chrome at all. While writing, the only AI element is a
small status pill in the header ("3 tips ready · on-device"). Pressing `⌘.` (or
clicking the pill) slides up a bottom drawer with the tips — the same editable cards —
over a dimmed backdrop. The drawer also hosts a one-line "tip digest" summary
("Mostly missing sources in section 'Methods'").

**Interaction model.**
- Analysis runs silently in the background (or on demand when Auto is off); results
  *never* appear mid-viewport. The pill count incrementing is the only signal.
- Drawer supports swipe-down / `Esc` dismissal; everything else matches the current
  panel (accept, edit, copy, reject).
- First-class theming: light/dark/system with tokens already defined in
  `global.css` — the calm aesthetic depends on correct `prefers-color-scheme` support
  and softer elevation instead of glows.

**Why it's modern.** "Calm technology" is the counter-trend to copilot-everywhere:
tools like iA Writer and Ulysses win on focus. For a note-taking app, protecting flow
is arguably the primary UX feature; AI earns attention instead of demanding it.

**Accessibility notes.** The pill is a live region, so counts are announced without
focus theft; the drawer is a proper `role="dialog"` with focus management and scroll
lock; reduced-motion users get an instant (non-sliding) drawer.

**Trade-offs / effort.** Tips are one interaction further away; anchoring is out of
scope. Effort: **low–medium** — mostly re-composition of existing components.

---

## Comparison and recommendation

| | 1 · Margin Notes | 2 · Copilot Panel | 3 · Ambient Focus |
|---|---|---|---|
| Attention model | in-context | persistent sidebar | on-demand |
| Anchoring to text | strong | optional | none |
| Flow protection | medium | medium | strongest |
| Steerability (refine in words) | low | strongest | medium |
| Implementation effort | high | medium | low–medium |
| Best for | heavy revision passes | research sprints w/ AI dialog | drafting & focus |

**Recommendation:** ship **Alternative 3 first** (low effort, immediate calm-UX win,
reuses the editable-tip cards introduced in this change), then grow toward
**Alternative 1's anchoring** for revision workflows. Alternative 2's refinement input
is worth adding to either — the prompt plumbing (`tipStyle.customGuidance`) already
supports it end-to-end.

An interactive visual mockup of all three alternatives accompanies this document
(see the session artifact "Noschen AI design alternatives").
