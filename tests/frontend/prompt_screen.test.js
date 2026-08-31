import { describe, it, expect, afterEach, beforeEach, vi } from 'vitest'
import { h } from 'vue'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import { installFakeServer, signedInRoutes, apiError } from './support/fake_server.js'

// S2 — the prompt in use (Requirements 11.4, FA-303 to FA-306).
//
// The screen the whole application exists for. What is tested here is what
// the ten seconds of NFA-01 are made of: the form is filled in, the preview
// follows, the copy either lands in the clipboard or is put where it can be
// selected by hand.

const realFetch = globalThis.fetch

// Longer than the pause the preview waits for after an input.
const AFTER_TYPING = 220

const KEYWORDS = [
  { id: 1, name: 'rolle', text: 'Du bist ein erfahrener Fachautor.', position: 'prepend', sort_order: 10 },
  { id: 2, name: 'formal', text: 'Schreibe in einem sachlichen Ton.', position: 'append', sort_order: 10 }
]

function promptDetail (overrides = {}) {
  return {
    id: 5,
    workspace_id: 9,
    owner_id: 1,
    title: 'Blogartikel-Generator',
    description: 'Erstellt SEO-Artikel zu beliebigem Thema',
    body: 'Schreibe einen Blogartikel über {{thema}} für {{zielgruppe}}.',
    visibility: 'workspace',
    status: 'active',
    favorite: false,
    tags: ['seo'],
    updated_at: new Date().toISOString(),
    revision_count: 0,
    variables: [
      { key: 'thema', label: 'Thema', type: 'text', default_value: null, required: true, position: 0 },
      { key: 'zielgruppe', label: 'Zielgruppe', type: 'select', default_value: 'Einsteiger', options: 'Einsteiger\nProfis', required: false, position: 1 }
    ],
    keywords: [KEYWORDS[0]],
    permissions: { update: true, delete: true, duplicate: true, move: true, visibility: true },
    ...overrides
  }
}

// A prompt whose empty field is optional, so both copy buttons are usable at
// the same moment and can be held against each other.
function optionalPrompt () {
  return promptDetail({
    body: 'Schreibe einen Blogartikel über {{thema}} für {{zielgruppe}}.',
    variables: [
      { key: 'thema', label: 'Thema', type: 'text', default_value: null, required: false, position: 0 },
      { key: 'zielgruppe', label: 'Zielgruppe', type: 'text', default_value: 'Einsteiger', required: false, position: 1 }
    ]
  })
}

function routesFor (prompt = promptDetail(), keywords = KEYWORDS) {
  return [
    ...signedInRoutes(),
    { method: 'GET', path: `/prompts/${prompt.id}`, body: { prompt } },
    { method: 'GET', path: '/keywords', body: { keywords } }
  ]
}

// Every mounted screen is taken down again afterwards. The copy shortcut
// listens on `window`, so a screen left standing keeps reacting — and the
// next test would see its own key press answered several times over. In the
// browser this cannot happen (there is one screen, and leaving it unmounts
// it); in a test file that mounts nineteen of them it can.
const mounted = []

async function screen ({ routes = routesFor(), at = '/prompt/5', extraRoutes = [] } = {}) {
  const server = installFakeServer(routes)
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')

  const router = createAppRouter(createMemoryHistory())
  for (const route of extraRoutes) router.addRoute(route)

  const wrapper = mount(App, { global: { plugins: [router] }, attachTo: document.body })
  mounted.push(wrapper)
  await router.push(at)
  await settle()

  return { wrapper, router, server }
}

const previewText = (wrapper) => wrapper.find('[data-test="preview"]').text()

// The preview without the placeholders drawn into it (8.3.1). Close to what a
// copy contains, but not the same string: the preview lays itself out around
// the placeholders, so taking them out leaves the whitespace they were holding
// apart. Normalising it gives the copy back — that equality is checked where
// it belongs, in preview_marks.test.js.
//
// `textContent` rather than the wrapper's own `text()`, which trims each
// piece — joining trimmed pieces would quietly swallow the spaces between
// them, which is precisely where the gaps are.
const withoutSlots = (wrapper) => wrapper.findAll('[data-test="preview"] span')
  .filter((span) => !span.classes('slot--empty') && !span.classes('slot--missing'))
  .map((span) => span.element.textContent)
  .join('')

