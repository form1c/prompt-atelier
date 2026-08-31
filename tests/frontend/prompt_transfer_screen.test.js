import { describe, it, expect, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import { installFakeServer, signedInRoutes, apiError } from './support/fake_server.js'

// Duplicating and moving on screen (TF-306, TF-307, TF-308, TF-352).
//
// Named after the component it tests, `PromptTransferView`. The screen for
// import and export is a different one — it carries the route `transfer` and
// its own suite in transfer_screen.test.js.
//
// The rules behind them are decided by the server, and they are checked there:
// what a copy inherits, what a move resets, who may write where. What is
// checked here is the interface above that — that it offers no target which
// can only end in a refusal, and that it names the consequences the server
// brought about quietly.

const realFetch = globalThis.fetch

function promptDetail (overrides = {}) {
  return {
    id: 5,
    workspace_id: 9,
    owner_id: 1,
    title: 'Blogartikel-Generator',
    body: 'Schreibe über {{thema}}.',
    visibility: 'workspace',
    status: 'active',
    favorite: false,
    tags: [],
    revision_count: 0,
    variables: [{ key: 'thema', type: 'text', required: false, position: 0 }],
    keywords: [],
    permissions: { update: true, delete: true, duplicate: true, move: true, visibility: true },
    ...overrides
  }
}

const mounted = []

async function screen ({ at, routes = [], prompt = promptDetail() } = {}) {
  // The routes of the case stand **first**: the first match wins, and a case
  // that wants to replace a default answer cannot do so otherwise.
  const server = installFakeServer([
    ...routes,
    ...signedInRoutes(),
    { method: 'GET', path: `/prompts/${prompt.id}`, body: { prompt } }
  ])
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

const targets = (wrapper) => wrapper.findAll('.transfer__target').map((entry) => entry.text())
const confirmButton = (wrapper) => wrapper.find('[data-test="confirm"]')
const sent = (server, fragment) => JSON.parse(server.callsTo('POST', fragment)[0].options.body)

afterEach(() => {
  while (mounted.length) mounted.pop().unmount()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('Choosing the target (TF-308)', () => {
  // The case it is about: "Nur-Lesen" is a workspace the user may read and in
  // which they may create nothing. Offering it would mean selling a refusal as
  // a choice.
  it('offers only workspaces one may create in', async () => {
    const { wrapper } = await screen({ at: '/prompt/5/duplicate' })

    expect(targets(wrapper).join(' ')).toContain('Marketing')
    expect(targets(wrapper).join(' ')).toContain('Personal workspace')
    expect(targets(wrapper).join(' ')).not.toContain('Nur-Lesen')
  })

  // When moving, the current workspace drops out as well: a move to where the
  // prompt already lies achieves nothing and costs a revision all the same.
  it('leaves out the current workspace when moving', async () => {
    const { wrapper } = await screen({ at: '/prompt/5/move' })

    expect(targets(wrapper).join(' ')).not.toContain('Marketing')
    expect(targets(wrapper).join(' ')).toContain('Personal workspace')
  })

  // 11.6: never an empty surface. Whoever may create nowhere gets a sentence
  // and not an empty list.
  it('says so when there is no target at all', async () => {
    const { wrapper } = await screen({
      at: '/prompt/5/duplicate',
      routes: [{
        method: 'GET',
        path: '/workspaces',
        body: {
          workspaces: [{ id: 11, name: 'Nur-Lesen', role: 'viewer', permissions: { create: false } }],
          selected_workspace_id: 11
        }
      }]
    })

    expect(wrapper.text()).toContain('may create prompts')
    expect(confirmButton(wrapper).attributes('disabled')).toBeDefined()
  })
})

describe('Duplicating (FA-204, TF-306, TF-352)', () => {
  const copy = promptDetail({ id: 88, title: 'Blogartikel-Generator (Kopie)', workspace_id: 7 })

  const routes = (body) => [
    { method: 'POST', path: '/prompts/5/duplicate', status: 201, body },
    { method: 'GET', path: '/prompts/88', body: { prompt: copy } }
  ]

  it('creates the copy in the chosen workspace', async () => {
    const { wrapper, server } = await screen({
      at: '/prompt/5/duplicate',
      routes: routes({ prompt: copy, dropped_keywords: [] })
    })

    await wrapper.findAll('input[type="radio"]')[1].setValue(true)
    await confirmButton(wrapper).trigger('click')
    await settle()

    expect(sent(server, '/duplicate').workspace_id).toBe(9)
  })

  // TF-352: the copy opens in the editor with the title selected — "… (Kopie)"
  // is a placeholder, not a name.
  it('leads into the editor with the title selected', async () => {
    const { wrapper, router } = await screen({
      at: '/prompt/5/duplicate',
      routes: routes({ prompt: copy, dropped_keywords: [] })
    })

    await confirmButton(wrapper).trigger('click')
    await settle()

    expect(router.currentRoute.value.name).toBe('prompt-edit')
    expect(router.currentRoute.value.params.id).toBe('88')

    const field = wrapper.find('.editor__form input[type="text"]').element
    expect(document.activeElement).toBe(field)
    expect(field.selectionEnd).toBe('Blogartikel-Generator (Kopie)'.length)
  })

  // TF-306: keywords that do not exist in the target are dropped. Whoever
  // notices that only because the prompt renders differently than expected has
  // long since passed the fault on.
  it('names the keywords that could not be resolved in the target', async () => {
    const { wrapper } = await screen({
      at: '/prompt/5/duplicate',
      routes: routes({ prompt: copy, dropped_keywords: ['formal', 'kurz'] })
    })

    await confirmButton(wrapper).trigger('click')
    await settle()

    expect(wrapper.text()).toContain('formal, kurz')
  })

  it('keeps quiet when nothing was dropped', async () => {
    const { wrapper } = await screen({
      at: '/prompt/5/duplicate',
      routes: routes({ prompt: copy, dropped_keywords: [] })
    })

    await confirmButton(wrapper).trigger('click')
    await settle()

    expect(wrapper.text()).not.toContain('do not exist in the target')
  })
})

describe('Moving (FA-207, TF-307)', () => {
  const moved = promptDetail({ workspace_id: 7, visibility: 'private' })

  it('warns beforehand about the visibility being reset', async () => {
    const { wrapper } = await screen({ at: '/prompt/5/move' })

    expect(wrapper.text()).toContain('visibility back to “Only me”')
  })

  it('reports it once more afterwards and leads to the prompt', async () => {
    const { wrapper, router, server } = await screen({
      at: '/prompt/5/move',
      routes: [{
        method: 'POST',
        path: '/prompts/5/move',
        body: { prompt: moved, visibility_reset: true, dropped_keywords: [] }
      }]
    })

    await confirmButton(wrapper).trigger('click')
    await settle()

    expect(sent(server, '/move').workspace_id).toBe(7)
    // On the wording of the message, not on "Only me": after the move that
    // stands in the visibility select of the prompt screen one lands on as
    // well. The first draft checked for that and was green while the message
    // did not appear at all — found by the mutation probe.
    expect(wrapper.text()).toContain('The visibility is now')
    expect(router.currentRoute.value.name).toBe('prompt')
  })

  // The counter-check: if the visibility was already `private` there was
  // nothing to reset — and then the note is a message about nothing.
  it('reports no reset when none took place', async () => {
    const { wrapper } = await screen({
      at: '/prompt/5/move',
      routes: [{
        method: 'POST',
        path: '/prompts/5/move',
        body: { prompt: moved, visibility_reset: false, dropped_keywords: [] }
      }]
    })

    await confirmButton(wrapper).trigger('click')
    await settle()

    expect(wrapper.text()).not.toContain('steht jetzt auf')
  })
})

describe('When the server refuses', () => {
  it('the screen stays and names the reason', async () => {
    const { wrapper, router } = await screen({
      at: '/prompt/5/duplicate',
      routes: [{
        method: 'POST',
        path: '/prompts/5/duplicate',
        ...apiError(403, 'forbidden')
      }]
    })

    await confirmButton(wrapper).trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('No permission for this action.')
    expect(router.currentRoute.value.name).toBe('prompt-duplicate')
  })
})

describe('The way there', () => {
  // The menu entries on the prompt screen have hung off exactly these routes
  // since AP-11 and stayed invisible as long as they did not exist.
  it('the menu of the prompt now carries both entries', async () => {
    const { wrapper } = await screen({ at: '/prompt/5' })

    await wrapper.findAll('button').find((entry) => entry.text().includes('More actions')).trigger('click')
    await settle()

    const menu = wrapper.find('.menu__list').text()
    expect(menu).toContain('Duplicate')
    expect(menu).toContain('Move to workspace')
    expect(menu).toContain('Edit')
  })
})
