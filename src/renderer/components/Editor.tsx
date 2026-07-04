import { useState, useEffect, useCallback, useRef } from 'react';
import { useEditor, EditorContent } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import Placeholder from '@tiptap/extension-placeholder';
import Heading from '@tiptap/extension-heading';
import { Trash2, Eye, EyeOff, Mic, Loader2, AlertCircle, History, Compass, X, ShieldCheck, MessagesSquare, Brain } from 'lucide-react';
import { Note, FeedbackItem, CoachInteraction, SUPPORTED_AUDIO_EXTENSIONS } from '../../shared/types';
import { runRuleChecks, RuleFinding } from '../../shared/ruleChecks';
import FeedbackPanel from './FeedbackPanel';
import ThinkingPartner from './ThinkingPartner';

// Metacognitive scaffolds: short, canned plan/monitor/evaluate prompts keyed
// to how far along the note is. Deterministic — no model involved.
const SCAFFOLDS: { id: string; minLen: number; maxLen: number; text: string }[] = [
  {
    id: 'plan',
    minLen: 0,
    maxLen: 120,
    text: 'Before you write: what is your thesis in one line? What should this note establish?',
  },
  {
    id: 'monitor',
    minLen: 1200,
    maxLen: 2500,
    text: 'Pause: is the current section actually answering the question your title poses?',
  },
  {
    id: 'evaluate',
    minLen: 2500,
    maxLen: Infinity,
    text: 'Which claim here would you defend least confidently? Consider strengthening or flagging it.',
  },
];