const copyButton = (wrapper) => wrapper.find('[data-test="copy"]')
const rawCopyButton = (wrapper) => wrapper.find('[data-test="copy-raw"]')

async function type (wrapper, selector, value) {
  await wrapper.find(selector).setValue(value)
  await new Promise((resolve) => setTimeout(resolve, AFTER_TYPING))
  await settle()
}

beforeEach(() => {
  globalThis.localStorage?.clear?.()
})

afterEach(() => {
  while (mounted.length) mounted.pop().unmount()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('Filling in and preview', () => {
  it('shows one field per variable by type, prefilled with the default value', async () => {
    const { wrapper } = await screen()

    // FA-303: a field per variable, by type, in the order of `position`.
    // Scoped to the form: the head line carries selects of its own.
    expect(wrapper.find('input[type="text"]').exists()).toBe(true)
    expect(wrapper.find('.fill select').element.value).toBe('Einsteiger')
    expect(wrapper.text()).toContain('Thema')
    expect(wrapper.text()).toContain('Zielgruppe')
  })

  // TF-450 — all four types from 7.1, and in one go. Until here only `text`
  // and `select` had been checked; `number` occurs eight times in the example
  // package and had not a single case. A wrong field shows up on screen only
  // if one opens the prompt that uses it.
  it('shows the matching field for each of the four variable types', async () => {
    const alleTypen = promptDetail({
      body: '{{frei}} {{lang}} {{wahl}} {{anzahl}}',
      variables: [
        { key: 'frei', label: 'Frei', type: 'text', required: false, position: 0 },
        { key: 'lang', label: 'Lang', type: 'multiline', required: false, position: 1 },
        { key: 'wahl', label: 'Wahl', type: 'select', options: 'Eins\nZwei', required: false, position: 2 },
        // `anzahl`, not `zahl`: a variable name that happens to read exactly
        // like a former domain value is indistinguishable from a leftover of
        // AP-18 — for TF-463 and for the next reader alike.
        { key: 'anzahl', label: 'Zahl', type: 'number', required: false, position: 3 }
      ],
      keywords: []
    })
    const { wrapper } = await screen({ routes: routesFor(alleTypen) })

    expect(wrapper.find('.fill input[type="text"]').exists()).toBe(true)
    expect(wrapper.find('.fill textarea').exists()).toBe(true)
    expect(wrapper.find('.fill select').exists()).toBe(true)
    expect(wrapper.find('.fill input[type="number"]').exists()).toBe(true)

    // And a number arrives in the preview as a number too.
    await type(wrapper, '.fill input[type="number"]', '150')
    expect(previewText(wrapper)).toContain('150')
  })

  // FA-303: sorted by `position`, not by the order they arrive in and not by
  // where they stand in the text. The two usually agree — the editor can pull
  // them apart, and whoever wrote the prompt knows better than the parser
  // which question comes first.
  it('orders the fields by position, not by the order of the answer', async () => {
    // Three fields, and the answer in none of the orders the screen could
    // produce by accident. With two, "reversed" and "sorted" are the same
    // thing whenever the answer arrives backwards — a mutation probe walked
    // straight through the first version of this case.
    const shuffled = promptDetail({
      variables: [
        { key: 'thema', label: 'Thema', type: 'text', required: false, position: 2 },
        { key: 'ton', label: 'Ton', type: 'text', required: false, position: 0 },
        { key: 'zielgruppe', label: 'Zielgruppe', type: 'text', required: false, position: 1 }
      ],
      body: '{{ton}} {{zielgruppe}} {{thema}}'
    })
    const { wrapper } = await screen({ routes: routesFor(shuffled) })

    // The first span of each field is its label; the second, when there is
    // one, is the message about a missing value.
    const labels = wrapper.findAll('.fill .field').map((field) => field.find('span').text())
    expect(labels).toEqual(['Ton', 'Zielgruppe', 'Thema'])
  })

  // FA-304 and the point of the whole screen: the preview renders here, with
  // the same pipeline the server uses.
  it('renders the preview in the browser without asking the server', async () => {
    const { wrapper, server } = await screen()

    await type(wrapper, 'input[type="text"]', 'Kaffeezubereitung')

    expect(previewText(wrapper)).toBe(
      'Du bist ein erfahrener Fachautor.\n\n' +
      'Schreibe einen Blogartikel über Kaffeezubereitung für Einsteiger.'
    )
    // Not one request per keystroke — that is what having the pipeline twice
    // is for (NFA-14).
    expect(server.callsTo('POST', '/render')).toHaveLength(0)
  })

  it('waits for the typing pause before it sets the preview anew', async () => {
    const { wrapper } = await screen()
    const before = previewText(wrapper)

    await wrapper.find('input[type="text"]').setValue('Kaffee')
    await settle()

    expect(previewText(wrapper)).toBe(before)

    await new Promise((resolve) => setTimeout(resolve, AFTER_TYPING))
    await settle()

    expect(previewText(wrapper)).toContain('Kaffee')
  })

  it('names the characters and words of the result', async () => {
    const { wrapper } = await screen()
    await type(wrapper, 'input[type="text"]', 'Kaffee')

    const characters = [...previewText(wrapper)].length
    expect(wrapper.text()).toContain(`${characters} characters`)
  })

  // 11.4: the default keywords are on, and switching one is a single click.
  it('has the default keywords on and toggles them', async () => {
    const { wrapper } = await screen()
    expect(previewText(wrapper)).toContain('Du bist ein erfahrener Fachautor.')

    const chip = wrapper.findAll('button').find((entry) => entry.text() === 'rolle')
    expect(chip.attributes('aria-pressed')).toBe('true')

    await chip.trigger('click')
    await new Promise((resolve) => setTimeout(resolve, AFTER_TYPING))
    await settle()

    expect(previewText(wrapper)).not.toContain('Du bist ein erfahrener Fachautor.')
  })

  it('shows no form for a prompt without variables', async () => {
    const { wrapper } = await screen({
      routes: routesFor(promptDetail({ body: 'Fasse den Text zusammen.', variables: [], keywords: [] }))
    })

    expect(wrapper.find('input[type="text"]').exists()).toBe(false)
    expect(wrapper.text()).toContain('no variables')
    expect(previewText(wrapper)).toBe('Fasse den Text zusammen.')
  })
})

describe('Copying', () => {
  // TF-401: the preview appears, the spot is marked, copying is blocked.
  //
  // All three bullets of 8.3, and the first one used to be missing here. The
  // case checked the marked *field* — the third bullet — and passed, while
  // "die Fundstelle wird optisch markiert" had never been built. A test that
  // carries a requirement's number has to check the whole sentence.
  it('blocks copying while a required value is missing', async () => {
    const { wrapper } = await screen()

    // A variable nobody filled in occupies no characters, so there is nothing
    // in the text to point at. The placeholder is drawn back in — that is the
    // spot.
    const gap = wrapper.find('[data-test="preview"] .slot--missing')
    expect(gap.exists()).toBe(true)
    expect(gap.text()).toBe('{{thema}}')

    // And it stays a drawing: the preview is produced anyway and still has the
    // gap where the value belongs.
    expect(withoutSlots(wrapper)).toContain('Schreibe einen Blogartikel über  für Einsteiger.')

    expect(wrapper.find('input[type="text"]').attributes('aria-invalid')).toBe('true')
    expect(copyButton(wrapper).attributes('disabled')).toBeDefined()
    expect(wrapper.text()).toContain('required fields')
  })

  it('releases copying as soon as the value is there', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    const { wrapper } = await screen()
    await type(wrapper, 'input[type="text"]', 'Kaffee')

    expect(copyButton(wrapper).attributes('disabled')).toBeUndefined()

    await copyButton(wrapper).trigger('click')
    await settle()

    expect(written).toHaveBeenCalledWith(previewText(wrapper))
    expect(wrapper.text()).toContain('Copied to the clipboard.')
  })

  // TF-416: the browser refuses. The text has to end up somewhere the reader
  // can select it — that is something no setting can take away.
  it('offers the text for selecting when the clipboard is refused', async () => {
    vi.stubGlobal('navigator', { clipboard: { writeText: vi.fn().mockRejectedValue(new Error('nope')) } })

    const { wrapper } = await screen()
    await type(wrapper, 'input[type="text"]', 'Kaffee')
    await copyButton(wrapper).trigger('click')
    await settle()

    const fallback = wrapper.find('textarea[readonly]')
    expect(fallback.exists()).toBe(true)
    expect(fallback.element.value).toBe(previewText(wrapper))
    expect(wrapper.text()).toContain('refused')
  })

  it('copes even without a clipboard in the browser', async () => {
    vi.stubGlobal('navigator', {})

    const { wrapper } = await screen()
    await type(wrapper, 'input[type="text"]', 'Kaffee')
    await copyButton(wrapper).trigger('click')
    await settle()

    expect(wrapper.find('textarea[readonly]').exists()).toBe(true)
  })

  // 11.6: Strg+Enter works anywhere on the screen — the hands are in the
  // form, not on the button.
  it('copies with Ctrl+Enter as well', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    const { wrapper } = await screen()
    await type(wrapper, 'input[type="text"]', 'Kaffee')

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true }))
    await settle()

    expect(written).toHaveBeenCalledTimes(1)
  })

  // The counter-check to the block above: the shortcut must not copy what the
  // block forbids.
  it('does not copy with Ctrl+Enter while the required value is missing', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    const { wrapper } = await screen()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true }))
    await settle()

    expect(written).not.toHaveBeenCalled()
    expect(wrapper.text()).not.toContain('Copied to the clipboard.')
  })

  // Typing the last required value and copying straight away — the pause for
  // the preview is still running at that moment. Before the order was put
  // right, the check saw the value as still missing and the shortcut answered
  // with nothing at all: no copy, no message, no explanation. Found in the
  // browser, where that is exactly how the workflow is performed.
  it('copies right after the last required value, without waiting for the pause', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    const { wrapper } = await screen()
    await wrapper.find('input[type="text"]').setValue('Kaffee')
    await settle()

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true }))
    await settle()

    expect(written).toHaveBeenCalledWith(expect.stringContaining('Kaffee'))
    expect(wrapper.text()).toContain('Copied to the clipboard.')
  })

  // The pause after the last keystroke may still be running when the button
  // is pressed. Copying what is on the screen rather than what was just typed
  // would be the worst of both.
  it('copies the last entry even while the preview is still waiting', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    const { wrapper } = await screen()
    await type(wrapper, 'input[type="text"]', 'Kaffee')
    await wrapper.find('input[type="text"]').setValue('Kaffeezubereitung')
    await settle()

    await copyButton(wrapper).trigger('click')
    await settle()

    expect(written).toHaveBeenCalledWith(expect.stringContaining('Kaffeezubereitung'))
  })
})

