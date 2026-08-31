import { test, expect } from '@playwright/test'
import { account } from './instance.js'

// Multiple selection and bulk actions in the library (TF-359, TF-360, TF-361).
//
// **What only a browser can show here** is the rule of FA-510: the selection is
// dropped when the list changes underneath it. The service knows nothing about
// it — the selection lives entirely on the screen — so there is no other level
// at which the rule could be checked at all.
//
// The instance is shared with every other browser file (test concept 3.2), so
// these cases create what they need and take nothing away that another file
// builds on. What is moved here is moved into the personal workspace of the
// account and moved nowhere else.

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

const bar = (page) => page.getByRole('region', { name: 'Auswahl' })

// FA-510: the checkboxes are not there until they are asked for. W-1 is the
// most frequent thing anybody does here, and a checkbox in front of every row
// taxes that path for the sake of occasional housekeeping.
const startSelecting = (page) => page.locator('[data-test="selection-mode"]').click()
const rowBoxes = (page) => page.locator('.hit__select input')

test.beforeEach(async ({ context }) => {
  await context.clearCookies()
})

// TF-359c: no bar without a selection. A bar reading "0 ausgewählt" with
// greyed-out buttons explains nothing and takes the room the list needs.
test('TF-359: the selection bar appears only with a selection', async ({ page }) => {
  await signIn(page)

  // Without the switch not one of the boxes is there — the point of this change.
  await expect(rowBoxes(page)).toHaveCount(0)
  await expect(page.locator('[data-test="select-visible"]')).toHaveCount(0)

  await startSelecting(page)
  await expect(bar(page)).toHaveCount(0)

  await rowBoxes(page).first().check()

  await expect(bar(page)).toBeVisible()
  await expect(bar(page)).toContainText('1 Prompt ausgewählt')
})

// The rule of FA-510, and the one that cannot be checked anywhere else: a
// selection that survives a filter change holds prompts nobody can see any
// more, and the report afterwards would name titles that are not on screen.
// TF-359g: leaving the mode drops the selection. A selection nobody can see is
// a selection nobody can check — and the next bulk action would work on a set
// that is not on the screen.
test('TF-359g: switching the mode off drops the selection', async ({ page }) => {
  await signIn(page)
  await startSelecting(page)
  await rowBoxes(page).first().check()
  await expect(bar(page)).toBeVisible()

  await startSelecting(page)

  await expect(rowBoxes(page)).toHaveCount(0)
  await expect(bar(page)).toHaveCount(0)

  // And on again: nothing is selected any more.
  await startSelecting(page)
  await expect(bar(page)).toHaveCount(0)
})

test('TF-359: the selection drops when the list changes', async ({ page }) => {
  await signIn(page)
  await startSelecting(page)
  await rowBoxes(page).first().check()
  await expect(bar(page)).toBeVisible()

  await page.getByRole('searchbox').fill('P-EDIT')

  await expect(bar(page)).toHaveCount(0)
  await expect(page.getByText('Die Auswahl wurde aufgehoben, weil sich die Liste geändert hat.'))
    .toBeVisible()
})

test('TF-359b: the header checkbox selects what is visible and names the count', async ({ page }) => {
  await signIn(page)
  await startSelecting(page)
  const visible = await rowBoxes(page).count()

  await page.locator('[data-test="select-visible"]').check()

  await expect(bar(page)).toContainText(`${visible} Prompts ausgewählt`)
  await expect(page.getByText(`Alle ${visible} angezeigten auswählen`)).toBeVisible()
})

