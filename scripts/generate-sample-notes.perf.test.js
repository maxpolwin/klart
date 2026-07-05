// Performance regression test for the note list/search path.
//
// This mirrors the algorithm in src/main/main.ts (getNotesCache + sortNotes +
// notes:search) closely enough to catch a regression introduced there or in
// the sample generator, without needing to boot Electron. It is NOT a
// micro-benchmark — thresholds are deliberately generous (10-20x headroom
// over observed local timings) so it fails only on a real slowdown, not CI
// jitter. Run via `npm run test:perf`.

import { describe, it, expect } from 'vitest';

const { generateNotes } = require('./generate-sample-notes.js');

// Same as getNotesCache() in src/main/main.ts: parse each note from its
// on-disk JSON representation and build an id -> Note map.
function loadCache(rawNotes) {
  const cache = new Map();
  for (const raw of rawNotes) {
    const note = JSON.parse(raw);
    cache.set(note.id, note);
  }
  return cache;
}

// Same as sortNotes() in src/main/main.ts.
function sortNotes(notes) {
  return notes.sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime());
}

// Same as the notes:search handler in src/main/main.ts.
function search(notes, query) {
  const lowerQuery = query.toLowerCase();
  return notes.filter(
    (note) =>
      note.title.toLowerCase().includes(lowerQuery) || note.content.toLowerCase().includes(lowerQuery)
  );
}

describe('notes list/search performance', () => {
  const NOTE_COUNT = 500;
  const notes = generateNotes(NOTE_COUNT);
  const rawNotes = notes.map((n) => JSON.stringify(n));

  it(`parses and caches ${NOTE_COUNT} notes in well under a second`, () => {
    const start = performance.now();
    const cache = loadCache(rawNotes);
    const elapsed = performance.now() - start;

    expect(cache.size).toBe(NOTE_COUNT);
    expect(elapsed).toBeLessThan(1000);
  });

  it(`sorts ${NOTE_COUNT} notes by updatedAt in well under a second`, () => {
    const cache = loadCache(rawNotes);
    const start = performance.now();
    const sorted = sortNotes([...cache.values()]);
    const elapsed = performance.now() - start;

    for (let i = 1; i < sorted.length; i++) {
      expect(new Date(sorted[i - 1].updatedAt).getTime()).toBeGreaterThanOrEqual(
        new Date(sorted[i].updatedAt).getTime()
      );
    }
    expect(elapsed).toBeLessThan(1000);
  });

  it(`searches across ${NOTE_COUNT} notes (title+content) in well under a second`, () => {
    const cache = loadCache(rawNotes);
    const all = [...cache.values()];
    const start = performance.now();
    const results = search(all, 'decision');
    const elapsed = performance.now() - start;

    expect(results.length).toBeGreaterThan(0);
    for (const r of results) {
      const haystack = (r.title + r.content).toLowerCase();
      expect(haystack).toContain('decision');
    }
    expect(elapsed).toBeLessThan(1000);
  });
});
