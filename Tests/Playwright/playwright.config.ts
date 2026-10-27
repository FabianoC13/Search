import { defineConfig } from '@playwright/test';

// Two ways in, one set of specs (see fixtures.ts):
//   SEARCH_MODE=attach  the Search Beta you have open, Chromium mode, with
//                       "Let Playwright and other tools drive Chromium" on
//                       (chromium.connectOverCDP on 127.0.0.1:9222)
//   SEARCH_MODE=launch  a Search Beta Playwright starts itself, as it starts
//                       Chrome (chromium.launch with its executable)
// One worker: in attach mode every spec shares your Search, and its windows.
export default defineConfig({
  testDir: './specs',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 30_000,
  reporter: [['list'], ['json', { outputFile: 'results.json' }]],
});
