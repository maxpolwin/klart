import { app, BrowserWindow, ipcMain, session, Menu, MenuItem, shell, nativeTheme } from 'electron';
import * as path from 'path';
import * as fs from 'fs';
import * as fsp from 'fs/promises';
import { v4 as uuidv4 } from 'uuid';
import {
  initializeLocalLLM,
  generateLocalResponse,
  checkLocalLLMAvailable,
  shutdownLocalLLM,
  truncateToTokenBudget,
  estimateTokens,
  LLMConfig,
  getLocalLLMStatus,
  getModelPath,
  getUserModelsDir,
} from './llm/localLLM';
import {
  BUILTIN_MODELS,
  DEFAULT_BUILTIN_MODEL_ID,
  effectiveMaxContext,
  getModelById,
  resolveModel,
} from './llm/modelRegistry';
import {
  downloadModel,
  cancelDownload,
  deleteDownloadedModel,
  getDownloadSnapshot,
  abortAllDownloads,
  sweepStalePartials,
  DownloadProgress,
} from './llm/modelDownloader';
import {
  compressText,
  getCompressorStatus,
  disposeCompressor,
} from './llm/promptCompressor';
import {
  getMistralApiKey,
  setMistralApiKey,
  migrateApiKeyFromSettings,
  isEncryptionAvailable,
} from './secureStorage';

interface Note {
  id: string;
  title: string;
  content: string;
  createdAt: string;
  updatedAt: string;
  excludedSections: string[];
}

interface FeedbackTypeConfig {
  id: string;
  label: string;
  description: string;
  color: string;
  enabled: boolean;
}

interface TipStyleConfig {
  detailLevel: 'brief' | 'standard' | 'detailed';
  tone: 'neutral' | 'academic' | 'direct' | 'encouraging';
  maxTips: number;
  language: string; // '' = match the language of the notes
  customGuidance: string;
}

interface PromptConfig {
  systemPrompt: string;
  feedbackTypes: FeedbackTypeConfig[];
  tipStyle?: TipStyleConfig;
}

interface SttSettings {
  sttProvider: 'mistral-cloud' | 'mistral-local' | 'qwen-edge';
  localSttUrl: string;
  qwenSttUrl: string;
  sttTimestamps: boolean;
  sttDiarize: boolean;
  sttLanguage: string;
}

interface AISettings {
  provider: 'builtin' | 'ollama' | 'mistral';
  builtinModel: 'qwen2.5-0.5b' | 'phi-3-mini-128k';
  ollamaModel: string;
  ollamaUrl: string;
  mistralApiKey: string;
  spellcheckEnabled: boolean;
  spellcheckLanguages: string[];
  chunkingThresholdMs: number;
  llmContextSize: number;
  llmMaxTokens: number;
  llmBatchSize: number;
  compressionEnabled: boolean; // Use LLMLingua-2 prompt compression to fit the token budget
  promptConfig: PromptConfig;
  stt: SttSettings;
}

// Default feedback types
const DEFAULT_FEEDBACK_TYPES: FeedbackTypeConfig[] = [
  {
    id: 'gap',
    label: 'Gap',
    description: 'Missing information, perspectives, or analysis that should be added',
    color: '#60a5fa',
    enabled: true,
  },
  {
    id: 'mece',
    label: 'MECE',
    description: 'Categories that are not mutually exclusive or collectively exhaustive',
    color: '#c084fc',
    enabled: true,
  },
  {
    id: 'source',
    label: 'Source',
    description: 'Missing citations, references, or empirical evidence',
    color: '#4ade80',
    enabled: true,
  },
  {
    id: 'structure',
    label: 'Structure',
    description: 'Organization, flow, or formatting improvements needed',
    color: '#fbbf24',
    enabled: true,
  },
];

const DEFAULT_TIP_STYLE: TipStyleConfig = {
  detailLevel: 'standard',
  tone: 'neutral',
  maxTips: 3,
  language: '',
  customGuidance: '',
};

// Default system prompt template
const DEFAULT_SYSTEM_PROMPT = `You are a research assistant helping improve academic notes on "{{topic}}".
Current section: "{{section}}"
Other sections in the document: {{otherSections}}

Your task: Analyze the notes and provide SPECIFIC, ACTIONABLE feedback with DETAILED suggestions.

Feedback types:
{{feedbackTypes}}

IMPORTANT: Your suggestions must contain ACTUAL CONTENT that can be directly inserted into the notes. Do NOT write generic placeholders like "Add more details" or "Include subsection A". Instead, write the actual paragraphs, analysis, or content.

Example of a GOOD response:
{"feedback":[{"type":"gap","text":"The analysis lacks discussion of economic implications.","suggestion":"The economic impact of this development includes rising costs of supply chain restructuring, estimated at $500B globally. Companies are diversifying manufacturing to Vietnam, India, and Mexico, though this 'friend-shoring' approach increases production costs by 15-20%. The long-term economic equilibrium remains uncertain as nations balance security concerns against efficiency."}]}

Example of a BAD response (do NOT do this):
{"feedback":[{"type":"structure","text":"Needs better organization.","suggestion":"Add a section header. Include subsection A and B."}]}

Provide 2-3 feedback items. Output ONLY valid JSON:`;

const NOTES_DIR = path.join(app.getPath('userData'), 'notes');
const SETTINGS_FILE = path.join(app.getPath('userData'), 'settings.json');

// Sent to the renderer instead of the real API key; if it comes back unchanged
// on save, the stored key is kept. The plaintext key never leaves the main process.
const MASKED_API_KEY = '••••••••';

const NOTE_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_NOTE_CONTENT_BYTES = 10 * 1024 * 1024; // 10 MB per note
const MAX_AUDIO_FILE_BYTES = 250 * 1024 * 1024; // 250 MB per audio file
const LLM_FETCH_TIMEOUT_MS = 120_000;
const STT_FETCH_TIMEOUT_MS = 600_000;

function ensureDirectories() {
  if (!fs.existsSync(NOTES_DIR)) {
    fs.mkdirSync(NOTES_DIR, { recursive: true });
  }
}

