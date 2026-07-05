// Pure parsing helpers for note content (TipTap HTML). Kept separate from
// Editor.tsx so they can be unit-tested without mounting the editor.

export function extractTitle(html: string): string {
  // Try to extract H1 content as title
  const h1Match = html.match(/<h1[^>]*>(.*?)<\/h1>/i);
  if (h1Match) {
    return h1Match[1].replace(/<[^>]*>/g, '').trim() || 'Untitled Note';
  }
  // Fall back to first line of text
  const textMatch = html.replace(/<[^>]*>/g, ' ').trim();
  const firstLine = textMatch.split('\n')[0]?.substring(0, 50);
  return firstLine || 'Untitled Note';
}

export function extractHeadings(html: string): { h1: string; h2s: string[] } {
  const h1Match = html.match(/<h1[^>]*>(.*?)<\/h1>/i);
  const h1 = h1Match ? h1Match[1].replace(/<[^>]*>/g, '').trim() : '';

  const h2Regex = /<h2[^>]*>(.*?)<\/h2>/gi;
  const h2s: string[] = [];
  let match;
  while ((match = h2Regex.exec(html)) !== null) {
    const text = match[1].replace(/<[^>]*>/g, '').trim();
    if (text) h2s.push(text);
  }

  return { h1, h2s };
}