// TF-443 — where the finished text came from (8.3.1, 11.4).
//
// The colouring itself is a matter of taste; what is tested is the promise
// underneath it. A piece the screen paints as a value has to be a value, and a
// placeholder has to be a drawing that no copy carries away.
describe('Provenance in the preview', () => {
  const optional = () => promptDetail({
    body: 'Zum Thema {{thema}} für {{gruppe}}.',
    variables: [
      { key: 'thema', label: 'Thema', type: 'text', required: false, position: 0 },
      { key: 'gruppe', label: 'Gruppe', type: 'text', default_value: 'Einsteiger', required: false, position: 1 }
    ],
    keywords: []
  })

  it('highlights the value that was put in', async () => {
    const { wrapper } = await screen({ routes: routesFor(optional()) })
    await type(wrapper, 'input[type="text"]', 'Kaffee')

    const values = wrapper.findAll('[data-test="preview"] .slot--value')
    expect(values.map((piece) => piece.text())).toEqual(['Kaffee', 'Einsteiger'])
  })

  // The variable left empty by choice: placeholder yes, block no. Exactly the
  // distinction 8.3 makes — what is marked is the spot, what blocks is only a
  // missing required value.
  it('shows an empty optional variable as a placeholder without blocking copying', async () => {
    const { wrapper } = await screen({ routes: routesFor(optional()) })

    const slot = wrapper.find('[data-test="preview"] .slot--empty')
    expect(slot.exists()).toBe(true)
    expect(slot.text()).toBe('{{thema}}')
    expect(wrapper.find('[data-test="preview"] .slot--missing').exists()).toBe(false)
    expect(copyButton(wrapper).attributes('disabled')).toBeUndefined()
  })

  // The point at which display and clipboard may part company — and the only
  // one at which that is ever meant to hold.
  it('does not write the placeholder to the clipboard', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    const { wrapper } = await screen({ routes: routesFor(optional()) })

    expect(previewText(wrapper)).toContain('{{thema}}')

    await copyButton(wrapper).trigger('click')
    await settle()

    expect(written).toHaveBeenCalledWith('Zum Thema  für Einsteiger.')
  })

  // Reported by the client on "Protokollauszug deuten" from the example data.
  // A multiline variable alone between two blank lines — the usual shape for
  // this type, and present in no test case: they all used single-line texts.
  //
  // If nothing stands in it, the four line breaks in the finished text
  // collapse to two. That is why the placeholder stuck to the sentence that
  // followed. The preview now lays the text **around** the placeholder.
  it('leaves the blank lines around an empty multiline variable alone', async () => {
    const protokoll = promptDetail({
      body: 'Deute diesen Protokollauszug:\n\n{{auszug}}\n\nWas ist passiert?',
      variables: [{ key: 'auszug', label: 'Auszug', type: 'multiline', required: true, position: 0 }],
      keywords: []
    })
    const { wrapper } = await screen({ routes: routesFor(protokoll) })

    expect(previewText(wrapper)).toBe(
      'Deute diesen Protokollauszug:\n\n{{auszug}}\n\nWas ist passiert?'
    )

    // Filled in, the value stands in the same place, with the same gaps.
    await type(wrapper, 'textarea', 'Zeile 1\nZeile 2')

    expect(previewText(wrapper)).toBe(
      'Deute diesen Protokollauszug:\n\nZeile 1\nZeile 2\n\nWas ist passiert?'
    )
  })

  // The note has to name **which** button does what. Two buttons that both
  // copy, one leaving the empty placeholders out and one taking them along, is
  // exactly the distinction somebody cannot guess from the labels alone.
  it('says on screen which button takes the placeholders along', async () => {
    const { wrapper } = await screen({ routes: routesFor(optional()) })

    expect(wrapper.text()).toContain('“Copy” leaves them out')
    expect(wrapper.text()).toContain('hands over the prompt with all of them')
  })

  it('shows no note once nothing is empty any more', async () => {
    const { wrapper } = await screen({ routes: routesFor(optional()) })
    await type(wrapper, 'input[type="text"]', 'Kaffee')

    expect(wrapper.find('[data-test="preview"] .slot--empty').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('nicht mitkopiert')
  })
})

