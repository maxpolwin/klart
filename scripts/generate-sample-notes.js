#!/usr/bin/env node

// Generates realistic sample notes for manual performance testing of
// notes:list / notes:search / editor open+analyze (see src/main/main.ts and
// src/renderer/components/Editor.tsx).
//
// Usage:
//   node scripts/generate-sample-notes.js [--count=300] [--out=<dir>]
//
// By default writes into this OS's Electron userData "notes" folder (the
// same NOTES_DIR the app reads on notes:list), so the generated notes show
// up the next time you launch Noschen. Pass --out to write elsewhere
// instead (e.g. a scratch dir) without touching your real note library.
//
// Each note is one <id>.json file, matching the exact shape written by
// notes:save in src/main/main.ts, with content as TipTap-compatible HTML
// (the format Editor.tsx parses for h1/h2 headings).

const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

function parseArg(name, fallback) {
  const arg = process.argv.find((a) => a.startsWith(`--${name}=`));
  return arg ? arg.slice(name.length + 3) : fallback;
}

const COUNT = parseInt(parseArg('count', '300'), 10);
const OUT_DIR = parseArg('out', defaultNotesDir());

function defaultNotesDir() {
  const appName = 'noschen';
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', appName, 'notes');
  }
  if (process.platform === 'win32') {
    return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), appName, 'notes');
  }
  return path.join(os.homedir(), '.config', appName, 'notes');
}

// ─────────────────────────────────────────────────────────────────────────
// Content templates: one per detection category the app's system prompt
// looks for (see DEFAULT_SYSTEM_PROMPT in src/shared/types.ts), across a
// spread of sizes to exercise chunking/compression at different scales.
// ─────────────────────────────────────────────────────────────────────────

const LOREM_SENTENCES = [
  'The team reviewed quarterly performance against the original targets set in January.',
  'Preliminary results suggest a moderate but statistically significant effect across all cohorts.',
  'Several stakeholders raised concerns about the timeline given current resourcing constraints.',
  'The literature on this topic remains fragmented, with few longitudinal studies available.',
  'Customer feedback indicates strong demand for the feature, particularly among enterprise users.',
  'A follow-up analysis is required to rule out confounding variables in the sample.',
  'Competitors have moved quickly into this space, narrowing the window for differentiation.',
  'The proposed methodology borrows heavily from prior work but adapts the sampling strategy.',
  'Budget approval is still pending final sign-off from finance leadership.',
  'Early experiments show promising results, though the sample size remains small.',
  'The regulatory environment continues to shift, adding uncertainty to the rollout plan.',
  'Cross-functional alignment was reached after several rounds of stakeholder review.',
  'Risks identified include vendor lock-in, data quality gaps, and integration overhead.',
  'The pilot program will run for six weeks before a go/no-go decision is made.',
  'Further research is needed to operationalize this concept into a measurable metric.',
];

function paragraph(sentenceCount) {
  const picked = [];
  for (let i = 0; i < sentenceCount; i++) {
    picked.push(LOREM_SENTENCES[(i + Math.floor(Math.random() * LOREM_SENTENCES.length)) % LOREM_SENTENCES.length]);
  }
  return `<p>${picked.join(' ')}</p>`;
}

function heading2(text) {
  return `<h2>${text}</h2>`;
}

function bulletList(items) {
  return `<ul>${items.map((i) => `<li><p>${i}</p></li>`).join('')}</ul>`;
}

// size: number of body paragraphs per section (controls note length)
function researchNote(title, sections, size) {
  let html = `<h1>${title}</h1>`;
  for (const section of sections) {
    html += heading2(section);
    for (let i = 0; i < size; i++) html += paragraph(3 + (i % 3));
  }
  html += heading2('Sources');
  html += bulletList([
    'Smith, J. et al. (2023). Working paper, unpublished.',
    'Internal survey data, n=' + (100 + Math.floor(Math.random() * 900)),
    'Industry report, competitor benchmarking deck',
  ]);
  return html;
}

function meetingNote(title, attendees, size) {
  let html = `<h1>${title}</h1>`;
  html += `<p><strong>Date:</strong> ${randomDate()} &nbsp; <strong>Attendees:</strong> ${attendees.join(', ')}</p>`;
  html += heading2('Agenda');
  html += bulletList(['Status update', 'Open risks', 'Decisions needed', 'Next steps']);
  html += heading2('Discussion');
  for (let i = 0; i < size; i++) html += paragraph(2 + (i % 2));
  html += heading2('Decisions');
  html += bulletList([
    'Proceed with option B pending budget sign-off.',
    'Defer the migration discussion to next sprint.',
  ]);
  html += heading2('Action Items');
  html += bulletList([
    `@${attendees[0] || 'Owner'} to share the updated deck by Friday.`,
    `@${attendees[1] || 'Owner'} to follow up with legal on the contract terms.`,
  ]);
  return html;
}

function strategyNote(title, sections, size) {
  let html = `<h1>${title}</h1>`;
  for (const section of sections) {
    html += heading2(section);
    for (let i = 0; i < size; i++) html += paragraph(3 + (i % 2));
  }
  return html;
}

