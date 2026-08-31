import { describe, it, expect, afterEach, vi } from 'vitest'
import { h } from 'vue'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import {
  installFakeServer, signedInRoutes, promptRow, apiError, SIGNED_IN_USER, WORKSPACES
} from './support/fake_server.js'

// S1 — the library (Requirements 11.3, FA-501 to FA-509).
//
// The screen this application starts on, and the one workflow that has a time
// limit attached to it (NFA-01: under ten seconds from loading to the
// clipboard). Most of what is tested here is what that time is made of — the
// focus already in the right place, the keyboard leading from the field into
// the list, the filters not needing a detour through a menu.

const realFetch = globalThis.fetch

// Longer than the pause the screen waits for after a keystroke, so a test
// observes the request rather than the moment before it.
const AFTER_TYPING = 220

const BLANK = { render: () => h('p', 'x') }

async function library ({ routes = signedInRoutes(), at = '/', extraRoutes = [] } = {}) {
  const server = installFakeServer(routes)
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')
  const state = await import('../../frontend/src/state/session.js')

  const router = createAppRouter(createMemoryHistory())
  for (const route of extraRoutes) router.addRoute(route)
  const wrapper = mount(App, { global: { plugins: [router] }, attachTo: document.body })
  await router.push(at)
  await settle()

  return { wrapper, router, server, state }
}

async function type (wrapper, text) {
  const field = wrapper.find('input[type="search"]')
  await field.setValue(text)
  await new Promise((resolve) => setTimeout(resolve, AFTER_TYPING))
  await settle()
}

const rows = (wrapper) => wrapper.findAll('.hit')
const openButtons = (wrapper) => wrapper.findAll('.hit__open')

