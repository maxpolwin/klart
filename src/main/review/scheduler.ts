// Pure spaced-repetition scheduler — no dependencies, no I/O, unit-testable.
//
// Implements canonical SM-2 (SuperMemo 2) at day granularity. The signature
// is deliberately minimal so a stronger scheduler (e.g. FSRS) can swap in
// behind `initialSchedule`/`scheduleNext` without touching callers.

import type { Sm2State, ReviewGradeLabel } from '../../shared/types';

// Map the four grade buttons onto the SuperMemo 0-5 quality scale.
// 'again' < 3 → lapse; 'hard'/'good'/'easy' → successful recall.
export const GRADE_QUALITY: Record<ReviewGradeLabel, number> = {
  again: 2,
  hard: 3,
  good: 4,
  easy: 5,
};

const DAY_MS = 24 * 60 * 60 * 1000;
const MIN_EASE = 1.3;
const INITIAL_EASE = 2.5;

export function initialSchedule(now: Date = new Date()): Sm2State {
  return {
    ease: INITIAL_EASE,
    intervalDays: 0,
    reps: 0,
    dueDate: now.toISOString(), // new cards are due immediately
    lapses: 0,
  };
}

export function scheduleNext(state: Sm2State, quality: number, now: Date = new Date()): Sm2State {
  const q = Math.max(0, Math.min(5, Math.round(quality)));

  if (q < 3) {
    // Lapse: restart repetitions at a 1-day interval.
    // Canonical SM-2 leaves the E-factor unchanged on failure.
    return {
      ...state,
      reps: 0,
      intervalDays: 1,
      lapses: state.lapses + 1,
      dueDate: new Date(now.getTime() + DAY_MS).toISOString(),
    };
  }

  const reps = state.reps + 1;
  const ease = Math.max(
    MIN_EASE,
    state.ease + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02))
  );
  const intervalDays =
    reps === 1 ? 1 :
    reps === 2 ? 6 :
    Math.round(state.intervalDays * ease);

  return {
    ease,
    reps,
    intervalDays,
    lapses: state.lapses,
    dueDate: new Date(now.getTime() + intervalDays * DAY_MS).toISOString(),
  };
}
