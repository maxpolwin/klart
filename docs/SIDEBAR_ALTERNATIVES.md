# Sidebar Alternatives: A Cleaner, More Minimal Notes List

The current sidebar (`SidebarView.swift`) works but reads as cramped: the
native `.searchable(placement: .sidebar)` field sits flush against the first
row of the list with no breathing room, rows are dense (3pt vertical padding),
and there's no visual grouping to help the eye land on a specific note in a
long list. This document ideates four alternatives that all fix the
search-to-list gap and pursue a cleaner, more minimal sidebar, using
Noschen's existing "Quiet" palette (`Theme.swift`) — no new colors.

## Cross-cutting best practices (apply to every alternative)

1. **Whitespace is structural, not padding-as-afterthought.** Every
   alternative below creates separation between the search field and the
   list through a deliberate layout decision (a gap token, a section label,
   or — in Alternative 4 — the data itself), not just a bigger number.
2. **44×24 pt minimum hit targets** (WCAG 2.2 "Target Size Minimum") — every
   row, in every alternative, resolves to at least a 44pt-tall tap/click
   area even where the visual content is shorter.
3. **Never encode selection or state by color alone.** Selected rows pair a
   background tint with a shape cue (leading bar, border, or elevation), so
   the state reads in grayscale and for color-blind users.
4. **Keep it a real list.** Whatever the visual treatment, the underlying
   accessibility tree stays a `List`/`ForEach` with row semantics — Concept 4
   is the one alternative that needs an explicit fallback note on this (see
   below).
5. **Respect `prefers-reduced-motion`** — hover/selection transitions are
   ≤150 ms fades, never introduced as the *only* way to notice a state
   change.
6. **One accent, used sparingly.** All four reuse `Theme.accent` for exactly
   one thing each (selection, or the timeline spine) — never as decoration.

---

## Alternative 1 — "Quiet Rail" (refined minimal baseline)

**Metaphor:** the current sidebar, but every element is given room to
breathe. The lowest-risk, highest-consistency option.

**Layout.** The search field is inset 12pt from both edges inside a soft
rounded field (instead of the flush native toolbar search), followed by a
fixed 28pt gap before the list begins — the single biggest lever for the
"cramped" complaint. Rows drop the alternating chrome entirely: no
dividers, 52pt tall, title + one metadata line (relative time · one-line
preview), hover state is a 6% tint, selection is a 6% accent wash **plus** a
3pt leading accent bar so it never relies on color alone.

**Why it's cleaner.** Removing per-row dividers and leaning on consistent
row height + generous line-height does more for "minimal" than any new
component would — this is the François Truffaut version of a redesign:
subtract, don't add.

**Trade-offs / effort.** Lowest effort — swap `.searchable` for a custom
inset `TextField`, adjust `NoteRow` padding, add a selection-bar overlay.
No data model changes. **Effort: low.**

---

## Alternative 2 — "Grouped Timeline" (date-sectioned)

**Metaphor:** Mail.app / Messages — notes chunked by recency so the eye
scans groups, not 40 identical rows.

**Layout.** Search field as in Alternative 1, then a 24pt gap, then sticky
section headers — `TODAY`, `YESTERDAY`, `THIS WEEK`, `EARLIER` — as 10px
uppercase, letter-spaced labels with their own 20pt top margin. Whitespace
comes from *grouping*, not just padding: each section boundary is itself a
moment of visual rest. Rows inside a group can sit slightly tighter (44pt)
since the group label already tells the user roughly "when," reducing how
much each row needs to communicate.

**Why it's cleaner.** This is Miller's-Law chunking applied to a note list:
grouping turns "scan 40 items" into "scan 4 groups, then ~8 items." It's
also the alternative that scales best as note counts grow — Concept 1 gets
visually noisier with more notes, this one doesn't.

**Trade-offs / effort.** Needs a `Dictionary(grouping:)` over
`state.filteredNotes` by day-bucket, plus sticky headers (`Section` inside
`List` gives this natively in SwiftUI). Search must decide whether grouping
persists during a query (recommendation: flatten to a single "Results"
section while searching, regroup when the query clears). **Effort:
low–medium.**

---

## Alternative 3 — "Card Rail" (elevated, detached cards)

**Metaphor:** Craft / Notion sidebars — each note is a distinct object you
pick up, not a row you scan through.

