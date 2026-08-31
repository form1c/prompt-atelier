import path from 'node:path'
import { defineConfig, devices } from '@playwright/test'
import { PORT, BASE_URL, RESULTS } from './tests/e2e/instance.js'

// The browser tests (test concept 3.3, third stage).
//
// They run against an instance of their own: own port, own directory, own
// database, built from scratch by tests/e2e/server.rb. Nothing points at the
// installation being developed against — that one holds real work, and a test
// run must not be able to reach it, not even by mistake.
//
// The configuration lives in code/ rather than in frontend/ because that is
// where node_modules and the npm workspace are (18.2). The tests are not
// about the frontend package; they are about the whole assembled system.

const CLIPBOARD = ['clipboard-read', 'clipboard-write']

export default defineConfig({
  testDir: './tests/e2e',
  testMatch: '**/*.spec.js',
  // The browser measurements belong to playwright.measure.config.js, which
  // starts an instance holding 5.000 prompts. Left in this run they would take
  // their figures against the six-prompt fixture — and pass, with numbers that
  // are about nothing. A measurement in the wrong suite does not fail; it
  // agrees.
  testIgnore: 'measurement.spec.js',

  // Traces outside code/, like every other test run.
  outputDir: path.join(RESULTS, 'playwright'),
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : [['list']],

  // One at a time. The instance is a single SQLite database with a single
  // seeded state; parallel workers would be signing in and out of the same
  // accounts and the failures would be blamed on the interface.
  workers: 1,
  fullyParallel: false,

  use: {
    baseURL: BASE_URL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure'
  },

  // TF-712 / NFA-10 — three engines, and the substitution is deliberate:
  // Edge is represented by Chromium (shared basis), Safari by WebKit. Without
  // it NFA-10 would be formally unproven, because neither Edge nor Safari can
  // be driven on a Linux build machine at all.
  //
  // TF-709 / NFA-09 — and one of them again at 360 px, the narrowest supported
  // width. Only the core workflow: W-1 is what the requirement names, and
  // running seven suites twice would triple the time for cases whose subject
  // is not the layout.
  // **The clipboard permission is Chromium's alone.** Firefox and WebKit
  // refuse the name outright (`Unknown permission: clipboard-read`), so it is
  // granted per project rather than per spec — the configuration is the place
  // that knows which engine is running. What the other two lose is only the
  // *reading back* of the clipboard, not the copying: every browser still
  // clicks the button and still has to show the confirmation.
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'], permissions: CLIPBOARD } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
    {
      name: '360px',
      testMatch: 'workflow.spec.js',
      use: {
        ...devices['Desktop Chrome'],
        permissions: CLIPBOARD,
        viewport: { width: 360, height: 720 }
      }
    }
  ],

  webServer: {
    command: 'ruby tests/e2e/server.rb',
    url: `${BASE_URL}/health`,
    // Never reuse: a server left over from an earlier run would be serving an
    // older build of the interface, and the test would be describing code
    // that is no longer there.
    reuseExistingServer: false,
    // It builds the interface before it starts listening.
    timeout: 180_000,
    stdout: 'pipe',
    stderr: 'pipe',
    env: {
      PROMPTATELIER_E2E_PORT: String(PORT),
      PROMPTATELIER_TEST_RESULTS: RESULTS
    }
  }
})
