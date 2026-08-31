import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { account } from './instance.js'

// Accessibility for W-1 and W-2 (TF-710, TF-711, NFA-11, A-14).
//
// **Three checks, because no one of them carries the promise alone.**
//
// 1. **axe-core** against the WCAG 2.1 AA rule set. Without a tool that really
//    knows the rules, "WCAG 2.1 level AA" would be a claim with a home-made
//    sample underneath it — more promise than check.
// 2. **Contrast, measured and stated as a number.** axe reports violations;
//    here the worst value found also goes into the output, because TF-711 asks
//    for a measurement and not for a tick.
// 3. **A visible focus** at every stop of the keyboard path. axe does not
//    check that: it sees that an element can be reached, not that you can tell
//    where you are standing. A-14 asks for exactly that — "the focus is
//    visible at all times".
//
// Chromium only: the rule set does not depend on the engine, and the same
// check run three times reported the same violation three times.

const { email, password } = account()

test.skip(({ browserName }) => browserName !== 'chromium',
  'The rule set is the same in every engine; checked three times it reports the same violation three times.')

async function signIn (page) {
  await page.goto('/')
  await page.getByLabel('E-Mail-Adresse', { exact: true }).fill(email)
  await page.getByLabel('Passwort', { exact: true }).fill(password)
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click()
  await expect(page.getByRole('banner')).toContainText('Martin')

  await page.getByRole('button', { name: 'Workspace' }).click()
  await page.getByRole('button', { name: 'Marketing', exact: true }).click()
}

async function openTheFilledPrompt (page) {
  await page.getByRole('searchbox').fill('Blogartikel')
  await page.getByRole('button', { name: /Blogartikel-Generator öffnen/ }).click()
  await expect(page.getByRole('heading', { name: 'Blogartikel-Generator' })).toBeVisible()
}

const WCAG = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']

async function auditOf (page) {
  return new AxeBuilder({ page }).withTags(WCAG).analyze()
}

// A violation reads as one line per rule with the elements under it. The
// default report prints an object graph nobody reads.
function describe (violations) {
  return violations.map((violation) =>
    `${violation.id} (${violation.impact}): ${violation.help}\n` +
    violation.nodes.map((node) => `    ${node.target.join(' ')}`).join('\n')
  ).join('\n')
}

// --- WCAG 2.1 AA (NFA-11) ---------------------------------------------------

test('W-1: sign-in, library and prompt pass WCAG 2.1 AA', async ({ page }) => {
  await page.goto('/')
  const login = await auditOf(page)
  expect(describe(login.violations), 'Anmeldeseite').toBe('')

  await signIn(page)
  const library = await auditOf(page)
  expect(describe(library.violations), 'Bibliothek').toBe('')

  await openTheFilledPrompt(page)
  const prompt = await auditOf(page)
  expect(describe(prompt.violations), 'Prompt mit Ausfüllformular').toBe('')

  // A check that checked nothing also reports zero violations.
  expect(prompt.passes.length, 'die Prüfung hat überhaupt Regeln angewandt').toBeGreaterThan(10)
})

test('W-2: the editor passes WCAG 2.1 AA', async ({ page }) => {
  await signIn(page)
  await page.getByRole('link', { name: 'Neu' }).click()
  await expect(page.getByRole('heading', { name: 'Neuer Prompt' })).toBeVisible()

  const empty = await auditOf(page)
  expect(describe(empty.violations), 'leerer Editor').toBe('')

  // And with content: the variable list, the preview and the messages only come
  // into being while typing — an empty form checks half the page.
  await page.getByLabel('Titel', { exact: true }).fill('Barrierefreiheitsprobe')
  await page.getByLabel('Prompt-Text', { exact: true })
    .fill('Schreibe ein Angebot für {{kunde}} über {{leistung}}.')
  await expect(page.getByText('2 erkannte Variablen')).toBeVisible()

  const filled = await auditOf(page)
  expect(describe(filled.violations), 'Editor mit Text und Variablen').toBe('')
})

// --- TF-711: contrast, measured ---------------------------------------------

test('TF-711: every visible text holds at least 4.5:1', async ({ page }) => {
  await signIn(page)
  await openTheFilledPrompt(page)

  const worst = await page.evaluate(measureContrast)

  console.log(`TF-711 Kontrast: schlechtester Wert ${worst.ratio.toFixed(2)}:1 ` +
              `bei ${worst.where} ("${worst.text}"), ${worst.checked} Textstellen geprüft`)

  expect(worst.checked, 'with no text places checked, any claim is true').toBeGreaterThan(20)
  expect(worst.ratio).toBeGreaterThanOrEqual(worst.required)
})

// --- TF-710: the focus is visible at all times -------------------------------

// A-14 asks for both: the path can be walked without a mouse (workflow.spec.js
// checks that) **and** you can see at all times where you are. The second is
// what gets lost while building: an `outline: none` somewhere in a stylesheet
// takes it away without breaking a single flow.
test('TF-710: every stop of the keyboard path shows the focus', async ({ page }) => {
  await signIn(page)

  // Both screens of W-1, each from the top. The search box is in the library;
  // the prompt page has none, and a walk that carried on there would never have
  // started in the first place.
  const library = await walkTheTabOrder(page)
  await openTheFilledPrompt(page)
  const prompt = await walkTheTabOrder(page)

  const visited = library.visited + prompt.visited
  console.log(`TF-710: ${visited} Stationen abgelaufen, ${library.invisible.length + prompt.invisible.length} ohne sichtbaren Fokus`)

  // A path with no stops would pass any claim made about it.
  expect(visited, 'the tab order has any stops at all').toBeGreaterThan(8)
  expect([...library.invisible, ...prompt.invisible]
    .map((station) => `${station.where}: ${station.reason}`).join('\n')).toBe('')
})

