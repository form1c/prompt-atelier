import { test, expect } from '@playwright/test'
import { account, BASE_URL } from './instance.js'

// TF-714 / NFA-13 — no outgoing traffic, no third-party sources.
//
// Searching the built bundle for addresses in loading position has been
// automated since AP-09 (`bundle_sources.test.js`). That sees what the code
// **says**. This file sees what the browser **does**, and the two are not the
// same: an address can be assembled at runtime, a font pulled in by `@font-face`
// from inside a stylesheet, an image arrive through a `srcset` that no search
// for `.src=` would ever find.
//
// **It is also the counter-check to SEC-11.** A strict content security policy
// is worth nothing if the bundle contains foreign sources: the browser blocks
// them and the page stays half empty. A blocked request still shows up here —
// `page.on('request')` fires before the policy applies — and that is exactly
// why this is the better of the two checks.
//
// Runs in all three engines: what each of them fetches of its own accord (an
// icon, a font, a connectivity probe) differs between them, and the promise
// holds for all of them.

const { email, password } = account()

// What a request may be: this instance, or no network at all.
const isOwn = (url) =>
  url.startsWith(BASE_URL) || url.startsWith('data:') || url.startsWith('blob:') ||
  url.startsWith('about:')

function watchTheNetwork (page) {
  const foreign = []
  page.on('request', (request) => {
    if (!isOwn(request.url())) foreign.push(`${request.method()} ${request.url()} (${request.resourceType()})`)
  })
  return foreign
}

test('TF-714: the application calls no foreign address while running', async ({ page }) => {
  const foreign = watchTheNetwork(page)

  // The whole core path, not one page: things are fetched on navigation, and a
  // sign-in page alone has never loaded half the application.
  await page.goto('/')
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(email)
  await page.getByLabel('Passwort', { exact: true }).fill(password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText('Martin')

  await page.getByRole('button', { name: 'Workspace' }).click()
  await page.getByRole('button', { name: 'Marketing', exact: true }).click()

  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()
  await expect(page.getByRole('heading', { name: 'Blogartikel-Generator' })).toBeVisible()
  await page.getByLabel(/thema/i).fill('Kaffeezubereitung')
  await expect(page.locator('[data-test="preview"]')).toContainText('Kaffeezubereitung')

  await page.getByRole('link', { name: 'Neu' }).click()
  await expect(page.getByRole('heading', { name: 'Neuer Prompt' })).toBeVisible()

  expect(foreign.join('\n')).toBe('')
})

// The counter-check: a case that records nothing also reports "no foreign
// address". Without this one, the case above would be a statement about a
// recording that might not exist at all.
test('the recording sees any calls at all', async ({ page }) => {
  const seen = []
  page.on('request', (request) => seen.push(request.url()))

  await page.goto('/')
  await expect(page.getByRole('button', { name: 'Anmelden', exact: true })).toBeVisible()

  expect(seen.length, 'not a single request observed, so the case beside it checks nothing')
    .toBeGreaterThan(2)
  expect(seen.every(isOwn)).toBe(true)
})
