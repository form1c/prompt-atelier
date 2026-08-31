import { test, expect } from '@playwright/test'
import { adminAccount } from './instance.js'

// FA-107 in a real browser: register, wait, be let in, sign in.
//
// The instance runs on `approval` (server.rb), which is the setting an
// operator is meant to choose and the only one under which all four steps
// exist. What only a browser can show is the middle: that somebody who has
// just registered is told they are **waiting** rather than that they were
// locked out, and that the administrator can tell the two apart in his list.
//
// The account is created by this file and removed again at the end. The
// instance belongs to every file here, and one that left an account behind
// would change what the next one counts.

const admin = adminAccount()
const NEWCOMER = { name: 'Nina Neuzugang', email: 'nina@example.test', password: 'ein-eigenes-langes-passwort' }

async function signIn (page, email, password) {
  await page.goto('/')
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(email)
  await page.getByLabel('Passwort', { exact: true }).fill(password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
}

const goTo = (page, entry) => page.getByRole('link', { name: entry, exact: true }).click()

async function goToAdmin (page, section = null) {
  await goTo(page, 'Admin')
  if (section) await page.getByRole('navigation', { name: 'Bereiche der Administration' })
    .getByRole('link', { name: section, exact: true }).click()
}

// Scoped to the account list: the workspace list below carries the personal
// workspace of the same person, and an unscoped lookup would match both.
const rowOf = (page, name) => page.locator('[aria-labelledby="accounts-heading"] .entry')
  .filter({ hasText: name })

test.beforeEach(async ({ context }) => {
  await context.clearCookies()
})

test('FA-107: register, wait, be approved, sign in', async ({ page }) => {
  // --- the way from the sign-in page ---------------------------------------
  await page.goto('/')
  await page.getByRole('link', { name: 'Konto anlegen' }).click()
  await expect(page).toHaveURL(/\/register$/)

  // Said before anything is typed, not after: whoever fills in a form expects
  // to be let in at the end of it.
  await expect(page.locator('[data-test="approval-notice"]')).toContainText('freigeschaltet')

  // --- eintragen ----------------------------------------------------------
  await page.getByLabel('Name', { exact: true }).fill(NEWCOMER.name)
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(NEWCOMER.email)
  await page.getByLabel('Passwort', { exact: true }).fill(NEWCOMER.password)
  await page.getByLabel('Passwort wiederholen').fill(NEWCOMER.password)
  await page.getByRole('button', { name: 'Konto anlegen', exact: true }).click()

  await expect(page.locator('[data-test="pending"]')).toContainText('Freischaltung')
  // Not signed in: a session every following call would refuse is worse than
  // none at all.
  await page.goto('/keywords')
  await expect(page).toHaveURL(/\/login/)

  // --- warten -------------------------------------------------------------
  await signIn(page, NEWCOMER.email, NEWCOMER.password)
  await expect(page.getByRole('alert')).toContainText('wartet noch auf die Freischaltung')
  // The sentence that must not appear. Somebody who registered a minute ago
  // and reads "locked" looks for a fault of their own where there is none.
  await expect(page.getByRole('alert')).not.toContainText('ist gesperrt')

  // --- freischalten (FA-906, FA-107) --------------------------------------
  await page.context().clearCookies()
  await signIn(page, admin.email, admin.password)
  await goToAdmin(page)

  // The count is how the administrator learns of it at all — the application
  // sends no e-mail (E-13).
  await expect(page.locator('[data-test="pending-count"]')).toContainText('1')
  await expect(rowOf(page, NEWCOMER.name)).toContainText('Wartet auf Freischaltung')

  await rowOf(page, NEWCOMER.name).locator('[data-test="approve"]').click()
  await expect(rowOf(page, NEWCOMER.name)).toContainText('Aktiv')
  await expect(page.locator('[data-test="pending-count"]')).toHaveCount(0)

  // --- and the action stands in the log under its own name ----------------
  await page.getByRole('navigation', { name: 'Bereiche der Administration' })
    .getByRole('link', { name: 'Protokoll', exact: true }).click()
  await page.locator('[data-test="audit-action"]').selectOption('user.approved')
  await page.locator('[data-test="audit-filter"]').click()
  await expect(page.locator('[aria-labelledby="audit-heading"] .entry').first())
    .toContainText('user.approved')

  // --- signing in -----------------------------------------------------------
  await page.context().clearCookies()
  await signIn(page, NEWCOMER.email, NEWCOMER.password)
  await expect(page.getByRole('banner')).toContainText(NEWCOMER.name)
  // FA-602: a place to write from the first moment.
  await expect(page.getByRole('banner')).toContainText('Persönlich')

  // --- clearing up: the instance stays as it was found ---------------------
  await page.context().clearCookies()
  await signIn(page, admin.email, admin.password)
  await goToAdmin(page)
  await rowOf(page, NEWCOMER.name).getByRole('button', { name: `${NEWCOMER.name} löschen` }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Endgültig löschen' }).click()
  await expect(rowOf(page, NEWCOMER.name)).toHaveCount(0)
})

// FA-908, and the reason the filter exists: the log is bounded by time, so
// nothing is pushed out of the table — but a burst of refused logins pushes
// everything else out of *sight*, and the administrator looks at the log
// precisely when something has happened.
test('FA-908: the log can be narrowed down to one action', async ({ page }) => {
  await signIn(page, admin.email, admin.password)
  await goToAdmin(page, 'Protokoll')

  // The entry list, not the whole section: the section carries the filter's
  // own `<select>`, whose options list every kind of event there is — so
  // "does not contain login.succeeded" would be false no matter what the
  // filter did.
  const entries = page.locator('[aria-labelledby="audit-heading"] .entry')
  await expect(entries.first()).toContainText('login.succeeded')

  // The event this case filters for is made **here**, by this case.
  //
  // It used to rely on one being in the log already, and there always was:
  // `management.spec` creates a workspace, and it happens to run first. So
  // the file passed in the full run and failed on its own — which is the
  // wrong way round, because the rule for this suite is that a file alone is
  // always green (test concept 3.2). When the earlier file broke for an
  // unrelated reason, this case broke with it and pointed at the log.
  await goTo(page, 'Bibliothek')
  await goTo(page, 'Workspace')
  await page.getByLabel('Name', { exact: true }).last().fill('Prüfstelle Protokoll')
  await page.getByRole('button', { name: 'Anlegen', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText('Prüfstelle Protokoll')
  await goToAdmin(page, 'Protokoll')

  await page.locator('[data-test="audit-action"]').selectOption('workspace.created')
  await page.locator('[data-test="audit-filter"]').click()

  await expect(entries.filter({ hasText: 'login.succeeded' })).toHaveCount(0)
  await expect(entries.first()).toContainText('workspace.created')

  await page.getByRole('button', { name: 'Filter zurücksetzen' }).click()
  await expect(entries.filter({ hasText: 'login.succeeded' }).first()).toBeVisible()
})
