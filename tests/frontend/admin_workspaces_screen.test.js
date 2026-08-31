import { describe, it, expect, afterEach, vi } from 'vitest'
import { adminScreen, unmountAll, rowOf } from './support/admin.js'

// S6, workspaces (FA-907).

const realFetch = globalThis.fetch

afterEach(() => {
  unmountAll()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('The workspace overview (FA-907)', () => {
  // Chapter 6.2: counts and an owner, and no way into anybody's content. The
  // shape of this list is the promise.
  it('shows workspaces with numbers and without content', async () => {
    const { wrapper } = await adminScreen('/administration/workspaces')

    const row = rowOf(wrapper, 'Marketing')
    expect(row.text()).toContain('Owner Sabine')
    expect(row.text()).toContain('4 members')
    expect(row.text()).toContain('8 prompts')
    expect(row.findAll('a')).toHaveLength(0)
    expect(row.findAll('button')).toHaveLength(0)
  })

  // Each section fetches its own data. Before AP-15b one page loaded accounts,
  // workspaces and the log on every visit, even when somebody only wanted to
  // reset a password.
  it('loads only its own stock', async () => {
    const { server } = await adminScreen('/administration/workspaces')

    expect(server.callsTo('GET', '/admin/workspaces')).toHaveLength(1)
    expect(server.callsTo('GET', '/admin/audit')).toHaveLength(0)
    expect(server.callsTo('GET', '/admin/settings')).toHaveLength(0)
  })
})
