// Unit test for the pure SM-2 scheduler (src/main/review/scheduler.ts).
// Run with: npm run build:main && node scripts/test-scheduler.js

const assert = require('assert');
const { initialSchedule, scheduleNext, GRADE_QUALITY } = require('../dist/main/review/scheduler.js');

const now = new Date('2026-01-01T00:00:00.000Z');
const day = 24 * 60 * 60 * 1000;

// New cards are due immediately with the standard initial ease
const fresh = initialSchedule(now);
assert.strictEqual(fresh.ease, 2.5);
assert.strictEqual(fresh.reps, 0);
assert.strictEqual(fresh.lapses, 0);
assert.strictEqual(fresh.dueDate, now.toISOString());

// First successful recall (good) → 1 day
const r1 = scheduleNext(fresh, GRADE_QUALITY.good, now);
assert.strictEqual(r1.reps, 1);
assert.strictEqual(r1.intervalDays, 1);
assert.strictEqual(r1.dueDate, new Date(now.getTime() + day).toISOString());
// q=4 leaves ease unchanged: EF + (0.1 - 1*(0.08+1*0.02)) = EF + 0
assert.ok(Math.abs(r1.ease - 2.5) < 1e-9);

// Second successful recall → 6 days
const r2 = scheduleNext(r1, GRADE_QUALITY.good, now);
assert.strictEqual(r2.reps, 2);
assert.strictEqual(r2.intervalDays, 6);

// Third successful recall → round(6 * ease) = 15 days
const r3 = scheduleNext(r2, GRADE_QUALITY.good, now);
assert.strictEqual(r3.reps, 3);
assert.strictEqual(r3.intervalDays, Math.round(6 * r2.ease));

// 'easy' raises ease, 'hard' lowers it (bounded at 1.3)
const easy = scheduleNext(r2, GRADE_QUALITY.easy, now);
assert.ok(easy.ease > r2.ease);
let hard = { ...r2 };
for (let i = 0; i < 20; i++) hard = scheduleNext(hard, GRADE_QUALITY.hard, now);
assert.ok(hard.ease >= 1.3);

// 'again' → lapse: reps reset, interval 1 day, lapse counted, ease unchanged
const lapsed = scheduleNext(r3, GRADE_QUALITY.again, now);
assert.strictEqual(lapsed.reps, 0);
assert.strictEqual(lapsed.intervalDays, 1);
assert.strictEqual(lapsed.lapses, r3.lapses + 1);
assert.strictEqual(lapsed.ease, r3.ease);

// Recovery after a lapse restarts the 1 → 6 → ease ladder
const rec1 = scheduleNext(lapsed, GRADE_QUALITY.good, now);
assert.strictEqual(rec1.intervalDays, 1);
const rec2 = scheduleNext(rec1, GRADE_QUALITY.good, now);
assert.strictEqual(rec2.intervalDays, 6);

// Quality is clamped into [0, 5]
const clamped = scheduleNext(fresh, 99, now);
assert.strictEqual(clamped.reps, 1);

console.log('scheduler: all assertions passed');
