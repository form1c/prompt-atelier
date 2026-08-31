import { describe, it, expect, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import {
  installFakeServer, signedInRoutes, apiError, WORKSPACES, ownerWorkspaces
} from './support/fake_server.js'

// S5 — the workspace and its members (FA-603, FA-606, FA-608, W-5).
//
// The rules are the server's and are checked there: the last owner may not
// leave (TF-206), the personal workspace is untouchable (TF-205, TF-425).
// What is checked here is what the screen does with them — that it shows a
// refusal rather than swallowing it, that it offers nothing which can only
// end in one, and that a rename reaches the header too.

const realFetch = globalThis.fetch

const MEMBERS = [
  { user_id: 2, name: 'Sabine', email: 'owner@test', role: 'owner' },
  { user_id: 4, name: 'Martin', email: 'editor@test', role: 'editor' }
]

const mounted = []

async function screen ({ workspaces = ownerWorkspaces(), members = MEMBERS, routes = [] } = {}) {
  const server = installFakeServer([
    ...routes,
    { method: 'GET', path: '/workspaces', body: workspaces },
    ...signedInRoutes(),
    { method: 'GET', path: '/workspaces/9/members', body: { members } }
  ])
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')

  const router = createAppRouter(createMemoryHistory())
  const wrapper = mount(App, { global: { plugins: [router] }, attachTo: document.body })
  mounted.push(wrapper)
  await router.push('/workspace')
  await settle()

  return { wrapper, router, server }
}

// Searched inside a section rather than across the screen: "Role" appears
// twice — once on the form that adds somebody, and once, invisibly, on every
// row of the member list ("Rolle von Sabine"). The first version of this
// helper took the first match and thereby changed an existing member's role
// while the test claimed to be filling in a form.
const field = (root, label) => root.findAll('label').find((entry) => entry.text().startsWith(label))
const inputFor = (root, label) => field(root, label).find('input, select')
const invite = (wrapper) => wrapper.find('.workspace__invite')
const buttonNamed = (wrapper, text) => wrapper.findAll('button').find((entry) => entry.text().includes(text))
const rowOf = (wrapper, name) => wrapper.findAll('.entry').find((entry) => entry.text().includes(name))
const sent = (server, method, fragment) => JSON.parse(server.callsTo(method, fragment).at(-1).options.body)

afterEach(() => {
  while (mounted.length) mounted.pop().unmount()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('Renaming (FA-608)', () => {
  // The name is what everyone sees the workspace by, and the switcher in the
  // header shows it. So the check is on the header, not on a request count:
  // counting was the first attempt and a mutation probe walked straight
  // through it — the list is fetched more than once at sign-in anyway, so
  // "more than one call" was true with and without the refresh.
  it('sends the new name and puts it into the header', async () => {
    const renamed = ownerWorkspaces()
    renamed.workspaces = renamed.workspaces.map((entry) => (
      entry.id === 9 ? { ...entry, name: 'Marketing DACH' } : entry
    ))

    const { wrapper, server } = await screen({
      routes: [
        { method: 'PUT', path: '/workspaces/9', body: { workspace: { id: 9, name: 'Marketing DACH' } } },
        // The first fetch answers as before, everything after it with the new
        // name — which is what the server would do.
        { method: 'GET', path: '/workspaces', body: ownerWorkspaces(), once: true }
      ],
      workspaces: renamed
    })

    expect(wrapper.find('header').text()).toContain('Marketing')

    await inputFor(wrapper, 'Name of the workspace').setValue('Marketing DACH')
    await wrapper.find('[data-test="rename"]').trigger('click')
    await settle()

    expect(sent(server, 'PUT', '/workspaces/9')).toEqual({ name: 'Marketing DACH' })
    expect(wrapper.find('header').text()).toContain('Marketing DACH')
  })

  // A button that does nothing is an invitation to try it out.
  it('stays disabled as long as the name is unchanged', async () => {
    const { wrapper } = await screen()

    expect(wrapper.find('[data-test="rename"]').attributes('disabled')).toBeDefined()

    await inputFor(wrapper, 'Name of the workspace').setValue('Anders')
    await settle()
    expect(wrapper.find('[data-test="rename"]').attributes('disabled')).toBeUndefined()
  })

  // Permission matrix: renaming starts at `admin`. An editor sees the name
  // and cannot change it.
  it('offers no renaming to an editor', async () => {
    const { wrapper } = await screen({ workspaces: WORKSPACES })

    expect(wrapper.find('[data-test="rename"]').exists()).toBe(false)
    expect(inputFor(wrapper, 'Name of the workspace').attributes('disabled')).toBeDefined()
  })
})

describe('Creating (FA-601)', () => {
  // The only way to a workspace that can be shared. Until AP-13 the endpoint
  // existed and nothing called it — an installation could be run for a year
  // without a second workspace ever coming into being.
  it('creates a workspace and selects it right away', async () => {
    const fresh = { id: 21, name: 'Vertrieb', slug: 'vertrieb', is_personal: false, role: 'owner' }
    const { wrapper, server } = await screen({
      routes: [
        { method: 'POST', path: '/workspaces', status: 201, body: { workspace: fresh } },
        { method: 'PUT', path: '/workspaces/selection', body: { selected_workspace_id: 21 } }
      ]
    })

    await inputFor(wrapper.find('[aria-labelledby="workspace-new-heading"]'), 'Name').setValue('Vertrieb')
    await wrapper.find('[data-test="create"]').trigger('click')
    await settle()

    expect(sent(server, 'POST', '/workspaces')).toEqual({ name: 'Vertrieb' })
    // Making something and then having to look for it is a step nobody wants.
    expect(server.callsTo('PUT', '/workspaces/selection')).toHaveLength(1)
  })

  it('reports a refused name at the form', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'POST',
        path: '/workspaces',
        ...apiError(422, 'validation_failed')
      }]
    })

    await inputFor(wrapper.find('[aria-labelledby="workspace-new-heading"]'), 'Name').setValue('   x')
    await wrapper.find('[data-test="create"]').trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('The entry is incomplete or wrong.')
  })
})

