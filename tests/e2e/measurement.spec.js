import { test, expect } from '@playwright/test'
import { bench } from './instance.js'

// The browser half of chapter 12 (TF-702, TF-703).
//
// **Why these two cannot be measured on the server.** `measure` times the way
// from a request arriving to its answer being complete. What NFA-03 and NFA-04
// are about happens after that: laying out a library of fifty lines, and the
// debounce of FA-304 that deliberately waits before the preview follows an
// input. Neither exists in a server timing, and adding an estimate for them
// would be inventing the number this file exists to take.
//
// It runs against a stock of 5.000 prompts — the same corpus `measure` uses,
// built by scripts/lib/bench.rb — because A-04 states its targets at that
// size. The regression suites keep their six-prompt fixture; this one is
// started separately, by `run_tests --measure`.
//
// Both figures are 95th percentiles over repeated runs, as section 11 asks.
// A single run of a browser measurement says almost nothing: the first paint
// after a fresh profile, one garbage collection or one unlucky frame moves it
// by more than the difference anybody would act on.

const facts = bench()

const RUNS_LIBRARY = 10
const RUNS_PREVIEW = 20

// NFA-03 and NFA-04. Written out rather than imported from the application,
// because a limit that travels with the code being measured is a limit that
// can be lowered to fit.
const LIBRARY_LIMIT = 1500
const PREVIEW_LIMIT = 150

function percentile (values, wanted) {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.max(Math.ceil((wanted / 100) * sorted.length) - 1, 0)]
}

// Into the run's own output, so a measurement that passed still leaves its
// numbers behind. A green tick alone cannot be compared with next month's.
function report (name, samples, limit) {
  const p95 = percentile(samples, 95)
  console.log(`${name}: p95 ${p95.toFixed(1)} ms, median ${percentile(samples, 50).toFixed(1)} ms, ` +
              `min ${Math.min(...samples).toFixed(1)} ms, max ${Math.max(...samples).toFixed(1)} ms, ` +
              `limit ${limit} ms, ${samples.length} runs`)
  return p95
}

async function signIn (page) {
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(facts.email)
  await page.getByLabel('Passwort', { exact: true }).fill(facts.password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
}

// The workspace holding the stock. Chosen **once**, before any clock starts:
// the choice is kept on the server (FA-205), so every later sign-in lands in
// the same library. Doing it inside the timed loop would put a menu click into
// a number that is about a page load.
async function chooseTheStock (page) {
  await page.goto('/')
  await signIn(page)
  await page.getByRole('button', { name: 'Workspace' }).click()
  await page.getByRole('button', { name: 'Marketing', exact: true }).click()
  await expect(rows(page).first()).toBeVisible()
}

const rows = (page) => page.getByRole('button', { name: / öffnen$/ })

// TF-702 / NFA-03 — from the click on "Anmelden" to a library on screen.
//
// The clock starts at the click and stops when the first line is really
// visible, which is the first moment the person can act. It therefore contains
// the password check, and the instance is configured with the **delivered**
// Argon2 cost for exactly that reason: measured at a reduced one it would be a
// number about a configuration nobody is given.
test('TF-702: the library stands within 1.5 s of signing in', async ({ page, context }) => {
  test.setTimeout(180_000)
  await chooseTheStock(page)
  const samples = []

  for (let run = 0; run < RUNS_LIBRARY; run++) {
    await context.clearCookies()
    await page.goto('/')
    await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(facts.email)
    await page.getByLabel('Passwort', { exact: true }).fill(facts.password)

    const started = Date.now()
    await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
    await expect(rows(page).first()).toBeVisible()
    samples.push(Date.now() - started)

    // The library really is the big one, not an empty workspace that happens
    // to render quickly. Checked inside the loop rather than once: a run that
    // silently landed somewhere else would otherwise contribute the fastest
    // sample in the set.
    await expect(rows(page)).toHaveCount(50)
  }

  expect(report('TF-702 library after sign-in', samples, LIBRARY_LIMIT))
    .toBeLessThanOrEqual(LIBRARY_LIMIT)
})

// TF-703 / NFA-04 — from the last keystroke to the preview showing it.
//
// Timed **inside the page**, between the input event and the mutation that
// carries the new text into the preview. Timing it from the test process
// instead would add Playwright's own round trip to every sample — the same
// mistake the load measurement made on the server side, where the measuring
// process's own scheduling turned 13 ms into 209.
//
// It contains the debounce of FA-304 on purpose. That wait is what the person
// experiences, and leaving it out would measure a step nobody is waiting for.
test('TF-703: the preview follows the last keystroke within 150 ms', async ({ page }) => {
  test.setTimeout(180_000)
  await chooseTheStock(page)
  await rows(page).first().click()

  // Loosely, as the workflow spec addresses it: the visible label carries a
  // required marker beside the name, and an exact match would miss it.
  const field = page.getByLabel(/thema/i)
  await expect(field).toBeVisible()
  const samples = []

  for (let run = 0; run < RUNS_PREVIEW; run++) {
    const value = `Messwert-${run}-${Math.random().toString(36).slice(2, 8)}`
    samples.push(await field.evaluate(timeUntilPreviewFollows, value))
    await expect(page.locator('[data-test="preview"]')).toContainText(value)
  }

  expect(report('TF-703 preview after input', samples, PREVIEW_LIMIT))
    .toBeLessThanOrEqual(PREVIEW_LIMIT)
})

// Runs in the page. Sets the field the way a keystroke does and resolves with
// the time until the preview carries the value.
function timeUntilPreviewFollows (input, wanted) {
  const preview = document.querySelector('[data-test="preview"]')
  if (!preview) throw new Error('no preview on the page, so there is nothing to measure')

  return new Promise((resolve, reject) => {
    const gaveUp = setTimeout(() => reject(new Error('the preview never showed the value')), 5000)
    let started = 0

    const observer = new MutationObserver(() => {
      if (!preview.textContent.includes(wanted)) return
      clearTimeout(gaveUp)
      observer.disconnect()
      resolve(performance.now() - started)
    })
    observer.observe(preview, { childList: true, subtree: true, characterData: true })

    // Through the native setter, then the event: assigning `.value` alone
    // tells Vue nothing, and the measurement would wait for a change that was
    // never announced.
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
    setter.call(input, wanted)
    started = performance.now()
    input.dispatchEvent(new Event('input', { bubbles: true }))
  })
}
