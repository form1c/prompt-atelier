import { test, expect } from '@playwright/test'
import { account } from './instance.js'

// S1 in a real browser, against the real server and the fixture of test
// concept 4.3 (Requirements 11.3, FA-501 to FA-509).
//
// What only this level shows is the whole chain in one piece: the filter in
// the address, the request that comes out of it, the visibility rule on the
// server, and the line that ends up on the screen. Every step of it is tested
// on its own elsewhere; none of those tests would notice if two of them
// stopped fitting together.

const { email, password } = account()

async function signIn (page) {
  await page.goto('/')
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(email)
  await page.getByLabel('Passwort', { exact: true }).fill(password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText('Martin')
}

// `name` may be a string or a pattern. The personal workspace carries the note
// "persönlich" inside its button, so its accessible name is longer than its
// name — `exact` would demand the note as well.
async function switchTo (page, name) {
  await page.getByRole('button', { name: 'Workspace' }).click()
  await page.getByRole('button', { name, exact: typeof name === 'string' }).click()
}

test.beforeEach(async ({ context }) => {
  await context.clearCookies()
})

// The personal workspace is empty, and W-6 says this screen must not be a
// blank surface.
//
// The workspace is chosen **here** rather than relied upon. It used to rest on
// being the first test in the run to sign in: the choice is remembered on the
// server (FA-605), so any earlier test that switched to Marketing left this one
// looking at a full library. It stayed green for as long as this file happened
// to sort first, and went red the day another file was added before it. What a
// test needs, it should establish.
test('explains in the empty personal workspace what a prompt is', async ({ page }) => {
  await signIn(page)
  await switchTo(page, /^Persönlicher Workspace/)

  await expect(page.getByRole('heading', { name: 'Noch keine Prompts' })).toBeVisible()
  await expect(page.getByText('Platzhalter')).toBeVisible()
})

test('shows the prompts of the workspace after switching', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Marketing')

  await expect(page.getByRole('button', { name: /P-WS öffnen/ })).toBeVisible()

  // The full line of 11.3, on the one prompt of the instance that has
  // everything on it: description, tags, author, and the number of variables.
  const line = page.getByRole('button', { name: /Blogartikel-Generator öffnen/ })
  await expect(line).toContainText('Erstellt SEO-Artikel zu beliebigem Thema')
  await expect(line).toContainText('content · seo')
  await expect(line).toContainText('Sabine')
  await expect(line).toContainText('{{2}}')

  // The visibility rule reaches the screen: a private prompt of somebody else
  // is not on it (SEC-06, FA-502).
  await expect(page.getByRole('button', { name: /P-PRIV-S öffnen/ })).toHaveCount(0)
  // Nor is an archived one, until it is asked for (11.3).
  await expect(page.getByRole('button', { name: /P-ARCH öffnen/ })).toHaveCount(0)
})

test('searches while typing and keeps the term in the address', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Marketing')

  await page.getByRole('searchbox').fill('P-EDIT')

  await expect(page.getByRole('button', { name: /P-EDIT öffnen/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /P-WS öffnen/ })).toHaveCount(0)
  await expect(page).toHaveURL(/search=P-EDIT/)
})

// FA-506: the address is the state, so a link carries the filtered view with
// it. This is the half that cannot be tested without a browser — a fresh page
// load has to arrive at the same screen.
test('restores a shared link with its filters', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Marketing')
  await page.getByRole('searchbox').fill('P-EDIT')
  await expect(page).toHaveURL(/search=P-EDIT/)

  const shared = page.url()
  await page.goto('/')
  await page.goto(shared)

  await expect(page.getByRole('searchbox')).toHaveValue('P-EDIT')
  await expect(page.getByRole('button', { name: /P-EDIT öffnen/ })).toBeVisible()
})

// The archived prompt appears only on request — from both sides, because a
// filter that shows everything always would pass the first half alone.
test('shows archived prompts only when asked explicitly', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Marketing')
  await expect(page.getByRole('button', { name: /P-ARCH öffnen/ })).toHaveCount(0)

  await page.getByRole('button', { name: 'Nur archivierte' }).click()

  await expect(page.getByRole('button', { name: /P-ARCH öffnen/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /P-WS öffnen/ })).toHaveCount(0)
})

// A filter that is on has to look it. `aria-pressed` was set from the start,
// so a test on the attribute would have passed while the library sat filtered
// down to the favourites with nothing on the screen saying so.
//
// The colour is therefore read out of the browser rather than out of the
// stylesheet: what is being checked is that pressing the button changes how it
// looks, not that a rule exists somewhere (11.6).
test('shows a filter that is on that it is on', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Marketing')

  const paint = (name) => page.getByRole('button', { name }).evaluate((node) => {
    const style = getComputedStyle(node)
    return `${style.backgroundColor} ${style.borderTopColor} ${style.fontWeight}`
  })

  await page.getByRole('button', { name: 'Nur archivierte' }).click()
  await expect(page.getByRole('button', { name: 'Nur archivierte' })).toHaveAttribute('aria-pressed', 'true')

  // The pointer has to be away before anything is measured. What was compared
  // at first was the same button before and after the click — and the test was
  // green **because** the pointer stood on it afterwards: `:hover` alone
  // already recolours it. The mutation probe found that by removing the rule
  // and the test not noticing.
  await page.mouse.move(0, 0)

  const on = await paint('Nur archivierte')
  const off = await paint('Nur Favoriten')

  // Two buttons of the same kind at the same moment: the one switched on has
  // to look different from the one switched off beside it.
  expect(on).not.toBe(off)
})

// FA-509. Without this view the instance-wide visibility would be pointless:
// nobody could find such a prompt.
test('finds instance-wide prompts of others in the overall view', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Alle Workspaces')

  const line = page.getByRole('button', { name: /P-INST öffnen/ })
  await expect(line).toBeVisible()
  // The origin is on the line, and only here (11.3).
  await expect(line).toContainText('Marketing')
  // 11.2: no management entries in this view, they would have no workspace.
  await expect(page.getByRole('navigation')).not.toContainText('Verwaltung')
})

// NFA-01 rests on this: type, press Enter, and the first hit has the focus.
test('leads from the search box into the list with the keyboard', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Marketing')

  // Typed and confirmed straight away — no waiting in between, because that
  // is how people use a search field. The pause after the last keystroke is
  // still running at this point, and the list still shows everything.
  await page.getByRole('searchbox').fill('P-EDIT')
  await page.getByRole('searchbox').press('Enter')

  await expect(page.getByRole('button', { name: /P-EDIT öffnen/ })).toBeFocused()
  await expect(page.getByRole('button', { name: /P-WS öffnen/ })).toHaveCount(0)
})

// FA-505: the star belongs to the person, and it survives a reload because it
// is kept on the server rather than in the page.
test('remembers a favourite across a reload', async ({ page }) => {
  await signIn(page)
  await switchTo(page, 'Marketing')

  await page.getByRole('button', { name: 'Als Favorit merken' }).first().click()
  await page.reload()

  await expect(page.getByRole('button', { name: 'Aus den Favoriten nehmen' })).toHaveCount(1)
})