describe('Members (FA-603)', () => {
  it('shows name, address and role', async () => {
    const { wrapper } = await screen()

    const row = rowOf(wrapper, 'Sabine')
    expect(row.text()).toContain('owner@test')
    expect(row.find('select').element.value).toBe('owner')
  })

  it('takes a member on board by their email address', async () => {
    const added = [...MEMBERS, { user_id: 5, name: 'Lisa', email: 'viewer@test', role: 'viewer' }]
    const { wrapper, server } = await screen({
      routes: [{ method: 'POST', path: '/workspaces/9/members', status: 201, body: { members: added } }]
    })

    await inputFor(invite(wrapper), 'Email address').setValue('viewer@test')
    await inputFor(invite(wrapper), 'Role').setValue('viewer')
    await wrapper.find('[data-test="add-member"]').trigger('click')
    await settle()

    expect(sent(server, 'POST', '/workspaces/9/members')).toEqual({ email: 'viewer@test', role: 'viewer' })
    expect(wrapper.text()).toContain('Lisa')
  })

  it('names an unknown address instead of swallowing it', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'POST',
        path: '/workspaces/9/members',
        ...apiError(422, 'unknown_user')
      }]
    })

    await inputFor(invite(wrapper), 'Email address').setValue('niemand@test')
    await wrapper.find('[data-test="add-member"]').trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('Unknown account')
  })

  it('changes a role', async () => {
    const changed = [MEMBERS[0], { ...MEMBERS[1], role: 'admin' }]
    const { wrapper, server } = await screen({
      routes: [{ method: 'PUT', path: '/workspaces/9/members/4', body: { members: changed } }]
    })

    await rowOf(wrapper, 'Martin').find('select').setValue('admin')
    await settle()

    expect(sent(server, 'PUT', '/workspaces/9/members/4')).toEqual({ role: 'admin' })
  })

  // TF-206 from the screen's side. The server refuses; the select has to go
  // back, or it shows a role that was never set — and the next look at the
  // screen says something untrue.
  it('takes the choice back when the server refuses the role change', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'PUT',
        path: '/workspaces/9/members/2',
        ...apiError(403, 'last_owner')
      }]
    })

    const select = rowOf(wrapper, 'Sabine').find('select')
    await select.setValue('admin')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('Another owner has to be appointed')
    expect(select.element.value).toBe('owner')
  })

  it('reports a refused removal as well', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'DELETE',
        path: '/workspaces/9/members/2',
        ...apiError(403, 'last_owner')
      }]
    })

    await rowOf(wrapper, 'Sabine').find('button').trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('Another owner has to be appointed')
    expect(wrapper.text()).toContain('Sabine')
  })

  // Its own row in the matrix: an `admin` manages members but may make
  // nobody an owner. Offering the role would only lead to a refusal.
  it('offers the owner role only to whoever may grant it', async () => {
    const asAdmin = ownerWorkspaces()
    asAdmin.workspaces = asAdmin.workspaces.map((entry) => (
      entry.id === 9
        ? { ...entry, role: 'admin', permissions: { ...entry.permissions, grant_owner: false, delete: false } }
        : entry
    ))
    const { wrapper } = await screen({ workspaces: asAdmin })

    const options = rowOf(wrapper, 'Martin').findAll('option').map((entry) => entry.element.value)
    expect(options).not.toContain('owner')

    // But the existing owner stays in their own field — otherwise the
    // display would claim Sabine is something else.
    expect(rowOf(wrapper, 'Sabine').find('select').element.value).toBe('owner')
  })
})

