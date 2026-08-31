import { test, expect } from '@playwright/test'
import { account, BASE_URL } from './instance.js'

// The first test that goes all the way through: a real browser, the built
// interface, the real server, a real database (FA-101, FA-102, NT-2).
//
// What only this level can show is the part no test tool imitates faithfully:
// how a browser treats the session cookie. Finding S-01 was exactly that —
// an unconditional `Secure` attribute would have made a standard installation
// impossible to sign in to, while every automated test stayed green.

const { email, password } = account()

// The fields are addressed by their label, the way a user finds them, and
// exactly: "Passwort" also matches the heading of the section below the form.
async function signIn (page, { as = email, using = password } = {}) {
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(as)
  await page.getByLabel('Passwort', { exact: true }).fill(using)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
}

test.beforeEach(async ({ context }) => {
  await context.clearCookies()
})

test('sends an unauthenticated call to the sign-in page', async ({ page }) => {
  await page.goto('/')

  await expect(page).toHaveURL(/\/login$/)
  await expect(page.getByRole('heading', { name: 'Anmelden' })).toBeVisible()
})

// TF-421 in a real browser, not against a mounted component.
//
// The assertion used to be "no link at all on this screen", which stopped
// being the right statement when FA-107 put the way to a registration on it.
// What TF-421 is about is the **password**: there is no self-service reset in
// v1 (E-13), and an inviting link that leads nowhere is worse than the plain
// sentence about who can help. So the section is what carries no link.
test('names the administrative route and offers no self-service link', async ({ page }) => {
  await page.goto('/')

  const forgotten = page.locator('section', { hasText: 'Passwort vergessen?' })
  await expect(page.getByRole('heading', { name: 'Passwort vergessen?' })).toBeVisible()
  await expect(forgotten.locator('a')).toHaveCount(0)
  await expect(page.getByRole('link', { name: /Passwort/ })).toHaveCount(0)
})

test('refuses wrong credentials without saying which entry was wrong', async ({ page }) => {
  await page.goto('/')
  await signIn(page, { using: 'ganz-sicher-falsch' })

  await expect(page.getByRole('alert')).toHaveText('E-Mail-Adresse oder Passwort ist nicht richtig.')
  await expect(page).toHaveURL(/\/login$/)
})

test('signs in and shows the library', async ({ page }) => {
  await page.goto('/')
  await signIn(page)

  await expect(page).toHaveURL(/\/$/)
  await expect(page.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()
  await expect(page.getByRole('banner')).toContainText('Martin')
})

// NT-2, first half: the session survives closing the tab. A new page in the
// same context is exactly that — same cookie jar, fresh document. It fails if
// the cookie is a session cookie the browser drops, or if `Secure` is set on
// a plain http installation (SEC-03).
test('keeps the session when the tab is closed and opened again', async ({ page, context }) => {
  await page.goto('/')
  await signIn(page)
  await expect(page.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()
  await page.close()

  const reopened = await context.newPage()
  await reopened.goto('/')

  await expect(reopened.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()
  await expect(reopened).toHaveURL(/\/$/)
})

// NT-2, and the finding that came out of it: closing the *browser* ended the
// session, closing the tab did not. The cookie had no expiry, and a browser
// discards those when it closes — whatever FA-103 promises about 14 days.
//
// A restart is imitated the way a browser performs one: keep the cookies that
// carry an expiry, drop the rest, start again.
test('keeps the session across a restart of the browser', async ({ page, context, browser }) => {
  await page.goto('/')
  await signIn(page)
  await expect(page.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()

  const state = await context.storageState()
  const survivors = state.cookies.filter((cookie) => cookie.expires > 0)

  // Both of them, or neither is any use: with the session cookie gone the
  // user is signed out, with the CSRF cookie gone every write ends in 403
  // (SEC-05) and nothing but signing out recovers.
  expect(survivors.map((cookie) => cookie.name).sort())
    .toEqual(['promptatelier_csrf', 'promptatelier_session'])

  const restarted = await browser.newContext({ storageState: { ...state, cookies: survivors } })
  try {
    const afterRestart = await restarted.newPage()
    await afterRestart.goto(BASE_URL)

    await expect(afterRestart.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()
  } finally {
    await restarted.close()
  }
})

// It used to be a `button--plain`: no border, no background, nothing but the
// name of the account. It read as a label that happened to sit in the corner,
// not as something to press — and the way to sign out is behind it.
test('the account control makes itself known as a button', async ({ page }) => {
  await page.goto('/')
  await signIn(page)

  const account = page.getByRole('button', { name: 'Konto' })
  const border = await account.evaluate((node) => getComputedStyle(node).borderTopColor)

  // Anything but "no colour at all", which is what a transparent border
  // computes to.
  expect(border).not.toBe('rgba(0, 0, 0, 0)')
  await expect(account).toHaveAttribute('aria-expanded', 'false')
})

// NT-2, second half.
test('after signing out the back button does not get in either', async ({ page }) => {
  await page.goto('/')
  await signIn(page)
  await expect(page.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()

  await page.getByRole('button', { name: 'Konto' }).click()
  await page.getByRole('button', { name: 'Abmelden' }).click()
  await expect(page).toHaveURL(/\/login$/)

  await page.goBack()

  // Deliberately not "the sign-in screen is on display": signing out replaces
  // the entry rather than adding one, so the step back leads out of the
  // application altogether — which is the same answer to the question NT-2
  // asks. What is asserted is the expectation itself, not the route it takes.
  await expect(page.getByRole('heading', { name: 'Bibliothek' })).toHaveCount(0)
  await expect(page.getByText('Martin')).toHaveCount(0)

  // And typing the address again does not get in either: the session is gone
  // on the server, not just on the screen (FA-102).
  await page.goto('/')
  await expect(page).toHaveURL(/\/login$/)
})

// The counter-check to the two above: the assertions there would pass just as
// well against an interface that never signs anyone in. This one proves the
// door does open, and that the cookie is what opens it.
test('without the session cookie there is no way in', async ({ page, context }) => {
  await page.goto('/')
  await signIn(page)
  await expect(page.getByRole('heading', { name: 'Bibliothek' })).toBeVisible()

  await context.clearCookies()
  await page.reload()

  await expect(page).toHaveURL(/\/login$/)
})