interface EditorProps {
  note: Note;
  onSave: (note: Note) => void;
  onDelete: () => void;
  aiConnected: boolean;
  isAnalyzing: boolean;
  setIsAnalyzing: (analyzing: boolean) => void;
  onOpenSettings: () => void;
  onReviewCardsChanged?: () => void;
}

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
  onReviewCardsChanged,
}: EditorProps) {
  const [feedback, setFeedback] = useState<FeedbackItem[]>([]);
  const [showRejected, setShowRejected] = useState(false);
  const [lastContent, setLastContent] = useState(note.content);
  const analysisTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const saveTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const checksTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  // Coaching state
  const [respondingId, setRespondingId] = useState<string | null>(null);
  const [draftingId, setDraftingId] = useState<string | null>(null);
  const [coachLog, setCoachLog] = useState<CoachInteraction[]>([]);
  const [showCoachHistory, setShowCoachHistory] = useState(false);
  const [dismissedScaffolds, setDismissedScaffolds] = useState<Set<string>>(new Set());
  const [ruleFindings, setRuleFindings] = useState<RuleFinding[]>([]);
  const [showPartner, setShowPartner] = useState(false);
  const [makingCards, setMakingCards] = useState(false);
  const [cardsMessage, setCardsMessage] = useState<string | null>(null);
  const [contentLength, setContentLength] = useState(
    note.content.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim().length
  );

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
      },
    },
  });

  // Update editor content when note changes
  useEffect(() => {
    if (editor && note.content !== editor.getHTML()) {
      editor.commands.setContent(note.content);
      setLastContent(note.content);
      setFeedback([]);
    }
  }, [note.id, editor]);

  // Load coaching memory + reset coaching UI when switching notes
  useEffect(() => {
    setRespondingId(null);
    setDraftingId(null);
    setShowCoachHistory(false);
    setDismissedScaffolds(new Set());
    setRuleFindings(runRuleChecks(note.content));
    setContentLength(note.content.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim().length);
    window.api.coach
      .getLog(note.id)
      .then(setCoachLog)
      .catch(() => setCoachLog([]));
  }, [note.id]);

  const appendToCoachLog = useCallback(
    async (interaction: Partial<CoachInteraction>) => {
      try {
        const saved = await window.api.coach.appendInteraction(note.id, interaction);
        if (saved) {
          setCoachLog((prev) => [...prev, saved]);
        }
      } catch (error) {
        console.error('Failed to persist coaching interaction:', error);
      }
    },
    [note.id]
  );

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

      if (aiConnected && html !== lastContent && html.trim().length > 50) {
        analysisTimeoutRef.current = setTimeout(() => {
          analyzeContent(html);
        }, 2000);
      }

      // Deterministic offline checks + scaffold sizing (no model involved,
      // works even when AI is disconnected)
      if (checksTimeoutRef.current) {
        clearTimeout(checksTimeoutRef.current);
      }
      checksTimeoutRef.current = setTimeout(() => {
        setRuleFindings(runRuleChecks(html));
        setContentLength(html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim().length);
      }, 1200);

      setLastContent(html);
    },
    [note, onSave, aiConnected, lastContent]
  );

  const analyzeContent = async (html: string) => {
    setIsAnalyzing(true);

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
      console.error('Analysis failed:', error);
    }

    setIsAnalyzing(false);
  };

  // Convert lightweight markdown to HTML for insertion
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

  // Insert content right after the block containing relevantText,
  // falling back to the end of the document.
  const insertNearRelevantText = (htmlContent: string, relevantText?: string) => {
    if (!editor) return;

    if (relevantText) {
      const cleaned = relevantText
        .replace(/\.\.\.$/g, '')
        .replace(/^["']|["']$/g, '')
        .trim();
      const searchText = cleaned.substring(0, 50);

      if (searchText.length >= 8 && editor.getText().includes(searchText)) {
        const doc = editor.state.doc;
        let insertPos = -1;

        doc.descendants((node, pos) => {
          if (insertPos >= 0) return false;
          if (node.isText && node.text?.includes(searchText)) {
            const $pos = doc.resolve(pos);
            insertPos = $pos.after($pos.depth); // position right after the parent block
            return false;
          }
        });

        if (insertPos >= 0) {
          try {
            editor.chain().focus().insertContentAt(insertPos, htmlContent).run();
            return;
          } catch {
            // fall through to end-of-document insertion
          }
        }
      }
    }

    editor.commands.focus('end');
    editor.commands.insertContent(htmlContent);
  };

  // Coach mode primary action: the WRITER answers the question, and their
  // own words are inserted into the note (generation effect — the human
  // produces the content, the AI only prompted it).
  const handleRespond = (feedbackId: string, userText: string) => {
    const feedbackItem = feedback.find((f) => f.id === feedbackId);
    if (!feedbackItem || !editor || !userText.trim()) return;

    setFeedback((prev) =>
      prev.map((f) =>
        f.id === feedbackId ? { ...f, status: 'accepted', userResponse: userText } : f
      )
    );

    insertNearRelevantText(convertToHtml(userText.trim()), feedbackItem.relevantText);

    // Persist to the coaching log (human-authored — counts toward skill signal)
    appendToCoachLog({
      kind: 'question',
      type: feedbackItem.type,
      sectionId: feedbackItem.sectionId,
      question: feedbackItem.question || feedbackItem.text,
      userResponse: userText.trim(),
      resolved: true,
    });

    setRespondingId(null);
  };

  // Explicit AI drafting — the only path that inserts AI-authored prose in
  // coach mode. Gated behind the writer committing their own take first;
  // the exact inserted text is logged as AI-authored (provenance).
  const handleDraftForMe = async (feedbackId: string, userTake: string) => {
    const feedbackItem = feedback.find((f) => f.id === feedbackId);
    if (!feedbackItem || !editor) return;

    setDraftingId(feedbackId);
    try {
      const html = editor.getHTML();
      const { h1, h2s } = extractHeadings(html);
      const plainText = html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();

      const result = await window.api.ai.draft({
        content: plainText,
        context: { h1, h2: h2s[h2s.length - 1] || '', allH2s: h2s },
        item: {
          type: feedbackItem.type,
          text: feedbackItem.text,
          question: feedbackItem.question,
          relevantText: feedbackItem.relevantText,
        },
        userTake,
      });

      if (result.error || !result.draft) {
        console.error('Draft generation failed:', result.error);
        return;
      }

      setFeedback((prev) =>
        prev.map((f) => (f.id === feedbackId ? { ...f, status: 'accepted' } : f))
      );

      insertNearRelevantText(convertToHtml(result.draft), feedbackItem.relevantText);

      // Provenance: record the exact AI-authored text that entered the note
      appendToCoachLog({
        kind: 'draft',
        type: feedbackItem.type,
        sectionId: feedbackItem.sectionId,
        question: feedbackItem.question || feedbackItem.text,
        userResponse: userTake,
        aiDraft: result.draft,
        resolved: true,
      });
    } finally {
      setDraftingId(null);
    }
  };

  // Legacy generate-mode accept: inserts the AI-written suggestion
  const handleAcceptFeedback = (feedbackId: string) => {
    const feedbackItem = feedback.find((f) => f.id === feedbackId);
    if (!feedbackItem || !editor) return;

    // Coach items have no insertable prose — route to the respond composer
    if (feedbackItem.mode === 'coach' || (!feedbackItem.suggestion && feedbackItem.question)) {
      setRespondingId(feedbackId);
      return;
    }

    setFeedback((prev) =>
      prev.map((f) => (f.id === feedbackId ? { ...f, status: 'accepted' } : f))
    );

    // Process the suggestion: convert escaped newlines
    const processedSuggestion = (feedbackItem.suggestion || feedbackItem.text)
      .replace(/\\n/g, '\n')
      .trim();

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

  // Move a rejected item back into the active queue for reconsideration
  const handleReconsiderFeedback = (feedbackId: string) => {
    setFeedback((prev) =>
      prev.map((f) => (f.id === feedbackId ? { ...f, status: 'active' } : f))
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

      // Cmd/Ctrl + Enter: respond to (coach) or accept (generate) the first
      // active feedback. Skipped while a respond composer is open — its own
      // textarea handles submission.
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && activeFeedback.length > 0 && !respondingId) {
        e.preventDefault();
        handleAcceptFeedback(activeFeedback[0].id);
      }

      // Cmd/Ctrl + Backspace to reject first active feedback
      if ((e.metaKey || e.ctrlKey) && e.key === 'Backspace' && activeFeedback.length > 0 && !respondingId) {
        e.preventDefault();
        handleRejectFeedback(activeFeedback[0].id);
      }
    };

    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [editor, note, activeFeedback, onSave, respondingId]);

  // Manual, on-demand card generation from this note (never on the debounce)
  const handleMakeReviewCards = async () => {
    if (makingCards) return;
    setMakingCards(true);
    setCardsMessage(null);
    try {
      const result = await window.api.review.generateCards(note.id);
      if (result.error && result.created === 0) {
        setCardsMessage(result.error);
      } else {
        setCardsMessage(`+${result.created} review card${result.created === 1 ? '' : 's'}`);
        onReviewCardsChanged?.();
      }
    } catch {
      setCardsMessage('Card generation failed');
    } finally {
      setMakingCards(false);
      setTimeout(() => setCardsMessage(null), 5000);
    }
  };

  // Current-section context handed to the thinking partner on each turn
  const getNoteContext = useCallback(() => {
    const html = editor?.getHTML() || '';
    const { h1, h2s } = extractHeadings(html);
    const section = h2s[h2s.length - 1] || '';

    // Take the content of the last H2 section (the one being worked on)
    let sectionHtml = html;
    const parts = html.split(/<h2[^>]*>/i);
    if (parts.length > 1) {
      sectionHtml = parts[parts.length - 1];
    }
    const sectionText = sectionHtml
      .replace(/<[^>]*>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .substring(0, 4000);

    return { h1, section, sectionText };
  }, [editor]);

  // Pick the first applicable, not-yet-dismissed metacognitive scaffold
  const activeScaffold = SCAFFOLDS.find(
    (s) =>
      contentLength >= s.minLen &&
      contentLength < s.maxLen &&
      !dismissedScaffolds.has(s.id)
  );

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
        // Electron provides a `path` property on dropped File objects
        const filePath = (file as File & { path?: string }).path;
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

  return (
    <>
      <div className="editor-header">
        <div className="ai-status">
          <div
            className={`ai-status-dot ${
              aiConnected ? (isAnalyzing ? 'analyzing' : 'connected') : ''
            }`}
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
          {cardsMessage && <span className="cards-message">{cardsMessage}</span>}
          <button
            className="editor-header-btn"
            onClick={handleMakeReviewCards}
            disabled={makingCards}
            title="Turn this note's sections into spaced recall prompts"
          >
            {makingCards ? <Loader2 size={14} className="spin" /> : <Brain size={14} />}
            {makingCards ? 'Making cards…' : 'Make review cards'}
          </button>
          <button
            className={`editor-header-btn ${showPartner ? 'active' : ''}`}
            onClick={() => setShowPartner(!showPartner)}
            title="Open the thinking partner — it questions, it doesn't write"
          >
            <MessagesSquare size={14} />
            Partner
          </button>
          <button className="editor-header-btn danger" onClick={handleDeleteConfirm}>
            <Trash2 size={14} />
            Delete
          </button>
        </div>
      </div>

      {showPartner && (
        <ThinkingPartner
          noteId={note.id}
          getNoteContext={getNoteContext}
          onClose={() => setShowPartner(false)}
        />
      )}
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
          <div className="transcription-progress">
            <Loader2 size={16} className="spin" />
            <span>Transcribing audio...</span>
          </div>
        )}

        {/* Transcription error */}
        {transcriptionError && (
          <div className="transcription-error">
            <AlertCircle size={14} />
            <span>{transcriptionError}</span>
            <button onClick={() => setTranscriptionError(null)}>&times;</button>
          </div>
        )}

        <EditorContent editor={editor} />

        {/* Metacognitive scaffold — deterministic, dismissible */}
        {activeScaffold && (
          <div className="scaffold-bar">
            <Compass size={14} />
            <span>{activeScaffold.text}</span>
            <button
              className="scaffold-dismiss"
              onClick={() =>
                setDismissedScaffolds((prev) => new Set(prev).add(activeScaffold.id))
              }
              title="Dismiss"
            >
              <X size={12} />
            </button>
          </div>
        )}

        {activeFeedback.length > 0 && (
          <FeedbackPanel
            feedback={activeFeedback}
            onAccept={handleAcceptFeedback}
            onReject={handleRejectFeedback}
            onRespond={handleRespond}
            onDraft={handleDraftForMe}
            respondingId={respondingId}
            onStartRespond={setRespondingId}
            draftingId={draftingId}
            title="Coach"
          />
        )}

        {/* Deterministic offline checks — named rules, no LLM involved */}
        {ruleFindings.length > 0 && (
          <div className="rule-checks-panel">
            <div className="rule-checks-header">
              <ShieldCheck size={14} />
              <span>Offline checks ({ruleFindings.length})</span>
            </div>
            {ruleFindings.map((finding, i) => (
              <div key={`${finding.rule}-${i}`} className="rule-check-item">
                <span className="rule-check-badge">{finding.label}</span>
                <span className="rule-check-message">
                  {finding.message}
                  {finding.excerpt && (
                    <span className="rule-check-excerpt"> — "{finding.excerpt}"</span>
                  )}
                </span>
              </div>
            ))}
          </div>
        )}

        {rejectedFeedback.length > 0 && (
          <div style={{ marginTop: '16px' }}>
            <button
              className="feedback-panel-toggle"
              onClick={() => setShowRejected(!showRejected)}
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
                onAccept={handleReconsiderFeedback}
                onReject={() => {}}
                title="Previously Rejected"
                isRejectedPanel
              />
            )}
          </div>
        )}

        {/* Coaching memory: past questions answered on this note */}
        {coachLog.length > 0 && (
          <div style={{ marginTop: '16px' }}>
            <button
              className="feedback-panel-toggle"
              onClick={() => setShowCoachHistory(!showCoachHistory)}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '6px',
                fontSize: '12px',
                color: 'var(--text-muted)',
              }}
            >
              <History size={14} />
              {showCoachHistory ? 'Hide' : 'Show'} coaching history ({coachLog.length})
            </button>

            {showCoachHistory && (
              <div className="coach-history">
                {[...coachLog].reverse().map((entry) => (
                  <div key={entry.id} className="coach-history-item">
                    <span className={`coach-history-kind ${entry.kind}`}>
                      {entry.kind === 'draft' ? 'AI DRAFT' : entry.kind.toUpperCase()}
                    </span>
                    <div className="coach-history-body">
                      <p className="coach-history-question">{entry.question}</p>
                      {entry.userResponse && (
                        <p className="coach-history-response">You: {entry.userResponse}</p>
                      )}
                      {entry.aiDraft && (
                        <p className="coach-history-draft">AI wrote: {entry.aiDraft.substring(0, 160)}{entry.aiDraft.length > 160 ? '…' : ''}</p>
                      )}
                    </div>
                  </div>
                ))}
              </div>
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
          <span>Respond</span>
        </div>
        <div className="shortcut">
          <kbd>⌘</kbd><kbd>⌫</kbd>
          <span>Dismiss</span>
        </div>
      </div>
    </>
  );
}

export default Editor;
