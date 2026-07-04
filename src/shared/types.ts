export interface Note {
  id: string;
  title: string;
  content: string;
  createdAt: string;
  updatedAt: string;
  excludedSections: string[];
}

// ═══════════════════════════════════════════════════════════════════════════
// SPEECH-TO-TEXT (Transcription)
// ═══════════════════════════════════════════════════════════════════════════

export type SttProvider = 'mistral-cloud' | 'mistral-local' | 'qwen-edge';

export interface SttSettings {
  sttProvider: SttProvider;
  localSttUrl: string;          // For local/on-prem Voxtral endpoint (e.g. http://localhost:8000)
  qwenSttUrl: string;           // For local Qwen3-ASR edge endpoint (e.g. http://localhost:9000)
  sttTimestamps: boolean;       // Include word-level timestamps
  sttDiarize: boolean;          // Enable speaker diarization (Mistral only)
  sttLanguage: string;          // Language code (e.g. 'en', 'de', 'fr') or empty for auto-detect
}

export interface TranscriptionWord {
  word: string;
  start: number;
  end: number;
}

export interface TranscriptionSegment {
  start: number;
  end: number;
  text: string;
  speaker?: string;
}

export interface TranscriptionResult {
  text: string;
  words?: TranscriptionWord[];
  segments?: TranscriptionSegment[];
  duration?: number;            // Total audio duration in seconds
  error?: string;
}

// Supported audio file extensions for drag-and-drop
export const SUPPORTED_AUDIO_EXTENSIONS = [
  '.mp3', '.wav', '.wave', '.m4a', '.flac', '.ogg', '.opus', '.wma', '.aac', '.webm',
];

export const SUPPORTED_AUDIO_MIME_TYPES = [
  'audio/mpeg', 'audio/wav', 'audio/wave', 'audio/x-wav', 'audio/mp4', 'audio/m4a',
  'audio/flac', 'audio/ogg', 'audio/opus', 'audio/x-ms-wma', 'audio/aac', 'audio/webm',
];

// Custom feedback type configuration
export interface FeedbackTypeConfig {
  id: string;           // Unique identifier (e.g., 'gap', 'mece', 'custom1')
  label: string;        // Display label (e.g., 'Gap', 'MECE')
  description: string;  // What this feedback type checks for
  color: string;        // Hex color for the badge (e.g., '#60a5fa')
  enabled: boolean;     // Whether to include in analysis
}

// AI interaction mode:
// - 'coach' (default): the AI asks questions the writer answers themselves — it never drafts content
// - 'generate': legacy behavior — the AI drafts insertable content
export type AIMode = 'coach' | 'generate';

// Prompt configuration
export interface PromptConfig {
  systemPrompt: string;           // The main system prompt template (used in 'generate' mode and for "Draft it for me")
  feedbackTypes: FeedbackTypeConfig[];  // Configurable feedback types
  mode?: AIMode;                  // Defaults to 'coach'
  coachSystemPrompt?: string;     // System prompt template used in 'coach' mode
}

export interface AISettings {
  provider: 'builtin' | 'ollama' | 'mistral';
  ollamaModel: string;
  ollamaUrl: string;
  mistralApiKey: string;
  spellcheckEnabled: boolean;
  spellcheckLanguages: string[];
  chunkingThresholdMs: number; // Response time threshold for adaptive chunking (ms)
  // Built-in LLM configuration
  llmContextSize: number;   // Context window size (default: 2048)
  llmMaxTokens: number;     // Max tokens to generate (default: 1024)
  llmBatchSize: number;     // Batch size for inference (default: 512)
  // Prompt configuration
  promptConfig: PromptConfig;
  // Speech-to-text configuration
  stt: SttSettings;
}

export interface SpellcheckLanguage {
  code: string;
  name: string;
}

export interface AIContext {
  h1: string;
  h2: string;
  allH2s: string[];
}