function getDefaultSettings(): AISettings {
  return {
    provider: 'builtin',
    builtinModel: 'qwen2.5-0.5b',
    ollamaModel: 'llama3.2',
    ollamaUrl: 'http://localhost:11434',
    mistralApiKey: '',
    spellcheckEnabled: true,
    spellcheckLanguages: ['en-US'],
    chunkingThresholdMs: 3000, // 3 seconds default (increased for better responses)
    llmContextSize: 2048,      // Context window size
    llmMaxTokens: 1536,        // Max tokens to generate (increased for detailed responses)
    llmBatchSize: 512,         // Batch size for inference
    compressionEnabled: true,  // LLMLingua-2 prompt compression (falls back to truncation if model missing)
    promptConfig: {
      systemPrompt: DEFAULT_SYSTEM_PROMPT,
      feedbackTypes: DEFAULT_FEEDBACK_TYPES,
      tipStyle: DEFAULT_TIP_STYLE,
    },
    stt: {
      sttProvider: 'mistral-cloud',
      localSttUrl: 'http://localhost:8000',
      qwenSttUrl: 'http://localhost:9000',
      sttTimestamps: true,
      sttDiarize: false,
      sttLanguage: '',
    },
  };
}

function loadSettings(): AISettings {
  try {
    if (fs.existsSync(SETTINGS_FILE)) {
      let raw = JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf-8'));

      // Migrate plaintext API key from settings.json to secure storage
      if (raw.mistralApiKey && raw.mistralApiKey.length > 0 && raw.mistralApiKey !== MASKED_API_KEY) {
        raw = migrateApiKeyFromSettings(raw);
        // Re-save settings without the plaintext key
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(raw, null, 2));
      }

      // Merge with defaults so newly added settings (e.g. compressionEnabled)
      // get sensible values for pre-existing settings.json files.
      raw = { ...getDefaultSettings(), ...raw };

      // A hand-edited or stale builtinModel must never reach the model loader
      if (!getModelById(raw.builtinModel)) {
        raw.builtinModel = DEFAULT_BUILTIN_MODEL_ID;
      }

      // Inject the API key from secure storage
      raw.mistralApiKey = getMistralApiKey();
      return raw as AISettings;
    }
  } catch (error) {
    console.error('Failed to load settings:', error);
  }
  return getDefaultSettings();
}

function saveSettings(settings: AISettings) {
  // Store the API key only in secure storage (an empty value clears it)
  setMistralApiKey(settings.mistralApiKey || '');

  // Save settings without the plaintext API key
  const settingsToSave = { ...settings, mistralApiKey: '' };
  fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settingsToSave, null, 2));
}

function maskSettingsForRenderer(settings: AISettings): AISettings {
  return { ...settings, mistralApiKey: settings.mistralApiKey ? MASKED_API_KEY : '' };
}

// Validate user-configured endpoint URLs before fetching (http/https only)
function sanitizeHttpBaseUrl(raw: string, fallback: string): string {
  const candidate = (raw || fallback).trim();
  const url = new URL(candidate);
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`Unsupported URL protocol: ${url.protocol}`);
  }
  return url.toString().replace(/\/+$/, '');
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

let mainWindow: BrowserWindow | null = null;

const isDev = !app.isPackaged;

// Only the app itself may be loaded in the window; external links go to the browser.
function isAllowedNavigation(url: string): boolean {
  try {
    const parsed = new URL(url);
    if (isDev && parsed.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(parsed.hostname)) {
      return true;
    }
    return parsed.protocol === 'file:';
  } catch {
    return false;
  }
}

async function createWindow() {
  const settings = loadSettings();

  mainWindow = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 800,
    minHeight: 600,
    // Match the system appearance so there's no flash before the UI paints
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#1a1712' : '#f4efe4',
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: settings.spellcheckEnabled,
    },
  });

  // Open external links in the system browser, never in-app
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\//i.test(url)) {
      shell.openExternal(url);
    }
    return { action: 'deny' };
  });

  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (!isAllowedNavigation(url)) {
      event.preventDefault();
      if (/^https:\/\//i.test(url)) {
        shell.openExternal(url);
      }
    }
  });

  // Configure spellchecker languages
  if (settings.spellcheckEnabled && settings.spellcheckLanguages.length > 0) {
    session.defaultSession.setSpellCheckerLanguages(settings.spellcheckLanguages);
  }

  // Set up context menu for spelling corrections
  mainWindow.webContents.on('context-menu', (event, params) => {
    const menu = new Menu();

    // Add spelling suggestions if there are any
    if (params.misspelledWord) {
      for (const suggestion of params.dictionarySuggestions.slice(0, 5)) {
        menu.append(new MenuItem({
          label: suggestion,
          click: () => mainWindow?.webContents.replaceMisspelling(suggestion),
        }));
      }

      if (params.dictionarySuggestions.length > 0) {
        menu.append(new MenuItem({ type: 'separator' }));
      }

      // Add to dictionary option
      menu.append(new MenuItem({
        label: `Add "${params.misspelledWord}" to dictionary`,
        click: () => mainWindow?.webContents.session.addWordToSpellCheckerDictionary(params.misspelledWord),
      }));

      menu.append(new MenuItem({ type: 'separator' }));
    }

    // Standard edit menu items
    if (params.isEditable) {
      menu.append(new MenuItem({ role: 'cut', label: 'Cut' }));
      menu.append(new MenuItem({ role: 'copy', label: 'Copy' }));
      menu.append(new MenuItem({ role: 'paste', label: 'Paste' }));
      menu.append(new MenuItem({ role: 'selectAll', label: 'Select All' }));
    } else if (params.selectionText) {
      menu.append(new MenuItem({ role: 'copy', label: 'Copy' }));
    }

    if (menu.items.length > 0) {
      menu.popup();
    }
  });

  if (isDev) {
    // Try common dev server ports
    const ports = [5173, 5174, 5175, 3000];
    let loaded = false;

    for (const port of ports) {
      try {
        await mainWindow.loadURL(`http://localhost:${port}`);
        console.log(`Loaded dev server on port ${port}`);
        loaded = true;
        break;
      } catch {
        console.log(`Port ${port} not available, trying next...`);
      }
    }

    if (!loaded) {
      console.error('Could not connect to dev server');
    }

    mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  }
}

