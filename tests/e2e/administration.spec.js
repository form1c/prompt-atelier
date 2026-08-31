import { test, expect } from '@playwright/test'
import { adminAccount } from './instance.js'

// W-7 in a real browser (TF-356): create an account, lock it, reset its
// password, delete it with its prompts transferred.
//
// The whole flow runs on an account this file **creates**, and it takes it
// away again at the end. Locking or deleting one of the fixture's accounts
// would break every other file — the instance belongs to all of them.
//
// The piece that only a browser can show is the one-time password: it exists
// in readable form exactly once, in one answer, and the test signs in with it
// afterwards. Below this level one can only check that a string came back.

const admin = adminAccount()

async function signIn (page, email, password) {
  await page.goto('/')
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(email)
  await page.getByLabel('Passwort', { exact: true }).fill(password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
}

const goTo = (page, entry) => page.getByRole('link', { name: entry, exact: true }).click()

// The administration is four screens behind one entry in the sidebar since
// AP-15b (S6). "Admin" lands on the accounts; the rest is a tab away.
async function goToAdmin (page, section = null) {
  await goTo(page, 'Admin')
  if (section) await page.getByRole('navigation', { name: 'Bereiche der Administration' })
    .getByRole('link', { name: section, exact: true }).click()
}

// Scoped to the account list. The workspace list below carries
// "Persönlich-Testkonto", so an unscoped row lookup matches two elements —
// a strict-mode violation that says nothing about the screen.
const rowOf = (page, name) => page.locator('[aria-labelledby="accounts-heading"] .entry')
  .filter({ hasText: name })

// The profile sits in the account menu, not in the sidebar (11.2).
async function openProfile (page) {
  await page.getByRole('banner').getByRole('button', { name: 'Konto' }).click()
  await page.getByRole('link', { name: 'Profil', exact: true }).click()
}

test.beforeEach(async ({ context }) => {
  await context.clearCookies()
})

test('W-7: create, lock, reset and delete an account', async ({ page }) => {
  await signIn(page, admin.email, admin.password)
  await expect(page.getByRole('banner')).toContainText('Thomas')

  await goTo(page, 'Admin')
  await expect(page.getByRole('heading', { name: 'Administration' })).toBeVisible()

  // --- creating an account -------------------------------------------------
  const section = page.locator('[aria-labelledby="accounts-heading"]')
  await section.getByLabel('Name', { exact: true }).fill('Testkonto')
  await section.getByLabel('E-Mail-Adresse', { exact: true }).fill('testkonto@example.test')
  await page.getByRole('button', { name: 'Anlegen', exact: true }).click()

  // Shown once, in a dialogue that has to be dismissed by hand.
  const dialog = page.getByRole('dialog')
  await expect(dialog).toContainText('genau einmal angezeigt')
  const initial = (await page.locator('[data-test="initial-password"]').innerText()).trim()
  expect(initial.length).toBeGreaterThanOrEqual(16)
  await dialog.getByRole('button', { name: 'Notiert' }).click()

  await expect(rowOf(page, 'Testkonto')).toContainText('testkonto@example.test')
  await expect(rowOf(page, 'Testkonto')).toContainText('noch nie angemeldet')

  // --- the forced change (FA-903) ------------------------------------------
  await page.context().clearCookies()
  await signIn(page, 'testkonto@example.test', initial)

  // The password works, and the application is closed until a new one is set.
  await expect(page.getByText('Bitte vergeben Sie ein neues Passwort')).toBeVisible()
  await page.goto('/keywords')
  await expect(page).toHaveURL(/\/profile$/)

  await page.getByLabel('Bisheriges Passwort').fill(initial)
  await page.getByLabel('Neues Passwort', { exact: true }).fill('ein-eigenes-langes-passwort')
  await page.getByLabel('Neues Passwort wiederholen').fill('ein-eigenes-langes-passwort')
  await page.getByRole('button', { name: 'Passwort ändern', exact: true }).click()
  await expect(page.getByText('Das Passwort wurde geändert.')).toBeVisible()

  // And the application opens again.
  await goTo(page, 'Bibliothek')
  await expect(page.getByRole('heading', { name: 'Noch keine Prompts' })).toBeVisible()

  // Something of its own, so the deletion below has a decision to make.
  await page.getByRole('link', { name: 'Neu' }).click()
  await page.getByLabel('Titel', { exact: true }).fill('Erbstück')
  await page.getByLabel('Prompt-Text', { exact: true }).fill('Bleibt hoffentlich erhalten.')
  await page.getByRole('button', { name: /Speichern/ }).click()
  await expect(page.getByRole('heading', { name: 'Erbstück' })).toBeVisible()

  // --- locking an account ---------------------------------------------------
  await page.context().clearCookies()
  await signIn(page, admin.email, admin.password)
  await goTo(page, 'Admin')
  await rowOf(page, 'Testkonto').getByRole('button', { name: 'Testkonto sperren' }).click()
  await expect(rowOf(page, 'Testkonto')).toContainText('Gesperrt')

  // A locked account cannot sign in — the half of FA-902 that matters.
  await page.context().clearCookies()
  await signIn(page, 'testkonto@example.test', 'ein-eigenes-langes-passwort')
  await expect(page.getByRole('alert')).toBeVisible()
  await expect(page).toHaveURL(/\/login/)

  // --- resetting (FA-903) --------------------------------------------------
  await page.context().clearCookies()
  await signIn(page, admin.email, admin.password)
  await goTo(page, 'Admin')
  await rowOf(page, 'Testkonto').getByRole('button', { name: 'Testkonto entsperren' }).click()
  await expect(rowOf(page, 'Testkonto')).toContainText('Aktiv')

  await rowOf(page, 'Testkonto').getByRole('button', { name: 'Passwort von Testkonto' }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Zurücksetzen' }).click()
  const second = (await page.locator('[data-test="initial-password"]').innerText()).trim()
  expect(second).not.toBe(initial)
  await page.getByRole('button', { name: 'Notiert' }).click()

  // --- deletion with transfer ----------------------------------------------
  await rowOf(page, 'Testkonto').getByRole('button', { name: 'Testkonto löschen' }).click()
  await expect(page.getByRole('dialog')).toContainText('1 Prompts')
  await page.getByRole('dialog').getByText('Prompts übertragen auf').click()
  await page.locator('[data-test="successor"]').selectOption({ label: 'Thomas' })
  await page.getByRole('button', { name: 'Endgültig löschen' }).click()

  await expect(rowOf(page, 'Testkonto')).toHaveCount(0)

  // The inherited prompt is Thomas's now, and he can see it — an inheritance
  // he could not reach would be one in name only.
  await goTo(page, 'Bibliothek')
  await page.getByRole('searchbox').fill('Erbstück')
  await expect(page.getByRole('button', { name: /Erbstück öffnen/ })).toBeVisible()

  // Taken away again: the instance is left as it was found.
  await page.getByRole('button', { name: /Erbstück öffnen/ }).click()
  await page.getByRole('button', { name: 'Weitere Aktionen' }).click()
  await page.getByRole('button', { name: 'In den Papierkorb' }).click()
  await goTo(page, 'Papierkorb')
  await page.getByRole('button', { name: '„Erbstück“ endgültig löschen' }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Endgültig löschen' }).click()
  await expect(page.getByText('Der Papierkorb ist leer')).toBeVisible()
})

// SEC-18 in the browser: the disclosure really arrives as a file. Below this
// level one can only check that the payload was right.
test('downloads the personal data report as a file', async ({ page }) => {
  await signIn(page, admin.email, admin.password)
  await openProfile(page)

  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.getByRole('button', { name: 'Daten herunterladen' }).click()
  ])

  expect(download.suggestedFilename()).toBe('selbstauskunft.json')

  const stream = await download.createReadStream()
  const chunks = []
  for await (const chunk of stream) chunks.push(chunk)
  const disclosure = JSON.parse(Buffer.concat(chunks).toString('utf8'))

  expect(disclosure.account.email).toBe(admin.email)
  expect(disclosure).toHaveProperty('memberships')
  expect(disclosure).toHaveProperty('audit_entries')
  expect(disclosure.account).not.toHaveProperty('password_hash')
})

// Chapter 6.2, from the side that matters: the administration screen is not a
// way into anybody's prompts.
test('no route leads from the administration into content of others', async ({ page }) => {
  await signIn(page, admin.email, admin.password)
  await goToAdmin(page, 'Workspaces')

  const workspaces = page.locator('[aria-labelledby="workspaces-heading"]')
  await expect(workspaces).toContainText('Marketing')
  await expect(workspaces).toContainText('Prompts')
  await expect(workspaces.locator('a')).toHaveCount(0)
  await expect(workspaces.locator('button')).toHaveCount(0)
})

// FA-910 in a real browser: a product setting changed here is in force on the
// next request, with nothing restarted. Below this level one can only check
// that a row was written.
//
// `security.registration` is the one to try it on, because the instance runs
// on `approval` (server.rb) and the login screen shows the difference without
// any further step.
test('FA-910: a setting takes effect at once, without a restart', async ({ page }) => {
  await signIn(page, admin.email, admin.password)
  await goToAdmin(page, 'Einstellungen')

  await expect(page.getByRole('heading', { name: 'Einstellungen dieser Instanz' })).toBeVisible()
  // Not offered, and that is the point of the split: whoever could widen the
  // trusted proxies from here would disable the login limit.
  await expect(page.locator('[data-test="server.port"]')).toHaveCount(0)
  await expect(page.getByRole('button', { name: /Neustart/i })).toHaveCount(0)

  await page.locator('[data-test="security.registration"]').selectOption('off')
  await page.locator('[data-test="save-settings"]').click()
  await expect(page.getByRole('status')).toContainText('übernommen')

  // The next request already behaves differently — the login screen no longer
  // offers a way to register.
  await page.context().clearCookies()
  await page.goto('/')
  await expect(page.getByRole('link', { name: 'Konto anlegen' })).toHaveCount(0)

  // Put back in the body as well as in the hook below: here it is part of
  // what the case demonstrates (the change goes both ways), there it is the
  // safety net for a run that stops in the middle.
  await setRegistration(page, 'approval')
})

// The instance belongs to every file in this directory, and this is the only
// case that changes something about it as a whole. A run that stopped between
// the two halves above would leave registration switched off — and
// registration.spec.js, which runs afterwards, would fail with a message
// about a missing link rather than about the setting that was left behind.
test.afterEach(async ({ page }, testInfo) => {
  if (!testInfo.title.includes('FA-910')) return

  await page.context().clearCookies()
  await setRegistration(page, 'approval')
})

async function setRegistration (page, value) {
  await signIn(page, admin.email, admin.password)
  await goToAdmin(page, 'Einstellungen')
  await page.locator('[data-test="security.registration"]').selectOption(value)
  await page.locator('[data-test="save-settings"]').click()
  await expect(page.getByRole('status')).toContainText('übernommen')
}
