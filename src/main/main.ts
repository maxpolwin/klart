import { app, BrowserWindow, ipcMain, dialog, session, Menu, MenuItem } from 'electron';
import * as path from 'path';
import * as fs from 'fs';
import { v4 as uuidv4 } from 'uuid';
import {
  initializeLocalLLM,
  generateLocalResponse,
  checkLocalLLMAvailable,
  disposeLocalLLM,
  truncateToTokenBudget,
  LLMConfig,
  getLocalLLMStatus,
} from './llm/localLLM';
import {
  getMistralApiKey,
  setMistralApiKey,
  migrateApiKeyFromSettings,
  isEncryptionAvailable,
} from './secureStorage';
import {
  DEFAULT_FEEDBACK_TYPES,
  DEFAULT_SYSTEM_PROMPT,
  DEFAULT_COACH_SYSTEM_PROMPT,
  COACH_QUESTION_STEMS,
} from '../shared/types';
import type {
  Note,
  FeedbackTypeConfig,
  AISettings,
  AIMode,
  CoachInteraction,
  SttSettings,
} from '../shared/types';

const NOTES_DIR = path.join(app.getPath('userData'), 'notes');
const COACHING_DIR = path.join(app.getPath('userData'), 'coaching');
const SETTINGS_FILE = path.join(app.getPath('userData'), 'settings.json');

function ensureDirectories() {
  for (const dir of [NOTES_DIR, COACHING_DIR]) {
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
  }
}

function getDefaultSettings(): AISettings {
  return {
    provider: 'builtin',
    ollamaModel: 'llama3.2',
    ollamaUrl: 'http://localhost:11434',
    mistralApiKey: '',
    spellcheckEnabled: true,
    spellcheckLanguages: ['en-US'],
    chunkingThresholdMs: 3000, // 3 seconds default (increased for better responses)
    llmContextSize: 2048,      // Context window size
    llmMaxTokens: 1536,        // Max tokens to generate (increased for detailed responses)
    llmBatchSize: 512,         // Batch size for inference
    promptConfig: {
      systemPrompt: DEFAULT_SYSTEM_PROMPT,
      feedbackTypes: DEFAULT_FEEDBACK_TYPES,
      mode: 'coach',
      coachSystemPrompt: DEFAULT_COACH_SYSTEM_PROMPT,
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
      if (raw.mistralApiKey && raw.mistralApiKey.length > 0) {
        raw = migrateApiKeyFromSettings(raw);
        // Re-save settings without the plaintext key
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(raw, null, 2));
      }

      // Inject the API key from secure storage
      raw.mistralApiKey = getMistralApiKey();

      // Non-destructive migration for pre-coach settings: default to coach
      // mode and seed the coach prompt. The user's existing systemPrompt is
      // preserved untouched — it simply becomes the drafting prompt.
      if (raw.promptConfig) {
        raw.promptConfig.mode = raw.promptConfig.mode ?? 'coach';
        raw.promptConfig.coachSystemPrompt =
          raw.promptConfig.coachSystemPrompt ?? DEFAULT_COACH_SYSTEM_PROMPT;
      }

      return raw as AISettings;
    }
  } catch (error) {
    console.error('Failed to load settings:', error);
  }
  return getDefaultSettings();
}

function saveSettings(settings: AISettings) {
  // Extract and securely store the API key
  const apiKey = settings.mistralApiKey || '';
  if (apiKey) {
    setMistralApiKey(apiKey);
  }

  // Save settings without the plaintext API key
  const settingsToSave = { ...settings, mistralApiKey: '' };
  fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settingsToSave, null, 2));
}

let mainWindow: BrowserWindow | null = null;

const isDev = !app.isPackaged;

async function createWindow() {
  const settings = loadSettings();

  mainWindow = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 800,
    minHeight: 600,
    backgroundColor: '#0f0f0f',
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      spellcheck: settings.spellcheckEnabled,
    },
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
  await createWindow();

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

// Note operations
ipcMain.handle('notes:list', async () => {
  const files = fs.readdirSync(NOTES_DIR).filter(f => f.endsWith('.json'));
  const notes: Note[] = [];

  for (const file of files) {
    try {
      const content = fs.readFileSync(path.join(NOTES_DIR, file), 'utf-8');
      notes.push(JSON.parse(content));
    } catch (error) {
      console.error(`Failed to read note ${file}:`, error);
    }
  }

  return notes.sort((a, b) =>
    new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime()
  );
});