app.whenReady().then(async () => {
  ensureDirectories();

  // Deny all permission requests except sanitized clipboard writes (used by the
  // copy-suggestion button); nothing else in the app needs browser permissions.
  session.defaultSession.setPermissionRequestHandler((_wc, permission, callback) => {
    callback(permission === 'clipboard-sanitized-write');
  });

  await createWindow();

  // Clean up model-download leftovers from a previous crash (non-blocking)
  void sweepStalePartials();

  app.on('activate', async () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      await createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// NOTES (async fs + in-memory cache: the disk is only read once per session,
// and list/search never re-read every file)
// ═══════════════════════════════════════════════════════════════════════════

let notesCache: Map<string, Note> | null = null;

function isValidNoteId(id: unknown): id is string {
  return typeof id === 'string' && NOTE_ID_PATTERN.test(id);
}

function notePath(id: string): string {
  return path.join(NOTES_DIR, `${id}.json`);
}

async function getNotesCache(): Promise<Map<string, Note>> {
  if (notesCache) return notesCache;

  const cache = new Map<string, Note>();
  try {
    const files = (await fsp.readdir(NOTES_DIR)).filter((f) => f.endsWith('.json'));
    await Promise.all(
      files.map(async (file) => {
        try {
          const content = await fsp.readFile(path.join(NOTES_DIR, file), 'utf-8');
          const note = JSON.parse(content) as Note;
          if (note && isValidNoteId(note.id)) {
            cache.set(note.id, note);
          }
        } catch (error) {
          console.error(`Failed to read note ${file}:`, error);
        }
      })
    );
  } catch (error) {
    console.error('Failed to read notes directory:', error);
  }

  notesCache = cache;
  return cache;
}

function sortNotes(notes: Note[]): Note[] {
  return notes.sort(
    (a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime()
  );
}

ipcMain.handle('notes:list', async () => {
  const cache = await getNotesCache();
  return sortNotes([...cache.values()]);
});

ipcMain.handle('notes:get', async (_, id: string) => {
  if (!isValidNoteId(id)) return null;
  const cache = await getNotesCache();
  return cache.get(id) ?? null;
});

ipcMain.handle('notes:create', async () => {
  const note: Note = {
    id: uuidv4(),
    title: 'Untitled Note',
    content: '',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    excludedSections: [],
  };

  const cache = await getNotesCache();
  cache.set(note.id, note);
  await fsp.writeFile(notePath(note.id), JSON.stringify(note, null, 2));

  return note;
});

ipcMain.handle('notes:save', async (_, note: Note) => {
  if (!note || !isValidNoteId(note.id)) {
    throw new Error('Invalid note id');
  }

  // Rebuild the note from validated fields; never trust the renderer's shape
  const clean: Note = {
    id: note.id,
    title: typeof note.title === 'string' ? note.title.slice(0, 500) : 'Untitled Note',
    content: typeof note.content === 'string' ? note.content : '',
    createdAt: typeof note.createdAt === 'string' ? note.createdAt : new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    excludedSections: Array.isArray(note.excludedSections)
      ? note.excludedSections.filter((s): s is string => typeof s === 'string')
      : [],
  };

  if (Buffer.byteLength(clean.content, 'utf-8') > MAX_NOTE_CONTENT_BYTES) {
    throw new Error('Note content too large');
  }

  const cache = await getNotesCache();
  cache.set(clean.id, clean);
  await fsp.writeFile(notePath(clean.id), JSON.stringify(clean, null, 2));
  return clean;
});

ipcMain.handle('notes:delete', async (_, id: string) => {
  if (!isValidNoteId(id)) return false;

  const cache = await getNotesCache();
  cache.delete(id);
  try {
    await fsp.unlink(notePath(id));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
  }
  return true;
});

ipcMain.handle('notes:search', async (_, query: string) => {
  if (typeof query !== 'string') return [];
  const lowerQuery = query.toLowerCase();
  const cache = await getNotesCache();
  const results = [...cache.values()].filter(
    (note) =>
      note.title.toLowerCase().includes(lowerQuery) ||
      note.content.toLowerCase().includes(lowerQuery)
  );
  return sortNotes(results);
});

// Settings operations
ipcMain.handle('settings:get', async () => {
  return maskSettingsForRenderer(loadSettings());
});

ipcMain.handle('settings:save', async (_, incoming: AISettings) => {
  // If the masked placeholder comes back unchanged, keep the stored key
  const apiKey =
    incoming.mistralApiKey === MASKED_API_KEY
      ? getMistralApiKey()
      : incoming.mistralApiKey || '';
  const settings: AISettings = { ...incoming, mistralApiKey: apiKey };
  saveSettings(settings);

  // Apply spellcheck settings at runtime
  if (mainWindow) {
    if (settings.spellcheckEnabled && settings.spellcheckLanguages.length > 0) {
      session.defaultSession.setSpellCheckerLanguages(settings.spellcheckLanguages);
    }
  }

  return maskSettingsForRenderer(loadSettings());
});

// Secure storage status
ipcMain.handle('security:encryptionAvailable', async () => {
  return isEncryptionAvailable();
});

// Spellcheck operations
ipcMain.handle('spellcheck:getAvailableLanguages', async () => {
  // Return commonly available spellcheck languages
  // Chromium downloads dictionaries on demand, these are the most common ones
  return [
    { code: 'en-US', name: 'English (US)' },
    { code: 'en-GB', name: 'English (UK)' },
    { code: 'en-AU', name: 'English (Australia)' },
    { code: 'de-DE', name: 'German (Germany)' },
    { code: 'de-AT', name: 'German (Austria)' },
    { code: 'de-CH', name: 'German (Switzerland)' },
    { code: 'fr-FR', name: 'French (France)' },
    { code: 'es-ES', name: 'Spanish (Spain)' },
    { code: 'es-MX', name: 'Spanish (Mexico)' },
    { code: 'it-IT', name: 'Italian' },
    { code: 'pt-BR', name: 'Portuguese (Brazil)' },
    { code: 'pt-PT', name: 'Portuguese (Portugal)' },
    { code: 'nl-NL', name: 'Dutch' },
    { code: 'pl-PL', name: 'Polish' },
    { code: 'ru-RU', name: 'Russian' },
    { code: 'uk-UA', name: 'Ukrainian' },
    { code: 'sv-SE', name: 'Swedish' },
    { code: 'da-DK', name: 'Danish' },
    { code: 'nb-NO', name: 'Norwegian' },
    { code: 'fi-FI', name: 'Finnish' },
    { code: 'cs-CZ', name: 'Czech' },
    { code: 'hu-HU', name: 'Hungarian' },
    { code: 'ro-RO', name: 'Romanian' },
    { code: 'bg-BG', name: 'Bulgarian' },
    { code: 'el-GR', name: 'Greek' },
    { code: 'tr-TR', name: 'Turkish' },
    { code: 'vi-VN', name: 'Vietnamese' },
    { code: 'th-TH', name: 'Thai' },
    { code: 'id-ID', name: 'Indonesian' },
    { code: 'ms-MY', name: 'Malay' },
    { code: 'ko-KR', name: 'Korean' },
    { code: 'ja-JP', name: 'Japanese' },
    { code: 'zh-CN', name: 'Chinese (Simplified)' },
    { code: 'zh-TW', name: 'Chinese (Traditional)' },
  ];
});

ipcMain.handle('spellcheck:getCurrentLanguages', async () => {
  return session.defaultSession.getSpellCheckerLanguages();
});

// Helper function for Mistral API calls (used as fallback)
async function callMistralAPI(apiKey: string, systemPrompt: string, userPrompt: string) {
  try {
    const response = await fetch('https://api.mistral.ai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: 'mistral-small-latest',
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userPrompt },
        ],
        response_format: { type: 'json_object' },
      }),
      signal: AbortSignal.timeout(LLM_FETCH_TIMEOUT_MS),
    });

    if (!response.ok) {
      throw new Error('Mistral request failed');
    }

    const data = await response.json() as { choices: { message: { content: string } }[] };
    const parsed = JSON.parse(data.choices[0].message.content);
    return ensureSuggestions(parsed);
  } catch (error) {
    console.error('[AI] Mistral API fallback failed:', error);
    return { feedback: [], error: 'Mistral API fallback failed' };
  }
}

