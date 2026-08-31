import { describe, it, expect, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import { installFakeServer, signedInRoutes, apiError } from './support/fake_server.js'

// S3 — the editor (Requirements 11.5, FA-301, FA-302, TF-351, TF-352).
//
// What is checked here is the seam between screen and rules: the mechanics of
// the draft live in util/draft.js and are checked there without a browser
// (TF-451). This is about the screen using them — that typing in the text
// really produces variables, that the order really is sent along, and that
// unsaved work does not go quietly missing.

const realFetch = globalThis.fetch

function promptDetail (overrides = {}) {
  return {
    id: 5,
    workspace_id: 9,
    owner_id: 1,
    title: 'Blogartikel-Generator',
    description: 'Erstellt SEO-Artikel',
    body: 'Schreibe über {{thema}} für {{zielgruppe}}.',
    visibility: 'workspace',
    status: 'active',
    model_hint: null,
    favorite: false,
    tags: ['seo'],
    revision_count: 0,
    variables: [
      { key: 'thema', label: 'Thema', type: 'text', default_value: null, required: true, position: 0 },
      { key: 'zielgruppe', label: 'Zielgruppe', type: 'select', options: 'Einsteiger\nProfis', default_value: 'Einsteiger', required: false, position: 1 }
    ],
    keywords: [],
    permissions: { update: true, delete: true, duplicate: true, move: true, visibility: true },
    ...overrides
  }
}

const mounted = []

async function screen ({ at = '/prompt/new', routes = [] } = {}) {
  const server = installFakeServer([...signedInRoutes(), ...routes])
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')

  const router = createAppRouter(createMemoryHistory())
  const wrapper = mount(App, { global: { plugins: [router] }, attachTo: document.body })
  mounted.push(wrapper)
  await router.push(at)
  await settle()

  return { wrapper, router, server }
}

const editing = (prompt = promptDetail()) => ({
  at: `/prompt/${prompt.id}/edit`,
  routes: [{ method: 'GET', path: `/prompts/${prompt.id}`, body: { prompt } }]
})

const bodyField = (wrapper) => wrapper.find('[data-test="body"]')
const previewText = (wrapper) => wrapper.find('[data-test="preview"]').text()
const titleField = (wrapper) => wrapper.find('.editor__form input[type="text"]')
const saveButton = (wrapper) => wrapper.find('button[type="submit"]')
const sent = (server, method, fragment) => JSON.parse(server.callsTo(method, fragment)[0].options.body)

afterEach(() => {
  while (mounted.length) mounted.pop().unmount()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('Variables appear while typing (TF-351)', () => {
  it('creates an entry for a newly typed placeholder without a separate step', async () => {
    const { wrapper } = await screen()

    expect(wrapper.text()).toContain('No variables yet')

    await bodyField(wrapper).setValue('Schreibe über {{thema}}.')
    await settle()

    expect(wrapper.text()).toContain('1 variable detected')
    expect(wrapper.find('.variables__key').text()).toBe('{{thema}}')
    // And there is no way to add one by hand — the set follows from the text
    // and from nothing else (FA-301).
    expect(wrapper.text()).not.toContain('Variable hinzufügen')
  })

  it('takes the entry away again when the occurrence disappears', async () => {
    const { wrapper } = await screen()

    await bodyField(wrapper).setValue('{{thema}}')
    await settle()
    await bodyField(wrapper).setValue('Ganz ohne.')
    await settle()

    expect(wrapper.findAll('.variables__key')).toHaveLength(0)
  })

  // 11.5: the preview shows the prompt with its default values. Whatever has
  // none stands there as a placeholder — the same presentation as when reading
  // (8.3.1), so nobody has to learn two notations.
  it('shows the preview with default values and placeholders', async () => {
    const { wrapper } = await screen(editing())
    await settle()

    expect(previewText(wrapper)).toBe('Schreibe über {{thema}} für Einsteiger.')
    expect(wrapper.find('[data-test="preview"] .slot--missing').text()).toBe('{{thema}}')
    expect(wrapper.find('[data-test="preview"] .slot--value').text()).toBe('Einsteiger')
  })
})

// TF-454 — found by the client while using it: in the options textarea no line
// break could be produced. Enter did nothing, and with that exactly **one**
// option was possible — in a field whose help text says one option per line.
//
// The cause was a feedback loop: on every key press the value was split,
// tidied up and written back into the field reassembled. "Eins\n" fell apart
// into ["Eins", ""], the empty last line was thrown out, back came "Eins" —
// the break was gone before the finger was off the key.
describe('Options of a select variable', () => {
  async function withSelection () {
    const { wrapper, server } = await screen()
    await bodyField(wrapper).setValue('Für {{gruppe}}.')
    await settle()
    await wrapper.find('.variables select').setValue('select')
    await settle()

    return { wrapper, server, options: wrapper.find('.variables textarea') }
  }

  it('leaves a line break alone', async () => {
    const { options } = await withSelection()

    await options.setValue('Eins\n')

    expect(options.element.value).toBe('Eins\n')
  })

  // Checked after **every** step, not only at the end: "Eins\nZwei\nDrei" runs
  // through cleanly even with the fault, because there is no empty line in it.
  // The fault shows itself only in the intermediate states — which is exactly
  // where one is the whole time while typing.
  it('thereby takes several options', async () => {
    const { options } = await withSelection()

    for (const typed of ['Eins\n', 'Eins\nZwei', 'Eins\nZwei\n', 'Eins\nZwei\nDrei']) {
      await options.setValue(typed)
      expect(options.element.value, typed).toBe(typed)
    }
  })

  // The same fault in miniature, and unnoticed without this case: were it
  // trimmed while typing, the space between two words would disappear in the
  // very moment one types it — "Sehr" + space + "formal" would become
  // "Sehrformal".
  it('leaves a trailing space alone while typing is going on', async () => {
    const { options } = await withSelection()

    await options.setValue('Sehr ')
    expect(options.element.value).toBe('Sehr ')

    await options.setValue('Sehr formal')
    expect(options.element.value).toBe('Sehr formal')
  })

  // Tidied up all the same — only once, on the way to the server. What comes
  // into being while typing is allowed to be untidy.
  it('sends them trimmed and without blank lines to the server', async () => {
    const { wrapper, server, options } = await withSelection()
    server.add({ method: 'POST', path: '/prompts', status: 201, body: { prompt: promptDetail({ id: 90 }) } })

    await titleField(wrapper).setValue('Mit Auswahl')
    await options.setValue('  Eins  \n\nZwei\n')
    await saveButton(wrapper).trigger('click')
    await settle()

    expect(sent(server, 'POST', '/prompts').variables[0].options).toEqual(['Eins', 'Zwei'])
  })
})

describe('Saving', () => {
  it('creates a new prompt in the chosen workspace', async () => {
    const { wrapper, router, server } = await screen({
      routes: [{ method: 'POST', path: '/prompts', status: 201, body: { prompt: promptDetail({ id: 77 }) } }]
    })

    await titleField(wrapper).setValue('Neuer Titel')
    await bodyField(wrapper).setValue('Text mit {{thema}}.')
    await settle()
    await saveButton(wrapper).trigger('click')
    await settle()

    const payload = sent(server, 'POST', '/prompts')
    expect(payload.title).toBe('Neuer Titel')
    expect(payload.workspace_id).toBe(9)
    expect(payload.variables).toEqual([expect.objectContaining({ key: 'thema', position: 0 })])

    // After creating it one stands in front of the prompt, not in front of an
    // empty form: the next step is to use it.
    expect(router.currentRoute.value.name).toBe('prompt')
    expect(router.currentRoute.value.params.id).toBe('77')
  })

  it('sends a change to an existing prompt as a PUT', async () => {
    const prompt = promptDetail()
    const { wrapper, server } = await screen({
      ...editing(prompt),
      routes: [...editing(prompt).routes,
               { method: 'PUT', path: `/prompts/${prompt.id}`, body: { prompt } }]
    })

    await titleField(wrapper).setValue('Anderer Titel')
    await saveButton(wrapper).trigger('click')
    await settle()

    expect(sent(server, 'PUT', `/prompts/${prompt.id}`).title).toBe('Anderer Titel')
    expect(server.callsTo('POST', '/prompts')).toHaveLength(0)
  })

  // FA-302: the order belongs to the author. Without the position sent along
  // it would fall back to the order of the text on the server.
  it('sends a hand-rearranged order along', async () => {
    const prompt = promptDetail()
    const { wrapper, server } = await screen({
      ...editing(prompt),
      routes: [...editing(prompt).routes,
               { method: 'PUT', path: `/prompts/${prompt.id}`, body: { prompt } }]
    })

    await wrapper.findAll('.variables__step')[1].trigger('click') // thema nach unten
    await settle()
    await saveButton(wrapper).trigger('click')
    await settle()

    expect(sent(server, 'PUT', `/prompts/${prompt.id}`).variables.map((v) => [v.key, v.position]))
      .toEqual([['zielgruppe', 0], ['thema', 1]])
  })

  it('saves with Ctrl+S as well', async () => {
    const prompt = promptDetail()
    const { wrapper, server } = await screen({
      ...editing(prompt),
      routes: [...editing(prompt).routes,
               { method: 'PUT', path: `/prompts/${prompt.id}`, body: { prompt } }]
    })

    await titleField(wrapper).setValue('Mit Kuerzel')
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 's', ctrlKey: true, bubbles: true }))
    await settle()

    expect(server.callsTo('PUT', `/prompts/${prompt.id}`)).toHaveLength(1)
  })

  // 15.2: the reason comes from the server, which already answers in the
  // language of the user. The browser does not check for itself — a second
  // version of the rules would be the unchecked one (SEC-06).
  it('shows the refusal of the server and marks the field', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'POST',
        path: '/prompts',
        ...apiError(422, 'validation_failed', undefined, { title: 'title_required' })
      }]
    })

    await bodyField(wrapper).setValue('Text.')
    await saveButton(wrapper).trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('The entry is incomplete or wrong.')
    expect(titleField(wrapper).attributes('aria-invalid')).toBe('true')
    // And the draft is still there — a refusal must not cost any work.
    expect(bodyField(wrapper).element.value).toBe('Text.')
  })
})

