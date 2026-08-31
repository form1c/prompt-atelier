import { test, expect } from '@playwright/test'
import { account } from './instance.js'

// W-1 — find a prompt and use it (TF-350, NFA-01).
//
// The workflow the application exists for, and the only one with a time limit
// attached: under ten seconds from loading to the clipboard. That figure is
// measured by hand in NT-3; what is checked here is that the path is there at
// all — and that it is there **without a mouse**, which is the half nobody
// notices is broken until they try.
//
// The last step needs a real browser for a second reason: the clipboard. No
// test tool imitates a browser's refusal faithfully, and the fallback for it
// (TF-416) is the difference between "copying failed" and "nothing happened".

const { email, password } = account()

async function signIn (page) {
  await page.goto('/')
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(email)
  await page.getByLabel('Passwort', { exact: true }).fill(password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText('Martin')

  await page.getByRole('button', { name: 'Workspace' }).click()
  await page.getByRole('button', { name: 'Marketing', exact: true }).click()
}

const preview = (page) => page.locator('[data-test="preview"]')

// **Reading the clipboard back is Chromium's alone.** Firefox and WebKit
// refuse the permission name outright, so playwright.config.js grants it per
// project and this helper decides per case. What the other two engines lose is
// only the reading — every one of them still clicks the button and still has
// to show the confirmation, which is the part the application is responsible
// for. Stated rather than skipped: a case that quietly does nothing on two of
// three engines is a case that reports success for them (testbed rule 9).
const clipboardOf = async (page, browserName) =>
  browserName === 'chromium' ? await page.evaluate(() => navigator.clipboard.readText()) : null

const readsTheClipboard = (browserName) => browserName === 'chromium'

test.beforeEach(async ({ context }) => {
  await context.clearCookies()
})

test('W-1 with the mouse: search, fill in, copy', async ({ page, browserName }) => {
  await signIn(page)

  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()

  // 11.4: both columns, and the preview is the one that matters.
  await expect(page.getByRole('heading', { name: 'Blogartikel-Generator' })).toBeVisible()
  await expect(preview(page)).toBeVisible()

  // Required and empty: the preview is there, the copy is not (8.3, TF-401).
  await expect(page.getByRole('button', { name: /Kopieren/ })).toBeDisabled()

  await page.getByLabel(/thema/i).fill('Kaffeezubereitung')
  await page.getByLabel(/zielgruppe/i).selectOption('Fortgeschrittene')

  await expect(preview(page)).toContainText('Kaffeezubereitung')
  await expect(preview(page)).toContainText('Fortgeschrittene')
  await expect(page.getByRole('button', { name: /Kopieren/ })).toBeEnabled()

  await page.getByRole('button', { name: /Kopieren/ }).click()

  await expect(page.getByText('In die Zwischenablage kopiert.')).toBeVisible()
  if (!readsTheClipboard(browserName)) return
  const clipboard = await clipboardOf(page, browserName)
  expect(clipboard).toContain('Kaffeezubereitung')
  // Character for character what the screen shows — the whole point of having
  // the pipeline twice (NFA-14, R-01).
  //
  // Stated first that nothing is left empty: a drawn placeholder is on the
  // screen and not in the text (8.3), so without this line the comparison
  // below would be claiming more than it checks.
  await expect(preview(page).locator('.slot--empty, .slot--missing')).toHaveCount(0)
  expect(clipboard).toBe((await preview(page).textContent()).trim())
})

// FA-305, second way. The unit tests take this apart; what a real browser adds
// is the one thing they cannot have — the actual clipboard.
test('copies with placeholders on request, even without a required value', async ({ page, browserName }) => {
  await signIn(page)

  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()

  // The mandatory value is missing, so the one button is barred and the other
  // is not. That is the whole difference between them.
  await expect(page.getByRole('button', { name: /^Kopieren/ })).toBeDisabled()
  await expect(preview(page).locator('.slot--missing')).toHaveText('{{thema}}')

  await page.getByRole('button', { name: 'Mit Platzhaltern kopieren' }).click()

  await expect(page.getByText('Mit Platzhaltern in die Zwischenablage kopiert.')).toBeVisible()
  if (!readsTheClipboard(browserName)) return
  const clipboard = await clipboardOf(page, browserName)

  // **Every** placeholder, whatever is filled in — including `zielgruppe`,
  // which carries a default value and would be substituted in the preview.
  // That is the change from NT-7: the button used to copy the preview, so
  // somebody who had filled the fields in got a text with no placeholders
  // under a button that promises them.
  expect(clipboard).toContain('{{thema}}')
  expect(clipboard).toContain('{{zielgruppe}}')
  expect(clipboard).not.toContain('Einsteiger')
  // The keyword that is switched on belongs to it — this is the assembled
  // prompt with its open slot, not the raw row from the database.
  expect(clipboard).toContain('Schreibe in einem sachlichen Ton.')
})

// FA-307, and the reason it has a button of its own: three texts live on this
// screen, and each button has to copy the one it stands next to. Checked in a
// real browser because it ends in the real clipboard.
test('copies the edited version with the button below the field', async ({ page, browserName }) => {
  await signIn(page)

  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()

  // By role, not by label alone: the section around the field carries the same
  // name as the field itself — a heading for the region and an aria-label for
  // the control. That is fine for a screen reader, which hears the role after
  // the name, but a query on the name alone matches both.
  const workbench = page.getByRole('textbox', { name: 'Fassung für diese Verwendung' })
  await expect(workbench).toHaveValue(/\{\{thema\}\}/)
  await workbench.fill('Nur für diesen einen Einsatz: {{thema}}')

  await page.getByRole('button', { name: 'Diese Fassung kopieren' }).click()
  await expect(page.getByText('Fassung für diese Verwendung in die Zwischenablage kopiert.')).toBeVisible()

  if (!readsTheClipboard(browserName)) return
  expect(await clipboardOf(page, browserName))
    .toBe('Nur für diesen einen Einsatz: {{thema}}')

  // And the button up in the preview is untouched by that edit — the case the
  // rearrangement exists for. It used to copy this field, so somebody could be
  // pasting a change made two days ago while looking at the preview.
  await page.getByRole('button', { name: 'Mit Platzhaltern kopieren' }).click()
  expect(await clipboardOf(page, browserName))
    .not.toContain('Nur für diesen einen Einsatz')
})

// A-14 and the second half of TF-350: the same path with the keyboard alone.
// The focus starts in the search field, Enter leads into the list, Enter opens
// the hit, Tab reaches the fields, Ctrl+Enter copies.
test('W-1 without a mouse: the same path on the keyboard alone', async ({ page, browserName }) => {
  await signIn(page)

  await page.getByRole('searchbox').focus()
  await page.keyboard.type('Blogartikel')
  await page.keyboard.press('Enter')
  await expect(page.getByRole('button', { name: /Blogartikel-Generator öffnen/ })).toBeFocused()

  await page.keyboard.press('Enter')
  await expect(page.getByRole('heading', { name: 'Blogartikel-Generator' })).toBeVisible()

  await page.getByLabel(/thema/i).focus()
  await page.keyboard.type('Kaffeezubereitung')

  // Pressed straight after typing — the pause for the preview is still
  // running at this moment, and that is how people use a keyboard.
  await page.keyboard.press('Control+Enter')

  await expect(page.getByText('In die Zwischenablage kopiert.')).toBeVisible()
  if (!readsTheClipboard(browserName)) return

  expect(await clipboardOf(page, browserName)).toContain('Kaffeezubereitung')
})

// FA-306: what was typed comes back. Kept in the browser, so it survives a
// reload and belongs to this device only.
test('remembers the entries of a prompt across a reload', async ({ page }) => {
  await signIn(page)
  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()
  await page.getByLabel(/thema/i).fill('Kaffeezubereitung')
  await expect(preview(page)).toContainText('Kaffeezubereitung')

  await page.reload()

  await expect(page.getByLabel(/thema/i)).toHaveValue('Kaffeezubereitung')
  await expect(preview(page)).toContainText('Kaffeezubereitung')
})

// FA-304: switching a keyword changes the result. The prompt of the instance
// carries "formal" as a default, so it is on when the screen opens.
test('switches a keyword off and the preview follows', async ({ page }) => {
  await signIn(page)
  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()
  await page.getByLabel(/thema/i).fill('Kaffee')

  const chip = page.getByRole('button', { name: 'formal', exact: true })
  await expect(chip).toHaveAttribute('aria-pressed', 'true')
  await expect(preview(page)).toContainText('Schreibe in einem sachlichen Ton.')

  await chip.click()

  await expect(preview(page)).not.toContainText('Schreibe in einem sachlichen Ton.')
  await expect(chip).toHaveAttribute('aria-pressed', 'false')
})

// R-01 in its most direct form: what the browser shows and what the server
// renders must be the same text. Anything else means the copy and a later
// model call would differ.
test('preview in the browser and rendering on the server agree character for character', async ({ page }) => {
  await signIn(page)
  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()
  await page.getByLabel(/thema/i).fill('Kaffeezubereitung')
  await page.getByLabel(/zielgruppe/i).selectOption('Einsteiger')
  await expect(preview(page)).toContainText('Kaffeezubereitung')

  const shown = (await preview(page).textContent()).trim()

  const rendered = await page.evaluate(async () => {
    const csrf = document.cookie.split('; ').find((entry) => entry.startsWith('promptatelier_csrf='))
    const id = Number(window.location.pathname.split('/').pop())
    const response = await fetch(`/api/v1/prompts/${id}/render`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf.split('=')[1] },
      credentials: 'same-origin',
      body: JSON.stringify({
        values: { thema: 'Kaffeezubereitung', zielgruppe: 'Einsteiger' },
        // The keywords the screen has switched on — the default of this
        // prompt. Comparing without them would compare two different things.
        keyword_ids: [...document.querySelectorAll('.chips__chip[aria-pressed="true"]')]
          .map((chip) => Number(chip.dataset.id))
      })
    })
    return (await response.json()).text
  })

  expect(rendered).toBe(shown)
})

