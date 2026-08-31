import { vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './flush.js'
import { installFakeServer, signedInRoutes, SIGNED_IN_USER, WORKSPACES } from './fake_server.js'

// Mounting an administration screen (S6).
//
// Since AP-15b the administration is four screens behind one entry in the
// sidebar, so each suite says which one it wants. The shared answers live
// here rather than being copied four times — a stand-in that differs between
// suites is a stand-in that answers as no server does.

export const ACCOUNTS = [
  {
    id: 1, name: 'Martin', email: 'editor@test', status: 'active', is_instance_admin: false,
    must_change_password: false, last_login_at: new Date(Date.now() - 3600000).toISOString(),
    prompt_count: 4, workspace_count: 2
  },
  {
    id: 2, name: 'Lisa', email: 'viewer@test', status: 'locked', is_instance_admin: false,
    must_change_password: false, last_login_at: null, prompt_count: 0, workspace_count: 1
  }
]

// Somebody who registered and is waiting. Deliberately named so they sort
// between the other two by name: if the list is not moving them to the top,
// the alphabet would leave them in the middle and the assertion would fail.
export const PENDING = {
  id: 3, name: 'Nina', email: 'nina@example.test', status: 'locked', is_instance_admin: false,
  must_change_password: false, last_login_at: null, prompt_count: 0, workspace_count: 1,
  pending_since: new Date().toISOString()
}

export const WORKSPACE_ROWS = [
  { id: 9, name: 'Marketing', is_personal: false, owner: 'Sabine', member_count: 4, prompt_count: 8 }
]

export const AUDIT = [
  { id: 3, actor_name: 'Thomas', action: 'user.created', target_type: 'user', target_id: 1,
    created_at: new Date().toISOString() }
]

export const AUDIT_ACTIONS = ['user.created', 'user.approved', 'login.failed', 'login.failed.collapsed']

// Shaped as the server really answers (15.3): a page, the paging data beside
// it and the list of kinds the filter offers. A stand-in that left any of
// them out would let a screen pass that never shows them.
export function auditAnswer (entries = AUDIT, meta = {}) {
  return {
    method: 'GET',
    path: '/admin/audit',
    body: {
      entries,
      actions: AUDIT_ACTIONS,
      meta: { total: entries.length, page: 1, per_page: 50, ...meta }
    }
  }
}

export const SETTINGS = [
  {
    key: 'security.registration', value: 'off', from_file: true,
    kind: 'registration_mode', choices: ['off', 'approval', 'open']
  },
  { key: 'retention.trash_days', value: 30, from_file: true, kind: 'positive_integer', choices: null },
  { key: 'retention.audit_months', value: 12, from_file: false, kind: 'positive_integer', choices: null }
]

const mounted = []

export async function adminScreen (path, { routes = [], accounts = ACCOUNTS } = {}) {
  const server = installFakeServer([
    ...routes,
    { method: 'GET', path: '/admin/users', body: { users: accounts } },
    { method: 'GET', path: '/admin/workspaces', body: { workspaces: WORKSPACE_ROWS } },
    auditAnswer(),
    { method: 'GET', path: '/admin/settings', body: { settings: SETTINGS } },
    { method: 'GET', path: '/auth/me', body: { user: { ...SIGNED_IN_USER, is_instance_admin: true } } },
    { method: 'GET', path: '/workspaces', body: WORKSPACES },
    ...signedInRoutes()
  ])
  vi.resetModules()
  const { default: App } = await import('../../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../../frontend/src/router/index.js')

  const router = createAppRouter(createMemoryHistory())
  const wrapper = mount(App, { global: { plugins: [router] }, attachTo: document.body })
  mounted.push(wrapper)
  await router.push(path)
  await settle()

  return { wrapper, router, server }
}

export function unmountAll () {
  while (mounted.length) mounted.pop().unmount()
}

export const rowOf = (wrapper, name) =>
  wrapper.findAll('.entry').find((entry) => entry.text().includes(name))
export const buttonNamed = (root, text) =>
  root.findAll('button').find((entry) => entry.text().includes(text))
export const dialog = (wrapper) => wrapper.find('[role="dialog"]')