// Adaptive chunking state - tracks if we need to chunk based on response time
let useAdaptiveChunking = false;
let lastResponseTime = 0;

// Generate system prompt from template and settings
function generateSystemPrompt(
  template: string,
  ctx: { h1: string; h2: string; allH2s: string[] },
  feedbackTypes: FeedbackTypeConfig[]
): string {
  // Build feedback types description
  const enabledTypes = feedbackTypes.filter(t => t.enabled);
  const feedbackTypesStr = enabledTypes
    .map(t => `- "${t.id}": ${t.description}`)
    .join('\n');

  // Replace template variables
  return template
    .replace(/\{\{topic\}\}/g, ctx.h1)
    .replace(/\{\{section\}\}/g, ctx.h2)
    .replace(/\{\{otherSections\}\}/g, ctx.allH2s.slice(0, 5).join(', '))
    .replace(/\{\{feedbackTypes\}\}/g, feedbackTypesStr);
}

function clampMaxTips(value: unknown): number {
  const n = Math.round(Number(value));
  if (!Number.isFinite(n)) return DEFAULT_TIP_STYLE.maxTips;
  return Math.min(6, Math.max(1, n));
}

// Build extra prompt instructions from the user's tip-style preferences
function buildTipStyleInstructions(tipStyle: TipStyleConfig): string {
  const lines: string[] = [];

  if (tipStyle.detailLevel === 'brief') {
    lines.push('Keep each "text" under 20 words and each "suggestion" under 60 words.');
  } else if (tipStyle.detailLevel === 'detailed') {
    lines.push('Write thorough suggestions: 1-3 full paragraphs of ready-to-insert content per item.');
  }

  const toneInstructions: Record<TipStyleConfig['tone'], string> = {
    neutral: '',
    academic: 'Use a formal, academic tone with precise terminology.',
    direct: 'Be blunt and direct. No hedging, no filler.',
    encouraging: 'Use a supportive, encouraging tone; frame feedback constructively.',
  };
  if (toneInstructions[tipStyle.tone]) {
    lines.push(toneInstructions[tipStyle.tone]);
  }

  const maxTips = clampMaxTips(tipStyle.maxTips);
  lines.push(`Provide at most ${maxTips} feedback item${maxTips === 1 ? '' : 's'}.`);

  if (tipStyle.language) {
    lines.push(`Write all feedback and suggestions in ${tipStyle.language}.`);
  } else {
    lines.push('Write feedback in the same language as the notes.');
  }

  const custom = (tipStyle.customGuidance || '').trim();
  if (custom) {
    lines.push(custom);
  }

  return `\n\nSTYLE REQUIREMENTS:\n${lines.map(l => `- ${l}`).join('\n')}\n\nRemember: Output ONLY valid JSON.`;
}

function getTipStyle(settings: AISettings): TipStyleConfig {
  return { ...DEFAULT_TIP_STYLE, ...(settings.promptConfig?.tipStyle || {}) };
}

// Get prompt configuration from settings
function getPromptConfig(settings: AISettings) {
  // Builtin models carry their own content budget in the registry (1200 for
  // the tiny Qwen, more for larger models); other providers get the full 2000.
  const maxContentTokens =
    settings.provider === 'builtin'
      ? resolveModel(settings.builtinModel).contentBudgetTokens
      : 2000;
  return {
    maxContentTokens,
    generatePrompt: (ctx: { h1: string; h2: string; allH2s: string[] }) => {
      // Ensure promptConfig exists (for backwards compatibility)
      const promptConfig = settings.promptConfig || {
        systemPrompt: DEFAULT_SYSTEM_PROMPT,
        feedbackTypes: DEFAULT_FEEDBACK_TYPES,
      };
      return (
        generateSystemPrompt(
          promptConfig.systemPrompt,
          ctx,
          promptConfig.feedbackTypes
        ) + buildTipStyleInstructions(getTipStyle(settings))
      );
    },
  };
}