// Tabs through from the top of the page and reports the stops with no visible
// focus. Stops as soon as the focus comes back round — otherwise the loop would
// run out through the browser's address bar and back in again.
async function walkTheTabOrder (page, steps = 30) {
  await page.locator('body').press('Tab')
  const invisible = []
  const seen = new Set()

  for (let step = 0; step < steps; step++) {
    const station = await page.evaluate(focusIndicator)
    if (!station) break
    if (seen.has(station.key)) break

    seen.add(station.key)
    if (!station.visible) invisible.push(station)
    await page.keyboard.press('Tab')
  }

  return { visited: seen.size, invisible }
}

// --- what runs inside the page -----------------------------------------------

// The worst contrast on the page. Every visible text node is measured against
// the background that really lies behind it: `background-color` is usually
// transparent, and then the nearest ancestor that sets one counts.
function measureContrast () {
  const luminance = (rgb) => {
    const [r, g, b] = rgb.map((value) => {
      const channel = value / 255
      return channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4
    })
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }

  const parse = (color) => {
    const parts = color.match(/[\d.]+/g)
    if (!parts) return null
    const alpha = parts.length > 3 ? Number(parts[3]) : 1
    return { rgb: parts.slice(0, 3).map(Number), alpha }
  }

  const backgroundBehind = (element) => {
    for (let node = element; node; node = node.parentElement) {
      const parsed = parse(getComputedStyle(node).backgroundColor)
      if (parsed && parsed.alpha > 0.5) return parsed.rgb
    }
    return [255, 255, 255]
  }

  const ratio = (front, back) => {
    const a = luminance(front)
    const b = luminance(back)
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
  }

  // WCAG 1.4.3: large text may do 3:1, everything else 4.5:1. Large means from
  // 24 px, or from 18.66 px when bold.
  const requiredFor = (style) => {
    const size = parseFloat(style.fontSize)
    const bold = Number(style.fontWeight) >= 700
    return size >= 24 || (bold && size >= 18.66) ? 3 : 4.5
  }

  let worst = { ratio: Infinity, required: 4.5, where: '—', text: '', checked: 0 }
  let checked = 0

  for (const element of document.querySelectorAll('body *')) {
    const own = [...element.childNodes]
      .filter((node) => node.nodeType === Node.TEXT_NODE)
      .map((node) => node.textContent.trim())
      .join(' ')
      .trim()
    if (!own) continue

    const style = getComputedStyle(element)
    if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) < 0.1) continue
    if (element.getBoundingClientRect().width === 0) continue

    const front = parse(style.color)
    if (!front) continue

    checked++
    const value = ratio(front.rgb, backgroundBehind(element))
    const required = requiredFor(style)
    // The worst one **relative to its own requirement**: 3.2:1 on large text
    // is fine, 4.4:1 on small text is not.
    if (value / required < worst.ratio / worst.required) {
      worst = {
        ratio: value,
        required,
        where: `${element.tagName.toLowerCase()}${element.className ? '.' + String(element.className).split(' ')[0] : ''}`,
        text: own.slice(0, 40),
        checked
      }
    }
  }

  worst.checked = checked
  return worst
}

// Whether the element that currently holds the focus looks like it does.
// The state with and without focus is compared: `:focus-visible` cannot be
// queried, but the difference can.
function focusIndicator () {
  const element = document.activeElement
  if (!element || element === document.body) return null

  const snapshot = (node) => {
    const style = getComputedStyle(node)
    return {
      outline: `${style.outlineStyle} ${style.outlineWidth} ${style.outlineColor}`,
      shadow: style.boxShadow,
      border: `${style.borderColor} ${style.borderWidth}`,
      background: style.backgroundColor
    }
  }

  const focused = snapshot(element)
  element.blur()
  const blurred = snapshot(element)
  element.focus()

  const where = `${element.tagName.toLowerCase()}` +
    (element.getAttribute('aria-label') || element.textContent || '').trim().slice(0, 30)

  // A **node-exact** key beside the readable one. `where` is a name and two
  // different controls can share it — two checkboxes whose labels agree in the
  // first thirty characters, for instance. Used as the stop condition it ends
  // the walk early and silently: after the selection boxes arrived in the
  // library the walk covered 31 stops instead of 33, and nothing said so.
  const key = [...document.querySelectorAll('*')].indexOf(element)

  const outlineDrawn = focused.outline !== 'none 0px' &&
    !focused.outline.startsWith('none') && parseFloat(focused.outline.split(' ')[1]) > 0
  const changed = JSON.stringify(focused) !== JSON.stringify(blurred)

  if (outlineDrawn) return { where, key, visible: true }
  if (changed) return { where, key, visible: true }

  return { where, key, visible: false, reason: 'no outline and no visible change against the unfocused state' }
}