ipcMain.handle('notes:get', async (_, id: string) => {
  const filePath = path.join(NOTES_DIR, `${id}.json`);
  if (fs.existsSync(filePath)) {
    return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
  }
  return null;
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

  fs.writeFileSync(
    path.join(NOTES_DIR, `${note.id}.json`),
    JSON.stringify(note, null, 2)
  );

  return note;
});

ipcMain.handle('notes:save', async (_, note: Note) => {
  note.updatedAt = new Date().toISOString();
  fs.writeFileSync(
    path.join(NOTES_DIR, `${note.id}.json`),
    JSON.stringify(note, null, 2)
  );
  return note;
});

ipcMain.handle('notes:delete', async (_, id: string) => {
  const filePath = path.join(NOTES_DIR, `${id}.json`);
  if (fs.existsSync(filePath)) {
    fs.unlinkSync(filePath);
  }
  return true;
});

ipcMain.handle('notes:search', async (_, query: string) => {
  const files = fs.readdirSync(NOTES_DIR).filter(f => f.endsWith('.json'));
  const results: Note[] = [];
  const lowerQuery = query.toLowerCase();

  for (const file of files) {
    try {
      const content = fs.readFileSync(path.join(NOTES_DIR, file), 'utf-8');
      const note: Note = JSON.parse(content);
      if (
        note.title.toLowerCase().includes(lowerQuery) ||
        note.content.toLowerCase().includes(lowerQuery)
      ) {
        results.push(note);
      }
    } catch (error) {
      console.error(`Failed to search note ${file}:`, error);
    }
  }

  return results.sort((a, b) =>
    new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime()
  );
});

// Settings operations
ipcMain.handle('settings:get', async () => {
  return loadSettings();
});

ipcMain.handle('settings:save', async (_, settings: AISettings) => {
  saveSettings(settings);

  // Apply spellcheck settings at runtime
  if (mainWindow) {
    if (settings.spellcheckEnabled && settings.spellcheckLanguages.length > 0) {
      session.defaultSession.setSpellCheckerLanguages(settings.spellcheckLanguages);
    }
  }

  // Return settings with the API key (from secure storage) for the renderer
  return { ...settings, mistralApiKey: getMistralApiKey() };
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
async function callMistralAPI(apiKey: string, systemPrompt: string, userPrompt: string, mode: AIMode = 'generate') {
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
    });

    if (!response.ok) {
      throw new Error('Mistral request failed');
    }

    const data = await response.json() as { choices: { message: { content: string } }[] };
    const parsed = JSON.parse(data.choices[0].message.content);
    return finalizeFeedback(parsed, mode);
  } catch (error) {
    console.error('[AI] Mistral API fallback failed:', error);
    return { feedback: [], error: 'Mistral API fallback failed' };
  }
}

// Adaptive chunking state - tracks if we need to chunk based on response time
let useAdaptiveChunking = false;
let lastResponseTime = 0;

// Resolve the active AI mode ('coach' is the default)
function getAIMode(settings: AISettings): AIMode {
  return settings.promptConfig?.mode ?? 'coach';
}

// Generate system prompt from template and settings
function generateSystemPrompt(
  template: string,
  ctx: { h1: string; h2: string; allH2s: string[] },
  feedbackTypes: FeedbackTypeConfig[],
  mode: AIMode = 'generate'
): string {
  // Build feedback types description. In coach mode, include the curated
  // question stem so the model selects/adapts a stem instead of inventing
  // Socratic questions from scratch (unreliable on small local models).
  const enabledTypes = feedbackTypes.filter(t => t.enabled);
  const feedbackTypesStr = enabledTypes
    .map(t => {
      const stem = mode === 'coach' ? COACH_QUESTION_STEMS[t.id] : undefined;
      return stem
        ? `- "${t.id}": ${t.description}. Ask like: "${stem}"`
        : `- "${t.id}": ${t.description}`;
    })
    .join('\n');

  // Replace template variables
  return template
    .replace(/\{\{topic\}\}/g, ctx.h1)
    .replace(/\{\{section\}\}/g, ctx.h2)
    .replace(/\{\{otherSections\}\}/g, ctx.allH2s.slice(0, 5).join(', '))
    .replace(/\{\{feedbackTypes\}\}/g, feedbackTypesStr);
}

