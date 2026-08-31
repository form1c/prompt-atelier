import { describe, it, expect, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import {
  installFakeServer, signedInRoutes, apiError, WORKSPACES, ownerWorkspaces
} from './support/fake_server.js'

// S9 — the trash (FA-703, FA-704, W-9).
//
// Who may see and do what is the server's decision and is checked there
// (TF-335 to TF-337). What is checked here is what can only go wrong on the
// screen: that the three facts of FA-703 are really on the line — when, **by
// whom**, from where — that purging asks and restoring does not, and that no
// row carries a button the server would refuse.

const realFetch = globalThis.fetch

const deletedPrompt = (overrides = {}) => ({
  id: 21,
  workspace_id: 9,
  owner_id: 1,
  title: 'Versehentlich gelöscht',
  visibility: 'workspace',
  status: 'active',
  favorite: false,
  deleted_at: new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString(),
  deleted_by: 4,
  deleted_by_name: 'Martin',
  workspace_name: 'Marketing',
  workspace_is_personal: false,
  permissions: { restore: true, purge: false },
  ...overrides
})

const mounted = []

async function screen ({ prompts = [deletedPrompt()], routes = [], workspaces = WORKSPACES } = {}) {
  const server = installFakeServer([
    ...routes,
    { method: 'GET', path: '/workspaces', body: workspaces },
    ...signedInRoutes(),
    { method: 'GET', path: '/trash', body: { prompts } }
  ])
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')

  const router = createAppRouter(createMemoryHistory())
  const wrapper = mount(App, { global: { plugins: [router] }, attachTo: document.body })
  mounted.push(wrapper)
  await router.push('/trash')
  await settle()

  return { wrapper, router, server }
}

const rowOf = (wrapper, title) => wrapper.findAll('.entry').find((entry) => entry.text().includes(title))
const buttonNamed = (root, text) => root.findAll('button').find((entry) => entry.text().includes(text))

afterEach(() => {
  while (mounted.length) mounted.pop().unmount()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('The list (FA-703, TF-335)', () => {
  // The three facts the requirement names. The deleting user is the one that
  // matters: in a team an administrator may delete somebody else's prompt, and
  // its owner has to see who did. As an identifier the line would read
  // "gelöscht von 4", which answers nobody's question.
  it('names the moment, the deleting user and the origin', async () => {
    const { wrapper } = await screen()

    const row = rowOf(wrapper, 'Versehentlich gelöscht')
    expect(row.text()).toContain('Martin')
    expect(row.text()).toContain('Marketing')
    expect(row.text()).toMatch(/\d+ hours ago/)
  })

  // The same rule as in the library: one workspace has one name. The trash
  // used to print the stored `Persönlich-Martin` under a switcher reading
  // "Personal workspace".
  it('names the personal workspace as the switcher does', async () => {
    const { wrapper } = await screen({
      prompts: [deletedPrompt({ workspace_name: 'Persönlich-Martin', workspace_is_personal: true })]
    })

    const row = rowOf(wrapper, 'Versehentlich gelöscht')

    expect(row.text()).toContain('Personal workspace')
    expect(row.text()).not.toContain('Persönlich-Martin')
  })

  it('asks for the chosen workspace', async () => {
    const { server } = await screen()

    expect(server.callsTo('GET', '/trash')[0].path).toContain('workspace_id=9')
  })

  it('explains an empty trash instead of showing nothing', async () => {
    const { wrapper } = await screen({ prompts: [] })

    expect(wrapper.text()).toContain('The trash is empty')
  })
})

describe('Restoring (FA-703, TF-337)', () => {
  it('brings the prompt back without asking', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'POST', path: '/trash/21/restore', body: { prompt: {} } }]
    })

    await buttonNamed(rowOf(wrapper, 'Versehentlich'), 'Restore').trigger('click')
    await settle()

    expect(server.callsTo('POST', '/trash/21/restore')).toHaveLength(1)
    // No confirmation: restoring is the reversible direction, and asking for
    // one would stand in the way of the very thing this screen is for (11.6).
    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
  })

  it('reloads the list afterwards', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'POST', path: '/trash/21/restore', body: { prompt: {} } }]
    })

    await buttonNamed(rowOf(wrapper, 'Versehentlich'), 'Restore').trigger('click')
    await settle()

    expect(server.callsTo('GET', '/trash').length).toBe(2)
  })

  it('reports a refusal instead of letting the row disappear', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'POST',
        path: '/trash/21/restore',
        ...apiError(403, 'forbidden')
      }]
    })

    await buttonNamed(rowOf(wrapper, 'Versehentlich'), 'Restore').trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('No permission for this action.')
  })
})

describe('Deleting for good (FA-704)', () => {
  const purgeable = deletedPrompt({ permissions: { restore: true, purge: true } })

  it('asks beforehand, because it cannot be undone', async () => {
    const { wrapper, server } = await screen({
      prompts: [purgeable],
      workspaces: ownerWorkspaces(),
      routes: [{ method: 'DELETE', path: '/trash/21', body: { status: 'ok' } }]
    })

    await buttonNamed(rowOf(wrapper, 'Versehentlich'), 'Delete for good').trigger('click')
    await settle()

    expect(wrapper.find('[role="dialog"]').exists()).toBe(true)
    expect(server.callsTo('DELETE', '/trash/21')).toHaveLength(0)

    await wrapper.find('[data-test="confirm"]').trigger('click')
    await settle()

    expect(server.callsTo('DELETE', '/trash/21')).toHaveLength(1)
  })

  it('deletes nothing when the question is cancelled', async () => {
    const { wrapper, server } = await screen({
      prompts: [purgeable],
      workspaces: ownerWorkspaces()
    })

    await buttonNamed(rowOf(wrapper, 'Versehentlich'), 'Delete for good').trigger('click')
    await settle()
    await buttonNamed(wrapper.find('[role="dialog"]'), 'Cancel').trigger('click')
    await settle()

    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
    expect(server.callsTo('DELETE', '/trash/21')).toHaveLength(0)
  })

  // FA-704: purging is for `admin` and `owner` only. The answer comes per row
  // from the server (SEC-06) — derived here it would be a second copy of the
  // rule, and the second copy is the one nobody tests.
  it('offers the control only where the server allows it', async () => {
    const { wrapper } = await screen()

    const row = rowOf(wrapper, 'Versehentlich')
    expect(buttonNamed(row, 'Restore')).toBeDefined()
    expect(buttonNamed(row, 'Delete for good')).toBeUndefined()
  })

  // The counter-check to the case above: a row that may be purged and not
  // restored exists too — an administrator sees foreign deletions of prompts
  // they do not own.
  it('and the other way round as well', async () => {
    const { wrapper } = await screen({
      prompts: [deletedPrompt({ permissions: { restore: false, purge: true } })],
      workspaces: ownerWorkspaces()
    })

    const row = rowOf(wrapper, 'Versehentlich')
    expect(buttonNamed(row, 'Restore')).toBeUndefined()
    expect(buttonNamed(row, 'Delete for good')).toBeDefined()
  })
})

describe('Whoever has no trash', () => {
  // A viewer gets 403 from the server. The screen says so instead of asking
  // and displaying the refusal as an error.
  it('gets a sentence and no error message', async () => {
    const readOnly = { ...WORKSPACES, selected_workspace_id: 11 }
    const { wrapper, server } = await screen({ workspaces: readOnly })

    expect(wrapper.text()).toContain('No trash in this workspace')
    expect(wrapper.find('.alert').exists()).toBe(false)
    expect(server.callsTo('GET', '/trash')).toHaveLength(0)
  })
})
