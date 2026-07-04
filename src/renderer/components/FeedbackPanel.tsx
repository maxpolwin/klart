import { memo, useState } from 'react';
import { Check, X, RefreshCw, ChevronDown, ChevronRight, Sparkles, Copy, Undo2 } from 'lucide-react';
import { FeedbackItem, FeedbackTypeConfig, DEFAULT_FEEDBACK_LABELS } from '../../shared/types';

interface FeedbackPanelProps {
  feedback: FeedbackItem[];
  onAccept: (id: string, editedSuggestion?: string) => void;
  onReject: (id: string) => void;
  title: string;
  isRejectedPanel?: boolean;
  typeConfigs?: FeedbackTypeConfig[];
}

function hexToRgba(hex: string, alpha: number): string {
  const match = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!match) return `rgba(147, 51, 234, ${alpha})`;
  const value = parseInt(match[1], 16);
  const r = (value >> 16) & 0xff;
  const g = (value >> 8) & 0xff;
  const b = value & 0xff;
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function FeedbackPanel({
  feedback,
  onAccept,
  onReject,
  title,
  isRejectedPanel = false,
  typeConfigs,
}: FeedbackPanelProps) {
  const [expandedItems, setExpandedItems] = useState<Set<string>>(new Set());
  // Suggestions the user has edited before inserting, keyed by feedback id
  const [editedSuggestions, setEditedSuggestions] = useState<Record<string, string>>({});
  const [copiedId, setCopiedId] = useState<string | null>(null);

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

  const getBadge = (type: string): { label: string; style?: React.CSSProperties; className: string } => {
    const config = typeConfigs?.find((t) => t.id === type);
    if (config) {
      return {
        label: config.label || type.toUpperCase(),
        className: 'feedback-item-badge',
        style: {
          background: hexToRgba(config.color, 0.1),
          color: config.color,
          border: `1px solid ${hexToRgba(config.color, 0.35)}`,
        },
      };
    }
    return {
      label: DEFAULT_FEEDBACK_LABELS[type as keyof typeof DEFAULT_FEEDBACK_LABELS] || type.toUpperCase(),
      className: `feedback-item-badge ${type}`,
    };
  };

  const getSuggestionText = (item: FeedbackItem): string =>
    editedSuggestions[item.id] ?? (item.suggestion || '').replace(/\\n/g, '\n');

  const handleCopy = async (item: FeedbackItem) => {
    const text = getSuggestionText(item) || item.text;
    try {
      await navigator.clipboard.writeText(text);
      setCopiedId(item.id);
      setTimeout(() => setCopiedId((prev) => (prev === item.id ? null : prev)), 1500);
    } catch (error) {
      console.error('Copy failed:', error);
    }
  };

  const handleAccept = (item: FeedbackItem) => {
    const edited = editedSuggestions[item.id];
    onAccept(item.id, edited !== undefined ? edited : undefined);
  };

  return (
    <section className="feedback-panel" aria-label={title}>
      <div className="feedback-panel-header">
        <span className="feedback-panel-title">
          <Sparkles size={16} aria-hidden="true" />
          {title} ({feedback.length})
        </span>
      </div>
      <ul className="feedback-list">
        {feedback.map((item) => {
          const badge = getBadge(item.type);
          const isExpanded = expandedItems.has(item.id);
          const isEdited = editedSuggestions[item.id] !== undefined;

          return (
            <li key={item.id} className="feedback-item">
              <span className={badge.className} style={badge.style}>
                {badge.label}
              </span>
              <div className="feedback-item-content">
                <p className="feedback-item-text">{item.text}</p>
                {item.relevantText && (
                  <p className="feedback-item-related">
                    Related to: "{item.relevantText.substring(0, 60)}..."
                  </p>
                )}
                {item.suggestion && (
                  <button
                    className="feedback-expand-btn"
                    onClick={() => toggleExpand(item.id)}
                    aria-expanded={isExpanded}
                  >
                    {isExpanded ? (
                      <ChevronDown size={14} aria-hidden="true" />
                    ) : (
                      <ChevronRight size={14} aria-hidden="true" />
                    )}
                    {isExpanded ? 'Hide' : 'Preview & edit'} suggested content
                    {isEdited && <span className="feedback-edited-tag">edited</span>}
                  </button>
                )}
                {item.suggestion && isExpanded && (
                  <div className="feedback-item-suggestion-wrap">
                    <textarea
                      className="feedback-item-suggestion-editor"
                      value={getSuggestionText(item)}
                      onChange={(e) =>
                        setEditedSuggestions((prev) => ({ ...prev, [item.id]: e.target.value }))
                      }
                      rows={Math.min(12, Math.max(4, getSuggestionText(item).split('\n').length + 1))}
                      aria-label="Edit suggested content before inserting"
                      spellCheck
                    />
                    <div className="feedback-suggestion-tools">
                      <button
                        className="feedback-tool-btn"
                        onClick={() => handleCopy(item)}
                        title="Copy suggestion to clipboard"
                      >
                        <Copy size={12} aria-hidden="true" />
                        {copiedId === item.id ? 'Copied!' : 'Copy'}
                      </button>
                      {isEdited && (
                        <button
                          className="feedback-tool-btn"
                          onClick={() =>
                            setEditedSuggestions((prev) => {
                              const next = { ...prev };
                              delete next[item.id];
                              return next;
                            })
                          }
                          title="Revert to the original suggestion"
                        >
                          <Undo2 size={12} aria-hidden="true" />
                          Reset
                        </button>
                      )}
                    </div>
                  </div>
                )}
              </div>
              <div className="feedback-item-actions">
                {isRejectedPanel ? (
                  <button
                    className="feedback-item-btn accept"
                    onClick={() => handleAccept(item)}
                    title="Reconsider this suggestion"
                    aria-label="Reconsider this suggestion"
                  >
                    <RefreshCw size={14} aria-hidden="true" />
                  </button>
                ) : (
                  <>
                    <button
                      className="feedback-item-btn accept"
                      onClick={() => handleAccept(item)}
                      title="Accept and insert (⌘+Enter)"
                      aria-label="Accept and insert suggestion"
                    >
                      <Check size={14} aria-hidden="true" />
                    </button>
                    <button
                      className="feedback-item-btn reject"
                      onClick={() => onReject(item.id)}
                      title="Reject (⌘+⌫)"
                      aria-label="Reject suggestion"
                    >
                      <X size={14} aria-hidden="true" />
                    </button>
                  </>
                )}
              </div>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

export default memo(FeedbackPanel);
