import { test, expect } from '@playwright/test'
import { account } from './instance.js'

// W-8 in a real browser (TF-357).
//
// The rules are checked on the server and the drawing in Vitest. What only
// this level shows is the stretch a person actually walks: pick a file, see
// what it would do, decide, and find the result in the library afterwards.
//
// And one thing no other level can show at all — the file really goes through
// a file input. Everything else stubs that away.
//
// **The instance belongs to every file.** These cases work in a workspace they
// create themselves and take it away again, because an import that landed in
// *Marketing* would change what every other file finds there.

const { email, password } = account()

async function signIn (page) {
  await page.goto('/')
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(email)
  await page.getByLabel('Passwort', { exact: true }).fill(password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText('Martin')
}

async function switchTo (page, name) {
  await page.getByRole('banner').getByRole('button', { name: 'Workspace' }).click()
  await page.getByRole('button', { name, exact: typeof name === 'string' }).click()
}

const goTo = (page, entry) => page.getByRole('link', { name: entry, exact: true }).click()

// By its test hook, not by its label. "Datei" is a substring of the Markdown
// hint ("Eine lesbare Datei je Prompt") and of the region's own name, so
// getByLabel matches three elements — a strict-mode violation that says
// nothing about the screen being wrong.
const fileField = (page) => page.locator('[data-test="file"]')

// Importing needs `admin` or `owner`, and Martin is an editor in Marketing —
// so the case makes a workspace of its own, where he is the owner.
async function ownWorkspace (page, name) {
  await switchTo(page, /^Persönlicher Workspace/)
  await goTo(page, 'Workspace')
  await page.locator('[aria-labelledby="workspace-new-heading"]').getByLabel('Name').fill(name)
  await page.getByRole('button', { name: 'Anlegen', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText(name)
}

async function removeWorkspace (page, name) {
  await goTo(page, 'Workspace')
  await page.getByRole('button', { name: 'Diesen Workspace löschen' }).click()
  await page.getByRole('dialog').getByLabel('Name des Workspace').fill(name)
  await page.getByRole('button', { name: 'Endgültig löschen' }).click()
  await expect(page.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()
}

const fileWith = (prompts) => ({
  name: 'export.json',
  mimeType: 'application/json',
  buffer: Buffer.from(JSON.stringify({
    format: 'promptatelier-export', version: 1,
    workspace: { name: 'Irgendwo' }, keywords: [], prompts
  }))
})

test.beforeEach(async ({ context }) => {
  await context.clearCookies()
})

// TF-357 — the sentence W-8 is built on: no writing without a preview.
test('W-8: import a file, with a preview before anything is written', async ({ page }) => {
  await signIn(page)
  await ownWorkspace(page, 'Einspielraum')

  await goTo(page, 'Import/Export')
  await expect(page.getByRole('heading', { name: 'Import und Export' })).toBeVisible()

  // Nothing to press before a file has been read. Not disabled — absent.
  await expect(page.getByRole('button', { name: 'Einspielen', exact: true })).toHaveCount(0)

  await fileField(page).setInputFiles(fileWith([
    { title: 'Aus der Datei', body: 'Ein Text mit {{thema}}.' }
  ]))

  await expect(page.getByText('1 neu')).toBeVisible()
  await page.getByRole('button', { name: 'Einspielen', exact: true }).click()
  await expect(page.getByText('1 angelegt')).toBeVisible()

  // The part only a real run shows: the prompt is findable afterwards, which
  // means the search index knows it too.
  await goTo(page, 'Bibliothek')
  await page.getByRole('searchbox').fill('Aus der Datei')
  await page.getByRole('button', { name: /Aus der Datei öffnen/ }).click()
  await expect(page.getByLabel(/thema/i)).toBeVisible()

  await removeWorkspace(page, 'Einspielraum')
})

// FA-802 and the reason W-8 exists at all: an import that silently overwrites
// is a data-loss event. The preview names the collision and the decision is
// made by hand.
test('names a collision and overwrites only after the decision', async ({ page }) => {
  await signIn(page)
  await ownWorkspace(page, 'Kollisionsraum')

  await page.getByRole('link', { name: 'Neu' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Doppelt')
  await page.getByLabel('Prompt-Text', { exact: true }).fill('Der ursprüngliche Text.')
  await page.getByRole('button', { name: /Speichern/ }).click()
  await expect(page.getByRole('heading', { name: 'Doppelt' })).toBeVisible()

  await goTo(page, 'Import/Export')
  await fileField(page).setInputFiles(fileWith([
    { title: 'doppelt', body: 'Der eingespielte Text.' }
  ]))

  await expect(page.getByText('Titel gibt es hier schon')).toBeVisible()

  // Skipping is where it starts, and skipping leaves the original alone.
  await page.getByRole('button', { name: 'Einspielen', exact: true }).click()
  await expect(page.getByText('0 angelegt')).toBeVisible()
  await goTo(page, 'Bibliothek')
  await page.getByRole('button', { name: /Doppelt öffnen/ }).click()
  await expect(page.locator('[data-test="preview"]')).toContainText('Der ursprüngliche Text.')

  // Deciding otherwise overwrites — and leaves the previous state as a
  // revision, so "Änderung rückgängig" brings it back (FA-701, TF-341d).
  await goTo(page, 'Import/Export')
  await fileField(page).setInputFiles(fileWith([
    { title: 'doppelt', body: 'Der eingespielte Text.' }
  ]))
  await page.getByLabel(/Entscheidung für/).selectOption('overwrite')
  await page.getByRole('button', { name: 'Einspielen', exact: true }).click()
  await expect(page.getByText('1 überschrieben')).toBeVisible()

  await goTo(page, 'Bibliothek')
  await page.getByRole('button', { name: /Doppelt öffnen/ }).click()
  await expect(page.locator('[data-test="preview"]')).toContainText('Der eingespielte Text.')

  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('button', { name: 'Letzte Änderung rückgängig' }).click()
  await expect(page.locator('[data-test="preview"]')).toContainText('Der ursprüngliche Text.')

  await removeWorkspace(page, 'Kollisionsraum')
})

// TF-342: a file that is not usable is refused with a reason, and nothing is
// written. The screen has to say what is wrong with the file, not that
// "something went wrong".
test('refuses a damaged file with a reason and writes nothing', async ({ page }) => {
  await signIn(page)
  await ownWorkspace(page, 'Abweisraum')

  await goTo(page, 'Import/Export')
  await fileField(page).setInputFiles({
    name: 'kaputt.json',
    mimeType: 'application/json',
    buffer: Buffer.from('{ "format": "promptatelier-export", ')
  })

  await expect(page.getByRole('alert')).toContainText('kein gültiges JSON')
  await expect(page.getByRole('button', { name: 'Einspielen', exact: true })).toHaveCount(0)

  await goTo(page, 'Bibliothek')
  await expect(page.getByRole('heading', { name: 'Noch keine Prompts' })).toBeVisible()

  await removeWorkspace(page, 'Abweisraum')
})

// FA-801: the export really arrives as a file. Only a browser can show that —
// everything below this level ends at "the payload was correct".
test('downloads an export as a file', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Marketing')
  await goTo(page, 'Import/Export')

  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.getByRole('button', { name: 'Exportieren' }).click()
  ])

  expect(download.suggestedFilename()).toMatch(/^marketing-\d{4}-\d{2}-\d{2}\.json$/)

  const stream = await download.createReadStream()
  const chunks = []
  for await (const chunk of stream) chunks.push(chunk)
  const payload = JSON.parse(Buffer.concat(chunks).toString('utf8'))

  expect(payload.format).toBe('promptatelier-export')
  expect(payload.prompts.length).toBeGreaterThan(0)
  // Martin is an editor in Marketing, so the file holds his own (FA-801).
  expect(payload.prompts.map((entry) => entry.title)).not.toContain('P-WS')
})

// --- the bulk decision (TF-346 to TF-346d, FA-802) -------------------------

// The point the client opened this round with: with many collisions, each one
// had to be switched over on its own.
//
// **The toil was never the protection.** W-8 is aimed at *silent* overwriting,
// not at the number of clicks — and whoever clicks through 180 select boxes
// clicks mechanically. The summary line names the consequence instead.
test('TF-346: one bulk decision sets every collision', async ({ page }) => {
  await signIn(page)
  await ownWorkspace(page, 'Sammelraum')

  // Create three prompts that the file will then collide with, all of them.
  for (const title of ['Erster', 'Zweiter', 'Dritter']) {
    await page.getByRole('link', { name: 'Neu' }).click()
    await page.getByLabel('Titel', { exact: true }).fill(title)
    await page.getByLabel('Prompt-Text', { exact: true }).fill('Der ursprüngliche Text.')
    await page.getByRole('button', { name: /Speichern/ }).click()
    await expect(page.getByRole('heading', { name: title })).toBeVisible()
  }

  await goTo(page, 'Import/Export')
  await fileField(page).setInputFiles(fileWith([
    { title: 'Erster', body: 'Neu aus der Datei.' },
    { title: 'Zweiter', body: 'Neu aus der Datei.' },
    { title: 'Dritter', body: 'Neu aus der Datei.' }
  ]))

  // TF-346d: the default is to skip, and the summary says so.
  await expect(page.locator('[data-test="import-plan"]')).toContainText('überschreibt 0')
  await expect(page.locator('[data-test="import-plan"]')).toContainText('überspringt 3')

  await page.locator('[data-test="decide-all-overwrite"]').click()

  // TF-346c: the summary follows and names the consequence.
  await expect(page.locator('[data-test="import-plan"]')).toContainText('überschreibt 3')

  // TF-346b: the bulk decision sets, it does not lock.
  await page.locator('.entry select').first().selectOption('skip')
  await expect(page.locator('[data-test="import-plan"]')).toContainText('überschreibt 2')

  await page.getByRole('button', { name: 'Einspielen', exact: true }).click()
  await expect(page.getByText('2 überschrieben')).toBeVisible()

  await removeWorkspace(page, 'Sammelraum')
})