// Extract current section content for focused analysis
function extractCurrentSection(content: string, currentH2: string): string {
  if (!currentH2) return content;

  // Split by H2 headings and find the current section
  const h2Pattern = /(?=##\s+[^#])|(?=<h2[^>]*>)/gi;
  const sections = content.split(h2Pattern);

  for (const section of sections) {
    if (section.toLowerCase().includes(currentH2.toLowerCase())) {
      return section;
    }
  }

  // If not found, return the last portion of content
  return content.slice(-2000);
}

// Enforce the configured maximum number of tips on any provider's response
function applyTipLimit<T extends { feedback?: unknown[] }>(response: T, maxTips: number): T {
  if (response && Array.isArray(response.feedback)) {
    response.feedback = response.feedback.slice(0, maxTips);
  }
  return response;
}

ipcMain.handle('ai:analyze', async (_, content: string, context: { h1: string; h2: string; allH2s: string[] }) => {
  const settings = loadSettings();

  if (typeof content !== 'string') {
    return { feedback: [], error: 'Invalid content' };
  }
  const ctx = {
    h1: typeof context?.h1 === 'string' ? context.h1 : '',
    h2: typeof context?.h2 === 'string' ? context.h2 : '',
    allH2s: Array.isArray(context?.allH2s)
      ? context.allH2s.filter((s): s is string => typeof s === 'string')
      : [],
  };

  // Get prompt configuration from settings
  const isBuiltinProvider = settings.provider === 'builtin';
  const promptConfig = getPromptConfig(settings);
  const maxTips = clampMaxTips(getTipStyle(settings).maxTips);

  // Content token budget (per-model from the registry for builtin, 2000 otherwise).
  const targetTokens = promptConfig.maxContentTokens;

  let analysisContent = content;
  // Upstream context reduction: when the local model has been slow, narrow to the
  // current section before applying the token budget.
  if (isBuiltinProvider && useAdaptiveChunking) {
    console.log('[AI] Using adaptive chunking (previous response was slow)');
    analysisContent = extractCurrentSection(content, ctx.h2);
  }

  // Token optimization: only pay the cost when content actually exceeds the budget.
  // LLMLingua-2 semantically compresses (keeps high-value tokens); if the compressor
  // model is disabled or unavailable it transparently falls back to truncation.
  if (estimateTokens(analysisContent) > targetTokens) {
    if (settings.compressionEnabled) {
      analysisContent = await compressText(analysisContent, targetTokens);
    } else {
      analysisContent = truncateToTokenBudget(analysisContent, targetTokens);
    }
  }

  const systemPrompt = promptConfig.generatePrompt(ctx);
  const userPrompt = `Analyze:\n\n${analysisContent}`;

  try {
    if (settings.provider === 'builtin') {
      // Use built-in local LLM with better error handling
      const availability = await checkLocalLLMAvailable(settings.builtinModel);
      if (!availability.available) {
        console.error('[AI] Local model not available:', availability.error);
        return { feedback: [], error: availability.error };
      }

      const initResult = await initializeLocalLLM(settings.builtinModel);
      if (!initResult.success) {
        console.error('[AI] Failed to initialize local LLM:', initResult.error);
        return { feedback: [], error: initResult.error };
      }

      console.log('[AI] Generating response with local model...');
      const startTime = Date.now();
      const llmConfig: LLMConfig = {
        contextSize: settings.llmContextSize || 2048,
        maxTokens: settings.llmMaxTokens || 1024,
        batchSize: settings.llmBatchSize || 512,
        modelId: settings.builtinModel,
      };
      const result = await generateLocalResponse(systemPrompt, userPrompt, llmConfig);
      lastResponseTime = Date.now() - startTime;

      // Adapt chunking based on response time (use setting, default to 2000ms)
      const threshold = settings.chunkingThresholdMs || 2000;
      if (lastResponseTime > threshold) {
        if (!useAdaptiveChunking) {
          console.log(`[AI] Response took ${lastResponseTime}ms (> ${threshold}ms), enabling chunking for next request`);
          useAdaptiveChunking = true;
        }
      } else {
        if (useAdaptiveChunking) {
          console.log(`[AI] Response took ${lastResponseTime}ms (< ${threshold}ms), disabling chunking`);
          useAdaptiveChunking = false;
        }
      }

      if (result.error) {
        console.error('[AI] Local LLM generation error:', result.error);
        // Graceful fallback: if Mistral API key exists, try that
        if (settings.mistralApiKey) {
          console.log('[AI] Falling back to Mistral API...');
          const fallback = await callMistralAPI(settings.mistralApiKey, systemPrompt, `Analyze:\n\n${analysisContent}`);
          return applyTipLimit(fallback, maxTips);
        }
        return { feedback: [], error: result.error };
      }

      // Try to extract JSON from the response
      try {
        let responseText = result.response || '';

        // Strip markdown code blocks if present
        responseText = responseText.replace(/```json\s*/gi, '').replace(/```\s*/g, '');

        // Find the JSON object
        const jsonMatch = responseText.match(/\{[\s\S]*\}/);
        if (jsonMatch) {
          // Clean up any trailing incomplete content
          let jsonStr = jsonMatch[0];

          // Try to fix incomplete JSON by finding proper closing
          const openBraces = (jsonStr.match(/\{/g) || []).length;
          const closeBraces = (jsonStr.match(/\}/g) || []).length;

          if (openBraces > closeBraces) {
            // JSON is incomplete, try to salvage what we can
            console.warn('[AI] Incomplete JSON detected, attempting to fix...');
            // Find the last complete feedback item
            const lastCompleteItem = jsonStr.lastIndexOf('}]');
            if (lastCompleteItem > 0) {
              jsonStr = jsonStr.substring(0, lastCompleteItem + 2) + '}';
            }
          }

          const parsed = JSON.parse(jsonStr);

          // Get valid types from settings (or use defaults)
          const feedbackTypes = settings.promptConfig?.feedbackTypes || DEFAULT_FEEDBACK_TYPES;
          const validTypes = feedbackTypes.filter(t => t.enabled).map(t => t.id);

          // Validate and clean up feedback items
          if (parsed.feedback && Array.isArray(parsed.feedback)) {
            parsed.feedback = parsed.feedback.filter((item: { type?: string; text?: string }) => {
              // Filter out invalid types
              if (item.type && !validTypes.includes(item.type)) {
                // Try to extract a valid type from malformed entries
                if (item.type.includes('|')) {
                  item.type = item.type.split('|')[0];
                }
              }
              return item.type && item.text && validTypes.includes(item.type);
            });
          }

          return applyTipLimit(ensureSuggestions(parsed), maxTips);
        }
        console.warn('[AI] No JSON found in response:', responseText.slice(0, 200));
        return { feedback: [] };
      } catch (parseError) {
        console.error('[AI] Failed to parse local LLM response:', result.response?.slice(0, 300));
        return { feedback: [] };
      }
    } else if (settings.provider === 'ollama') {
      const ollamaBase = sanitizeHttpBaseUrl(settings.ollamaUrl, 'http://localhost:11434');
      const response = await fetch(`${ollamaBase}/api/generate`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: settings.ollamaModel,
          prompt: `${systemPrompt}\n\nUser: ${userPrompt}`,
          stream: false,
          format: 'json',
        }),
        signal: AbortSignal.timeout(LLM_FETCH_TIMEOUT_MS),
      });

      if (!response.ok) {
        throw new Error('Ollama request failed');
      }

      const data = await response.json() as { response: string };
      try {
        const parsed = JSON.parse(data.response);
        return applyTipLimit(ensureSuggestions(parsed), maxTips);
      } catch {
        return { feedback: [] };
      }
    } else {
      // Mistral API fallback
      const response = await fetch('https://api.mistral.ai/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${settings.mistralApiKey}`,
        },
        body: JSON.stringify({
          model: 'mistral-small-latest',
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: userPrompt },
          ],
          response_format: { type: 'json_object' },
        }),
        signal: AbortSignal.timeout(LLM_FETCH_TIMEOUT_MS),
      });

      if (!response.ok) {
        throw new Error('Mistral request failed');
      }

      const data = await response.json() as { choices: { message: { content: string } }[] };
      try {
        const parsed = JSON.parse(data.choices[0].message.content);
        return applyTipLimit(ensureSuggestions(parsed), maxTips);
      } catch {
        return { feedback: [] };
      }
    }
  } catch (error) {
    console.error('AI analysis failed:', error);
    return { feedback: [], error: 'AI analysis failed. Check your settings.' };
  }
});