// The same check on the shape it did not have until now: a multiline variable
// alone between two blank lines, filled with multiline text.
//
// That is precisely where the two versions of step 4 lie furthest apart —
// Ruby's `$` already means the end of a line, JavaScript needs the m flag for
// that. On a single-line prompt the difference cannot be seen, and single-line
// is what every prompt in this check has been so far.
test('they agree for a multiline value between blank lines too', async ({ page }) => {
  await signIn(page)
  await page.getByRole('searchbox').fill('Protokoll')
  await page.getByRole('button', { name: /Protokoll deuten öffnen/ }).click()

  // With trailing spaces and a blank line in the middle: step 4 touches both
  // of them.
  const value = 'Zeile eins   \n\n\nZeile zwei  '
  await page.getByLabel(/auszug/i).fill(value)
  await expect(preview(page)).toContainText('Zeile zwei')

  const shown = (await preview(page).textContent()).trim()
  // Nothing is empty any more, so the preview draws no placeholder in and the
  // text shown is the finished one (8.3.1).
  await expect(preview(page).locator('.slot--empty, .slot--missing')).toHaveCount(0)

  const rendered = await page.evaluate(async (auszug) => {
    const csrf = document.cookie.split('; ').find((entry) => entry.startsWith('promptatelier_csrf='))
    const id = Number(window.location.pathname.split('/').pop())
    const response = await fetch(`/api/v1/prompts/${id}/render`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf.split('=')[1] },
      credentials: 'same-origin',
      body: JSON.stringify({ values: { auszug }, keyword_ids: [] })
    })
    return (await response.json()).text
  }, value)

  expect(rendered).toBe(shown)
  // And the counter-check that normalising really happened here: without step
  // 4 the trailing spaces and the doubled blank line would still be there.
  expect(rendered).toBe('Deute diesen Auszug:\n\nZeile eins\n\nZeile zwei\n\nWas ist passiert?')
})
