import { useState, useEffect, useCallback, useRef } from 'react';
import Sidebar from './components/Sidebar';
import Editor from './components/Editor';
import SettingsModal from './components/SettingsModal';
import EmptyState from './components/EmptyState';
import { Note, AISettings, FeedbackItem, SpellcheckLanguage, TranscriptionResult } from '../shared/types';

declare global {
  interface Window {
    api: {
      notes: {
        list: () => Promise<Note[]>;
        get: (id: string) => Promise<Note | null>;
        create: () => Promise<Note>;
        save: (note: Note) => Promise<Note>;
        delete: (id: string) => Promise<boolean>;
        search: (query: string) => Promise<Note[]>;
      };
      settings: {
        get: () => Promise<AISettings>;
        save: (settings: AISettings) => Promise<AISettings>;
      };
      ai: {
        analyze: (content: string, context: { h1: string; h2: string; allH2s: string[] }) => Promise<{ feedback: Omit<FeedbackItem, 'id' | 'status'>[]; error?: string }>;
        checkConnection: () => Promise<boolean>;
        getStatus: () => Promise<{ provider: string; localLLM: { initialized: boolean; initializing: boolean; error: string | null; gpuAcceleration: { enabled: boolean; type: string; layers: number } }; modelPath: string | null }>;
      };
      spellcheck: {
        getAvailableLanguages: () => Promise<SpellcheckLanguage[]>;
        getCurrentLanguages: () => Promise<string[]>;
      };
      stt: {
        getPathForFile: (file: File) => string;
        transcribe: (filePath: string) => Promise<TranscriptionResult>;
        formatTranscript: (result: TranscriptionResult, fileName: string) => Promise<string>;
        checkAvailable: () => Promise<{ available: boolean; error?: string }>;
      };
      security: {
        isEncryptionAvailable: () => Promise<boolean>;
      };
    };
  }
}

const SEARCH_DEBOUNCE_MS = 250;

function sortNotes(notes: Note[]): Note[] {
  return [...notes].sort(
    (a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime()
  );
}

function App() {
  const [notes, setNotes] = useState<Note[]>([]);
  const [activeNote, setActiveNote] = useState<Note | null>(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [aiConnected, setAiConnected] = useState(false);
  const [isAnalyzing, setIsAnalyzing] = useState(false);
  const [settings, setSettings] = useState<AISettings | null>(null);
  const searchTimeoutRef = useRef<number | null>(null);

  // Load notes on mount
  useEffect(() => {
    loadNotes();
    loadSettings();
    checkAiConnection();
  }, []);

  const loadNotes = async () => {
    const loadedNotes = await window.api.notes.list();
    setNotes(loadedNotes);
  };

  const loadSettings = async () => {
    const loaded = await window.api.settings.get();
    setSettings(loaded);
  };

  const checkAiConnection = async () => {
    const connected = await window.api.ai.checkConnection();
    setAiConnected(connected);
  };

  const handleSearch = useCallback((query: string) => {
    setSearchQuery(query);
    if (searchTimeoutRef.current !== null) {
      window.clearTimeout(searchTimeoutRef.current);
    }
    searchTimeoutRef.current = window.setTimeout(async () => {
      if (query.trim()) {
        const results = await window.api.notes.search(query);
        setNotes(results);
      } else {
        const loadedNotes = await window.api.notes.list();
        setNotes(loadedNotes);
      }
    }, SEARCH_DEBOUNCE_MS);
  }, []);

  const handleCreateNote = useCallback(async () => {
    const newNote = await window.api.notes.create();
    setNotes((prev) => [newNote, ...prev]);
    setActiveNote(newNote);
  }, []);

  const handleSelectNote = useCallback(async (note: Note) => {
    // Reload the note to get latest content
    const fullNote = await window.api.notes.get(note.id);
    if (fullNote) {
      setActiveNote(fullNote);
    }
  }, []);

  const handleSaveNote = useCallback(async (note: Note) => {
    const savedNote = await window.api.notes.save(note);
    setActiveNote(savedNote);
    // Update the list in place instead of re-fetching every note from disk
    setNotes((prev) => {
      const exists = prev.some((n) => n.id === savedNote.id);
      const next = exists
        ? prev.map((n) => (n.id === savedNote.id ? savedNote : n))
        : [savedNote, ...prev];
      return sortNotes(next);
    });
  }, []);

  const handleDeleteNote = useCallback(async (noteId: string) => {
    await window.api.notes.delete(noteId);
    setActiveNote((prev) => (prev?.id === noteId ? null : prev));
    setNotes((prev) => prev.filter((n) => n.id !== noteId));
  }, []);

  const handleOpenSettings = useCallback(() => setIsSettingsOpen(true), []);

  const handleSettingsSaved = useCallback(() => {
    loadSettings();
    checkAiConnection();
  }, []);

  return (
    <div className="app">
      <Sidebar
        notes={notes}
        activeNoteId={activeNote?.id}
        searchQuery={searchQuery}
        onSearch={handleSearch}
        onSelectNote={handleSelectNote}
        onCreateNote={handleCreateNote}
        onOpenSettings={handleOpenSettings}
      />
      <div className="editor-area">
        {activeNote ? (
          <Editor
            note={activeNote}
            onSave={handleSaveNote}
            onDelete={() => handleDeleteNote(activeNote.id)}
            aiConnected={aiConnected}
            isAnalyzing={isAnalyzing}
            setIsAnalyzing={setIsAnalyzing}
            onOpenSettings={handleOpenSettings}
            feedbackTypes={settings?.promptConfig?.feedbackTypes}
          />
        ) : (
          <EmptyState onCreateNote={handleCreateNote} />
        )}
      </div>
      {isSettingsOpen && (
        <SettingsModal
          onClose={() => setIsSettingsOpen(false)}
          onSaved={handleSettingsSaved}
        />
      )}
    </div>
  );
}

export default App;
