import path from 'node:path'
import { defineConfig, devices } from '@playwright/test'
import { PORT, BASE_URL, RESULTS } from './tests/e2e/instance.js'

// The browser measurements (TF-702, TF-703) — a configuration of their own.
//
// **Why not a project inside playwright.config.js.** They need an instance
// with 5.000 prompts, and building one costs about a minute. Every browser
// test run would pay it, for two cases that are not regression tests but
// measurements: they belong to a release, not to a commit. `run_tests --e2e`
// therefore keeps its six-prompt fixture and `run_tests --measure` starts
// this one.
//
// It is the same server file and the same corpus the server-side measurements
// use (scripts/lib/bench.rb), so both halves of chapter 12 describe one
// library rather than two that merely sound alike.

const MEASURE_PORT = Number(process.env.PROMPTATELIER_E2E_PORT ?? PORT + 1)
const MEASURE_URL = `http://127.0.0.1:${MEASURE_PORT}`

export default defineConfig({
  testDir: './tests/e2e',
  testMatch: 'measurement.spec.js',

  outputDir: path.join(RESULTS, 'playwright-measure'),
  reporter: [['list']],

  // One at a time, and never retried. A measurement that is repeated until it
  // passes is not a measurement — the second attempt would be the one reported
  // and the first would leave no trace.
  workers: 1,
  fullyParallel: false,
  retries: 0,

  use: {
    baseURL: MEASURE_URL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure'
  },

  // Chromium only, deliberately. TF-712 asks that the application **works** in
  // three engines, and the browser suite checks that; the numbers of chapter
  // 12 are stated once and taken on one engine. Three sets of figures would
  // invite the question which of them the requirement means, and nothing in
  // chapter 12 answers it.
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],

  webServer: {
    command: 'ruby tests/e2e/server.rb',
    url: `${MEASURE_URL}/health`,
    reuseExistingServer: false,
    // It builds the interface **and** seeds 5.000 prompts before it listens.
    timeout: 600_000,
    stdout: 'pipe',
    stderr: 'pipe',
    env: {
      PROMPTATELIER_E2E_PORT: String(MEASURE_PORT),
      PROMPTATELIER_E2E_PROMPTS: process.env.PROMPTATELIER_E2E_PROMPTS ?? '5000',
      PROMPTATELIER_TEST_RESULTS: RESULTS
    }
  }
})