describe('Deleting (FA-606, TF-425)', () => {
  it('demands the name written out', async () => {
    const { wrapper } = await screen()

    await wrapper.find('[data-test="delete"]').trigger('click')
    await settle()

    const dialog = wrapper.find('[role="dialog"]')
    expect(dialog.find('[data-test="confirm"]').attributes('disabled')).toBeDefined()

    await dialog.find('input').setValue('Marketing')
    await settle()
    expect(dialog.find('[data-test="confirm"]').attributes('disabled')).toBeUndefined()
  })

  it('sends the name along and leads into the library afterwards', async () => {
    const { wrapper, router, server } = await screen({
      routes: [{ method: 'DELETE', path: '/workspaces/9', body: { status: 'ok' } }]
    })

    await wrapper.find('[data-test="delete"]').trigger('click')
    await settle()
    await wrapper.find('[role="dialog"] input').setValue('Marketing')
    await wrapper.find('[data-test="confirm"]').trigger('click')
    await settle()

    expect(sent(server, 'DELETE', '/workspaces/9')).toEqual({ confirm_name: 'Marketing' })
    expect(router.currentRoute.value.name).toBe('library')
  })

  // TF-425: for a personal workspace the action is **not offered at all**.
  // Not greyed out — the requirement says it is absent.
  it('does not offer the personal workspace for deletion', async () => {
    const personal = { ...ownerWorkspaces(), selected_workspace_id: 7 }
    const { wrapper } = await screen({ workspaces: personal })

    expect(wrapper.find('[data-test="delete"]').exists()).toBe(false)
    expect(buttonNamed(wrapper, 'Delete this workspace')).toBeUndefined()
    // And member management is absent too (FA-606): it has exactly one
    // member, for ever.
    expect(wrapper.find('[data-test="add-member"]').exists()).toBe(false)
    expect(wrapper.text()).toContain('personal workspace')
  })
})

describe('Whoever may not manage', () => {
  it('sees the name and no member list', async () => {
    const { wrapper, server } = await screen({ workspaces: WORKSPACES })

    expect(wrapper.text()).toContain('Marketing')
    expect(wrapper.text()).not.toContain('owner@test')
    // And it is not even asked: the answer would be 404, and the screen
    // would stand there as an error.
    expect(server.callsTo('GET', '/members')).toHaveLength(0)
  })
})