function randomDate() {
  const start = new Date(2025, 0, 1).getTime();
  const end = new Date(2026, 6, 5).getTime();
  return new Date(start + Math.random() * (end - start)).toISOString().slice(0, 10);
}

function plainTextLength(html) {
  return html.replace(/<[^>]*>/g, '').length;
}

// ─────────────────────────────────────────────────────────────────────────
// Note "profiles": mix of realistic sizes so the sample set stresses both
// list/search over many small notes and single-note load/analyze on huge
// ones. See MAX_NOTE_CONTENT_BYTES (10 MB) and contentBudgetTokens in
// src/main/main.ts / modelRegistry.json for what "huge" means in-app.
// ─────────────────────────────────────────────────────────────────────────

const PROFILES = [
  { name: 'tiny', weight: 0.35, sectionCount: [1, 2], size: [1, 2] },
  { name: 'medium', weight: 0.35, sectionCount: [3, 5], size: [2, 4] },
  { name: 'large', weight: 0.2, sectionCount: [5, 8], size: [5, 9] },
  { name: 'huge', weight: 0.08, sectionCount: [8, 14], size: [12, 20] },
  { name: 'extreme', weight: 0.02, sectionCount: [15, 25], size: [25, 40] },
];

function pickProfile() {
  const r = Math.random();
  let acc = 0;
  for (const p of PROFILES) {
    acc += p.weight;
    if (r <= acc) return p;
  }
  return PROFILES[0];
}

function randInt([min, max]) {
  return min + Math.floor(Math.random() * (max - min + 1));
}

const RESEARCH_SECTIONS = [
  'Background', 'Hypothesis', 'Methodology', 'Findings', 'Discussion',
  'Limitations', 'Implications', 'Related Work', 'Future Directions', 'Appendix',
];
const STRATEGY_SECTIONS = [
  'Market Overview', 'Competitive Landscape', 'Key Assumptions', 'Recommendation',
  'Financial Impact', 'Risks', 'Implementation Plan', 'Stakeholder Views', 'Next Steps',
];
const NAMES = ['Alex', 'Priya', 'Jordan', 'Sam', 'Chen', 'Morgan', 'Taylor', 'Riley'];

function buildNote(index) {
  const profile = pickProfile();
  const size = randInt(profile.size);
  const sectionCount = randInt(profile.sectionCount);
  const kind = index % 3;

  let title, content;
  if (kind === 0) {
    title = `Research Notes: Topic ${index}`;
    content = researchNote(title, shuffle(RESEARCH_SECTIONS).slice(0, sectionCount), size);
  } else if (kind === 1) {
    const attendees = shuffle(NAMES).slice(0, 2 + (index % 3));
    title = `Meeting Notes: Sync ${index}`;
    content = meetingNote(title, attendees, size);
  } else {
    title = `Strategy Note: Initiative ${index}`;
    content = strategyNote(title, shuffle(STRATEGY_SECTIONS).slice(0, sectionCount), size);
  }

  const createdAt = new Date(Date.now() - randInt([0, 200]) * 86400000).toISOString();
  const updatedAt = new Date(new Date(createdAt).getTime() + randInt([0, 5]) * 86400000).toISOString();

  return {
    id: crypto.randomUUID(),
    title,
    content,
    createdAt,
    updatedAt,
    excludedSections: [],
    _profile: profile.name, // stripped before writing; kept for the summary log
    _chars: plainTextLength(content),
  };
}

function shuffle(arr) {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function generateNotes(count) {
  const notes = [];
  for (let i = 0; i < count; i++) notes.push(buildNote(i));
  return notes;
}

function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const summary = {};
  for (const note of generateNotes(COUNT)) {
    const profile = note._profile;
    const chars = note._chars;
    delete note._profile;
    delete note._chars;

    fs.writeFileSync(path.join(OUT_DIR, `${note.id}.json`), JSON.stringify(note, null, 2));

    summary[profile] = summary[profile] || { count: 0, totalChars: 0 };
    summary[profile].count++;
    summary[profile].totalChars += chars;
  }

  console.log(`Wrote ${COUNT} sample notes to ${OUT_DIR}\n`);
  console.log('Size profile'.padEnd(12), 'Count'.padEnd(8), 'Avg chars');
  for (const [name, s] of Object.entries(summary)) {
    console.log(name.padEnd(12), String(s.count).padEnd(8), Math.round(s.totalChars / s.count));
  }
  console.log('\nRestart Noschen (or reopen the notes list) to see them.');
  console.log('Things worth timing while these are loaded:');
  console.log('  - App startup / time-to-first-notes-list-render');
  console.log('  - notes:search latency while typing (linear scan over all notes)');
  console.log('  - Opening a "huge"/"extreme" note and running AI analysis (chunking + compression)');
  console.log('  - Editor typing latency on a huge note (TipTap re-render cost)');
}

module.exports = { buildNote, generateNotes, PROFILES };

if (require.main === module) {
  main();
}
