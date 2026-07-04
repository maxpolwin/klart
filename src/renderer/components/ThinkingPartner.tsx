import { useEffect, useRef, useState } from 'react';
import { X, Send, Loader2, MessagesSquare } from 'lucide-react';
import { COACH_STANCES } from '../../shared/types';

// On-demand critical lenses (pull, not push): the writer summons a specific
// challenge instead of receiving an always-on firehose. Each lens picks the
// stance best suited to it.
const LENSES: { label: string; stance: string; message: string }[] = [
  {
    label: 'Challenge my reasoning',
    stance: 'devils_advocate',
    message: 'Challenge the reasoning in my current section. Where is it weakest?',
  },
  {
    label: 'Strongest counterargument',
    stance: 'devils_advocate',
    message: 'What is the strongest counterargument to my current section? Probe me on it — do not write it for me.',
  },
  {
    label: 'Is this MECE?',
    stance: 'socratic',
    message: 'Question me about whether my section structure is mutually exclusive and collectively exhaustive.',
  },
  {
    label: 'Reviewer 2',
    stance: 'devils_advocate',
    message: 'Act as a skeptical peer reviewer: what would Reviewer 2 push back on first in my current section?',
  },
  {
    label: "I'm stuck",
    stance: 'hint_ladder',
    message: 'I am stuck on my current section. Give me your first hint.',
  },
];

interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
}

interface ThinkingPartnerProps {
  noteId: string;
  getNoteContext: () => { h1: string; section: string; sectionText: string };
  onClose: () => void;
}

function ThinkingPartner({ noteId, getNoteContext, onClose }: ThinkingPartnerProps) {
  const [stance, setStance] = useState('socratic');
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState('');
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [provider, setProvider] = useState<string>('');
  const transcriptRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    window.api.settings.get().then((s) => setProvider(s.provider)).catch(() => {});
  }, []);

  // Reset the dialogue when switching notes
  useEffect(() => {
    setMessages([]);
    setError(null);
  }, [noteId]);

  useEffect(() => {
    transcriptRef.current?.scrollTo({ top: transcriptRef.current.scrollHeight });
  }, [messages, pending]);

  const send = async (text: string, useStance: string = stance) => {
    const content = text.trim();
    if (!content || pending) return;

    setError(null);
    setStance(useStance);
    const nextMessages: ChatMessage[] = [...messages, { role: 'user', content }];
    setMessages(nextMessages);
    setInput('');
    setPending(true);

    try {
      const result = await window.api.ai.chat({
        messages: nextMessages,
        stance: useStance,
        noteContext: getNoteContext(),
      });

      if (result.error || !result.reply) {
        setError(result.error || 'No reply received.');
        return;
      }

      setMessages((prev) => [...prev, { role: 'assistant', content: result.reply! }]);

      // Persist the exchange to the coaching log (memory for later review)
      window.api.coach
        .appendInteraction(noteId, {
          kind: 'chat',
          type: useStance,
          question: result.reply,
          userResponse: content,
          resolved: true,
        })
        .catch(() => {});
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Chat failed');
    } finally {
      setPending(false);
    }
  };

  return (
    <div className="thinking-partner">
      <div className="thinking-partner-header">
        <span className="thinking-partner-title">
          <MessagesSquare size={15} />
          Thinking partner
        </span>
        <button className="thinking-partner-close" onClick={onClose} title="Close">
          <X size={14} />
        </button>
      </div>

      <div className="thinking-partner-stances">
        {Object.values(COACH_STANCES).map((s) => (
          <button
            key={s.id}
            className={`stance-chip ${stance === s.id ? 'active' : ''}`}
            onClick={() => setStance(s.id)}
            title={s.description}
          >
            {s.label}
          </button>
        ))}
      </div>

      <div className="thinking-partner-transcript" ref={transcriptRef}>
        {messages.length === 0 && (
          <div className="thinking-partner-empty">
            <p>
              A sparring partner for your current section. It questions and
              challenges — it will not write for you.
            </p>
            <div className="thinking-partner-lenses">
              {LENSES.map((lens) => (
                <button
                  key={lens.label}
                  className="lens-btn"
                  onClick={() => send(lens.message, lens.stance)}
                  disabled={pending}
                >
                  {lens.label}
                </button>
              ))}
            </div>
            {provider === 'builtin' && (
              <p className="thinking-partner-note">
                Built-in mini model: short exchanges work best. For extended
                debate, configure Ollama or Mistral in Settings.
              </p>
            )}
          </div>
        )}
        {messages.map((m, i) => (
          <div key={i} className={`chat-msg ${m.role}`}>
            {m.content}
          </div>
        ))}
        {pending && (
          <div className="chat-msg assistant pending">
            <Loader2 size={12} className="spin" /> thinking…
          </div>
        )}
        {error && <div className="thinking-partner-error">{error}</div>}
      </div>

      <div className="thinking-partner-input">
        <textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault();
              send(input);
            }
          }}
          placeholder="Your thought first — then the coach responds…"
          rows={2}
          disabled={pending}
        />
        <button
          className="btn btn-primary thinking-partner-send"
          onClick={() => send(input)}
          disabled={pending || !input.trim()}
          title="Send (Enter)"
        >
          <Send size={14} />
        </button>
      </div>
    </div>
  );
}

export default ThinkingPartner;