// FA-305, second way — the prompt with its placeholders left standing, for
// whoever wants to finish it in another editor.
describe('Copying with placeholders', () => {
  it('is possible even when a required value is missing', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    const { wrapper } = await screen()

    expect(copyButton(wrapper).attributes('disabled')).toBeDefined()
    expect(rawCopyButton(wrapper).attributes('disabled')).toBeUndefined()

    await rawCopyButton(wrapper).trigger('click')
    await settle()

    expect(written.mock.calls[0][0]).toContain('{{thema}}')
    expect(wrapper.text()).toContain('Copied to the clipboard with placeholders.')
  })

  // **Every** placeholder, whatever is filled in — the change that came out of
  // NT-7. The button used to copy the preview, so somebody who had filled the
  // fields in got a text with no placeholders left under a button that
  // promises them. What it keeps from the screen are the switched-on keywords:
  // those are not variables, and leaving them out would hand over a prompt
  // that is not the one on display.
  it('keeps every placeholder and takes the switched-on keywords along', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    const { wrapper } = await screen()
    await type(wrapper, 'input[type="text"]', 'Kaffee')
    await wrapper.find(`[data-id="${KEYWORDS[1].id}"]`).trigger('click')
    await settle()

    await rawCopyButton(wrapper).trigger('click')
    await settle()

    const copied = written.mock.calls[0][0]
    expect(copied).toContain('{{thema}}')
    expect(copied).not.toContain('Kaffee')
    // Not even the default value of the optional variable: a default is a
    // value, and this button hands over the template.
    expect(copied).toContain('{{zielgruppe}}')
    expect(copied).not.toContain('Einsteiger')
    // The keywords do belong in it — they are not variables.
    expect(copied).toContain('Du bist ein erfahrener Fachautor.')
    expect(copied).toContain('Schreibe in einem sachlichen Ton.')
  })

  // The one thing that separates the two buttons, stated as a difference
  // rather than as two facts: on the same screen, in the same moment, one
  // leaves the empty placeholder out and the other takes it along.
  it('differs from plain copying by exactly the empty placeholders', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    // A prompt whose only empty field is **optional**: `Copy` is therefore
    // allowed, and the difference between the two buttons is the one thing
    // left over. With a mandatory field the comparison could not be made at
    // all, because one of the two buttons would be barred.
    const { wrapper } = await screen({ routes: routesFor(optionalPrompt()) })
    await settle()

    await copyButton(wrapper).trigger('click')
    await settle()
    await rawCopyButton(wrapper).trigger('click')
    await settle()

    const [finished, withSlots] = written.mock.calls.map((call) => call[0])
    expect(finished).not.toContain('{{thema}}')
    expect(withSlots).toContain('{{thema}}')
    // And the difference runs through every variable, not only the empty one:
    // one button hands over the finished prompt, the other the template.
    expect(finished).toContain('Einsteiger')
    expect(withSlots).not.toContain('Einsteiger')
    expect(withSlots).toContain('{{zielgruppe}}')
  })

  it('works with Ctrl+Shift+Enter too', async () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })

    const { wrapper } = await screen()
    window.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter', ctrlKey: true, shiftKey: true, bubbles: true
    }))
    await settle()

    expect(written).toHaveBeenCalledWith(expect.stringContaining('{{thema}}'))
    expect(wrapper.text()).toContain('Copied to the clipboard with placeholders.')
  })

  // TF-416 for the second route: if the browser refuses, the field has to hold
  // the text that was meant just now — not the one of the other button.
  it('offers the raw text for selecting when the clipboard is refused', async () => {
    vi.stubGlobal('navigator', { clipboard: { writeText: vi.fn().mockRejectedValue(new Error('nope')) } })

    const { wrapper } = await screen()
    await rawCopyButton(wrapper).trigger('click')
    await settle()

    expect(wrapper.find('textarea[readonly]').element.value).toContain('{{thema}}')
  })
})

