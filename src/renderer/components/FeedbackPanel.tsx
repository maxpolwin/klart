import { useEffect, useState } from 'react';
import { Check, X, RefreshCw, ChevronDown, ChevronRight, Sparkles, Lightbulb, PenLine, Loader2 } from 'lucide-react';
import { FeedbackItem, DEFAULT_FEEDBACK_LABELS } from '../../shared/types';

// Commit-first friction: the writer must state their own take before the AI
// will draft for them (cognitive forcing function against over-reliance).
const MIN_TAKE_LENGTH = 30;

interface FeedbackPanelProps {
  feedback: FeedbackItem[];
  onAccept: (id: string) => void; // legacy generate-mode accept (inserts AI suggestion)
  onReject: (id: string) => void;
  onRespond?: (id: string, text: string) => void; // coach mode: insert the writer's own words
  onDraft?: (id: string, userTake: string) => void; // explicit AI drafting (provenance-logged)
  respondingId?: string | null;
  onStartRespond?: (id: string | null) => void;
  draftingId?: string | null;
  title: string;
  isRejectedPanel?: boolean;
}

function FeedbackPanel({
  feedback,
  onAccept,
  onReject,
  onRespond,
  onDraft,
  respondingId = null,
  onStartRespond,
  draftingId = null,
  title,
  isRejectedPanel = false,
}: FeedbackPanelProps) {
  const [expandedItems, setExpandedItems] = useState<Set<string>>(new Set());
  const [revealedHints, setRevealedHints] = useState<Set<string>>(new Set());
  const [responseText, setResponseText] = useState('');
  const [draftGateId, setDraftGateId] = useState<string | null>(null);
  const [draftTake, setDraftTake] = useState('');

  // Reset the composer whenever the target item changes
  useEffect(() => {
    setResponseText('');
  }, [respondingId]);

  if (feedback.length === 0) return null;

  const toggleExpand = (id: string) => {
    setExpandedItems((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  };

  const revealHint = (id: string) => {
    setRevealedHints((prev) => new Set(prev).add(id));
  };

  const submitResponse = (id: string) => {
    const text = responseText.trim();
    if (!text || !onRespond) return;
    onRespond(id, text);
    setResponseText('');
    onStartRespond?.(null);
  };

  const openDraftGate = (id: string) => {
    setDraftGateId((prev) => (prev === id ? null : id));
    setDraftTake('');
  };

  const submitDraft = (id: string) => {
    const take = draftTake.trim();
    if (take.length < MIN_TAKE_LENGTH || !onDraft) return;
    onDraft(id, take);
    setDraftGateId(null);
    setDraftTake('');
  };

  const isCoachItem = (item: FeedbackItem) => item.mode === 'coach' || !!item.question;

  return (
    <div className="feedback-panel">
      <div className="feedback-panel-header">
        <span className="feedback-panel-title">
          <Sparkles size={16} />
          {title} ({feedback.length})
        </span>
      </div>
      <div className="feedback-list">
        {feedback.map((item) => (
          <div key={item.id} className="feedback-item">
            <span className={`feedback-item-badge ${item.type}`}>
              {DEFAULT_FEEDBACK_LABELS[item.type as keyof typeof DEFAULT_FEEDBACK_LABELS] || item.type.toUpperCase()}
            </span>
            <div className="feedback-item-content">
              {isCoachItem(item) ? (
                <>
                  <p className="feedback-item-question">{item.question || item.text}</p>
                  {item.question && item.text && item.text !== item.question && (
                    <p className="feedback-item-why">{item.text}</p>
                  )}
                </>
              ) : (
                <p className="feedback-item-text">{item.text}</p>
              )}
              {item.relevantText && (
                <p className="feedback-item-related">
                  Related to: "{item.relevantText.substring(0, 60)}..."
                </p>
              )}

              {/* Hint: a nudge that points where to look, revealed on demand */}
              {isCoachItem(item) && item.hint && !isRejectedPanel && (
                revealedHints.has(item.id) ? (
                  <p className="feedback-item-hint">
                    <Lightbulb size={12} /> {item.hint}
                  </p>
                ) : (
                  <button className="feedback-expand-btn" onClick={() => revealHint(item.id)}>
                    <Lightbulb size={14} />
                    Show hint
                  </button>
                )
              )}

              {/* Legacy generate-mode suggestion preview */}
              {!isCoachItem(item) && item.suggestion && (
                <button
                  className="feedback-expand-btn"
                  onClick={() => toggleExpand(item.id)}
                >
                  {expandedItems.has(item.id) ? (
                    <ChevronDown size={14} />
                  ) : (
                    <ChevronRight size={14} />
                  )}
                  {expandedItems.has(item.id) ? 'Hide' : 'Preview'} suggested content
                </button>
              )}
              {!isCoachItem(item) && item.suggestion && expandedItems.has(item.id) && (
                <div className="feedback-item-suggestion">
                  {item.suggestion.replace(/\\n/g, '\n')}
                </div>
              )}

              {/* Respond composer: the writer answers in their OWN words */}
              {isCoachItem(item) && respondingId === item.id && !isRejectedPanel && (
                <div className="feedback-respond-area">
                  <textarea
                    autoFocus
                    value={responseText}
                    onChange={(e) => setResponseText(e.target.value)}
                    onKeyDown={(e) => {
                      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
                        e.preventDefault();
                        submitResponse(item.id);
                      }
                    }}
                    placeholder="Answer in your own words — this goes into your note…"
                    rows={4}
                  />
                  <div className="feedback-respond-actions">
                    <button
                      className="btn btn-primary feedback-respond-submit"
                      disabled={!responseText.trim()}
                      onClick={() => submitResponse(item.id)}
                    >
                      Add my answer to the note
                    </button>
                    <button
                      className="btn btn-secondary"
                      onClick={() => onStartRespond?.(null)}
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              )}

              {/* Demoted, commit-gated AI drafting */}
              {isCoachItem(item) && !isRejectedPanel && onDraft && (
                <>
                  {draftingId === item.id ? (
                    <p className="feedback-drafting">
                      <Loader2 size={12} className="spin" /> Drafting… (will be logged as AI-authored)
                    </p>
                  ) : draftGateId === item.id ? (
                    <div className="feedback-draft-gate">
                      <p className="feedback-draft-gate-label">
                        Write your rough take first — the draft builds on it, and drafting is logged as AI-authored.
                      </p>
                      <textarea
                        autoFocus
                        value={draftTake}
                        onChange={(e) => setDraftTake(e.target.value)}
                        placeholder="Your one-or-two-line take on this…"
                        rows={2}
                      />
                      <div className="feedback-respond-actions">
                        <button
                          className="btn btn-secondary"
                          disabled={draftTake.trim().length < MIN_TAKE_LENGTH}
                          onClick={() => submitDraft(item.id)}
                        >
                          {draftTake.trim().length < MIN_TAKE_LENGTH
                            ? `Generate draft (${Math.max(0, MIN_TAKE_LENGTH - draftTake.trim().length)} more chars)`
                            : 'Generate draft'}
                        </button>
                        <button className="btn btn-secondary" onClick={() => setDraftGateId(null)}>
                          Cancel
                        </button>
                      </div>
                    </div>
                  ) : (
                    respondingId !== item.id && (
                      <button
                        className="feedback-draft-link"
                        onClick={() => openDraftGate(item.id)}
                        title="Explicitly ask the AI to draft — you commit your own take first"
                      >
                        Draft it for me…
                      </button>
                    )
                  )}
                </>
              )}
            </div>
            <div className="feedback-item-actions">
              {isRejectedPanel ? (
                <button
                  className="feedback-item-btn accept"
                  onClick={() => onAccept(item.id)}
                  title="Reconsider this suggestion"
                >
                  <RefreshCw size={14} />
                </button>
              ) : isCoachItem(item) ? (
                <>
                  <button
                    className="feedback-item-btn accept"
                    onClick={() => onStartRespond?.(respondingId === item.id ? null : item.id)}
                    title="Respond in your own words (⌘+Enter)"
                  >
                    <PenLine size={14} />
                  </button>
                  <button
                    className="feedback-item-btn reject"
                    onClick={() => onReject(item.id)}
                    title="Dismiss (⌘+⌫)"
                  >
                    <X size={14} />
                  </button>
                </>
              ) : (
                <>
                  <button
                    className="feedback-item-btn accept"
                    onClick={() => onAccept(item.id)}
                    title="Accept and insert (⌘+Enter)"
                  >
                    <Check size={14} />
                  </button>
                  <button
                    className="feedback-item-btn reject"
                    onClick={() => onReject(item.id)}
                    title="Reject (⌘+⌫)"
                  >
                    <X size={14} />
                  </button>
                </>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

export default FeedbackPanel;