// TF-361. Martin is an editor: he may bin his own prompt and not somebody
// else's, so the selection below contains one of each — which is the ordinary
// case and the only one worth measuring.
test('TF-361: a bulk trashing does what is allowed and names the rest', async ({ page }) => {
  await signIn(page)

  // Created, not taken from the stock: this file takes nothing away that
  // another builds on.
  await page.getByRole('link', { name: 'Neu' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Sammellöschprobe')
  await page.getByLabel('Prompt-Text', { exact: true }).fill('Ein Rumpf ohne Variablen.')
  await page.getByRole('button', { name: /Speichern/ }).click()
  await expect(page.getByRole('heading', { name: 'Sammellöschprobe' })).toBeVisible()

  await page.getByRole('link', { name: 'Zurück zur Bibliothek' }).click()
  await page.getByRole('searchbox').fill('Sammellöschprobe')
  await startSelecting(page)
  await expect(rowBoxes(page)).toHaveCount(1)

  await rowBoxes(page).first().check()
  await expect(bar(page)).toContainText('1 Prompt ausgewählt')

  await page.locator('[data-test="bulk-trash"]').click()
  await page.locator('[data-test="confirm"]').click()

  await expect(page.getByText('1 Prompts in den Papierkorb gelegt.')).toBeVisible()
  await expect(page.getByRole('button', { name: /Sammellöschprobe öffnen/ })).toHaveCount(0)
})

// TF-360b: the warning about FA-207 is given once, before, and says how many
// prompts it concerns — not fifty times afterwards, when it is too late to be
// a warning.
test('TF-360b: the warning about visibility comes before the move', async ({ page }) => {
  await signIn(page)
  await startSelecting(page)
  await rowBoxes(page).first().check()

  await page.locator('[data-test="bulk-move"]').click()

  await expect(page.getByText('1 Prompts verschieben')).toBeVisible()
  await expect(page.getByText(/wieder auf privat gesetzt/)).toBeVisible()
  // And the button stays out of reach as long as no target is chosen.
  await expect(page.locator('[data-test="confirm"]')).toBeDisabled()
})

// --- the trash (TF-362, TF-363) --------------------------------------------

// TF-363b: the only irreversible action of the application has no path without
// a question. Checked by opening the dialogue and leaving it — the prompt has
// to still be there afterwards.
test('TF-363b: bulk purging asks and does nothing without an answer', async ({ page }) => {
  await signIn(page)
  await page.getByRole('link', { name: 'Papierkorb' }).click()
  await expect(page.getByRole('heading', { name: /Papierkorb/ })).toBeVisible()

  const boxes = page.locator('.entry__select input')
  await expect(boxes.first()).toBeVisible()
  const before = await boxes.count()
  await boxes.first().check()

  await page.locator('[data-test="bulk-purge"]').click()
  await expect(page.getByText(/nicht rückgängig machen/)).toBeVisible()

  // Clicked away instead of confirmed: nothing may have happened.
  await page.getByRole('button', { name: 'Abbrechen' }).click()
  await expect(boxes).toHaveCount(before)
})

// TF-362. Martin is an editor, so he sees in the trash what he deleted or owns
// (FA-703) — the bulk restore must not widen that by one entry, and what it
// does restore has to be gone from the trash afterwards.
test('TF-362: a bulk restore brings the selection back', async ({ page }) => {
  await signIn(page)

  // Created and deleted by this case itself, so it takes nothing away that
  // another file builds on.
  await page.getByRole('link', { name: 'Neu' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Wiederherstellprobe')
  await page.getByLabel('Prompt-Text', { exact: true }).fill('Ein Rumpf.')
  await page.getByRole('button', { name: /Speichern/ }).click()
  await expect(page.getByRole('heading', { name: 'Wiederherstellprobe' })).toBeVisible()

  await page.getByRole('link', { name: 'Zurück zur Bibliothek' }).click()
  await page.getByRole('searchbox').fill('Wiederherstellprobe')
  await startSelecting(page)
  await expect(rowBoxes(page)).toHaveCount(1)
  await rowBoxes(page).first().check()
  await page.locator('[data-test="bulk-trash"]').click()
  await page.locator('[data-test="confirm"]').click()
  await expect(page.getByText('1 Prompts in den Papierkorb gelegt.')).toBeVisible()

  await page.getByRole('link', { name: 'Papierkorb' }).click()
  const line = page.locator('.entry', { hasText: 'Wiederherstellprobe' })
  await expect(line).toBeVisible()
  await line.locator('.entry__select input').check()

  await page.locator('[data-test="bulk-restore"]').click()

  await expect(page.getByText('1 Prompts wiederhergestellt.')).toBeVisible()
  await expect(page.locator('.entry', { hasText: 'Wiederherstellprobe' })).toHaveCount(0)
})