describe('Unsaved changes (11.5)', () => {
  it('asks on leaving', async () => {
    const { wrapper, router } = await screen()

    await titleField(wrapper).setValue('Angefangen')
    await settle()
    await router.push({ name: 'library' }).catch(() => {})
    await settle()

    expect(wrapper.find('[role="dialog"]').text()).toContain('Unsaved changes')
    expect(router.currentRoute.value.name).toBe('prompt-new')
  })

  it('lets whoever wants to discard go', async () => {
    const { wrapper, router } = await screen()

    await titleField(wrapper).setValue('Angefangen')
    await settle()
    await router.push({ name: 'library' }).catch(() => {})
    await settle()

    await wrapper.findAll('[role="dialog"] button').find((entry) => entry.text().includes('Discard')).trigger('click')
    await settle()

    expect(router.currentRoute.value.name).toBe('library')
  })

  it('stays for whoever wants to stay', async () => {
    const { wrapper, router } = await screen()

    await titleField(wrapper).setValue('Angefangen')
    await settle()
    await router.push({ name: 'library' }).catch(() => {})
    await settle()
    await wrapper.findAll('[role="dialog"] button').find((entry) => entry.text().includes('Stay here')).trigger('click')
    await settle()

    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
    expect(router.currentRoute.value.name).toBe('prompt-new')
  })

  // The counter-check: whoever touched nothing is not asked. A question
  // without cause is one you learn to click away, and then it no longer bites
  // in the case where it would have been warranted.
  it('does not ask when nothing was changed', async () => {
    const { wrapper, router } = await screen()

    await router.push({ name: 'library' })
    await settle()

    expect(router.currentRoute.value.name).toBe('library')
    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
  })

  it('stops asking once it has been saved', async () => {
    const prompt = promptDetail()
    const { wrapper, router } = await screen({
      ...editing(prompt),
      routes: [...editing(prompt).routes,
               { method: 'PUT', path: `/prompts/${prompt.id}`, body: { prompt } }]
    })

    await titleField(wrapper).setValue('Gespeichert')
    await saveButton(wrapper).trigger('click')
    await settle()

    expect(router.currentRoute.value.name).toBe('prompt')
    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
  })
})