// Get prompt configuration from settings
function getPromptConfig(settings: AISettings) {
  const isSmallModel = settings.provider === 'builtin';
  return {
    maxContentTokens: isSmallModel ? 1200 : 2000,
    generatePrompt: (ctx: { h1: string; h2: string; allH2s: string[] }) => {
      // Ensure promptConfig exists (for backwards compatibility)
      const promptConfig = settings.promptConfig || {
        systemPrompt: DEFAULT_SYSTEM_PROMPT,
        feedbackTypes: DEFAULT_FEEDBACK_TYPES,
      };
      const mode = getAIMode(settings);
      const template = mode === 'coach'
        ? (promptConfig.coachSystemPrompt || DEFAULT_COACH_SYSTEM_PROMPT)
        : promptConfig.systemPrompt;
      return generateSystemPrompt(template, ctx, promptConfig.feedbackTypes, mode);
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

ipcMain.handle('ai:analyze', async (_, content: string, context: { h1: string; h2: string; allH2s: string[] }) => {
  const settings = loadSettings();

  // Get prompt configuration from settings
  const isSmallModel = settings.provider === 'builtin';
  const mode = getAIMode(settings);
  const promptConfig = getPromptConfig(settings);

  // Adaptive chunking for built-in model:
  // - Start with full content
  // - Only chunk if previous response took > 2 seconds
  let analysisContent = content;
  if (isSmallModel && useAdaptiveChunking) {
    console.log('[AI] Using adaptive chunking (previous response was slow)');
    analysisContent = extractCurrentSection(content, context.h2);
    analysisContent = truncateToTokenBudget(analysisContent, promptConfig.maxContentTokens);
  } else if (isSmallModel) {
    // Use full content but with a reasonable limit for context window
    analysisContent = truncateToTokenBudget(content, 1500);
  }

  const systemPrompt = promptConfig.generatePrompt(context);
  const userPrompt = `Analyze:\n\n${analysisContent}`;

  try {
    if (settings.provider === 'builtin') {
      // Use built-in local LLM with better error handling
      const availability = await checkLocalLLMAvailable();
      if (!availability.available) {
        console.error('[AI] Local model not available:', availability.error);
        return { feedback: [], error: availability.error };
      }

      const initResult = await initializeLocalLLM();
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
          return await callMistralAPI(settings.mistralApiKey, systemPrompt, `Analyze:\n\n${content}`, mode);
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

          return finalizeFeedback(parsed, mode);
        }
        console.warn('[AI] No JSON found in response:', responseText.slice(0, 200));
        return { feedback: [] };
      } catch (parseError) {
        console.error('[AI] Failed to parse local LLM response:', result.response?.slice(0, 300));
        return { feedback: [] };
      }
    } else if (settings.provider === 'ollama') {
      const response = await fetch(`${settings.ollamaUrl}/api/generate`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: settings.ollamaModel,
          prompt: `${systemPrompt}\n\nUser: ${userPrompt}`,
          stream: false,
          format: 'json',
        }),
      });

      if (!response.ok) {
        throw new Error('Ollama request failed');
      }

      const data = await response.json() as { response: string };
      try {
        const parsed = JSON.parse(data.response);
        return finalizeFeedback(parsed, mode);
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
      });

      if (!response.ok) {
        throw new Error('Mistral request failed');
      }

      const data = await response.json() as { choices: { message: { content: string } }[] };
      try {
        const parsed = JSON.parse(data.choices[0].message.content);
        return finalizeFeedback(parsed, mode);
      } catch {
        return { feedback: [] };
      }
    }
  } catch (error) {
    console.error('AI analysis failed:', error);
    return { feedback: [], error: 'AI analysis failed. Check your settings.' };
  }
});

// Shape of raw feedback items parsed from model output
interface RawFeedbackItem {
  type: string;
  text: string;
  suggestion?: string;
  question?: string;
  hint?: string;
  relevantText?: string;
  mode?: AIMode;
}

// Route parsed model output through the mode-appropriate post-processor.
// coach → questions only (never fabricates insertable prose)
// generate → legacy behavior (backfills insertable suggestions)
function finalizeFeedback(response: { feedback?: RawFeedbackItem[] }, mode: AIMode) {
  return mode === 'coach' ? ensureCoachPrompts(response) : ensureSuggestions(response);
}

// Coach mode: guarantee every item carries a question the writer can answer,
// and strip any insertable prose the model produced anyway. This is the
// inverse of ensureSuggestions — it must NEVER fabricate content.
function ensureCoachPrompts(response: { feedback?: RawFeedbackItem[] }) {
  if (!response.feedback || !Array.isArray(response.feedback)) {
    return { feedback: [] };
  }

  response.feedback = response.feedback.map((item) => {
    if (!item.question || item.question.trim() === '') {
      // Fall back to the curated stem for this type, else phrase the
      // observation itself as a question.
      const stem = COACH_QUESTION_STEMS[item.type];
      item.question = stem
        ?? (item.text.trim().endsWith('?')
          ? item.text.trim()
          : `${item.text.trim().replace(/\.+$/, '')} — how would you address this in your own words?`);
    }
    // Never carry insertable prose in coach mode
    delete item.suggestion;
    item.mode = 'coach';
    return item;
  });

  return response;
}

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