export interface FeedbackItem {
  id: string;
  type: string;  // Now accepts any custom type
  text: string;
  suggestion?: string;
  relevantText?: string;
  status: 'active' | 'accepted' | 'rejected';
  sectionId?: string;
  // Coaching extensions (all optional — legacy items remain valid)
  mode?: AIMode;         // 'coach' items carry a question instead of insertable prose
  question?: string;     // The Socratic question the writer answers in their own words
  hint?: string;         // Optional nudge that points where to look without giving the answer
  userResponse?: string; // What the writer wrote in response (their words, inserted verbatim)
}

// ═══════════════════════════════════════════════════════════════════════════
// COACHING — persisted interactions (userData/coaching/<noteId>.json)
// ═══════════════════════════════════════════════════════════════════════════

// 'question': writer answered a coach question in their own words (human-authored)
// 'draft':    writer explicitly requested an AI draft (AI-authored — provenance record)
// 'chat':     a thinking-partner dialogue turn
// 'scaffold': a metacognitive prompt (plan/monitor/evaluate) the writer engaged with
export type CoachInteractionKind = 'question' | 'draft' | 'chat' | 'scaffold';

export interface CoachInteraction {
  id: string;
  noteId: string;
  sectionId?: string;
  kind: CoachInteractionKind;
  type: string;          // Feedback type id (gap, mece, ...) or chat stance
  question: string;      // The question/prompt that was posed
  userResponse?: string; // The writer's own words (human-authored)
  aiDraft?: string;      // Exact AI-authored text inserted, when kind === 'draft' (provenance)
  resolved: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface AIResponse {
  feedback: Omit<FeedbackItem, 'id' | 'status'>[];
  error?: string;
}

// Feedback type category for organization
export type FeedbackCategory = 'core' | 'academic' | 'strategy' | 'cross_cutting' | 'meeting';

// Extended feedback type config with category
export interface FeedbackTypeConfigWithCategory extends FeedbackTypeConfig {
  category: FeedbackCategory;
}

// All available feedback type IDs
export type DefaultFeedbackType =
  // Core
  | 'gap' | 'mece' | 'source' | 'structure'
  // Academic Research
  | 'literature_gap' | 'methodology' | 'argument' | 'bias' | 'so_what' | 'alternatives' | 'operationalization'
  // Strategy Consulting
  | 'assumptions' | 'second_order' | 'stakeholder' | 'implementation' | 'quantify' | 'risk' | 'synthesis'
  // Cross-Cutting
  | 'steel_man' | 'red_team' | 'simplify' | 'action_items'
  // Meeting Notes
  | 'decisions' | 'follow_ups' | 'attendee_alignment' | 'parking_lot' | 'timeline';

// Default colors for built-in types (backwards compatibility)
export const DEFAULT_FEEDBACK_COLORS: Record<string, { bg: string; text: string; border: string }> = {
  // Core
  mece: { bg: '#2d1f3d', text: '#c084fc', border: '#7c3aed' },
  gap: { bg: '#1f2d3d', text: '#60a5fa', border: '#2563eb' },
  source: { bg: '#1f3d2d', text: '#4ade80', border: '#16a34a' },
  structure: { bg: '#3d2d1f', text: '#fbbf24', border: '#d97706' },
  // Academic
  literature_gap: { bg: '#1a2744', text: '#93c5fd', border: '#3b82f6' },
  methodology: { bg: '#3d1f2d', text: '#f87171', border: '#dc2626' },
  argument: { bg: '#3d2a1f', text: '#fb923c', border: '#ea580c' },
  bias: { bg: '#3d1f3d', text: '#f472b6', border: '#db2777' },
  so_what: { bg: '#1f3d3d', text: '#2dd4bf', border: '#14b8a6' },
  alternatives: { bg: '#2a1f3d', text: '#a78bfa', border: '#7c3aed' },
  operationalization: { bg: '#1f3a3d', text: '#22d3ee', border: '#06b6d4' },
  // Strategy
  assumptions: { bg: '#3d1f2a', text: '#fb7185', border: '#e11d48' },
  second_order: { bg: '#2d1f3d', text: '#a78bfa', border: '#8b5cf6' },
  stakeholder: { bg: '#1f3d2a', text: '#34d399', border: '#10b981' },
  implementation: { bg: '#3d351f', text: '#fbbf24', border: '#f59e0b' },
  quantify: { bg: '#2a3d1f', text: '#a3e635', border: '#84cc16' },
  risk: { bg: '#3d1f1f', text: '#ef4444', border: '#dc2626' },
  synthesis: { bg: '#1f2d3d', text: '#38bdf8', border: '#0ea5e9' },
  // Cross-Cutting
  steel_man: { bg: '#2d2d2d', text: '#94a3b8', border: '#64748b' },
  red_team: { bg: '#3d1f1f', text: '#f87171', border: '#ef4444' },
  simplify: { bg: '#1f3d35', text: '#6ee7b7', border: '#34d399' },
  action_items: { bg: '#1f3d3d', text: '#5eead4', border: '#2dd4bf' },
  // Meeting
  decisions: { bg: '#3d351f', text: '#fcd34d', border: '#f59e0b' },
  follow_ups: { bg: '#3d2a1f', text: '#fdba74', border: '#f97316' },
  attendee_alignment: { bg: '#2d1f3d', text: '#d8b4fe', border: '#a855f7' },
  parking_lot: { bg: '#2a2a2a', text: '#a1a1aa', border: '#71717a' },
  timeline: { bg: '#3d1f35', text: '#f9a8d4', border: '#ec4899' },
};

// Default labels for built-in types (backwards compatibility)
export const DEFAULT_FEEDBACK_LABELS: Record<string, string> = {
  // Core
  mece: 'MECE',
  gap: 'Gap',
  source: 'Source',
  structure: 'Structure',
  // Academic
  literature_gap: 'Lit Gap',
  methodology: 'Method',
  argument: 'Argument',
  bias: 'Bias',
  so_what: 'So What?',
  alternatives: 'Alternatives',
  operationalization: 'Measure',
  // Strategy
  assumptions: 'Assumptions',
  second_order: '2nd Order',
  stakeholder: 'Stakeholder',
  implementation: 'Implement',
  quantify: 'Quantify',
  risk: 'Risk',
  synthesis: 'Synthesis',
  // Cross-Cutting
  steel_man: 'Steel Man',
  red_team: 'Red Team',
  simplify: 'Simplify',
  action_items: 'Actions',
  // Meeting
  decisions: 'Decision',
  follow_ups: 'Follow-up',
  attendee_alignment: 'Alignment',
  parking_lot: 'Parking Lot',
  timeline: 'Timeline',
};

// Category labels for UI grouping
export const FEEDBACK_CATEGORY_LABELS: Record<FeedbackCategory, string> = {
  core: 'Core Analysis',
  academic: 'Academic Research',
  strategy: 'Strategy Consulting',
  cross_cutting: 'Cross-Cutting',
  meeting: 'Meeting Notes',
};

// Default feedback type configurations
export const DEFAULT_FEEDBACK_TYPES: FeedbackTypeConfigWithCategory[] = [
  // ═══════════════════════════════════════════════════════════════════════════
  // CORE ANALYSIS (enabled by default)
  // ═══════════════════════════════════════════════════════════════════════════
  {
    id: 'gap',
    label: 'Gap',
    description: 'Missing information, perspectives, or analysis that should be added',
    color: '#60a5fa',
    enabled: true,
    category: 'core',
  },
  {
    id: 'mece',
    label: 'MECE',
    description: 'Categories that are not mutually exclusive or collectively exhaustive',
    color: '#c084fc',
    enabled: true,
    category: 'core',
  },
  {
    id: 'source',
    label: 'Source',
    description: 'Missing citations, references, or empirical evidence needed',
    color: '#4ade80',
    enabled: true,
    category: 'core',
  },
  {
    id: 'structure',
    label: 'Structure',
    description: 'Organization, flow, or formatting improvements needed',
    color: '#fbbf24',
    enabled: true,
    category: 'core',
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // ACADEMIC RESEARCH
  // ═══════════════════════════════════════════════════════════════════════════
  {
    id: 'literature_gap',
    label: 'Literature Gap',
    description: 'Identify gaps in referenced literature and suggest areas/papers to explore',
    color: '#93c5fd',
    enabled: false,
    category: 'academic',
  },
  {
    id: 'methodology',
    label: 'Methodology',
    description: 'Evaluate research design, sample size, validity threats, and methodological rigor',
    color: '#f87171',
    enabled: false,
    category: 'academic',
  },
  {
    id: 'argument',
    label: 'Argument Structure',
    description: 'Assess logical flow, identify weak links in reasoning, and flag logical fallacies',
    color: '#fb923c',
    enabled: false,
    category: 'academic',
  },
  {
    id: 'bias',
    label: 'Bias Detection',
    description: 'Surface potential confirmation bias, selection bias, framing issues, or blind spots',
    color: '#f472b6',
    enabled: false,
    category: 'academic',
  },
  {
    id: 'so_what',
    label: 'So What?',
    description: 'Challenge the significance - why does this matter? What are the implications?',
    color: '#2dd4bf',
    enabled: false,
    category: 'academic',
  },
  {
    id: 'alternatives',
    label: 'Alternatives',
    description: 'Propose competing hypotheses or alternative explanations for observed phenomena',
    color: '#a78bfa',
    enabled: false,
    category: 'academic',
  },
  {
    id: 'operationalization',
    label: 'Operationalization',
    description: 'How would you measure or test this concept empirically? Suggest concrete metrics',
    color: '#22d3ee',
    enabled: false,
    category: 'academic',
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // STRATEGY CONSULTING
  // ═══════════════════════════════════════════════════════════════════════════
  {
    id: 'assumptions',
    label: 'Assumptions',
    description: 'Surface and challenge hidden assumptions underlying the analysis',
    color: '#fb7185',
    enabled: false,
    category: 'strategy',
  },
  {
    id: 'second_order',
    label: 'Second-Order Effects',
    description: 'What happens after the first-order impact? Identify downstream consequences',
    color: '#a78bfa',
    enabled: false,
    category: 'strategy',
  },
  {
    id: 'stakeholder',
    label: 'Stakeholder Lens',
    description: 'How would different stakeholders (customer, competitor, regulator) view this?',
    color: '#34d399',
    enabled: false,
    category: 'strategy',
  },
  {
    id: 'implementation',
    label: 'Implementation',
    description: 'What makes this hard to execute? Identify practical barriers and constraints',
    color: '#fbbf24',
    enabled: false,
    category: 'strategy',
  },
  {
    id: 'quantify',
    label: 'Quantify It',
    description: 'Push for numbers, sizing, and specificity. Replace vague claims with data',
    color: '#a3e635',
    enabled: false,
    category: 'strategy',
  },
  {
    id: 'risk',
    label: 'Risk Scenarios',
    description: 'What could go wrong? Identify risks and suggest best/worst/base case scenarios',
    color: '#ef4444',
    enabled: false,
    category: 'strategy',
  },
  {
    id: 'synthesis',
    label: 'Synthesis',
    description: 'Distill into executive summary, key takeaways, or "so what" for decision-makers',
    color: '#38bdf8',
    enabled: false,
    category: 'strategy',
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // CROSS-CUTTING (works for both academic and consulting)
  // ═══════════════════════════════════════════════════════════════════════════
  {
    id: 'steel_man',
    label: 'Steel Man',
    description: 'Make the strongest possible version of this argument before critiquing',
    color: '#94a3b8',
    enabled: false,
    category: 'cross_cutting',
  },
  {
    id: 'red_team',
    label: 'Red Team',
    description: 'Argue against this position aggressively - find every weakness',
    color: '#f87171',
    enabled: false,
    category: 'cross_cutting',
  },
  {
    id: 'simplify',
    label: 'Simplify',
    description: 'Explain for a different audience (executive, layperson, expert) - reduce jargon',
    color: '#6ee7b7',
    enabled: false,
    category: 'cross_cutting',
  },
  {
    id: 'action_items',
    label: 'Action Items',
    description: 'Convert analysis into concrete, assignable next steps with clear owners',
    color: '#5eead4',
    enabled: false,
    category: 'cross_cutting',
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // MEETING NOTES (auto-detected when content looks like meeting notes)
  // ═══════════════════════════════════════════════════════════════════════════
  {
    id: 'decisions',
    label: 'Decisions',
    description: 'Extract and highlight key decisions made during the meeting',
    color: '#fcd34d',
    enabled: false,
    category: 'meeting',
  },
  {
    id: 'follow_ups',
    label: 'Follow-ups',
    description: 'Identify action items, owners, and deadlines mentioned but not clearly captured',
    color: '#fdba74',
    enabled: false,
    category: 'meeting',
  },
  {
    id: 'attendee_alignment',
    label: 'Alignment Check',
    description: 'Flag areas where attendees may have different interpretations or unclear consensus',
    color: '#d8b4fe',
    enabled: false,
    category: 'meeting',
  },
  {
    id: 'parking_lot',
    label: 'Parking Lot',
    description: 'Identify topics raised but deferred - should be tracked for future discussion',
    color: '#a1a1aa',
    enabled: false,
    category: 'meeting',
  },
  {
    id: 'timeline',
    label: 'Timeline',
    description: 'Extract dates, deadlines, and milestones mentioned; flag conflicts or gaps',
    color: '#f9a8d4',
    enabled: false,
    category: 'meeting',
  },
];

// Default system prompt template
export const DEFAULT_SYSTEM_PROMPT = `You are a research assistant helping improve notes on "{{topic}}".
Current section: "{{section}}"
Other sections in the document: {{otherSections}}

CONTEXT DETECTION:
First, determine what type of content this is:
- MEETING NOTES: Contains attendees, agenda, discussion points, action items, dates/times
- RESEARCH NOTES: Contains analysis, arguments, citations, methodology, findings
- STRATEGY NOTES: Contains recommendations, market analysis, competitive assessment, business cases

Your task: Analyze the notes and provide SPECIFIC, ACTIONABLE feedback with DETAILED suggestions.

Available feedback types (use ONLY from this list):
{{feedbackTypes}}

GUIDELINES BY CONTENT TYPE:

For MEETING NOTES, prioritize:
- decisions: Clearly document what was decided
- follow_ups: Capture action items with owners and deadlines
- timeline: Extract dates and milestones mentioned
- parking_lot: Note deferred topics for future meetings

For RESEARCH NOTES, prioritize:
- gap/literature_gap: Missing information or literature
- source: Claims needing citations
- methodology: Research design issues
- argument: Logical flow problems
- bias: Potential blind spots

For STRATEGY NOTES, prioritize:
- assumptions: Hidden assumptions to test
- quantify: Vague claims needing numbers
- stakeholder: Different perspective views
- risk: What could go wrong
- implementation: Execution barriers

IMPORTANT: Your suggestions must contain ACTUAL CONTENT that can be directly inserted into the notes. Do NOT write generic placeholders like "Add more details" or "Include subsection A". Instead, write the actual paragraphs, analysis, or content.

Example of a GOOD response:
{"feedback":[{"type":"gap","text":"The analysis lacks discussion of economic implications.","suggestion":"The economic impact of this development includes rising costs of supply chain restructuring, estimated at $500B globally. Companies are diversifying manufacturing to Vietnam, India, and Mexico, though this 'friend-shoring' approach increases production costs by 15-20%. The long-term economic equilibrium remains uncertain as nations balance security concerns against efficiency."}]}

Example of a GOOD meeting notes response:
{"feedback":[{"type":"decisions","text":"Key decision not clearly documented.","suggestion":"**DECISION:** The team agreed to proceed with Option B (cloud-first architecture) pending final budget approval from Finance by Jan 30. Sarah will own the implementation timeline."},{"type":"follow_ups","text":"Action item mentioned but not captured.","suggestion":"**ACTION:** @Mike to share competitive analysis deck with the team by EOD Friday (Jan 24). Include pricing comparison for top 3 competitors."}]}

Example of a BAD response (do NOT do this):
{"feedback":[{"type":"structure","text":"Needs better organization.","suggestion":"Add a section header. Include subsection A and B."}]}

Provide 2-4 feedback items based on content complexity. Output ONLY valid JSON:`;

// ═══════════════════════════════════════════════════════════════════════════
// COACH MODE — question stems and system prompt
// ═══════════════════════════════════════════════════════════════════════════

// Curated question stem per feedback type. In coach mode the model selects and
// lightly adapts one of these — it does not invent Socratic questions from
// scratch (small local models are unreliable at that). Also used as the
// fallback question when the model omits one.
export const COACH_QUESTION_STEMS: Record<string, string> = {
  // Core
  gap: 'What evidence or perspective would a skeptic say is missing here?',
  mece: 'Could any of these categories overlap or leave something out — which, and why?',
  source: 'Which claim here would a reviewer ask you to cite, and what kind of source would satisfy them?',
  structure: 'What single claim is this section making — and does its current order help a reader follow it?',
  // Academic
  literature_gap: 'What body of literature bears on this that you have not engaged with yet?',
  methodology: 'What is the biggest threat to validity in this design, and how would you counter it?',
  argument: 'Which step in this argument would be easiest for a critic to attack — and why?',
  bias: 'What would someone who disagrees with you say you are overlooking?',
  so_what: 'If this is true, what changes — who should care, and why?',
  alternatives: 'What alternative explanation could account for the same observation?',
  operationalization: 'How exactly would you measure or test this concept?',
  // Strategy
  assumptions: 'What must be true for this to hold — and how confident are you in each assumption?',
  second_order: 'If this happens, what happens next — which second-order effects follow?',
  stakeholder: 'How would a customer, competitor, or regulator read this differently?',
  implementation: 'What is the hardest practical barrier to executing this?',
  quantify: 'Which vague claim here could you replace with a number — and what is your estimate?',
  risk: 'What is the most plausible way this goes wrong?',
  synthesis: 'If you had one sentence for a decision-maker, what would it say?',
  // Cross-cutting
  steel_man: 'What is the strongest version of the opposing view?',
  red_team: 'Where would a determined critic strike first?',
  simplify: 'How would you explain this to a smart 12-year-old?',
  action_items: 'What is the concrete next step, who owns it, and by when?',
  // Meeting
  decisions: 'What exactly was decided here — can you state it in one sentence?',
  follow_ups: 'Which action item still lacks an owner or a deadline?',
  attendee_alignment: 'Where might attendees walk away with different interpretations?',
  parking_lot: 'Which deferred topic most needs a scheduled follow-up?',
  timeline: 'Which dates or milestones conflict or are missing?',
};

// Default coach-mode system prompt. Inverts the generate-mode contract:
// the model asks questions the writer answers — it never writes content.
export const DEFAULT_COACH_SYSTEM_PROMPT = `You are a research thinking coach for notes on "{{topic}}".
Current section: "{{section}}"
Other sections in the document: {{otherSections}}

Your role: help the WRITER think and remember better. You NEVER write content for them. You ask short, specific questions that make the writer produce the answer themselves.

Available feedback types (use ONLY ids from this list; each shows an example question style):
{{feedbackTypes}}

RULES:
1. Every item must contain a QUESTION the writer can answer by writing. Never provide finished paragraphs, facts, statistics, or example content of your own.
2. Anchor each question to something specific: quote a short phrase from the notes in "relevantText".
3. Be humble — you may be misreading the notes. Phrase observations as questions, not verdicts.
4. Optionally add a short "hint" that points WHERE to look without giving the answer.
5. Prioritize reasoning, evidence, and structure over wording and polish.

Output format — ONLY valid JSON:
{"feedback":[{"type":"<id>","text":"<one sentence: why this matters>","question":"<the question the writer should answer>","hint":"<optional nudge>","relevantText":"<short quote from the notes>"}]}

Example of a GOOD response:
{"feedback":[{"type":"gap","text":"The section claims productivity improved but offers no evidence.","question":"What evidence would a skeptic demand for the claim that productivity 'rose sharply' — and where could you find it?","hint":"Re-read the productivity sentence: is there a study, number, or source behind it?","relevantText":"productivity rose sharply"},{"type":"structure","text":"The section mixes two distinct arguments.","question":"What single claim is this section making — could the second half belong under its own heading?","relevantText":"communication patterns"}]}

Example of a BAD response (do NOT do this — never write content for the writer):
{"feedback":[{"type":"gap","text":"Missing economic analysis.","suggestion":"The economic impact of this development includes rising costs of supply chain restructuring, estimated at $500B globally..."}]}

Provide 2-4 feedback items. Output ONLY valid JSON:`;