// Helper function to ensure all feedback items have suggestions
function ensureSuggestions(response: { feedback?: Array<{ type: string; text: string; suggestion?: string }> }) {
  if (!response.feedback || !Array.isArray(response.feedback)) {
    return { feedback: [] };
  }

  const suggestionTemplates: Record<string, (text: string) => string> = {
    mece: (text) => `## Additional Category\n\n${text}\n\nConsider exploring this aspect in more detail.`,
    gap: (text) => `${text}\n\nThis perspective could strengthen the analysis by providing a more comprehensive view of the topic.`,
    source: (text) => `### Recommended Sources\n\n${text}\n\n- Consider searching Google Scholar for related academic papers\n- Look for recent review articles in this domain`,
    structure: (text) => `## Suggested Section\n\n${text}\n\n### Subsection A\n\n### Subsection B`,
  };

  response.feedback = response.feedback.map((item) => {
    if (!item.suggestion || item.suggestion.trim() === '') {
      const template = suggestionTemplates[item.type] || suggestionTemplates.gap;
      item.suggestion = template(item.text);
    }
    return item;
  });

  return response;
}

ipcMain.handle('ai:checkConnection', async () => {
  const settings = loadSettings();

  try {
    if (settings.provider === 'builtin') {
      const availability = await checkLocalLLMAvailable(settings.builtinModel);
      if (!availability.available) {
        console.log('[AI] Local model not available:', availability.error);
        return false;
      }
      // Try to initialize the model
      const initResult = await initializeLocalLLM(settings.builtinModel);
      return initResult.success;
    } else if (settings.provider === 'ollama') {
      const ollamaBase = sanitizeHttpBaseUrl(settings.ollamaUrl, 'http://localhost:11434');
      const response = await fetch(`${ollamaBase}/api/tags`, {
        signal: AbortSignal.timeout(5000),
      });
      return response.ok;
    } else {
      // For Mistral, validate the key with a lightweight authenticated call
      // (a missing/garbage key returns 401, so the test reflects reality).
      if (!settings.mistralApiKey) return false;
      const response = await fetch('https://api.mistral.ai/v1/models', {
        headers: { 'Authorization': `Bearer ${settings.mistralApiKey}` },
        signal: AbortSignal.timeout(8000),
      });
      return response.ok;
    }
  } catch (error) {
    console.error('[AI] Connection check failed:', error);
    return false;
  }
});

// Get detailed LLM status for debugging
ipcMain.handle('ai:getStatus', async () => {
  const settings = loadSettings();
  const status = getLocalLLMStatus();

  return {
    provider: settings.provider,
    localLLM: status,
    modelPath: settings.provider === 'builtin' ? resolveModel(settings.builtinModel).filename : null,
    compression: {
      enabled: settings.compressionEnabled,
      ...getCompressorStatus(),
    },
  };
});

// ═══════════════════════════════════════════════════════════════════════════
// BUILT-IN MODEL MANAGEMENT (registry info, in-app download, delete)
// ═══════════════════════════════════════════════════════════════════════════

function sendDownloadProgress(progress: DownloadProgress) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send('ai:downloadProgress', progress);
  }
}

// Registry entries augmented with this machine's state: the RAM-aware context
// ceiling, whether the file is installed (and deletable = lives in userData),
// and any in-flight download so a reopened Settings modal can re-attach.
ipcMain.handle('ai:getBuiltinModels', async () => {
  const userModelsDir = getUserModelsDir();
  return Promise.all(
    BUILTIN_MODELS.map(async (spec) => {
      const availability = await checkLocalLLMAvailable(spec.id);
      const resolvedPath = getModelPath(spec.id);
      return {
        ...spec,
        effectiveMaxContext: effectiveMaxContext(spec),
        installed: availability.available,
        deletable: availability.available && resolvedPath.startsWith(userModelsDir),
        download: getDownloadSnapshot(spec.id),
      };
    })
  );
});

