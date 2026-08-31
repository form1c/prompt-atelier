import { test, expect } from '@playwright/test'
import { account } from './instance.js'

// W-4, W-5 and W-9 in a real browser (TF-353, TF-354, TF-358).
//
// The three management screens are each checked without a browser as well —
// the rules on the server, the drawing in Vitest. What only this level shows
// is the stretch: a keyword written here really reaches the prompt over
// there, a moved prompt really turns up in the target workspace, and a
// deleted one really comes back with what it had.
//
// **The instance belongs to every file.** These cases create what they need
// and take nothing away: a workspace of their own, prompts of their own, a
// keyword of their own. What they create in the shared workspace they clear
// away again, because a keyword left behind changes what the prompt screen of
// another file shows.

const { email, password } = account()

async function signIn (page) {
  await page.goto('/')
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(email)
  await page.getByLabel('Passwort', { exact: true }).fill(password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText('Martin')
}

// The workspace is chosen explicitly, never inherited: the choice lives on
// the server (FA-605) and carries whatever an earlier case left there.
//
// Scoped to the header, unlike the same helper in the other files. On the
// workspace screen "Workspace" is in the name of three buttons — the
// switcher, "Martin aus dem Workspace entfernen" and "Diesen Workspace
// löschen" — and an unscoped locator matches all three.
async function switchTo (page, name) {
  await page.getByRole('banner').getByRole('button', { name: 'Workspace' }).click()
  await page.getByRole('button', { name, exact: typeof name === 'string' }).click()
}

const goTo = (page, entry) => page.getByRole('link', { name: entry, exact: true }).click()

test.beforeEach(async ({ context }) => {
  await context.clearCookies()
})

// TF-353 — W-4. The rule the workflow exists for: the effect is visible while
// the keyword is being written, not after it has been saved.
test('W-4: create a keyword, see its effect and use it', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Marketing')

  await goTo(page, 'Keywords')
  await expect(page.getByRole('heading', { name: 'Keywords', exact: true })).toBeVisible()

  const effect = page.locator('[data-test="effect"]')

  // Before a single character: the example prompt stands there on its own.
  await expect(effect).toContainText('Fasse den folgenden Abschnitt')
  await expect(effect.locator('.effect__keyword')).toHaveCount(0)

  await page.getByLabel('Name', { exact: true }).fill('knapp-e2e')
  await page.getByLabel('Text', { exact: true }).fill('Fasse dich kurz.')

  // The effect is there now, before anything was saved — this is the whole
  // point of W-4, and the reason it is a workflow of its own.
  await expect(effect.locator('.effect__keyword')).toHaveText('Fasse dich kurz.')
  await expect(effect).toHaveText(/^Fasse dich kurz\./)

  await page.getByLabel('Position').selectOption('append')
  await expect(effect).toHaveText(/Fasse dich kurz\.$/)

  await page.getByRole('button', { name: 'Anlegen', exact: true }).click()
  await expect(page.getByText('knapp-e2e')).toBeVisible()

  // And it is switchable on a prompt, which is what a keyword is for (FA-402).
  await goTo(page, 'Bibliothek')
  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()

  const chip = page.getByRole('button', { name: 'knapp-e2e' })
  await expect(chip).toBeVisible()
  await chip.click()
  await expect(page.locator('[data-test="preview"]')).toContainText('Fasse dich kurz.')

  // Cleared away again: a keyword left in the shared workspace would turn up
  // in the prompt screen of every other file.
  //
  // Checked on the list and not on the page: the confirmation that appears
  // for two seconds carries the name too, and asserting against the whole
  // page would be waiting for a message to disappear rather than for the
  // keyword to be gone.
  await goTo(page, 'Keywords')
  await page.getByRole('button', { name: 'knapp-e2e löschen' }).click()
  // Confirmed, because deleting a keyword cannot be undone (11.6) — and the
  // wording says so rather than reporting nought affected prompts.
  await expect(page.getByRole('dialog')).toContainText('Kein Prompt benutzt dieses Keyword')
  await page.getByRole('dialog').getByRole('button', { name: 'Endgültig löschen' }).click()
  await expect(page.getByRole('button', { name: 'knapp-e2e löschen' })).toHaveCount(0)
})