// ═══════════════════════════════════════════════════════════════════════════
// COACHING — interaction log (persistent memory) + explicit drafting
// ═══════════════════════════════════════════════════════════════════════════

function coachLogPath(noteId: string): string | null {
  const safe = String(noteId).replace(/[^\w.-]/g, '');
  if (!safe) return null;
  return path.join(COACHING_DIR, `${safe}.json`);
}

function readCoachLog(noteId: string): CoachInteraction[] {
  const filePath = coachLogPath(noteId);
  if (!filePath || !fs.existsSync(filePath)) return [];
  try {
    const parsed = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    console.error('[Coach] Failed to read coaching log:', error);
    return [];
  }
}

ipcMain.handle('coach:getLog', async (_, noteId: string) => {
  return readCoachLog(noteId);
});

ipcMain.handle('coach:appendInteraction', async (_, noteId: string, interaction: Partial<CoachInteraction>) => {
  const filePath = coachLogPath(noteId);
  if (!filePath) return null;

  const now = new Date().toISOString();
  const entry: CoachInteraction = {
    id: interaction.id || uuidv4(),
    noteId,
    sectionId: interaction.sectionId,
    kind: interaction.kind || 'question',
    type: interaction.type || 'gap',
    question: interaction.question || '',
    userResponse: interaction.userResponse,
    aiDraft: interaction.aiDraft,
    resolved: interaction.resolved ?? true,
    createdAt: interaction.createdAt || now,
    updatedAt: now,
  };

  const log = readCoachLog(noteId);
  log.push(entry);
  fs.writeFileSync(filePath, JSON.stringify(log, null, 2));
  return entry;
});

// Freeform (non-JSON) generation across all three providers.
// Used by explicit drafting ("Draft it for me") and the thinking partner.
async function generateFreeform(
  settings: AISettings,
  systemPrompt: string,
  userPrompt: string
): Promise<{ text?: string; error?: string }> {
  try {
    if (settings.provider === 'builtin') {
      const availability = await checkLocalLLMAvailable();
      if (!availability.available) return { error: availability.error };
      const initResult = await initializeLocalLLM();
      if (!initResult.success) return { error: initResult.error };
      const result = await generateLocalResponse(systemPrompt, userPrompt, {
        contextSize: settings.llmContextSize || 2048,
        maxTokens: settings.llmMaxTokens || 1024,
        batchSize: settings.llmBatchSize || 512,
      });
      if (result.error) return { error: result.error };
      return { text: (result.response || '').trim() };
    } else if (settings.provider === 'ollama') {
      const response = await fetch(`${settings.ollamaUrl}/api/generate`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: settings.ollamaModel,
          prompt: `${systemPrompt}\n\nUser: ${userPrompt}`,
          stream: false,
        }),
      });
      if (!response.ok) throw new Error('Ollama request failed');
      const data = await response.json() as { response: string };
      return { text: (data.response || '').trim() };
    } else {
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
        }),
      });
      if (!response.ok) throw new Error('Mistral request failed');
      const data = await response.json() as { choices: { message: { content: string } }[] };
      return { text: (data.choices[0].message.content || '').trim() };
    }
  } catch (error) {
    const msg = error instanceof Error ? error.message : 'Generation failed';
    console.error('[AI] Freeform generation failed:', msg);
    return { error: msg };
  }
}

// Explicit, deliberate drafting — the ONLY path that produces AI-authored
// prose in coach mode. The renderer gates it behind a commit-first step
// (the writer states their own take first) and logs the result as
// AI-authored in the coaching store (provenance).
ipcMain.handle('ai:draft', async (_, payload: {
  content: string;
  context: { h1: string; h2: string; allH2s: string[] };
  item: { type: string; text: string; question?: string; relevantText?: string };
  userTake: string;
}) => {
  const settings = loadSettings();
  const { content, context, item, userTake } = payload;

  // A dedicated drafting prompt: plain prose, epistemically honest — the
  // model must never invent facts; unverified evidence becomes a TODO.
  const systemPrompt = `You are a writing assistant. The writer of research notes on "${context.h1 || 'their topic'}" has EXPLICITLY asked you to draft a short passage they will edit and take ownership of. Write clear, plain prose in a neutral academic register. Never invent citations, statistics, or specific facts — where evidence is needed, write [TODO: verify]. Output plain text only — no JSON, no preamble, no commentary.`;

  const truncated = truncateToTokenBudget(content, settings.provider === 'builtin' ? 1000 : 1800);
  const userPrompt = [
    `Feedback being addressed: ${item.text}`,
    item.question ? `Question being addressed: ${item.question}` : '',
    `The writer's own take (build on it, keep their intent): ${userTake}`,
    item.relevantText ? `Relevant excerpt from the notes: ${item.relevantText}` : '',
    '',
    'Notes:',
    truncated,
    '',
    'Write a concise draft (1-2 short paragraphs) the writer can edit.',
  ].filter(Boolean).join('\n');

  const result = await generateFreeform(settings, systemPrompt, userPrompt);
  return { draft: result.text, error: result.error };
});

