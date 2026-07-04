import { useCallback, useEffect, useState } from 'react';
import { ArrowLeft, Brain, Eye, Trash2, CheckCircle2 } from 'lucide-react';
import { ReviewCard, ReviewGradeLabel, ReviewStats, CoachGlobalStats } from '../../shared/types';

// Blur-then-reveal: the writer must attempt recall before seeing the source.
// Auto-answering would destroy the retrieval effect the whole loop exists for.
const MIN_ATTEMPT_LENGTH = 15;

const GRADES: { grade: ReviewGradeLabel; label: string; hint: string }[] = [
  { grade: 'again', label: 'Again', hint: 'Blank — could not recall' },
  { grade: 'hard', label: 'Hard', hint: 'Recalled with real effort' },
  { grade: 'good', label: 'Good', hint: 'Recalled with some effort' },
  { grade: 'easy', label: 'Easy', hint: 'Recalled instantly' },
];

interface ReviewViewProps {
  onBack: () => void;
}

function ReviewView({ onBack }: ReviewViewProps) {
  const [queue, setQueue] = useState<ReviewCard[]>([]);
  const [index, setIndex] = useState(0);
  const [attempt, setAttempt] = useState('');
  const [revealed, setRevealed] = useState(false);
  const [stats, setStats] = useState<ReviewStats | null>(null);
  const [coachStats, setCoachStats] = useState<CoachGlobalStats | null>(null);
  const [loading, setLoading] = useState(true);

  const loadQueue = useCallback(async () => {
    setLoading(true);
    try {
      const [due, reviewStats, globalStats] = await Promise.all([
        window.api.review.listDue(),
        window.api.review.stats(),
        window.api.coach.globalStats(),
      ]);
      setQueue(due);
      setStats(reviewStats);
      setCoachStats(globalStats);
      setIndex(0);
      setAttempt('');
      setRevealed(false);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadQueue();
  }, [loadQueue]);

  const card = queue[index];

  const grade = async (gradeLabel: ReviewGradeLabel) => {
    if (!card) return;
    await window.api.review.grade(card.id, gradeLabel);
    const reviewStats = await window.api.review.stats();
    setStats(reviewStats);
    setIndex((i) => i + 1);
    setAttempt('');
    setRevealed(false);
  };

  const removeCard = async () => {
    if (!card) return;
    await window.api.review.deleteCard(card.id);
    setQueue((prev) => prev.filter((c) => c.id !== card.id));
    setAttempt('');
    setRevealed(false);
  };

  const attemptLongEnough = attempt.trim().length >= MIN_ATTEMPT_LENGTH;

  return (
    <div className="review-view">
      <div className="review-header">
        <button className="editor-header-btn" onClick={onBack}>
          <ArrowLeft size={14} />
          Notes
        </button>
        <span className="review-title">
          <Brain size={16} />
          Review — recall your own research
        </span>
        <span className="review-progress">
          {card ? `${index + 1} / ${queue.length}` : ''}
        </span>
      </div>

      <div className="review-body">
        {loading ? (
          <p className="review-empty">Loading…</p>
        ) : !card ? (
          <div className="review-done">
            <CheckCircle2 size={40} />
            <h2>{queue.length > 0 ? 'Queue done for now' : 'Nothing due'}</h2>
            <p>
              {stats && stats.total === 0
                ? 'No review cards yet. Open a note and use "Make review cards" to turn your own claims into recall prompts.'
                : `Reviewed today: ${stats?.reviewedToday ?? 0} · Total cards: ${stats?.total ?? 0} · Due now: ${stats?.due ?? 0}`}
            </p>
            {coachStats && (coachStats.questionsAnswered > 0 || coachStats.draftsRequested > 0 || coachStats.chatExchanges > 0) && (
              <div className="review-insights">
                <h3>Coaching balance</h3>
                <p>
                  Questions answered in your own words: <strong>{coachStats.questionsAnswered}</strong>
                  {' · '}AI drafts requested: <strong>{coachStats.draftsRequested}</strong>
                  {' · '}Sparring exchanges: <strong>{coachStats.chatExchanges}</strong>
                </p>
                {coachStats.draftsRequested > coachStats.questionsAnswered && (
                  <p className="review-insights-nudge">
                    You are drafting with AI more than answering in your own words —
                    writing it yourself is what builds durable understanding.
                  </p>
                )}
              </div>
            )}
          </div>
        ) : (
          <div className="review-card">
            <div className="review-card-meta">
              <span className="review-card-note">{card.noteTitle}</span>
              <span className="review-card-section">§ {card.sectionTitle}</span>
              {card.kind === 'self_explanation' && (
                <span className="review-card-kind">Explain it simply</span>
              )}
            </div>

            <p className="review-card-question">{card.question}</p>

            <textarea
              className="review-attempt"
              value={attempt}
              onChange={(e) => setAttempt(e.target.value)}
              placeholder="Jot your recall attempt from memory — the reveal unlocks after a genuine try…"
              rows={4}
              disabled={revealed}
            />

            {!revealed ? (
              <div className="review-actions">
                <button
                  className="btn btn-primary"
                  disabled={!attemptLongEnough}
                  onClick={() => setRevealed(true)}
                >
                  <Eye size={14} />
                  {attemptLongEnough
                    ? 'Reveal what you wrote'
                    : `Attempt first (${Math.max(0, MIN_ATTEMPT_LENGTH - attempt.trim().length)} more chars)`}
                </button>
                <button className="btn btn-secondary" onClick={removeCard} title="Remove this card">
                  <Trash2 size={14} />
                </button>
              </div>
            ) : (
              <>
                <div className="review-source">
                  <p className="review-source-label">From your note:</p>
                  <p className="review-source-text">{card.sourceExcerpt}</p>
                </div>
                <div className="review-grades">
                  {GRADES.map(({ grade: g, label, hint }) => (
                    <button
                      key={g}
                      className={`review-grade-btn ${g}`}
                      onClick={() => grade(g)}
                      title={hint}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

export default ReviewView;
