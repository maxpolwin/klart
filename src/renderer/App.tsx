import { useState, useEffect, useCallback } from 'react';
import Sidebar from './components/Sidebar';
import Editor from './components/Editor';
import SettingsModal from './components/SettingsModal';
import EmptyState from './components/EmptyState';
import { Note, AISettings, FeedbackItem, CoachInteraction, SpellcheckLanguage, TranscriptionResult } from '../shared/types';

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
        draft: (payload: {
          content: string;
          context: { h1: string; h2: string; allH2s: string[] };
          item: { type: string; text: string; question?: string; relevantText?: string };
          userTake: string;
        }) => Promise<{ draft?: string; error?: string }>;
        chat: (payload: {
          messages: { role: 'user' | 'assistant'; content: string }[];
          stance: string;
          noteContext?: { h1: string; section: string; sectionText: string };
        }) => Promise<{ reply?: string; error?: string }>;
        checkConnection: () => Promise<boolean>;
        getStatus: () => Promise<{ provider: string; localLLM: { initialized: boolean; initializing: boolean; error: string | null; gpuAcceleration: { enabled: boolean; type: string; layers: number } }; modelPath: string | null }>;
      };
      coach: {
        getLog: (noteId: string) => Promise<CoachInteraction[]>;
        appendInteraction: (noteId: string, interaction: Partial<CoachInteraction>) => Promise<CoachInteraction | null>;
      };
      spellcheck: {
        getAvailableLanguages: () => Promise<SpellcheckLanguage[]>;
        getCurrentLanguages: () => Promise<string[]>;
      };
      stt: {
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

function App() {
  const [notes, setNotes] = useState<Note[]>([]);
  const [activeNote, setActiveNote] = useState<Note | null>(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [aiConnected, setAiConnected] = useState(false);
  const [isAnalyzing, setIsAnalyzing] = useState(false);

  // Load notes on mount
  useEffect(() => {
    loadNotes();
    checkAiConnection();
  }, []);

  const loadNotes = async () => {
    const loadedNotes = await window.api.notes.list();
    setNotes(loadedNotes);
  };

  const checkAiConnection = async () => {
    const connected = await window.api.ai.checkConnection();
    setAiConnected(connected);
  };

  const handleSearch = async (query: string) => {
    setSearchQuery(query);
    if (query.trim()) {
      const results = await window.api.notes.search(query);
      setNotes(results);
    } else {
      loadNotes();
    }
  };

  const handleCreateNote = async () => {
    const newNote = await window.api.notes.create();
    await loadNotes();
    setActiveNote(newNote);
  };

  const handleSelectNote = async (note: Note) => {
    // Reload the note to get latest content
    const fullNote = await window.api.notes.get(note.id);
    if (fullNote) {
      setActiveNote(fullNote);
    }
  };

  const handleSaveNote = useCallback(async (note: Note) => {
    const savedNote = await window.api.notes.save(note);
    setActiveNote(savedNote);
    await loadNotes();
  }, []);

  const handleDeleteNote = async (noteId: string) => {
    await window.api.notes.delete(noteId);
    if (activeNote?.id === noteId) {
      setActiveNote(null);
    }
    await loadNotes();
  };

  const handleSettingsSaved = () => {
    checkAiConnection();
  };

  return (
    <div className="app">
      <Sidebar
        notes={notes}
        activeNoteId={activeNote?.id}
        searchQuery={searchQuery}
        onSearch={handleSearch}
        onSelectNote={handleSelectNote}
        onCreateNote={handleCreateNote}
        onOpenSettings={() => setIsSettingsOpen(true)}
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
            onOpenSettings={() => setIsSettingsOpen(true)}
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
