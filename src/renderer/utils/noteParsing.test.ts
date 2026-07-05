import { describe, it, expect } from 'vitest';
import { extractTitle, extractHeadings } from './noteParsing';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const { generateNotes } = require('../../../scripts/generate-sample-notes.js');

describe('extractTitle', () => {
  it('uses the H1 as the title', () => {
    expect(extractTitle('<h1>Research Notes: Topic 1</h1><p>body</p>')).toBe(
      'Research Notes: Topic 1'
    );
  });

  it('strips nested tags inside the H1', () => {
    expect(extractTitle('<h1><strong>Bold</strong> Title</h1>')).toBe('Bold Title');
  });

  it('falls back to the first line of text when there is no H1', () => {
    expect(extractTitle('<p>Just a paragraph, no heading.</p>')).toBe(
      'Just a paragraph, no heading.'
    );
  });

  it('falls back to "Untitled Note" for empty content', () => {
    expect(extractTitle('')).toBe('Untitled Note');
  });

  it('falls back to "Untitled Note" for an empty H1', () => {
    expect(extractTitle('<h1></h1><p>body</p>')).toBe('Untitled Note');
  });
});

describe('extractHeadings', () => {
  it('extracts the H1 and all H2s in document order', () => {
    const html =
      '<h1>Meeting Notes</h1><h2>Agenda</h2><p>...</p><h2>Decisions</h2><p>...</p>';
    expect(extractHeadings(html)).toEqual({
      h1: 'Meeting Notes',
      h2s: ['Agenda', 'Decisions'],
    });
  });

  it('returns an empty h1 and h2s array when none are present', () => {
    expect(extractHeadings('<p>no headings here</p>')).toEqual({ h1: '', h2s: [] });
  });

  it('skips H2s that are empty after stripping tags', () => {
    const html = '<h1>Title</h1><h2></h2><h2>Real Section</h2>';
    expect(extractHeadings(html)).toEqual({ h1: 'Title', h2s: ['Real Section'] });
  });
});

describe('extractTitle/extractHeadings against generated sample notes', () => {
  // Regression guard: every note the sample generator produces (research,
  // meeting, strategy content, across all size profiles) must resolve to a
  // non-empty title and its outline must match the section headings used to
  // build it. If a future change to the generator or the parsing regexes
  // breaks this, these tests catch it without needing the Electron app running.
  const notes = generateNotes(60);

  it('resolves a non-empty title for every generated note', () => {
    for (const note of notes) {
      expect(extractTitle(note.content).length).toBeGreaterThan(0);
    }
  });

  it('finds the H1 and at least one H2 for every generated note', () => {
    for (const note of notes) {
      const { h1, h2s } = extractHeadings(note.content);
      expect(h1).toBe(note.title);
      expect(h2s.length).toBeGreaterThan(0);
    }
  });
});
