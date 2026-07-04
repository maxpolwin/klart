import { useState, useEffect, useCallback, useRef } from 'react';
import { useEditor, EditorContent } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import Placeholder from '@tiptap/extension-placeholder';
import Heading from '@tiptap/extension-heading';
import { Trash2, Eye, EyeOff, Mic, Loader2, AlertCircle, Sparkles, Zap, ZapOff } from 'lucide-react';
import { Note, FeedbackItem, FeedbackTypeConfig, SUPPORTED_AUDIO_EXTENSIONS } from '../../shared/types';
import FeedbackPanel from './FeedbackPanel';

interface EditorProps {
  note: Note;
  onSave: (note: Note) => void;
  onDelete: () => void;
  aiConnected: boolean;
  isAnalyzing: boolean;
  setIsAnalyzing: (analyzing: boolean) => void;
  onOpenSettings: () => void;
  feedbackTypes?: FeedbackTypeConfig[];
}

const AUTO_ANALYZE_STORAGE_KEY = 'noschen.autoAnalyze';

function extractTitle(html: string): string {
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

function extractHeadings(html: string): { h1: string; h2s: string[] } {
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

function Editor({
  note,
  onSave,
  onDelete,
  aiConnected,
  isAnalyzing,
  setIsAnalyzing,
  onOpenSettings,
  feedbackTypes,
}: EditorProps) {
  const [feedback, setFeedback] = useState<FeedbackItem[]>([]);
  const [showRejected, setShowRejected] = useState(false);
  const [lastContent, setLastContent] = useState(note.content);
  const [analysisError, setAnalysisError] = useState<string | null>(null);
  const [autoAnalyze, setAutoAnalyze] = useState(
    () => localStorage.getItem(AUTO_ANALYZE_STORAGE_KEY) !== 'off'
  );
  const analysisTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const saveTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  // Incremented per analysis request so stale responses are dropped
  const analysisRunRef = useRef(0);

  // Drag-and-drop transcription state
  const [isDragOver, setIsDragOver] = useState(false);
  const [isTranscribing, setIsTranscribing] = useState(false);
  const [transcriptionError, setTranscriptionError] = useState<string | null>(null);
  const dragCounterRef = useRef(0);

  const editor = useEditor({
    extensions: [
      StarterKit.configure({
        heading: false,
      }),
      Heading.configure({
        levels: [1, 2, 3, 4, 5, 6],
      }),
      Placeholder.configure({
        placeholder: ({ node }) => {
          if (node.type.name === 'heading') {
            const level = node.attrs.level;
            if (level === 1) return 'Research Topic (H1)';
            if (level === 2) return 'Sub-question or Aspect (H2)';
            return `Heading ${level}`;
          }
          return 'Start writing your research notes...';
        },
      }),
    ],
    content: note.content,
    onUpdate: ({ editor }) => {
      const html = editor.getHTML();
      handleContentChange(html);
    },
    editorProps: {
      attributes: {
        class: 'prose prose-invert max-w-none',
        spellcheck: 'true',
        'aria-label': 'Note editor',
      },
    },
  });

  // Update editor content when note changes
  useEffect(() => {
    if (editor && note.content !== editor.getHTML()) {
      editor.commands.setContent(note.content);
      setLastContent(note.content);
      setFeedback([]);
      setAnalysisError(null);
    }
  }, [note.id, editor]);

  const toggleAutoAnalyze = useCallback(() => {
    setAutoAnalyze((prev) => {
      const next = !prev;
      localStorage.setItem(AUTO_ANALYZE_STORAGE_KEY, next ? 'on' : 'off');
      if (!next && analysisTimeoutRef.current) {
        clearTimeout(analysisTimeoutRef.current);
      }
      return next;
    });
  }, []);

  const analyzeContent = useCallback(async (html: string) => {
    const runId = ++analysisRunRef.current;
    setIsAnalyzing(true);
    setAnalysisError(null);

    const { h1, h2s } = extractHeadings(html);
    const currentH2 = h2s[h2s.length - 1] || ''; // Use last H2 as current section

    // Get plain text content for analysis
    const plainText = html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();

    try {
      const response = await window.api.ai.analyze(plainText, {
        h1,
        h2: currentH2,
        allH2s: h2s,
      });

      // A newer analysis started while this one was running - drop this result
      if (runId !== analysisRunRef.current) return;

      if (response.error) {
        setAnalysisError(response.error);
      }

      if (response.feedback && response.feedback.length > 0) {
        const newFeedback: FeedbackItem[] = response.feedback.map((f, i) => ({
          ...f,
          id: `${Date.now()}-${i}`,
          status: 'active' as const,
        }));

        // Merge with existing feedback, avoiding duplicates
        setFeedback((prev) => {
          const existing = prev.filter((p) => p.status !== 'active');
          return [...existing, ...newFeedback];
        });
      }
    } catch (error) {
      if (runId === analysisRunRef.current) {
        console.error('Analysis failed:', error);
        setAnalysisError('Analysis failed. Check your AI settings.');
      }
    }

    if (runId === analysisRunRef.current) {
      setIsAnalyzing(false);
    }
  }, [setIsAnalyzing]);

  const handleContentChange = useCallback(
    (html: string) => {
      // Auto-save after 1 second of inactivity
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
      }
      saveTimeoutRef.current = setTimeout(() => {
        const title = extractTitle(html);
        onSave({ ...note, content: html, title });
      }, 1000);

      // Trigger AI analysis after 2 seconds of inactivity
      if (analysisTimeoutRef.current) {
        clearTimeout(analysisTimeoutRef.current);
      }

      if (autoAnalyze && aiConnected && html !== lastContent && html.trim().length > 50) {
        analysisTimeoutRef.current = setTimeout(() => {
          analyzeContent(html);
        }, 2000);
      }

      setLastContent(html);
    },
    [note, onSave, aiConnected, autoAnalyze, lastContent, analyzeContent]
  );

  const handleAnalyzeNow = useCallback(() => {
    if (!editor || isAnalyzing) return;
    if (analysisTimeoutRef.current) {
      clearTimeout(analysisTimeoutRef.current);
    }
    analyzeContent(editor.getHTML());
  }, [editor, isAnalyzing, analyzeContent]);

  const handleAcceptFeedback = (feedbackId: string, editedSuggestion?: string) => {
    const feedbackItem = feedback.find((f) => f.id === feedbackId);
    if (!feedbackItem || !editor) return;

    setFeedback((prev) =>
      prev.map((f) => (f.id === feedbackId ? { ...f, status: 'accepted' } : f))
    );

    // Process the suggestion: convert escaped newlines
    const processedSuggestion = (editedSuggestion ?? feedbackItem.suggestion ?? feedbackItem.text)
      .replace(/\\n/g, '\n')
      .trim();

    // Convert markdown to HTML
    const convertToHtml = (text: string): string => {
      const lines = text.split('\n');
      let html = '';

      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed.startsWith('### ')) {
          html += `<h3>${trimmed.substring(4)}</h3>`;
        } else if (trimmed.startsWith('## ')) {
          html += `<h2>${trimmed.substring(3)}</h2>`;
        } else if (trimmed.startsWith('# ')) {
          html += `<h1>${trimmed.substring(2)}</h1>`;
        } else if (trimmed.startsWith('- ')) {
          html += `<li>${trimmed.substring(2)}</li>`;
        } else if (trimmed.startsWith('* ')) {
          html += `<li>${trimmed.substring(2)}</li>`;
        } else if (trimmed === '') {
          continue;
        } else {
          html += `<p>${trimmed}</p>`;
        }
      }
      return html;
    };

    const htmlContent = convertToHtml(processedSuggestion);

    // If there's relevant text, try to find and replace it
    if (feedbackItem.relevantText) {
      const relevantText = feedbackItem.relevantText
        .replace(/\.\.\.$/g, '')
        .replace(/^["']|["']$/g, '')
        .trim();

      // Try to find the relevant text in the document
      const textContent = editor.getText();
      const searchText = relevantText.substring(0, 50); // First 50 chars

      if (textContent.includes(searchText)) {
        // Find the position and select the text
        const doc = editor.state.doc;
        let found = false;

        doc.descendants((node, pos) => {
          if (found) return false;
          if (node.isText && node.text?.includes(searchText)) {
            const start = pos + (node.text.indexOf(searchText));
            const end = start + searchText.length;

            // Set selection and replace
            editor
              .chain()
              .focus()
              .setTextSelection({ from: start, to: end })
              .deleteSelection()
              .insertContent(htmlContent)
              .run();

            found = true;
            return false;
          }
        });

        if (found) return;
      }
    }

    // Fallback: insert at the end of the document
    editor.commands.focus('end');
    editor.commands.insertContent(htmlContent);
  };

  const handleRejectFeedback = (feedbackId: string) => {
    setFeedback((prev) =>
      prev.map((f) => (f.id === feedbackId ? { ...f, status: 'rejected' } : f))
    );
  };

  const handleDeleteConfirm = () => {
    if (window.confirm('Are you sure you want to delete this note?')) {
      onDelete();
    }
  };

  const activeFeedback = feedback.filter((f) => f.status === 'active');
  const rejectedFeedback = feedback.filter((f) => f.status === 'rejected');

  // Keyboard shortcuts
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Cmd/Ctrl + S to force save
      if ((e.metaKey || e.ctrlKey) && e.key === 's') {
        e.preventDefault();
        if (editor) {
          const html = editor.getHTML();
          const title = extractTitle(html);
          onSave({ ...note, content: html, title });
        }
      }

      // Cmd/Ctrl + Enter to accept first active feedback
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && activeFeedback.length > 0) {
        e.preventDefault();
        handleAcceptFeedback(activeFeedback[0].id);
      }

      // Cmd/Ctrl + Backspace to reject first active feedback
      if ((e.metaKey || e.ctrlKey) && e.key === 'Backspace' && activeFeedback.length > 0) {
        e.preventDefault();
        handleRejectFeedback(activeFeedback[0].id);
      }
    };

    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [editor, note, activeFeedback, onSave]);

  // ═══════════════════════════════════════════════════════════════════════
  // DRAG-AND-DROP AUDIO TRANSCRIPTION
  // ═══════════════════════════════════════════════════════════════════════

  const isAudioFile = useCallback((file: File | DataTransferItem): boolean => {
    // Check by MIME type
    if (file.type && file.type.startsWith('audio/')) return true;
    // Check by extension (for File objects with name)
    if ('name' in file && file.name) {
      const ext = '.' + file.name.split('.').pop()?.toLowerCase();
      return SUPPORTED_AUDIO_EXTENSIONS.includes(ext);
    }
    return false;
  }, []);

  const hasAudioFiles = useCallback((dataTransfer: DataTransfer): boolean => {
    for (let i = 0; i < dataTransfer.items.length; i++) {
      const item = dataTransfer.items[i];
      if (item.kind === 'file' && (item.type.startsWith('audio/') || item.type === '')) {
        return true; // Might be audio - check on drop
      }
    }
    return false;
  }, []);

  const handleDragEnter = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    dragCounterRef.current++;
    if (hasAudioFiles(e.dataTransfer)) {
      setIsDragOver(true);
    }
  }, [hasAudioFiles]);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    dragCounterRef.current--;
    if (dragCounterRef.current === 0) {
      setIsDragOver(false);
    }
  }, []);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
  }, []);

  const handleDrop = useCallback(async (e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragOver(false);
    dragCounterRef.current = 0;

    if (!editor) return;

    // Find audio files in the drop
    const audioFiles: File[] = [];
    for (let i = 0; i < e.dataTransfer.files.length; i++) {
      const file = e.dataTransfer.files[i];
      if (isAudioFile(file)) {
        audioFiles.push(file);
      }
    }

    if (audioFiles.length === 0) return;

    // Clear any previous error
    setTranscriptionError(null);
    setIsTranscribing(true);

    try {
      for (const file of audioFiles) {
        // Resolve the dropped file to a filesystem path via the preload bridge
        // (File.path was removed from recent Electron versions)
        let filePath = '';
        try {
          filePath = window.api.stt.getPathForFile(file);
        } catch {
          filePath = (file as File & { path?: string }).path || '';
        }
        if (!filePath) {
          setTranscriptionError('Could not read file path. Please try again.');
          continue;
        }

        // Transcribe the audio file
        const result = await window.api.stt.transcribe(filePath);

        if (result.error) {
          setTranscriptionError(result.error);
          continue;
        }

        if (!result.text) {
          setTranscriptionError('Transcription returned empty text.');
          continue;
        }

        // Format the transcript as HTML
        const html = await window.api.stt.formatTranscript(result, file.name);

        // Insert transcript at cursor position (or end of document)
        editor.chain().focus('end').insertContent(html).run();
      }
    } catch (error) {
      const msg = error instanceof Error ? error.message : 'Transcription failed';
      setTranscriptionError(msg);
    } finally {
      setIsTranscribing(false);
    }
  }, [editor, isAudioFile]);

  // Auto-dismiss transcription error after 8 seconds
  useEffect(() => {
    if (transcriptionError) {
      const timeout = setTimeout(() => setTranscriptionError(null), 8000);
      return () => clearTimeout(timeout);
    }
  }, [transcriptionError]);

  // Auto-dismiss analysis error after 10 seconds
  useEffect(() => {
    if (analysisError) {
      const timeout = setTimeout(() => setAnalysisError(null), 10000);
      return () => clearTimeout(timeout);
    }
  }, [analysisError]);

  return (
    <>
      <div className="editor-header">
        <div className="ai-status" role="status" aria-live="polite">
          <div
            className={`ai-status-dot ${
              aiConnected ? (isAnalyzing ? 'analyzing' : 'connected') : ''
            }`}
            aria-hidden="true"
          />
          <span>
            {aiConnected
              ? isAnalyzing
                ? 'Analyzing...'
                : 'AI Connected'
              : 'AI Disconnected'}
          </span>
          {!aiConnected && (
            <button
              onClick={onOpenSettings}
              style={{
                marginLeft: '8px',
                color: 'var(--accent-color)',
                fontSize: '12px',
              }}
            >
              Configure
            </button>
          )}
        </div>
        <div className="editor-header-actions">
          <button
            className={`editor-header-btn ${autoAnalyze ? 'toggled-on' : ''}`}
            onClick={toggleAutoAnalyze}
            aria-pressed={autoAnalyze}
            title={autoAnalyze ? 'Auto-analysis is on: tips appear while you write' : 'Auto-analysis is off: use "Analyze" to get tips on demand'}
          >
            {autoAnalyze ? <Zap size={14} /> : <ZapOff size={14} />}
            Auto
          </button>
          <button
            className="editor-header-btn"
            onClick={handleAnalyzeNow}
            disabled={!aiConnected || isAnalyzing}
            title="Analyze the note now"
          >
            {isAnalyzing ? <Loader2 size={14} className="spin" /> : <Sparkles size={14} />}
            Analyze
          </button>
          <button className="editor-header-btn danger" onClick={handleDeleteConfirm} title="Delete this note">
            <Trash2 size={14} />
            Delete
          </button>
        </div>
      </div>
      <div
        className={`editor-content ${isDragOver ? 'drag-over' : ''}`}
        onDragEnter={handleDragEnter}
        onDragLeave={handleDragLeave}
        onDragOver={handleDragOver}
        onDrop={handleDrop}
      >
        {/* Drop zone overlay */}
        {isDragOver && (
          <div className="drop-zone-overlay">
            <div className="drop-zone-content">
              <Mic size={48} />
              <p className="drop-zone-title">Drop audio file to transcribe</p>
              <p className="drop-zone-hint">MP3, WAV, M4A, FLAC, OGG, and more</p>
            </div>
          </div>
        )}

        {/* Transcription progress indicator */}
        {isTranscribing && (
          <div className="transcription-progress" role="status">
            <Loader2 size={16} className="spin" />
            <span>Transcribing audio...</span>
          </div>
        )}

        {/* Transcription error */}
        {transcriptionError && (
          <div className="transcription-error" role="alert">
            <AlertCircle size={14} />
            <span>{transcriptionError}</span>
            <button onClick={() => setTranscriptionError(null)} aria-label="Dismiss error">&times;</button>
          </div>
        )}

        {/* AI analysis error */}
        {analysisError && (
          <div className="transcription-error" role="alert">
            <AlertCircle size={14} />
            <span>{analysisError}</span>
            <button onClick={() => setAnalysisError(null)} aria-label="Dismiss error">&times;</button>
          </div>
        )}

        <EditorContent editor={editor} />

        {activeFeedback.length > 0 && (
          <FeedbackPanel
            feedback={activeFeedback}
            onAccept={handleAcceptFeedback}
            onReject={handleRejectFeedback}
            title="AI Suggestions"
            typeConfigs={feedbackTypes}
          />
        )}

        {rejectedFeedback.length > 0 && (
          <div style={{ marginTop: '16px' }}>
            <button
              className="feedback-panel-toggle"
              onClick={() => setShowRejected(!showRejected)}
              aria-expanded={showRejected}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '6px',
                fontSize: '12px',
                color: 'var(--text-muted)',
              }}
            >
              {showRejected ? <EyeOff size={14} /> : <Eye size={14} />}
              {showRejected ? 'Hide' : 'Show'} {rejectedFeedback.length} rejected suggestion
              {rejectedFeedback.length !== 1 ? 's' : ''}
            </button>

            {showRejected && (
              <FeedbackPanel
                feedback={rejectedFeedback}
                onAccept={handleAcceptFeedback}
                onReject={() => {}}
                title="Previously Rejected"
                isRejectedPanel
                typeConfigs={feedbackTypes}
              />
            )}
          </div>
        )}
      </div>
      <div className="shortcuts-bar">
        <div className="shortcut">
          <kbd>⌘</kbd><kbd>S</kbd>
          <span>Save</span>
        </div>
        <div className="shortcut">
          <kbd>⌘</kbd><kbd>Enter</kbd>
          <span>Accept</span>
        </div>
        <div className="shortcut">
          <kbd>⌘</kbd><kbd>⌫</kbd>
          <span>Reject</span>
        </div>
      </div>
    </>
  );
}

export default Editor;
