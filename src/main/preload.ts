import { contextBridge, ipcRenderer } from 'electron';
// Type-only imports are erased at compile time, so the sandboxed preload
// performs no runtime require of application code.
import type {
  Note,
  AISettings,
  AIContext,
  FeedbackItem,
  CoachInteraction,
  SpellcheckLanguage,
  TranscriptionResult,
} from '../shared/types';

// Feedback items as returned by analysis (id/status are added in the renderer)
type AnalyzedFeedbackItem = Omit<FeedbackItem, 'id' | 'status'>;

interface AIResponse {
  feedback: AnalyzedFeedbackItem[];
  error?: string;
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
    draft: (payload: {
      content: string;
      context: AIContext;
      item: { type: string; text: string; question?: string; relevantText?: string };
      userTake: string;
    }): Promise<{ draft?: string; error?: string }> =>
      ipcRenderer.invoke('ai:draft', payload),
    chat: (payload: {
      messages: { role: 'user' | 'assistant'; content: string }[];
      stance: string;
      noteContext?: { h1: string; section: string; sectionText: string };
    }): Promise<{ reply?: string; error?: string }> =>
      ipcRenderer.invoke('ai:chat', payload),
    checkConnection: (): Promise<boolean> => ipcRenderer.invoke('ai:checkConnection'),
    getStatus: (): Promise<LLMStatus> => ipcRenderer.invoke('ai:getStatus'),
  },
  coach: {
    getLog: (noteId: string): Promise<CoachInteraction[]> =>
      ipcRenderer.invoke('coach:getLog', noteId),
    appendInteraction: (noteId: string, interaction: Partial<CoachInteraction>): Promise<CoachInteraction | null> =>
      ipcRenderer.invoke('coach:appendInteraction', noteId, interaction),
  },
  spellcheck: {
    getAvailableLanguages: (): Promise<SpellcheckLanguage[]> =>
      ipcRenderer.invoke('spellcheck:getAvailableLanguages'),
    getCurrentLanguages: (): Promise<string[]> =>
      ipcRenderer.invoke('spellcheck:getCurrentLanguages'),
  },
  stt: {
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