describe('The way into the editor', () => {
  // After a search that found nothing, the library offers to create the term
  // as a prompt. It arrives as the title, so the typing is not lost.
  it('takes the search term over as the title', async () => {
    const { wrapper } = await screen({ at: '/prompt/new?title=Angebotsschreiben' })

    expect(titleField(wrapper).element.value).toBe('Angebotsschreiben')
  })

  // TF-352: after duplicating, "… (Kopie)" is a placeholder, not a name.
  // Selected, it is replaced by a single key press.
  it('marks the title when it needs naming', async () => {
    const prompt = promptDetail({ title: 'Blogartikel-Generator (Kopie)' })
    const { wrapper } = await screen({
      at: `/prompt/${prompt.id}/edit?rename=1`,
      routes: editing(prompt).routes
    })

    const field = titleField(wrapper).element
    expect(document.activeElement).toBe(field)
    expect(field.selectionStart).toBe(0)
    expect(field.selectionEnd).toBe('Blogartikel-Generator (Kopie)'.length)
  })
})

describe('The way to the editor', () => {
  it('the header offers a control for a new prompt', async () => {
    const { wrapper, router } = await screen({ at: '/' })

    await wrapper.find('.shell__new').trigger('click')
    await settle()

    expect(router.currentRoute.value.name).toBe('prompt-new')
  })

  // 11.6: single-key shortcuts work only outside an input field.
  it('n opens a new prompt, but not inside the search box', async () => {
    const { wrapper, router } = await screen({ at: '/' })

    const search = wrapper.find('input[type="search"]').element
    search.focus()
    search.dispatchEvent(new KeyboardEvent('keydown', { key: 'n', bubbles: true }))
    await settle()
    expect(router.currentRoute.value.name).toBe('library')

    search.blur()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'n', bubbles: true }))
    await settle()
    expect(router.currentRoute.value.name).toBe('prompt-new')
  })
})