describe('Remembering entries (FA-306)', () => {
  it('fills the fields on the next opening with what was entered last', async () => {
    const first = await screen()
    await type(first.wrapper, 'input[type="text"]', 'Kaffeezubereitung')
    const again = await screen()

    expect(again.wrapper.find('input[type="text"]').element.value).toBe('Kaffeezubereitung')
    expect(previewText(again.wrapper)).toContain('Kaffeezubereitung')
  })

  // The counter-check: a prompt that was never filled in shows its defaults,
  // not somebody else's leftovers.
  it('keeps the entries apart per prompt', async () => {
    const first = await screen()
    await type(first.wrapper, 'input[type="text"]', 'Kaffeezubereitung')
    const other = promptDetail({ id: 6, title: 'Anderer' })
    const second = await screen({ routes: routesFor(other), at: '/prompt/6' })

    expect(second.wrapper.find('input[type="text"]').element.value).toBe('')
  })
})

describe('Menu and permissions (11.4)', () => {
  const openMenu = async (wrapper) => {
    await wrapper.findAll('button').find((entry) => entry.text().includes('More actions')).trigger('click')
    await settle()
  }

  it('offers only what the server allows', async () => {
    const { wrapper } = await screen({
      routes: routesFor(promptDetail({
        permissions: { update: false, delete: false, duplicate: true, move: false, visibility: false }
      }))
    })
    await openMenu(wrapper)

    // 11.4: for a foreign prompt only duplicating (and exporting, from AP-14)
    // is left. Entries are left out, not greyed out.
    expect(wrapper.text()).not.toContain('Move to trash')
    // Status and visibility are changed in the head line; without the right
    // to do so they are not there at all.
    expect(wrapper.find('.prompt__meta select').exists()).toBe(false)
  })

  it('offers trash, status and visibility to whoever may use them', async () => {
    const { wrapper, server } = await screen({
      routes: [
        ...routesFor(),
        { method: 'DELETE', path: '/prompts/5', body: { status: 'ok' } }
      ]
    })

    // Status and visibility in the head line.
    expect(wrapper.findAll('.prompt__meta select')).toHaveLength(2)

    await openMenu(wrapper)
    await wrapper.findAll('button').find((entry) => entry.text() === 'Move to trash').trigger('click')
    await settle()

    expect(server.callsTo('DELETE', '/prompts/5')).toHaveLength(1)
  })

  it('offers undo only when a revision exists', async () => {
    const without = await screen()
    await openMenu(without.wrapper)
    expect(without.wrapper.text()).not.toContain('Undo')

    const with_ = await screen({ routes: routesFor(promptDetail({ revision_count: 2 })) })
    await openMenu(with_.wrapper)
    expect(with_.wrapper.text()).toContain('Undo')
  })
})

