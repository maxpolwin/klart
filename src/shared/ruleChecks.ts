// Deterministic, offline writing checks — no LLM involved.
//
// These are conservative, named heuristics (the Hemingway pattern): each
// finding tells the writer WHICH rule fired so the heuristic itself is
// learnable and transferable. They run entirely locally and even when the
// AI provider is disconnected. Kept deliberately conservative to avoid
// false-positive fatigue.

export interface RuleFinding {
  rule: string;     // machine id of the rule that fired
  label: string;    // short badge label
  message: string;  // human explanation, naming the heuristic
  excerpt?: string; // offending snippet, when available
}

const MAX_FINDINGS = 6;

// Words that soften claims. High density often signals an argument the
// writer is not ready to commit to (or claims needing evidence).
const HEDGE_WORDS = [
  'might', 'may', 'could', 'perhaps', 'possibly', 'arguably',
  'somewhat', 'likely', 'seems', 'appears', 'potentially', 'probably',
];

// Acronyms that need no definition
const ACRONYM_WHITELIST = new Set([
  'AI', 'US', 'USA', 'UK', 'EU', 'UN', 'OK', 'TODO', 'PDF', 'HTML', 'CSS',
  'JSON', 'API', 'URL', 'FAQ', 'MECE', 'IT', 'ID', 'GPS', 'CEO', 'GDP',
  'NB', 'PS', 'AM', 'PM', 'DIY', 'USD', 'EUR',
]);

const STOPWORDS = new Set([
  'about', 'above', 'after', 'again', 'against', 'along', 'among', 'analysis',
  'around', 'because', 'before', 'being', 'below', 'between', 'context',
  'could', 'discussion', 'during', 'every', 'first', 'notes', 'other',
  'overview', 'review', 'section', 'should', 'summary', 'their', 'there',
  'these', 'thing', 'things', 'through', 'toward', 'under', 'where', 'which',
  'while', 'would',
]);

// Citation-ish patterns: (Author, 2020), (Author et al. 2020), [1], URLs
const CITATION_PATTERN = /\(\s*[A-Z][A-Za-z-]+(?:\s+(?:&|and)\s+[A-Z][A-Za-z-]+)?(?:\s+et\s+al\.?)?,?\s+\d{4}[a-z]?\s*\)|\[\d+\]|https?:\/\/|\bet\s+al\./;

// Strong empirical claims that a reviewer would want sourced
const CLAIM_PATTERN = /\b\d+(?:\.\d+)?\s*(?:%|percent\b)|\b(?:billion|million|trillion)\b|\bsignificant(?:ly)?\s+(?:increase|decrease|higher|lower|effect|impact)\b|\b(?:most|all|no)\s+(?:researchers|studies|experts|evidence)\b|\bstudies\s+(?:show|prove|demonstrate)\b/i;

function htmlToText(html: string): string {
  return html
    .replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim();
}

function extractH2Sections(html: string): { title: string; text: string }[] {
  const sections: { title: string; text: string }[] = [];
  const parts = html.split(/<h2[^>]*>/i);
  // parts[0] is the preamble before the first H2
  for (let i = 1; i < parts.length; i++) {
    const closeIdx = parts[i].indexOf('</h2>');
    if (closeIdx < 0) continue;
    const title = htmlToText(parts[i].slice(0, closeIdx));
    const text = htmlToText(parts[i].slice(closeIdx + 5));
    if (title) sections.push({ title, text });
  }
  return sections;
}

function checkUncitedClaims(text: string, findings: RuleFinding[]) {
  const sentences = text.split(/(?<=[.!?])\s+/);
  let count = 0;
  for (const sentence of sentences) {
    if (count >= 3) break;
    if (sentence.length < 25) continue;
    if (CLAIM_PATTERN.test(sentence) && !CITATION_PATTERN.test(sentence)) {
      findings.push({
        rule: 'uncited-claim',
        label: 'No source',
        message: 'Empirical claim with no citation nearby — a reviewer would ask for the source.',
        excerpt: sentence.trim().substring(0, 90),
      });
      count++;
    }
  }
}

