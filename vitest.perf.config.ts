import { defineConfig } from 'vitest/config';

// Separate config for perf tests: run explicitly via `npm run test:perf`,
// excluded from the default `npm test` since they're slower and their
// thresholds are deliberately generous (regression detection, not benchmarking).
export default defineConfig({
  test: {
    environment: 'node',
    include: ['**/*.perf.test.js', '**/*.perf.test.ts'],
    testTimeout: 30000,
  },
});
