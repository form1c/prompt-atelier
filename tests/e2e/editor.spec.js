import { test, expect } from '@playwright/test'
import { account } from './instance.js'

// W-2 and W-3 — creating a prompt and duplicating one (TF-351, TF-352).
//
// The rules behind them are checked on both sides: the service knows what a
// copy inherits and how variables follow the text, the interface knows what it
// sends. What can be seen **only** here is the route: create, save, find again
// — through real HTTP, against real SQLite, with the form behaviour of a real
// browser.
//
// And the case no unit test poses: after saving, the prompt has to be findable
// in the library. Between "the POST came back 201" and "the search index knows
// about it" lies a great deal that nobody sees.
//
// **The instance belongs to every file together.** It is built once per run,
// not per file. These cases are the only ones here that write, and they must
// therefore take nothing away that another builds on: what is created is new,
// what is moved was created here. The first draft moved a prompt out of the
// stock and let three cases in library.spec.js fall — each green on its own,
// red together.

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

test.beforeEach(async ({ context }) => {
  await context.clearCookies()
})

// TF-351: variables appear while typing, with no separate creation step.
test('W-2: create a prompt, variables appear while typing', async ({ page }) => {
  await signIn(page)

  await page.getByRole('link', { name: 'Neu' }).click()
  await expect(page.getByRole('heading', { name: 'Neuer Prompt' })).toBeVisible()

  await page.getByLabel('Titel', { exact: true }).fill('Angebotsschreiben')
  await page.getByLabel('Prompt-Text', { exact: true })
    .fill('Schreibe ein Angebot für {{kunde}} über {{leistung}}.')

  // No click, no button: the two entries are there because the text names
  // them.
  await expect(page.getByText('2 erkannte Variablen')).toBeVisible()
  await expect(preview(page)).toContainText('{{kunde}}')

  // And the details of a variable can be maintained (FA-302).
  await page.getByLabel('Standardwert').first().fill('Musterfirma GmbH')
  await expect(preview(page)).toContainText('Musterfirma GmbH')

  await page.getByRole('button', { name: /Speichern/ }).click()

  // After creating it one stands in front of the prompt and can use it.
  await expect(page.getByRole('heading', { name: 'Angebotsschreiben' })).toBeVisible()
  await expect(page.getByLabel(/kunde/i)).toHaveValue('Musterfirma GmbH')

  // The part only a real end-to-end run shows: the prompt can be found again
  // as well.
  await page.getByRole('link', { name: 'Zurück zur Bibliothek' }).click()
  await page.getByRole('searchbox').fill('Angebotsschreiben')
  await expect(page.getByRole('button', { name: /Angebotsschreiben öffnen/ })).toBeVisible()
})