// TF-354 — W-5, both branches. The prompt is created here, moved into a
// workspace created here, and shared there; nothing of the fixture is
// touched.
test('W-5: share a prompt with the team, along both branches', async ({ page }) => {
  await signIn(page)
  await switchTo(page, /^Persönlicher Workspace/)

  // A workspace to share into (FA-601). Before AP-13 there was no way to make
  // one, and W-5 could not be walked at all without a fixture.
  await goTo(page, 'Workspace')
  await page.locator('[aria-labelledby="workspace-new-heading"]').getByLabel('Name').fill('Teamraum')
  await page.getByRole('button', { name: 'Anlegen', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText('Teamraum')

  // The prompt starts privately, in the personal workspace — the situation
  // W-5 begins from.
  await switchTo(page, /^Persönlicher Workspace/)
  await page.getByRole('link', { name: 'Neu' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Teamvorlage')
  await page.getByLabel('Prompt-Text', { exact: true }).fill('Eine Vorlage für das Team.')
  await page.getByRole('button', { name: /Speichern/ }).click()
  await expect(page.getByRole('heading', { name: 'Teamvorlage' })).toBeVisible()

  // Branch one: duplicate, so a copy of one's own stays behind.
  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('link', { name: /Duplizieren/ }).click()
  await page.getByRole('radio', { name: 'Teamraum' }).check()
  await page.getByRole('button', { name: 'Kopie anlegen' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Teamvorlage (geteilt)')
  await page.keyboard.press('Control+s')
  await expect(page.getByRole('heading', { name: 'Teamvorlage (geteilt)' })).toBeVisible()

  // And the last two steps of W-5, which are what "sharing" actually means:
  // visible to the workspace, and no longer a draft.
  //
  // Checked on the field, not on the confirmation: "Gespeichert." is on the
  // screen from the save a moment ago as well, and waiting for a message that
  // is already there proves nothing about the change just made.
  const visibility = page.locator('.prompt__meta select').first()
  const status = page.locator('.prompt__meta select').nth(1)
  await visibility.selectOption('workspace')
  await expect(visibility).toHaveValue('workspace')
  await status.selectOption('active')
  await expect(status).toHaveValue('active')

  // Branch two: move — nothing stays behind.
  //
  // By way of the library, not straight from here: the switcher changes the
  // context and the list follows it, but a prompt screen keeps showing its
  // prompt — deliberately, because throwing away what somebody is looking at
  // is not what changing workspace means.
  await goTo(page, 'Bibliothek')
  await switchTo(page, /^Persönlicher Workspace/)
  await page.getByRole('button', { name: /Teamvorlage öffnen/ }).click()
  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('link', { name: /In Workspace verschieben/ }).click()
  await page.getByRole('radio', { name: 'Teamraum' }).check()
  await page.getByRole('button', { name: 'Verschieben', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Teamvorlage' })).toBeVisible()

  // The difference between the two branches, in one place: the copy is in the
  // team workspace **and** the original is gone from where it was.
  await goTo(page, 'Bibliothek')
  await switchTo(page, 'Teamraum')
  await expect(page.getByRole('button', { name: /Teamvorlage öffnen/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /Teamvorlage \(geteilt\) öffnen/ })).toBeVisible()

  await switchTo(page, /^Persönlicher Workspace/)
  await expect(page.getByRole('heading', { name: 'Noch keine Prompts' })).toBeVisible()

  // Taken away again, with everything in it. The personal workspace is left
  // as it was found — library.spec.js expects it empty.
  await goTo(page, 'Bibliothek')
  await switchTo(page, 'Teamraum')
  await goTo(page, 'Workspace')
  await page.getByRole('button', { name: 'Diesen Workspace löschen' }).click()
  await page.getByRole('dialog').getByLabel('Name des Workspace').fill('Teamraum')
  await page.getByRole('button', { name: 'Endgültig löschen' }).click()
  await expect(page.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()
})

// TF-358 — W-9, both ways back. One prompt is overwritten and undone, another
// is deleted and fetched out of the trash.
test('W-9: undo a change and fetch one back from the trash', async ({ page }) => {
  await signIn(page)
  await switchTo(page, /^Persönlicher Workspace/)

  await page.getByRole('link', { name: 'Neu' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Rettungsfall')
  await page.getByLabel('Prompt-Text', { exact: true }).fill('Der richtige Text.')
  await page.getByRole('button', { name: /Speichern/ }).click()
  await expect(page.getByRole('heading', { name: 'Rettungsfall' })).toBeVisible()

  // Way one: overwritten by mistake, taken back.
  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('link', { name: 'Bearbeiten' }).click()
  await page.getByLabel('Prompt-Text', { exact: true }).fill('Aus Versehen alles überschrieben.')
  await page.keyboard.press('Control+s')
  await expect(page.locator('[data-test="preview"]')).toContainText('Aus Versehen')

  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('button', { name: 'Letzte Änderung rückgängig' }).click()
  await expect(page.locator('[data-test="preview"]')).toContainText('Der richtige Text.')

  // Way two: deleted, and out of the trash again.
  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('button', { name: 'In den Papierkorb' }).click()
  // On this prompt, not on the library being empty: what a case asserts has
  // to be about what it did, or a leftover from another file decides it.
  await expect(page.getByRole('button', { name: /Rettungsfall öffnen/ })).toHaveCount(0)

  await goTo(page, 'Papierkorb')
  const row = page.locator('.entry').filter({ hasText: 'Rettungsfall' })
  await expect(row).toBeVisible()
  // FA-703 asks for who deleted it and where it came from, by name.
  //
  // "Persönlicher Workspace" and not the stored `Persönlich-Martin`: the line
  // has to name the workspace the way the switcher above it does, or the same
  // place wears two names on one screen. The server sends the flag beside the
  // name so the browser can tell which of the two to show.
  await expect(row).toContainText('Martin')
  await expect(row).toContainText('Persönlicher Workspace')

  await page.getByRole('button', { name: '„Rettungsfall“ wiederherstellen' }).click()
  await expect(page.getByText('Der Papierkorb ist leer')).toBeVisible()

  await goTo(page, 'Bibliothek')
  await expect(page.getByRole('button', { name: /Rettungsfall öffnen/ })).toBeVisible()

  // Cleared away for good, so the personal workspace is left as it was found.
  await page.getByRole('button', { name: /Rettungsfall öffnen/ }).click()
  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('button', { name: 'In den Papierkorb' }).click()
  await goTo(page, 'Papierkorb')
  await page.getByRole('button', { name: '„Rettungsfall“ endgültig löschen' }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Endgültig löschen' }).click()
  await expect(page.getByText('Der Papierkorb ist leer')).toBeVisible()
})