afterEach(() => {
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('Hit list', () => {
  it('carries on every row what 11.3 asks for', async () => {
    const { wrapper } = await library({
      routes: signedInRoutes([promptRow({ updated_at: '2026-08-02T10:00:00Z' })])
    })

    const line = rows(wrapper)[0].text()

    expect(line).toContain('Blogartikel-Generator')
    expect(line).toContain('Erstellt SEO-Artikel zu beliebigem Thema')
    expect(line).toContain('seo · content')
    // The author is not decoration: in a team it decides whether someone
    // trusts a prompt enough to use it without reading all of it.
    expect(line).toContain('Sabine')
    // `{{2}}` — visible at a glance whether filling in is needed.
    expect(line).toContain('{{2}}')
  })

  it('names the number of hits beside the list', async () => {
    const { wrapper } = await library({
      routes: signedInRoutes([promptRow(), promptRow({ id: 2, title: 'Zweiter' })])
    })

    expect(wrapper.text()).toContain('2 prompts')
  })

  // FA-505. The row is only re-drawn once the server has agreed — a star that
  // changes first and springs back later is worse than one that waits.
  it('toggles the favourite without going through the prompt', async () => {
    const { wrapper, server } = await library({
      routes: [
        ...signedInRoutes([promptRow()]),
        { method: 'POST', path: '/prompts/1/favorite', body: { status: 'ok' } }
      ]
    })

    await wrapper.find('.hit__star').trigger('click')
    await settle()

    expect(server.callsTo('POST', '/prompts/1/favorite')).toHaveLength(1)
    expect(wrapper.find('.hit__star').attributes('aria-pressed')).toBe('true')
  })

  it('takes a set favourite back again', async () => {
    const { wrapper, server } = await library({
      routes: [
        ...signedInRoutes([promptRow({ favorite: true })]),
        { method: 'DELETE', path: '/prompts/1/favorite', body: { status: 'ok' } }
      ]
    })

    await wrapper.find('.hit__star').trigger('click')
    await settle()

    expect(server.callsTo('DELETE', '/prompts/1/favorite')).toHaveLength(1)
    expect(wrapper.find('.hit__star').attributes('aria-pressed')).toBe('false')
  })

  // FA-506 and NFA-08: the server answers a page at a time (15.1). Without a
  // way to the next one, the count in the heading would name prompts that no
  // click can reach — and nobody would notice until a library outgrew fifty.
  it('fetches the rest of the list', async () => {
    const first = [promptRow(), promptRow({ id: 2, title: 'Zweiter' })]
    const second = [promptRow({ id: 3, title: 'Dritter' })]
    const { wrapper, server } = await library({
      routes: [
        { method: 'GET', path: '/prompts', query: 'page=2', body: { prompts: second, meta: { total: 3 } } },
        { method: 'GET', path: '/auth/me', body: { user: SIGNED_IN_USER } },
        { method: 'GET', path: '/workspaces', body: WORKSPACES },
        { method: 'GET', path: '/prompts', body: { prompts: first, meta: { total: 3 } } },
        { method: 'GET', path: '/tags', body: { tags: [] } }
      ]
    })

    expect(wrapper.text()).toContain('3 prompts')
    const more = wrapper.findAll('button').find((entry) => entry.text().includes('Load'))
    expect(more.text()).toContain('1')

    await more.trigger('click')
    await settle()

    // Appended, not replaced: a button that says "load more" and then shows
    // less would be worse than none.
    expect(openButtons(wrapper)).toHaveLength(3)
    expect(server.callsTo('GET', '/prompts').at(-1).path).toContain('page=2')
    expect(wrapper.findAll('button').find((entry) => entry.text().includes('Load'))).toBeUndefined()
  })

  // The counter-check: with everything on display there is nothing to fetch,
  // and a button offering it would be a promise the server cannot keep.
  it('offers nothing more to load once everything is there', async () => {
    const { wrapper } = await library({ routes: signedInRoutes([promptRow()]) })

    expect(wrapper.findAll('button').find((entry) => entry.text().includes('Load'))).toBeUndefined()
  })
})

describe('Searching and filtering', () => {
  it('puts the focus into the search box on load', async () => {
    const { wrapper } = await library({ routes: signedInRoutes([promptRow()]) })

    // 11.3. Someone opening the library is looking for something; anything
    // else costs a click first, and NFA-01 counts in seconds.
    expect(document.activeElement).toBe(wrapper.find('input[type="search"]').element)
  })

  it('searches while typing and writes the term into the address', async () => {
    const { wrapper, router, server } = await library({ routes: signedInRoutes([promptRow()]) })

    await type(wrapper, 'blog')

    expect(router.currentRoute.value.query.search).toBe('blog')
    const asked = server.callsTo('GET', '/prompts').at(-1).path
    expect(asked).toContain('q=blog')
  })

  // The pause is what keeps a keystroke from becoming a request. Measured
  // from both sides, because that is the only way to see it: nothing goes out
  // while it is running, and exactly one call goes out when it is over.
  //
  // A count alone would not have noticed its removal — vue-router drops a
  // navigation that the next one overtakes, so four immediate searches still
  // arrive at the server as one.
  it('waits for the typing pause before it asks', async () => {
    const { wrapper, server } = await library({ routes: signedInRoutes([promptRow()]) })
    const before = server.callsTo('GET', '/prompts').length

    const field = wrapper.find('input[type="search"]')
    for (const term of ['b', 'bl', 'blo', 'blog']) await field.setValue(term)
    await settle()

    expect(server.callsTo('GET', '/prompts').length).toBe(before)

    await new Promise((resolve) => setTimeout(resolve, AFTER_TYPING))
    await settle()

    expect(server.callsTo('GET', '/prompts').length - before).toBe(1)
  })

  it('filters through the tag list and keeps the choice in the address', async () => {
    const { wrapper, router, server } = await library({
      routes: signedInRoutes([promptRow()], [{ id: 3, name: 'seo', usage_count: 12 }])
    })

    expect(wrapper.find('.tags__item').text()).toContain('12')

    await wrapper.find('.tags__item').trigger('click')
    await settle()

    expect(router.currentRoute.value.query.tags).toBe('3')
    expect(server.callsTo('GET', '/prompts').at(-1).path).toContain('tags%5B%5D=3')
  })

  it('toggles the favourite filter and the archive filter', async () => {
    const { wrapper, router, server } = await library({ routes: signedInRoutes([promptRow()]) })

    const button = (label) => wrapper.findAll('button').find((entry) => entry.text().includes(label))

    await button('Favourites only').trigger('click')
    await settle()
    expect(router.currentRoute.value.query.favorites).toBe('1')
    expect(server.callsTo('GET', '/prompts').at(-1).path).toContain('favorites_only=true')

    await button('Archived only').trigger('click')
    await settle()
    expect(router.currentRoute.value.query.archived).toBe('1')
    expect(server.callsTo('GET', '/prompts').at(-1).path).toContain('status=archived')
  })

  // The counter-check to the one above: without an explicit filter the
  // request must carry no status at all, or archived prompts would be on
  // display the whole time (11.3).
  it('does not ask for archived ones without an explicit filter', async () => {
    const { server } = await library({ routes: signedInRoutes([promptRow()]) })

    expect(server.callsTo('GET', '/prompts')[0].path).not.toContain('status=')
  })

  it('takes a shared link with filters exactly as it arrives', async () => {
    const { wrapper, server } = await library({
      routes: signedInRoutes([promptRow()], [{ id: 3, name: 'seo', usage_count: 12 }]),
      at: '/?workspace=9&search=blog&tags=3&favorites=1&sort=title'
    })

    const asked = server.callsTo('GET', '/prompts').at(-1).path
    expect(asked).toContain('q=blog')
    expect(asked).toContain('tags%5B%5D=3')
    expect(asked).toContain('favorites_only=true')
    expect(asked).toContain('sort=title')
    // And the controls show it, or the address and the screen would disagree.
    expect(wrapper.find('input[type="search"]').element.value).toBe('blog')
    expect(wrapper.find('.tags__item').attributes('aria-pressed')).toBe('true')
  })
})

describe('Keyboard operation', () => {
  it('leads from the search box into the list with Enter', async () => {
    const { wrapper } = await library({
      routes: signedInRoutes([promptRow(), promptRow({ id: 2, title: 'Zweiter' })])
    })

    await wrapper.find('input[type="search"]').trigger('keydown', { key: 'Enter' })
    await settle()

    // The definition of done for AP-10: a hit is reachable without moving a
    // mouse.
    expect(document.activeElement).toBe(openButtons(wrapper)[0].element)
  })

  // Typing and pressing Enter straight away is what people do — the pause
  // after the last keystroke is still running at that moment. The focus has
  // to land on the first hit of the *new* result, not of the one that is
  // about to be replaced. In the browser that mistake showed as no focus at
  // all: the row was gone by the time it was focused.
  it('searches at once on Enter and jumps into the new result', async () => {
    const many = [promptRow(), promptRow({ id: 2, title: 'Zweiter' })]
    const { wrapper } = await library({
      routes: [
        { method: 'GET', path: '/prompts', query: 'q=Zweiter', body: { prompts: [many[1]], meta: { total: 1 } } },
        ...signedInRoutes(many)
      ]
    })
    expect(openButtons(wrapper)).toHaveLength(2)

    const field = wrapper.find('input[type="search"]')
    await field.setValue('Zweiter')
    await field.trigger('keydown', { key: 'Enter' })
    await settle()

    expect(openButtons(wrapper)).toHaveLength(1)
    expect(document.activeElement).toBe(openButtons(wrapper)[0].element)
    expect(openButtons(wrapper)[0].text()).toContain('Zweiter')
  })

  it('moves between the hits with the arrow keys', async () => {
    const { wrapper } = await library({
      routes: signedInRoutes([promptRow(), promptRow({ id: 2, title: 'Zweiter' })])
    })

    await wrapper.find('input[type="search"]').trigger('keydown', { key: 'ArrowDown' })
    await settle()
    await openButtons(wrapper)[0].trigger('keydown', { key: 'ArrowDown' })

    expect(document.activeElement).toBe(openButtons(wrapper)[1].element)

    await openButtons(wrapper)[1].trigger('keydown', { key: 'ArrowUp' })
    expect(document.activeElement).toBe(openButtons(wrapper)[0].element)
  })

  it('stops at the start and at the end of the list', async () => {
    const { wrapper } = await library({
      routes: signedInRoutes([promptRow(), promptRow({ id: 2, title: 'Zweiter' })])
    })

    await wrapper.find('input[type="search"]').trigger('keydown', { key: 'Enter' })
    await settle()
    await openButtons(wrapper)[0].trigger('keydown', { key: 'ArrowUp' })

    // Not wrapping round to the last entry: the list is a list, not a wheel,
    // and an unexpected jump to the far end loses the reader's place.
    expect(document.activeElement).toBe(openButtons(wrapper)[0].element)

    await openButtons(wrapper)[0].trigger('keydown', { key: 'End' })
    expect(document.activeElement).toBe(openButtons(wrapper)[1].element)
  })

  // 11.6: single-key shortcuts work only outside input fields.
  it('brings the focus back into the search box with the slash key', async () => {
    const { wrapper } = await library({ routes: signedInRoutes([promptRow()]) })

    openButtons(wrapper)[0].element.focus()
    expect(document.activeElement).not.toBe(wrapper.find('input[type="search"]').element)

    window.dispatchEvent(new KeyboardEvent('keydown', { key: '/', bubbles: true }))
    await settle()

    expect(document.activeElement).toBe(wrapper.find('input[type="search"]').element)
  })

  // The counter-check. Without it the shortcut would swallow the character in
  // the search field itself, and nobody could search for a path.
  it('leaves the slash a character while inside an input field', async () => {
    const { wrapper } = await library({ routes: signedInRoutes([promptRow()]) })
    const field = wrapper.find('input[type="search"]')

    const event = new KeyboardEvent('keydown', { key: '/', bubbles: true, cancelable: true })
    field.element.focus()
    field.element.dispatchEvent(event)

    expect(event.defaultPrevented).toBe(false)
  })

  it('clears the search box and the focus with Escape', async () => {
    const { wrapper, router } = await library({ routes: signedInRoutes([promptRow()]) })
    await type(wrapper, 'blog')

    await wrapper.find('input[type="search"]').trigger('keydown', { key: 'Escape' })
    await settle()

    expect(router.currentRoute.value.query.search).toBeUndefined()
    expect(document.activeElement).not.toBe(wrapper.find('input[type="search"]').element)
  })
})

describe('Empty states', () => {
  // TF-420, and the difference that decides which one is shown: "nothing
  // matches" is answered by changing the filter, "there is nothing here" by
  // creating something. Offering the wrong one is worse than offering none.
  it('offers the way back after a search that found nothing', async () => {
    const { wrapper, router } = await library({ routes: signedInRoutes([]) })
    await type(wrapper, 'gibtesnicht')

    expect(wrapper.text()).toContain('No matches')
    expect(wrapper.text()).toContain('gibtesnicht')

    await wrapper.findAll('button').find((entry) => entry.text().includes('Clear filters')).trigger('click')
    await settle()

    expect(router.currentRoute.value.query.search).toBeUndefined()
  })

  it('explains what a prompt even is when there is nothing yet', async () => {
    const { wrapper } = await library({ routes: signedInRoutes([]) })

    expect(wrapper.text()).toContain('No prompts yet')
    expect(wrapper.text()).toContain('placeholders')
  })

  it('shows a server error together with the way to try again', async () => {
    const { wrapper } = await library({
      routes: [
        { method: 'GET', path: '/auth/me', body: { user: { id: 1, name: 'Martin', email: 'm@test' } } },
        { method: 'GET', path: '/workspaces', body: { workspaces: [{ id: 9, name: 'Marketing', is_personal: false, role: 'editor' }], selected_workspace_id: 9 } },
        { method: 'GET', path: '/tags', body: { tags: [] } },
        { method: 'GET', path: '/prompts', ...apiError(500, 'server_error') }
      ]
    })

    expect(wrapper.find('[role="alert"]').text()).toContain('Something went wrong')
    expect(wrapper.text()).toContain('Try again')
  })
})

describe('All workspaces (FA-509)', () => {
  it('shows the origin on the row and hides the management', async () => {
    const { wrapper } = await library({
      routes: signedInRoutes([promptRow({ workspace_name: 'Vertrieb' })]),
      at: '/?workspace=all',
      // Without an existing management screen there would be nothing to hide,
      // and the assertion below would hold whatever the rule did.
      extraRoutes: [{ path: '/trash', name: 'trash', component: BLANK }]
    })

    expect(rows(wrapper)[0].text()).toContain('Vertrieb')
    // 11.2: the management entries need one unambiguous workspace, and here
    // there is none.
    expect(wrapper.text()).not.toContain('Management')
    // The tag list goes for the same reason: tags belong to a workspace.
    expect(wrapper.find('.tags__item').exists()).toBe(false)
  })

  // One workspace, one name. The personal one keeps a German name in the
  // database (`Persönlich-<Name>`, written when the account is made) and the
  // interface shows a translated label for it. The row used to print the
  // stored name, so the same workspace read "Personal workspace" in the
  // switcher above and "Persönlich-Martin" in the line below — with nothing
  // to tell a reader they are the same place.
  it('names the personal workspace on the row as the switcher does', async () => {
    const { wrapper } = await library({
      routes: signedInRoutes([
        promptRow({ workspace_name: 'Persönlich-Martin', workspace_is_personal: true })
      ]),
      at: '/?workspace=all'
    })

    const row = rows(wrapper)[0].text()

    expect(row).toContain('Personal workspace')
    expect(row).not.toContain('Persönlich-Martin')
  })

  // The counter-check: in a single workspace the origin would be noise on
  // every line, and the management entries belong there.
  it('leaves the origin mark out inside a single workspace', async () => {
    const { wrapper } = await library({
      routes: signedInRoutes([promptRow({ workspace_name: 'Marketing' })], [{ id: 3, name: 'seo', usage_count: 1 }]),
      at: '/?workspace=9',
      extraRoutes: [{ path: '/trash', name: 'trash', component: BLANK }]
    })

    expect(rows(wrapper)[0].find('.hit__origin').exists()).toBe(false)
    expect(wrapper.find('.tags__item').exists()).toBe(true)
    // The counter-check to the case above: here the management entries belong.
    expect(wrapper.text()).toContain('Management')
  })

  it('switches into the overall view through the header', async () => {
    const { wrapper, router } = await library({ routes: signedInRoutes([promptRow()]) })

    await wrapper.findAll('button').find((entry) => entry.text().includes('Workspace')).trigger('click')
    await settle()
    await wrapper.findAll('button').find((entry) => entry.text().includes('All workspaces')).trigger('click')
    await settle()

    expect(router.currentRoute.value.query.workspace).toBe('all')
  })

  it('does not carry the tag selection along when the workspace changes', async () => {
    const { wrapper, router } = await library({
      routes: [
        ...signedInRoutes([promptRow()], [{ id: 3, name: 'seo', usage_count: 1 }]),
        { method: 'PUT', path: '/workspaces/selection', body: { selected_workspace_id: 7 } }
      ],
      at: '/?workspace=9&tags=3'
    })

    await wrapper.findAll('button').find((entry) => entry.text().includes('Workspace')).trigger('click')
    await settle()
    await wrapper.findAll('button').find((entry) => entry.text().includes('Personal workspace')).trigger('click')
    await settle()

    // A tag identifier means nothing in another workspace. Carried over it
    // would filter by something that does not exist there and show an empty
    // list for no visible reason.
    expect(router.currentRoute.value.query.workspace).toBe('7')
    expect(router.currentRoute.value.query.tags).toBeUndefined()
  })
})