describe('Someone elses prompt from the overall view (TF-426)', () => {
  it('lets the prompts own keywords take effect but not be switched off', async () => {
    const { wrapper } = await screen({
      routes: [
        ...signedInRoutes(),
        { method: 'GET', path: '/prompts/5', body: { prompt: promptDetail({ permissions: { duplicate: true } }) } },
        { method: 'GET', path: '/keywords', ...apiError(404, 'not_found') }
      ]
    })

    // The catalogue of that workspace cannot be read, so nothing new can be
    // switched on — but what belongs to the prompt still renders, exactly as
    // the server would render it.
    expect(previewText(wrapper)).toContain('Du bist ein erfahrener Fachautor.')

    const chip = wrapper.findAll('button').find((entry) => entry.text() === 'rolle')
    expect(chip.attributes('disabled')).toBeDefined()
    expect(wrapper.text()).toContain('another workspace')
  })
})

describe('The version for this one use (FA-307)', () => {
  const clipboard = () => {
    const written = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText: written } })
    return written
  }

  it('starts prefilled with the prompt including its placeholders', async () => {
    const { wrapper } = await screen()

    const field = wrapper.find('[data-test="workbench"]')
    expect(field.exists()).toBe(true)
    expect(field.element.value).toContain('{{thema}}')
  })

  // The whole point: what the button copies is what the person sees in the
  // field, and the button stands next to that field.
  it('copies the edited text with its own button', async () => {
    const written = clipboard()
    const { wrapper } = await screen()

    await wrapper.find('[data-test="workbench"]').setValue('Ganz eigener Text {{thema}}')
    await wrapper.find('[data-test="workbench-copy"]').trigger('click')
    await settle()

    expect(written).toHaveBeenCalledWith('Ganz eigener Text {{thema}}')
  })

  // Without an edit the field holds the source, and the button copies that.
  it('copies the prompt with all its placeholders when nothing was edited', async () => {
    const written = clipboard()
    const { wrapper } = await screen()

    await wrapper.find('[data-test="workbench-copy"]').trigger('click')
    await settle()

    expect(written).toHaveBeenCalledTimes(1)
    expect(written.mock.calls[0][0]).toContain('{{thema}}')
    expect(written.mock.calls[0][0]).not.toContain('Ganz eigener Text')
  })

  // The case the rearrangement is for. Before, one button copied two different
  // texts depending on whether a field further down the page had been touched
  // — and the field is remembered per prompt, so somebody could paste an edit
  // from two days ago while looking at the preview.
  it('leaves copying with placeholders untouched by the editing', async () => {
    const written = clipboard()
    const { wrapper } = await screen()

    await wrapper.find('[data-test="workbench"]').setValue('Ganz eigener Text {{thema}}')
    await settle()
    await wrapper.find('[data-test="copy-raw"]').trigger('click')
    await settle()

    expect(written.mock.calls[0][0]).not.toContain('Ganz eigener Text')
    expect(written.mock.calls[0][0]).toContain('{{thema}}')
  })

  // It is not the editor: nothing here reaches the prompt. Said in the text
  // and true in the traffic.
  it('sends nothing to the server', async () => {
    const { wrapper, server } = await screen()

    await wrapper.find('[data-test="workbench"]').setValue('nur für mich')
    await settle()

    expect(server.callsTo('PUT', '/prompts/5')).toHaveLength(0)
    expect(wrapper.text()).toContain('The stored prompt stays as it is')
  })

  it('offers the way back only once there is something to take back', async () => {
    const { wrapper } = await screen()
    expect(wrapper.find('[data-test="workbench-reset"]').exists()).toBe(false)

    await wrapper.find('[data-test="workbench"]').setValue('etwas anderes')
    await settle()
    expect(wrapper.find('[data-test="workbench-reset"]').exists()).toBe(true)

    await wrapper.find('[data-test="workbench-reset"]').trigger('click')
    await settle()

    expect(wrapper.find('[data-test="workbench"]').element.value).toContain('{{thema}}')
    expect(wrapper.find('[data-test="workbench"]').element.value).not.toContain('etwas anderes')
  })

  // Remembered per prompt, like the values of FA-306 and for the same reason:
  // stepping into the editor and coming back must not lose the adaptation.
  it('keeps the version across a reopening', async () => {
    const first = await screen()
    await first.wrapper.find('[data-test="workbench"]').setValue('bleibt erhalten')
    await settle()
    first.wrapper.unmount()

    const second = await screen()
    expect(second.wrapper.find('[data-test="workbench"]').element.value).toBe('bleibt erhalten')
  })
})