function checkHedgeDensity(text: string, findings: RuleFinding[]) {
  const words = text.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length < 120) return;
  const hedgeCount = words.filter((w) => HEDGE_WORDS.includes(w.replace(/[^a-z]/g, ''))).length;
  const per100 = (hedgeCount / words.length) * 100;
  if (per100 > 4) {
    findings.push({
      rule: 'hedge-density',
      label: 'Hedging',
      message: `High hedge-word density (${hedgeCount} in ${words.length} words) — which claims are you ready to commit to?`,
    });
  }
}

function checkUndefinedAcronyms(text: string, findings: RuleFinding[]) {
  const matches = text.match(/\b[A-Z]{2,6}s?\b/g) || [];
  const counts = new Map<string, number>();
  for (const raw of matches) {
    const acro = raw.replace(/s$/, '');
    if (ACRONYM_WHITELIST.has(acro) || acro.length < 2) continue;
    counts.set(acro, (counts.get(acro) || 0) + 1);
  }

  let reported = 0;
  for (const [acro, count] of counts) {
    if (reported >= 2) break;
    if (count < 2) continue; // only recurring acronyms
    // Defined if it ever appears adjacent to a parenthetical, e.g. "XYZ (…)" or "(XYZ)"
    const defined =
      new RegExp(`\\b${acro}s?\\s*\\(`).test(text) || new RegExp(`\\(\\s*${acro}s?\\s*\\)`).test(text);
    if (!defined) {
      findings.push({
        rule: 'undefined-term',
        label: 'Undefined',
        message: `"${acro}" is used ${count}× but never defined — will every reader know it?`,
      });
      reported++;
    }
  }
}

function checkThinSections(sections: { title: string; text: string }[], findings: RuleFinding[]) {
  if (sections.length < 2) return;
  let reported = 0;
  // Skip the last section — it is probably the one being written right now
  for (const section of sections.slice(0, -1)) {
    if (reported >= 2) break;
    const wordCount = section.text.split(/\s+/).filter(Boolean).length;
    if (wordCount < 25) {
      findings.push({
        rule: 'thin-section',
        label: 'Thin section',
        message: `Section "${section.title}" has almost no content — placeholder, or could it merge with another?`,
      });
      reported++;
    }
  }
}

function checkTitleOverlap(sections: { title: string; text: string }[], findings: RuleFinding[]) {
  if (sections.length < 2) return;
  const seen = new Map<string, string>(); // word -> first title
  for (const section of sections) {
    const words = section.title
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((w) => w.length > 4 && !STOPWORDS.has(w));
    for (const word of words) {
      const firstTitle = seen.get(word);
      if (firstTitle && firstTitle !== section.title) {
        findings.push({
          rule: 'title-overlap',
          label: 'MECE?',
          message: `"${firstTitle}" and "${section.title}" share "${word}" — do these sections overlap?`,
        });
        return; // one MECE hint at most
      }
      if (!firstTitle) seen.set(word, section.title);
    }
  }
}

export function runRuleChecks(html: string): RuleFinding[] {
  const findings: RuleFinding[] = [];
  if (!html || html.replace(/<[^>]*>/g, '').trim().length < 80) return findings;

  // Strip heading elements so their text doesn't bleed into sentence checks
  const text = htmlToText(html.replace(/<h[1-6][^>]*>[\s\S]*?<\/h[1-6]>/gi, ' '));
  const sections = extractH2Sections(html);

  checkUncitedClaims(text, findings);
  checkThinSections(sections, findings);
  checkTitleOverlap(sections, findings);
  checkUndefinedAcronyms(text, findings);
  checkHedgeDensity(text, findings);

  return findings.slice(0, MAX_FINDINGS);
}
