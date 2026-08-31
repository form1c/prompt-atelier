import { describe, it, expect, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import { installFakeServer, signedInRoutes, WORKSPACES, apiError } from './support/fake_server.js'

// S4 — the keyword catalogue (FA-401 to FA-404, W-4).
//
// What a keyword does to a prompt is checked without a browser in
// keyword_effect.test.js. What is checked here is the seam: that the preview
// really hangs on the form and follows the typing, that a name collision
// lands at the field rather than over the list, and that deleting asks first
// — naming the prompts it would affect.

const realFetch = globalThis.fetch

const keywordRow = (overrides = {}) => ({
  id: 3,
  name: 'formal',
  description: 'Förmliche Ansprache',
  text: 'Antworte in förmlichem Deutsch.',
  position: 'prepend',
  sort_order: 0,
  ...overrides
})

const mounted = []

async function screen ({ keywords = [keywordRow()], routes = [], workspaces = WORKSPACES } = {}) {
  // The case's own routes come first: the first match wins.
  const server = installFakeServer([
    ...routes,
    { method: 'GET', path: '/workspaces', body: workspaces },
    ...signedInRoutes(),
    { method: 'GET', path: '/keywords', body: { keywords } }
  ])
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')

  const router = createAppRouter(createMemoryHistory())
  const wrapper = mount(App, { global: { plugins: [router] }, attachTo: document.body })
  mounted.push(wrapper)
  await router.push('/keywords')
  await settle()

  return { wrapper, router, server }
}

const effect = (wrapper) => wrapper.find('[data-test="effect"]')
const field = (wrapper, label) => wrapper.findAll('label').find((entry) => entry.text().startsWith(label))
const inputFor = (wrapper, label) => field(wrapper, label).find('input, select, textarea')
const buttonNamed = (wrapper, text) => wrapper.findAll('button').find((entry) => entry.text().includes(text))
const sent = (server, method, fragment) => JSON.parse(server.callsTo(method, fragment).at(-1).options.body)

afterEach(() => {
  while (mounted.length) mounted.pop().unmount()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('The list', () => {
  it('shows the keywords of the workspace with position and order', async () => {
    const { wrapper } = await screen({
      keywords: [keywordRow(), keywordRow({ id: 4, name: 'kurz', position: 'append', sort_order: 2 })]
    })

    const text = wrapper.text()
    expect(text).toContain('formal')
    expect(text).toContain('Before the prompt')
    expect(text).toContain('kurz')
    expect(text).toContain('After the prompt')
  })

  it('asks for the chosen workspace', async () => {
    const { server } = await screen()

    expect(server.callsTo('GET', '/keywords')[0].path).toContain('workspace_id=9')
  })

  // 11.6: never an empty surface.
  it('explains an empty stock instead of showing nothing', async () => {
    const { wrapper } = await screen({ keywords: [] })

    expect(wrapper.text()).toContain('No keywords yet')
    expect(buttonNamed(wrapper, 'Create the first keyword')).toBeDefined()
  })
})

describe('The effect preview (W-4, TF-353)', () => {
  // The heart of the workflow: without this preview, "prepend/append" stays
  // abstract. It has to follow the **typing** — after saving it would be a
  // confirmation, not something to decide by.
  it('shows the block on the sample prompt while it is being typed', async () => {
    const { wrapper } = await screen()

    await inputFor(wrapper, 'Text').setValue('Antworte knapp.')
    await settle()

    const shown = effect(wrapper).text()
    expect(shown).toContain('Antworte knapp.')
    expect(shown).toContain('Summarise the following passage in three sentences.')
    expect(shown.indexOf('Antworte knapp.')).toBeLessThan(shown.indexOf('Summarise the'))
  })

  it('turns the order around as soon as the position changes', async () => {
    const { wrapper } = await screen()

    await inputFor(wrapper, 'Text').setValue('Antworte knapp.')
    await inputFor(wrapper, 'Position').setValue('append')
    await settle()

    const shown = effect(wrapper).text()
    expect(shown.indexOf('Antworte knapp.')).toBeGreaterThan(shown.indexOf('Summarise the'))
  })

  // The two parts are not merely one after the other but drawn apart —
  // otherwise the preview would be a block of text in which nobody can see
  // which half they just wrote (11.6).
  it('draws the block visibly differently from the prompt', async () => {
    const { wrapper } = await screen()

    await inputFor(wrapper, 'Text').setValue('Antworte knapp.')
    await settle()

    const own = effect(wrapper).find('.effect__keyword')
    const body = effect(wrapper).find('.effect__prompt')
    expect(own.text()).toContain('Antworte knapp.')
    expect(body.text()).toContain('Summarise the')
  })
})

describe('Creating and editing (FA-401)', () => {
  it('sends name, text, position and order to the workspace', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'POST', path: '/keywords', status: 201, body: { keyword: keywordRow() } }]
    })

    await inputFor(wrapper, 'Name').setValue('knapp')
    await inputFor(wrapper, 'Text').setValue('Antworte knapp.')
    await inputFor(wrapper, 'Position').setValue('append')
    await inputFor(wrapper, 'Order').setValue('3')
    await wrapper.find('[data-test="save-keyword"]').trigger('click')
    await settle()

    expect(sent(server, 'POST', '/keywords')).toMatchObject({
      workspace_id: 9, name: 'knapp', text: 'Antworte knapp.', position: 'append', sort_order: 3
    })
  })

  // A number field hands back a string. Vue casts it for `type="number"`, so
  // a filled field arrives as a number by itself — the case that does not is
  // the **empty** one, where the cast has nothing to work with and hands the
  // empty string straight through. Then `sort_order: ""` reaches a column the
  // ordering compares numerically (14.1).
  //
  // Found by a mutation probe: removing the conversion left the first of
  // these two green, and only the second noticed.
  it('sends the order as a number', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'POST', path: '/keywords', status: 201, body: { keyword: keywordRow() } }]
    })

    await inputFor(wrapper, 'Name').setValue('knapp')
    await inputFor(wrapper, 'Order').setValue('10')
    await wrapper.find('[data-test="save-keyword"]').trigger('click')
    await settle()

    expect(sent(server, 'POST', '/keywords').sort_order).toBe(10)
  })

  it('sends a cleared order as 0, not as an empty string', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'POST', path: '/keywords', status: 201, body: { keyword: keywordRow() } }]
    })

    await inputFor(wrapper, 'Name').setValue('knapp')
    await inputFor(wrapper, 'Order').setValue('')
    await wrapper.find('[data-test="save-keyword"]').trigger('click')
    await settle()

    expect(sent(server, 'POST', '/keywords').sort_order).toBe(0)
  })

  // The list has to show what was just made. Without the reload the keyword
  // would be on the server and not on the screen until somebody pressed F5 —
  // a mutation probe found this gap, and the browser test was the only level
  // that noticed.
  it('shows the new keyword in the list afterwards', async () => {
    const { wrapper } = await screen({
      routes: [
        { method: 'POST', path: '/keywords', status: 201, body: { keyword: keywordRow() } },
        { method: 'GET', path: '/keywords', body: { keywords: [keywordRow()] }, once: true }
      ],
      keywords: [keywordRow(), keywordRow({ id: 4, name: 'knapp' })]
    })

    expect(wrapper.text()).not.toContain('knapp')

    await inputFor(wrapper, 'Name').setValue('knapp')
    await wrapper.find('[data-test="save-keyword"]').trigger('click')
    await settle()

    expect(wrapper.text()).toContain('knapp')
  })

  it('takes an existing keyword into the form and saves it back', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'PUT', path: '/keywords/3', body: { keyword: keywordRow() } }]
    })

    await buttonNamed(wrapper, 'Edit').trigger('click')
    await settle()

    expect(inputFor(wrapper, 'Name').element.value).toBe('formal')
    expect(inputFor(wrapper, 'Text').element.value).toBe('Antworte in förmlichem Deutsch.')
    // And the preview shows straight away what this keyword does, without
    // anyone having to type something first.
    expect(effect(wrapper).text()).toContain('Antworte in förmlichem Deutsch.')

    await inputFor(wrapper, 'Name').setValue('foermlich')
    await wrapper.find('[data-test="save-keyword"]').trigger('click')
    await settle()

    expect(sent(server, 'PUT', '/keywords/3').name).toBe('foermlich')
  })

  // FA-401: a name the workspace already has is refused. The message belongs
  // at the form — above the list it would sit next to the entry that caused
  // the collision and read as that entry's fault.
  it('names a name collision at the form without losing the draft', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'POST',
        path: '/keywords',
        ...apiError(409, 'name_taken')
      }]
    })

    await inputFor(wrapper, 'Name').setValue('formal')
    await inputFor(wrapper, 'Text').setValue('Antworte knapp.')
    await wrapper.find('[data-test="save-keyword"]').trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('already a keyword with this name')
    expect(inputFor(wrapper, 'Text').element.value).toBe('Antworte knapp.')
  })
})