**Layout.** The search field lives in its own header zone with a bottom
hairline, visually detached from the list below it (20pt padding above and
below). Each note renders as a rounded-12 card using `Theme.surfaceRaised`
as its resting background, with **true whitespace between cards** (10pt
gap) rather than internal-only padding — this is the alternative where the
gap the user asked for is repeated at every row, not just once at the top.
Selection swaps the card to an accent-tinted background + border (macOS
Sequoia's "tinted," not solid-fill, selection style) instead of the old
solid blue highlight.

**Why it's cleaner.** Discrete cards read as more minimal *despite* using
more pixels per row, because each one is unambiguously a separate object —
there's nothing to visually parse, no dividers to distinguish from
selection state.

**Trade-offs / effort.** Straightforward SwiftUI (`.background(_, in:
RoundedRectangle)` per row + `LazyVStack` with `spacing: 10` instead of
`List`, since `List` fights custom inter-row spacing on macOS). Losing
`List` means re-implementing keyboard row navigation and the native
right-click/hover chrome. **Effort: medium.**

---

## Alternative 4 — "Constellation" (creative: time as the layout)

**Metaphor:** a research journal's timeline, not a file list — the sidebar
becomes a quiet vertical spine with notes as points along it, spaced by how
long ago they were written.

**Layout.** The search field is a borderless, underline-only field (only
gains a visible box on focus) to keep the header nearly invisible, followed
by a deliberate 32pt gap before a thin vertical line (1px, `Theme.border`)
runs down the sidebar. Each note is a small dot on the line — dot size and
opacity scale with recency (today's notes are solid and larger; a note from
three weeks ago is a faint outline) — with the title set beside it. **The
vertical gap between two dots is proportional to the real time gap between
the notes**, compressed logarithmically so a six-month-old note doesn't push
the list off-screen. This makes whitespace literally meaningful: a large
gap on the spine *is* the information "nothing happened here," which is
exactly the kind of "quiet" a research tool for thinking should have.
Hovering a dot grows it and slides in the one-line preview; the accent
color is reserved for exactly one thing — the spine segment behind the
selected note.

**Why it's the creative swing.** Every other alternative is still
fundamentally a list with better spacing. This one repurposes the app's own
premise — Noschen exists to support *thinking over time* — as the sidebar's
organizing metaphor. It's the option most likely to feel distinctive in a
screenshot, and the one most in keeping with "AI-powered **research**
note-taking," rather than a generic file browser.

**Accessibility fallback (important).** The proportional-gap visualization
is decorative on top of a real, evenly-navigable list: VoiceOver and
keyboard `List` traversal must move row-to-row exactly as in the other
three alternatives, in document order, with the same 44pt+ hit targets —
only the *visual* Y-position is time-proportional. For very large note
counts (dozens created the same minute), gap compression must clamp to a
minimum so rows never visually collide or drop below the 44pt hit-target
floor. Reduced-motion users get the dot growth/preview slide as an instant
state change, not an animation.

**Trade-offs / effort.** Requires computing normalized time-offsets per
note and a custom `Path` for the spine, plus the clamping logic above.
Highest design risk (needs a few sessions of live use to validate it
doesn't feel gimmicky at 100+ notes). **Effort: medium–high.**

---

## Comparison and recommendation

| | 1 · Quiet Rail | 2 · Grouped Timeline | 3 · Card Rail | 4 · Constellation |
|---|---|---|---|---|
| Fixes the search→list gap | yes (fixed 28pt) | yes (fixed 24pt + label) | yes (header zone) | yes (32pt + spine) |
| Scales to 100+ notes | fair | **best** | fair | needs clamping |
| Visual distinctiveness | low | low–medium | medium | **highest** |
| Keeps native `List` (cheap keyboard/VoiceOver) | yes | yes | no (custom stack) | no (custom, needs fallback) |
| Implementation effort | **low** | low–medium | medium | medium–high |

**Recommendation:** ship **Alternative 1 ("Quiet Rail") first** — it directly
answers the whitespace complaint with almost no risk and no data-model
changes, and every other alternative can be layered on top of its spacing
tokens later. Follow with **Alternative 2** once note counts in real usage
justify grouping. Keep **Alternative 4** as the "big bet" — worth a
throwaway prototype in the real app to see whether the time-proportional
spine holds up outside a mockup, since it's the one direction that turns
Noschen's own premise (thinking over time) into the interface itself.

An interactive visual mockup of all four alternatives accompanies this
document (see the session artifact "Noschen — Sidebar Directions").
