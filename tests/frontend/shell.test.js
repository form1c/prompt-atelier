import { describe, it, expect, afterEach, vi } from 'vitest'
import { h } from 'vue'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import { installFakeServer, signedInRoutes, SIGNED_IN_USER, WORKSPACES } from './support/fake_server.js'

// The frame around every signed-in screen (Requirements 11.2).

const realFetch = globalThis.fetch

const BLANK = { render: () => h('p', 'x') }

async function shell ({ user = SIGNED_IN_USER, extraRoutes = [] } = {}) {
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')
  const state = await import('../../frontend/src/state/session.js')

  const router = createAppRouter(createMemoryHistory())
  for (const route of extraRoutes) router.addRoute(route)

  const wrapper = mount(App, { global: { plugins: [router] } })
  await router.push('/')
  await settle()

  return { wrapper, router, state, user }
}

afterEach(() => {
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('Base layout', () => {
  // The list grows with the packages: what stands here is exactly what has a
  // screen. The counter-check is the entry that does not exist yet — without
  // it this case would only assert that something is there, and every new
  // screen would just mean updating a list.
  it('shows only entries whose screen exists', async () => {
    installFakeServer(signedInRoutes())
    const { wrapper } = await shell()

    const links = wrapper.findAll('nav a')
    const labels = links.map((link) => link.text())

    expect(labels).toEqual(['Library', 'Keywords', 'Workspace', 'Import/Export', 'Trash'])
    // Favourites and "recently used" are their own screens and do not exist
    // yet, so they are not in the menu.
    expect(labels).not.toContain('Favourites')

    // Every entry leads somewhere. A menu that lists the screens of the
    // packages still to come would be a list of dead ends, and the second
    // list to keep in step with the router.
    for (const link of links) {
      expect(link.attributes('href')).not.toBe('')
    }
  })

  it('takes an entry on board as soon as its screen exists', async () => {
    installFakeServer(signedInRoutes())
    const { wrapper } = await shell({
      extraRoutes: [{ path: '/favorites', name: 'favorites', component: BLANK }]
    })

    const labels = wrapper.findAll('nav a').map((link) => link.text())
    expect(labels).toContain('Favourites')
    expect(wrapper.text()).toContain('Management')
  })

  // 6.2: the instance section belongs to instance administrators.
  it('shows the instance section only to the instance administrator', async () => {
    installFakeServer([
      { method: 'GET', path: '/auth/me', body: { user: { ...SIGNED_IN_USER, is_instance_admin: true } } },
      { method: 'GET', path: '/workspaces', body: WORKSPACES }
    ])
    const { wrapper } = await shell({
      extraRoutes: [{ path: '/verwaltung', name: 'administration', component: BLANK }]
    })

    expect(wrapper.findAll('nav a').map((link) => link.text())).toContain('Admin')
  })

  // The counter-check. Hiding the entry is convenience, not protection — the
  // server refuses the calls behind it either way (SEC-06) — but an entry
  // that leads to a screen full of 403s is a defect all the same.
  it('does not show it to an ordinary account', async () => {
    installFakeServer(signedInRoutes())
    const { wrapper } = await shell({
      extraRoutes: [{ path: '/verwaltung', name: 'administration', component: BLANK }]
    })

    expect(wrapper.findAll('nav a').map((link) => link.text())).not.toContain('Admin')
    expect(wrapper.text()).not.toContain('Instance')
  })

  // FA-605
  it('switches the workspace and remembers the choice on the server', async () => {
    const server = installFakeServer([
      ...signedInRoutes(),
      { method: 'PUT', path: '/workspaces/selection', body: { selected_workspace_id: 7 } }
    ])
    const { wrapper, state } = await shell()

    const opener = wrapper.findAll('button').find((button) => button.text().includes('Workspace'))
    await opener.trigger('click')
    await settle()

    const entry = wrapper.findAll('button').find((button) => button.text().includes('Personal workspace'))
    await entry.trigger('click')
    await settle()

    expect(state.session.selectedWorkspaceId).toBe(7)
    expect(server.callsTo('PUT', '/workspaces/selection')).toHaveLength(1)
    expect(wrapper.find('header').text()).toContain('Personal workspace')
  })

  // Raised from a user test: on the profile screen the switcher looked as if
  // it held nothing but the personal workspace. It does not — the list is the
  // session's, and the session is one per browser, not one per screen. What
  // *is* missing there is the entry below the divider, "All workspaces", and
  // that one is deliberate: it is a view over the library and the profile is
  // not a library (11.2).
  //
  // Pinned here because the difference is easy to read as a lost list, and
  // because a screen that ever did shorten it would be a real defect.
  it('holds the same workspaces on a screen that is about no workspace', async () => {
    installFakeServer(signedInRoutes())
    const { wrapper, router } = await shell()

    await router.push('/profile')
    await settle()

    const opener = wrapper.findAll('button').find((button) => button.text().includes('Workspace'))
    await opener.trigger('click')
    await settle()

    const entries = wrapper.findAll('.menu__list button').map((button) => button.text())

    // Three of them, including the one that is only readable: membership is
    // what puts a workspace in this list, not what may be done in it.
    expect(entries).toEqual(['Personal workspace personal', 'Marketing', 'Nur-Lesen'])
    expect(entries).not.toContain('All workspaces')
  })

  it('sends no request when the chosen workspace is already the current one', async () => {
    const server = installFakeServer([
      ...signedInRoutes(),
      { method: 'PUT', path: '/workspaces/selection', body: { selected_workspace_id: 9 } }
    ])
    const { wrapper } = await shell()

    const opener = wrapper.findAll('button').find((button) => button.text().includes('Workspace'))
    await opener.trigger('click')
    await settle()

    const entry = wrapper.findAll('button').find((button) => button.text().includes('Marketing'))
    await entry.trigger('click')
    await settle()

    expect(server.callsTo('PUT', '/workspaces/selection')).toHaveLength(0)
  })
})

// TF-553 — the running version is on the screen.
//
// **The endpoint has existed since AP-01 and nothing displayed it.** The only
// way to learn which version an instance ran was the command line — on a
// machine the person reporting a fault usually cannot reach. A bug report
// without a version costs a round trip every time.
describe('The version in the sidebar (TF-553)', () => {
  it('shows the version the server reports, in the account menu', async () => {
    installFakeServer([...signedInRoutes(), { method: 'GET', path: '/version', body: { app: '1.0.0', schema: 6 } }])
    const { wrapper } = await shell()

    const account = wrapper.findAll('button').find((button) => button.text().includes(SIGNED_IN_USER.name))
    await account.trigger('click')
    await settle()

    expect(wrapper.find('.menu__note').text()).toBe('Version 1.0.0')
  })

  // The second place. The sidebar shows it without a click, which is where it
  // reads best, but the library fills that same sidebar with the tag list of
  // the workspace and can push it off the screen. Hence both.
  it('also stands at the foot of the sidebar, without a click', async () => {
    installFakeServer([...signedInRoutes(), { method: 'GET', path: '/version', body: { app: '1.0.0', schema: 6 } }])
    const { wrapper } = await shell()

    expect(wrapper.find('.shell__version').text()).toBe('Version 1.0.0')
    expect(wrapper.find('.shell__sidebar').text()).toContain('1.0.0')
  })

  // **The assertion that makes the case worth having.** `matches()` in the
  // fake server compares with `endsWith`, so a route written as `/version`
  // answers `/api/v1/version` just as happily — and the case above would be
  // green over a request to a route that does not exist on the real server.
  // What is checked here is the URL that actually went out.
  it('asks the operational path, not the API path', async () => {
    const server = installFakeServer([...signedInRoutes(), { method: 'GET', path: '/version', body: { app: '1.0.0', schema: 6 } }])
    await shell()

    const call = server.calls.find((entry) => entry.path.includes('version'))

    expect(call.path).toBe('/version')
    expect(call.path).not.toContain('/api/v1')
  })

  // A server that answers everything else but not this one must not take the
  // interface down with it. A red box over a version number would be worse
  // than no version number.
  it('stays quiet when the version cannot be read', async () => {
    installFakeServer([...signedInRoutes(), { method: 'GET', path: '/version', status: 500, body: {} }])
    const { wrapper } = await shell()

    const account = wrapper.findAll('button').find((button) => button.text().includes(SIGNED_IN_USER.name))
    await account.trigger('click')
    await settle()

    expect(wrapper.find('.menu__note').exists()).toBe(false)
    expect(wrapper.find('.shell__version').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('Version')
  })
})