// TF-454 in a real browser, found by the client while using it: in the options
// field Enter would not produce a second line, although the help text says one
// option per line. Exactly one option was possible.
//
// With **real key presses** here rather than values set at once — the fault sat
// in the intermediate state after each single stroke, and a whole value set in
// one go would not have shown it.
test('takes several lines in the options of a select', async ({ page }) => {
  await signIn(page)

  await page.getByRole('link', { name: 'Neu' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Mit Auswahl')
  await page.getByLabel('Prompt-Text', { exact: true }).fill('Für {{gruppe}}.')

  await page.getByLabel('Typ').selectOption('select')

  const options = page.getByLabel('Optionen')
  await options.click()
  await page.keyboard.type('Sehr formal')
  await page.keyboard.press('Enter')
  await page.keyboard.type('Locker')

  await expect(options).toHaveValue('Sehr formal\nLocker')

  await page.getByRole('button', { name: /Speichern/ }).click()
  await expect(page.getByRole('heading', { name: 'Mit Auswahl' })).toBeVisible()

  // And both stand in the filling form to choose from (FA-302).
  const choice = page.getByLabel('gruppe')
  await expect(choice.locator('option')).toHaveText(['', 'Sehr formal', 'Locker'])
})

// 11.5: unsaved changes bring up a question on leaving.
test('asks whoever leaves the editor with unsaved work', async ({ page }) => {
  await signIn(page)

  await page.getByRole('link', { name: 'Neu' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Halb fertig')
  await page.getByRole('button', { name: 'Abbrechen' }).click()

  await expect(page.getByRole('dialog')).toContainText('Ungespeicherte Änderungen')

  await page.getByRole('button', { name: 'Hierbleiben' }).click()
  await expect(page.getByLabel('Titel', { exact: true })).toHaveValue('Halb fertig')

  await page.getByRole('button', { name: 'Abbrechen' }).click()
  await page.getByRole('button', { name: 'Verwerfen und verlassen' }).click()
  await expect(page.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()
})

// W-3 and TF-352: the most frequent way to a new prompt.
test('W-3: duplicate a prompt and name the copy', async ({ page }) => {
  await signIn(page)

  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()

  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('link', { name: /Duplizieren/ }).click()

  // TF-308: only where one may create is offered. The target is chosen
  // explicitly — building on the preselection would mean hunting for the copy
  // somewhere.
  await expect(page.getByRole('group')).toContainText('Marketing')
  await page.getByRole('radio', { name: 'Marketing' }).check()
  await page.getByRole('button', { name: 'Kopie anlegen' }).click()

  // The title stands selected in the editor — "… (Kopie)" is a placeholder,
  // not a name, and one key press replaces it.
  const title = page.getByLabel('Titel', { exact: true })
  await expect(title).toHaveValue('Blogartikel-Generator (Kopie)')
  await expect(title).toBeFocused()

  await page.keyboard.type('Newsletter-Generator')
  await expect(title).toHaveValue('Newsletter-Generator')

  // Saving through the shortcut from 11.6, not through the button.
  await page.keyboard.press('Control+s')
  await expect(page.getByRole('heading', { name: 'Newsletter-Generator' })).toBeVisible()

  // And the original stands unchanged beside it — unlike after a move.
  await page.getByRole('link', { name: 'Zurück zur Bibliothek' }).click()
  await page.getByRole('searchbox').fill('Generator')
  await expect(page.getByRole('button', { name: /Blogartikel-Generator öffnen/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /Newsletter-Generator öffnen/ })).toBeVisible()
})

// FA-207 and TF-307: moving takes the prompt along **and** resets its
// visibility. The two together are the reason for the warning beforehand.
//
// What is moved is a prompt created for the purpose, and it goes **out of** the
// personal workspace **into** Marketing. The first attempt took `P-EDIT` out of
// the stock and put it away personally — upon which three cases in
// library.spec.js fell: one expects the personal workspace empty, two expect
// `P-EDIT` in Marketing. The instance belongs to every file together, and
// whoever takes something away takes it away from everyone.
test('moves a prompt and resets its visibility on the way', async ({ page }) => {
  await page.goto('/')
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(email)
  await page.getByLabel('Passwort', { exact: true }).fill(password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText('Martin')

  // Explicitly into the personal workspace rather than relying on the
  // remembered choice: that one lives on the server (FA-605) and carries
  // whatever a previous case picked last.
  await page.getByRole('button', { name: 'Workspace' }).click()
  await page.getByRole('button', { name: /^Persönlicher Workspace/ }).click()

  // Visible to the workspace — otherwise there would be nothing to reset on
  // the move and the case would check nothing.
  await page.getByRole('link', { name: 'Neu' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Umzugskandidat')
  await page.getByLabel('Prompt-Text', { exact: true }).fill('Ein Text ohne Variablen.')
  await page.getByLabel('Sichtbarkeit').selectOption('workspace')
  await page.getByRole('button', { name: /Speichern/ }).click()
  await expect(page.getByRole('heading', { name: 'Umzugskandidat' })).toBeVisible()

  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('link', { name: /In Workspace verschieben/ }).click()

  await expect(page.getByText(/Sichtbarkeit auf .Nur ich. zurückgesetzt/)).toBeVisible()
  await page.getByRole('radio', { name: 'Marketing' }).check()
  await page.getByRole('button', { name: 'Verschieben', exact: true }).click()

  await expect(page.getByRole('heading', { name: 'Umzugskandidat' })).toBeVisible()
  await expect(page.locator('.prompt__meta select').first()).toHaveValue('private')

  // And the counter-check to duplicating: it is gone from where it came.
  await page.getByRole('link', { name: 'Zurück zur Bibliothek' }).click()
  await page.getByRole('button', { name: 'Workspace' }).click()
  await page.getByRole('button', { name: /^Persönlicher Workspace/ }).click()
  await expect(page.getByRole('heading', { name: 'Noch keine Prompts' })).toBeVisible()
})
