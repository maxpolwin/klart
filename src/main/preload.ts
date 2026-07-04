import { contextBridge, ipcRenderer, webUtils } from 'electron';

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
  language: string;
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
  ollamaModel: string;
  ollamaUrl: string;
  mistralApiKey: string;
  spellcheckEnabled: boolean;
  spellcheckLanguages: string[];
  chunkingThresholdMs: number;
  llmContextSize: number;
  llmMaxTokens: number;
  llmBatchSize: number;
  promptConfig: PromptConfig;
  stt: SttSettings;
}

interface SpellcheckLanguage {
  code: string;
  name: string;
}

interface LLMStatus {
  provider: string;
  localLLM: {
    initialized: boolean;
    initializing: boolean;
    error: string | null;
    gpuAcceleration: {
      enabled: boolean;
      type: string;
      layers: number;
    };
  };
  modelPath: string | null;
}

interface AIContext {
  h1: string;
  h2: string;
  allH2s: string[];
}

interface FeedbackItem {
  type: string;  // Accepts custom types
  text: string;
  suggestion?: string;
  relevantText?: string;
}

interface AIResponse {
  feedback: FeedbackItem[];
  error?: string;
}

interface TranscriptionResult {
  text: string;
  words?: { word: string; start: number; end: number }[];
  segments?: { start: number; end: number; text: string; speaker?: string }[];
  duration?: number;
  error?: string;
}

const api = {
  notes: {
    list: (): Promise<Note[]> => ipcRenderer.invoke('notes:list'),
    get: (id: string): Promise<Note | null> => ipcRenderer.invoke('notes:get', id),
    create: (): Promise<Note> => ipcRenderer.invoke('notes:create'),
    save: (note: Note): Promise<Note> => ipcRenderer.invoke('notes:save', note),
    delete: (id: string): Promise<boolean> => ipcRenderer.invoke('notes:delete', id),
    search: (query: string): Promise<Note[]> => ipcRenderer.invoke('notes:search', query),
  },
  settings: {
    get: (): Promise<AISettings> => ipcRenderer.invoke('settings:get'),
    save: (settings: AISettings): Promise<AISettings> => ipcRenderer.invoke('settings:save', settings),
  },
  ai: {
    analyze: (content: string, context: AIContext): Promise<AIResponse> =>
      ipcRenderer.invoke('ai:analyze', content, context),
    checkConnection: (): Promise<boolean> => ipcRenderer.invoke('ai:checkConnection'),
    getStatus: (): Promise<LLMStatus> => ipcRenderer.invoke('ai:getStatus'),
  },
  spellcheck: {
    getAvailableLanguages: (): Promise<SpellcheckLanguage[]> =>
      ipcRenderer.invoke('spellcheck:getAvailableLanguages'),
    getCurrentLanguages: (): Promise<string[]> =>
      ipcRenderer.invoke('spellcheck:getCurrentLanguages'),
  },
  stt: {
    // File.path was removed from Electron's File objects; webUtils is the
    // supported way to resolve a dropped file to a filesystem path.
    getPathForFile: (file: File): string => webUtils.getPathForFile(file),
    transcribe: (filePath: string): Promise<TranscriptionResult> =>
      ipcRenderer.invoke('stt:transcribe', filePath),
    formatTranscript: (result: TranscriptionResult, fileName: string): Promise<string> =>
      ipcRenderer.invoke('stt:formatTranscript', result, fileName),
    checkAvailable: (): Promise<{ available: boolean; error?: string }> =>
      ipcRenderer.invoke('stt:checkAvailable'),
  },
  security: {
    isEncryptionAvailable: (): Promise<boolean> =>
      ipcRenderer.invoke('security:encryptionAvailable'),
  },
};

contextBridge.exposeInMainWorld('api', api);

export type API = typeof api;