ipcMain.handle('ai:downloadBuiltinModel', async (_, modelId: string) => {
  if (typeof modelId !== 'string' || !getModelById(modelId)) {
    return { success: false, error: `Unknown model: ${modelId}` };
  }
  return downloadModel(modelId, sendDownloadProgress);
});

ipcMain.handle('ai:cancelModelDownload', async (_, modelId: string) => {
  return typeof modelId === 'string' && cancelDownload(modelId);
});

ipcMain.handle('ai:deleteBuiltinModel', async (_, modelId: string) => {
  if (typeof modelId !== 'string' || !getModelById(modelId)) {
    return { success: false, error: `Unknown model: ${modelId}` };
  }
  return deleteDownloadedModel(modelId);
});

// ═══════════════════════════════════════════════════════════════════════════
// SPEECH-TO-TEXT (Transcription via Mistral Voxtral)
// ═══════════════════════════════════════════════════════════════════════════

const AUDIO_MIME_TYPES: Record<string, string> = {
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.wave': 'audio/wav',
  '.m4a': 'audio/mp4',
  '.flac': 'audio/flac',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/opus',
  '.wma': 'audio/x-ms-wma',
  '.aac': 'audio/aac',
  '.webm': 'audio/webm',
};

// Get MIME type from file extension
function getAudioMimeType(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  return AUDIO_MIME_TYPES[ext] || 'audio/mpeg';
}

// Format seconds as MM:SS or HH:MM:SS
function formatTimestamp(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) {
    return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  }
  return `${m}:${String(s).padStart(2, '0')}`;
}

interface TranscriptionResult {
  text: string;
  words?: { word: string; start: number; end: number }[];
  segments?: { start: number; end: number; text: string; speaker?: string }[];
  duration?: number;
  error?: string;
}

// Transcribe via Mistral API (cloud or local Voxtral endpoint)
async function transcribeMistral(
  filePath: string,
  apiUrl: string,
  apiKey: string,
  stt: SttSettings
): Promise<TranscriptionResult> {
  const fileBuffer = await fsp.readFile(filePath);
  const mimeType = getAudioMimeType(filePath);
  const fileName = path.basename(filePath);

  const blob = new Blob([fileBuffer], { type: mimeType });
  const formData = new FormData();
  formData.append('file', blob, fileName);
  formData.append('model', 'voxtral-mini-latest');

  if (stt.sttTimestamps) {
    formData.append('timestamp_granularities', JSON.stringify(['word', 'segment']));
  }
  if (stt.sttDiarize) {
    formData.append('diarize', 'true');
  }
  if (stt.sttLanguage) {
    formData.append('language', stt.sttLanguage);
  }

  const headers: Record<string, string> = {};
  if (apiKey) {
    headers['Authorization'] = `Bearer ${apiKey}`;
  }

  const response = await fetch(apiUrl, {
    method: 'POST',
    headers,
    body: formData,
    signal: AbortSignal.timeout(STT_FETCH_TIMEOUT_MS),
  });

  if (!response.ok) {
    const errorText = await response.text().catch(() => 'Unknown error');
    throw new Error(`Mistral API error (${response.status}): ${errorText}`);
  }

  const data = await response.json() as TranscriptionResult;
  return {
    text: data.text || '',
    words: data.words,
    segments: data.segments,
    duration: data.duration,
  };
}

// Transcribe via Qwen3-ASR edge server (qwen3-asr.cpp or custom wrapper)
// Qwen3-ASR servers typically expose a simpler REST API:
//   POST /asr  with multipart file upload
//   Returns: { text, segments?, duration? }
// Also supports OpenAI-compatible /v1/audio/transcriptions if wrapped
async function transcribeQwen(
  filePath: string,
  baseUrl: string,
  stt: SttSettings
): Promise<TranscriptionResult> {
  const fileBuffer = await fsp.readFile(filePath);
  const mimeType = getAudioMimeType(filePath);
  const fileName = path.basename(filePath);

  const blob = new Blob([fileBuffer], { type: mimeType });
  const formData = new FormData();
  formData.append('file', blob, fileName);

  if (stt.sttLanguage) {
    formData.append('language', stt.sttLanguage);
  }
  if (stt.sttTimestamps) {
    formData.append('timestamps', 'true');
  }

  // Try OpenAI-compatible endpoint first, fall back to /asr
  const endpoints = [
    `${baseUrl}/v1/audio/transcriptions`,
    `${baseUrl}/asr`,
  ];

  let lastError = '';
  for (const endpoint of endpoints) {
    try {
      const response = await fetch(endpoint, {
        method: 'POST',
        body: formData,
        signal: AbortSignal.timeout(STT_FETCH_TIMEOUT_MS),
      });

      if (!response.ok) {
        lastError = `Qwen API error (${response.status}): ${await response.text().catch(() => 'Unknown')}`;
        continue;
      }

      const data = await response.json() as any;

      // Normalize response format (Qwen servers may return different shapes)
      const text = data.text || data.transcription || data.result || '';
      const segments = data.segments || data.utterances || undefined;
      const duration = data.duration || undefined;

      return { text, segments, duration };
    } catch (e) {
      lastError = e instanceof Error ? e.message : 'Connection failed';
      continue;
    }
  }

  throw new Error(lastError || `Cannot reach Qwen STT server at ${baseUrl}`);
}