describe('Deleting (FA-404, TF-405)', () => {
  const refusal = {
    method: 'DELETE',
    path: '/keywords/3',
    status: 409,
    body: {
      error: { code: 'confirmation_required', message: '3 Prompts betroffen.' },
      affected_prompts: [
        { id: 1, title: 'Blogartikel-Generator' },
        { id: 2, title: 'Newsletter-Einleitung' }
      ]
    }
  }

  it('asks first and names the prompts it concerns', async () => {
    const { wrapper, server } = await screen({ routes: [refusal] })

    await buttonNamed(wrapper, 'Delete').trigger('click')
    await settle()

    const dialog = wrapper.find('[role="dialog"]')
    expect(dialog.exists()).toBe(true)
    expect(dialog.text()).toContain('Blogartikel-Generator')
    expect(dialog.text()).toContain('Newsletter-Einleitung')
    // And nothing is deleted until then: the first call carried no
    // confirmation, which is why the server refused it.
    expect(server.callsTo('DELETE', '/keywords/3')).toHaveLength(1)
  })

  it('deletes only after confirmation, and then explicitly', async () => {
    // The first call meets the refusal and consumes it, the second meets the
    // acceptance below — exactly the sequence FA-404 prescribes.
    const { wrapper, server } = await screen({
      routes: [
        { ...refusal, once: true },
        { method: 'DELETE', path: '/keywords/3', body: { removed_assignments: 2 } }
      ]
    })

    await buttonNamed(wrapper, 'Delete').trigger('click')
    await settle()
    await wrapper.find('[data-test="confirm"]').trigger('click')
    await settle()

    expect(sent(server, 'DELETE', '/keywords/3')).toEqual({ confirm: true })
    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
  })

  // A keyword nobody uses is confirmed too — deleting one cannot be undone,
  // and there is no trash for keywords (11.6). What changes is the wording:
  // "an 0 Prompts hinterlegt" beside an empty list is a sentence about
  // nothing.
  //
  // This case had it the other way round at first and was green, because the
  // stand-in server answered as the screen imagined rather than as the real
  // one does. The browser test found it in its first run — which is the whole
  // argument for having that level at all.
  it('asks even with no prompts concerned, but differently then', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'DELETE',
        path: '/keywords/3',
        status: 409,
        body: {
          error: { code: 'confirmation_required', message: '0 Prompts betroffen.' },
          affected_prompts: []
        }
      }]
    })

    await buttonNamed(wrapper, 'Delete').trigger('click')
    await settle()

    const dialog = wrapper.find('[role="dialog"]')
    expect(dialog.text()).toContain('No prompt uses this keyword')
    expect(dialog.findAll('.entry')).toHaveLength(0)
  })
})

describe('Whoever may not write', () => {
  // A viewer may read the keywords and create none (permission matrix).
  // Offering a form that can only end in a refusal is not information, it is
  // a trap — the same rule as the target list of TF-308.
  it('gets the list but no form', async () => {
    const readOnly = {
      ...WORKSPACES,
      selected_workspace_id: 11
    }
    const { wrapper } = await screen({ workspaces: readOnly })

    expect(wrapper.text()).toContain('formal')
    expect(wrapper.find('[data-test="save-keyword"]').exists()).toBe(false)
    expect(buttonNamed(wrapper, 'Delete')).toBeUndefined()
  })
})