ipcMain.handle('ai:checkConnection', async () => {
  const settings = loadSettings();

  try {
    if (settings.provider === 'builtin') {
      const availability = await checkLocalLLMAvailable();
      if (!availability.available) {
        console.log('[AI] Local model not available:', availability.error);
        return false;
      }
      // Try to initialize the model
      const initResult = await initializeLocalLLM();
      return initResult.success;
    } else if (settings.provider === 'ollama') {
      const response = await fetch(`${settings.ollamaUrl}/api/tags`);
      return response.ok;
    } else {
      // For Mistral, just check if API key is set
      return !!settings.mistralApiKey;
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
    modelPath: settings.provider === 'builtin' ? 'qwen2.5-0.5b-instruct-q4_k_m.gguf' : null,
  };
});

// ═══════════════════════════════════════════════════════════════════════════
// SPEECH-TO-TEXT (Transcription via Mistral Voxtral)
// ═══════════════════════════════════════════════════════════════════════════

// Get MIME type from file extension
function getAudioMimeType(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  const mimeTypes: Record<string, string> = {
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
  return mimeTypes[ext] || 'audio/mpeg';
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
  const fileBuffer = fs.readFileSync(filePath);
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
  const fileBuffer = fs.readFileSync(filePath);
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

  // Validate file exists
  if (!fs.existsSync(filePath)) {
    return { text: '', error: `File not found: ${filePath}` };
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
      const baseUrl = stt.localSttUrl.replace(/\/$/, '');
      result = await transcribeMistral(
        filePath,
        `${baseUrl}/v1/audio/transcriptions`,
        settings.mistralApiKey, // Optional for local
        stt
      );
    } else {
      // qwen-edge: Qwen3-ASR-0.6B local server
      const baseUrl = (stt.qwenSttUrl || 'http://localhost:9000').replace(/\/$/, '');
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

// Format transcription result as HTML for insertion into the editor
ipcMain.handle('stt:formatTranscript', async (_, result: TranscriptionResult, fileName: string): Promise<string> => {
  const settings = loadSettings();
  const stt = settings.stt || getDefaultSettings().stt;

  let html = '';

  // Header
  html += `<h3>Transcript: ${fileName.replace(/\.[^/.]+$/, '')}</h3>`;

  // If we have segments with speakers (diarization enabled)
  if (stt.sttDiarize && result.segments && result.segments.some(s => s.speaker)) {
    for (const segment of result.segments) {
      const timestamp = formatTimestamp(segment.start);
      const speaker = segment.speaker || 'Speaker';
      html += `<p><strong>[${timestamp}] ${speaker}:</strong> ${segment.text}</p>`;
    }
  }
  // If we have segments with timestamps (no diarization)
  else if (stt.sttTimestamps && result.segments && result.segments.length > 0) {
    for (const segment of result.segments) {
      const timestamp = formatTimestamp(segment.start);
      html += `<p><strong>[${timestamp}]</strong> ${segment.text}</p>`;
    }
  }
  // Plain text fallback
  else {
    // Split into paragraphs at natural breaks
    const paragraphs = result.text.split(/\n+/).filter(p => p.trim());
    for (const para of paragraphs) {
      html += `<p>${para}</p>`;
    }
    if (paragraphs.length === 0) {
      html += `<p>${result.text}</p>`;
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
      const baseUrl = stt.localSttUrl.replace(/\/$/, '');
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
    const baseUrl = (stt.qwenSttUrl || 'http://localhost:9000').replace(/\/$/, '');
    try {
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
      return { available: false, error: `Cannot reach Qwen3-ASR server at ${baseUrl}` };
    }
  }
});

// Cleanup on app quit
app.on('before-quit', async () => {
  await disposeLocalLLM();
});