ipcMain.handle('stt:transcribe', async (_, filePath: string): Promise<TranscriptionResult> => {
  const settings = loadSettings();
  const stt = settings.stt || getDefaultSettings().stt;

  // Validate the path before touching the filesystem: absolute, audio
  // extension, regular file, bounded size
  if (typeof filePath !== 'string' || !path.isAbsolute(filePath)) {
    return { text: '', error: 'Invalid file path' };
  }
  const ext = path.extname(filePath).toLowerCase();
  if (!(ext in AUDIO_MIME_TYPES)) {
    return { text: '', error: `Unsupported audio format: ${ext || 'unknown'}` };
  }

  let stats: fs.Stats;
  try {
    stats = await fsp.stat(filePath);
  } catch {
    return { text: '', error: `File not found: ${filePath}` };
  }
  if (!stats.isFile()) {
    return { text: '', error: 'Not a file' };
  }
  if (stats.size > MAX_AUDIO_FILE_BYTES) {
    return {
      text: '',
      error: `Audio file too large (max ${Math.round(MAX_AUDIO_FILE_BYTES / (1024 * 1024))} MB)`,
    };
  }

  try {
    console.log(`[STT] Transcribing ${path.basename(filePath)} via ${stt.sttProvider}...`);

    let result: TranscriptionResult;

    if (stt.sttProvider === 'mistral-cloud') {
      if (!settings.mistralApiKey) {
        return { text: '', error: 'Mistral API key not configured. Go to Settings > AI Provider to add your key.' };
      }
      result = await transcribeMistral(
        filePath,
        'https://api.mistral.ai/v1/audio/transcriptions',
        settings.mistralApiKey,
        stt
      );
    } else if (stt.sttProvider === 'mistral-local') {
      const baseUrl = sanitizeHttpBaseUrl(stt.localSttUrl, 'http://localhost:8000');
      result = await transcribeMistral(
        filePath,
        `${baseUrl}/v1/audio/transcriptions`,
        settings.mistralApiKey, // Optional for local
        stt
      );
    } else {
      // qwen-edge: Qwen3-ASR-0.6B local server
      const baseUrl = sanitizeHttpBaseUrl(stt.qwenSttUrl, 'http://localhost:9000');
      result = await transcribeQwen(filePath, baseUrl, stt);
    }

    console.log(`[STT] Transcription complete: ${result.text?.length || 0} chars`);
    return result;
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown transcription error';
    console.error('[STT] Transcription error:', errorMessage);
    return { text: '', error: errorMessage };
  }
});

// Format transcription result as HTML for insertion into the editor.
// All transcript text is HTML-escaped: it comes from external services and
// must never be able to inject markup into the editor.
ipcMain.handle('stt:formatTranscript', async (_, result: TranscriptionResult, fileName: string): Promise<string> => {
  const settings = loadSettings();
  const stt = settings.stt || getDefaultSettings().stt;

  let html = '';

  // Header
  const safeTitle = escapeHtml(String(fileName || 'Audio').replace(/\.[^/.]+$/, ''));
  html += `<h3>Transcript: ${safeTitle}</h3>`;

  const segments = Array.isArray(result?.segments) ? result.segments : undefined;

  // If we have segments with speakers (diarization enabled)
  if (stt.sttDiarize && segments && segments.some(s => s.speaker)) {
    for (const segment of segments) {
      const timestamp = formatTimestamp(segment.start);
      const speaker = escapeHtml(segment.speaker || 'Speaker');
      html += `<p><strong>[${timestamp}] ${speaker}:</strong> ${escapeHtml(segment.text)}</p>`;
    }
  }
  // If we have segments with timestamps (no diarization)
  else if (stt.sttTimestamps && segments && segments.length > 0) {
    for (const segment of segments) {
      const timestamp = formatTimestamp(segment.start);
      html += `<p><strong>[${timestamp}]</strong> ${escapeHtml(segment.text)}</p>`;
    }
  }
  // Plain text fallback
  else {
    const text = typeof result?.text === 'string' ? result.text : '';
    // Split into paragraphs at natural breaks
    const paragraphs = text.split(/\n+/).filter(p => p.trim());
    for (const para of paragraphs) {
      html += `<p>${escapeHtml(para)}</p>`;
    }
    if (paragraphs.length === 0) {
      html += `<p>${escapeHtml(text)}</p>`;
    }
  }

  // Duration info
  if (result.duration) {
    html += `<p><em>Duration: ${formatTimestamp(result.duration)}</em></p>`;
  }

  return html;
});

// Check if STT is configured and available
ipcMain.handle('stt:checkAvailable', async (): Promise<{ available: boolean; error?: string }> => {
  const settings = loadSettings();
  const stt = settings.stt || getDefaultSettings().stt;

  if (stt.sttProvider === 'mistral-cloud') {
    if (!settings.mistralApiKey) {
      return { available: false, error: 'Mistral API key not configured' };
    }
    return { available: true };
  } else if (stt.sttProvider === 'mistral-local') {
    try {
      const baseUrl = sanitizeHttpBaseUrl(stt.localSttUrl, 'http://localhost:8000');
      const response = await fetch(`${baseUrl}/v1/models`, {
        method: 'GET',
        signal: AbortSignal.timeout(5000),
      });
      return { available: response.ok };
    } catch {
      return { available: false, error: `Cannot reach local Voxtral endpoint at ${stt.localSttUrl}` };
    }
  } else {
    // qwen-edge: try to reach the Qwen3-ASR server
    try {
      const baseUrl = sanitizeHttpBaseUrl(stt.qwenSttUrl, 'http://localhost:9000');
      // Try /health, /v1/models, or just a GET to the base URL
      const endpoints = [`${baseUrl}/health`, `${baseUrl}/v1/models`, baseUrl];
      for (const endpoint of endpoints) {
        try {
          const response = await fetch(endpoint, {
            method: 'GET',
            signal: AbortSignal.timeout(3000),
          });
          if (response.ok) return { available: true };
        } catch {
          continue;
        }
      }
      return { available: false, error: `Cannot reach Qwen3-ASR server at ${baseUrl}` };
    } catch {
      return { available: false, error: `Cannot reach Qwen3-ASR server at ${stt.qwenSttUrl}` };
    }
  }
});

// Cleanup on app quit: abort downloads first (flushes their .partial files so
// the tail bytes aren't torn — a torn partial forces a full re-download),
// then drain/abort generations before releasing the model.
app.on('before-quit', async () => {
  await abortAllDownloads();
  await shutdownLocalLLM();
  await disposeCompressor();
});
