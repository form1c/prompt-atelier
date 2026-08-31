import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
  session, isSignedIn, loadSession, signIn, signOut, selectWorkspace,
  selectedWorkspace, forgetSession, completeSetup
} from '../../frontend/src/state/session.js'
import { onSessionExpired } from '../../frontend/src/api/client.js'
import {
  installFakeServer, signedInRoutes, apiError, SIGNED_IN_USER, WORKSPACES
} from './support/fake_server.js'

// Who is signed in — the state every screen depends on (FA-101 to FA-103,
// FA-605).

const realFetch = globalThis.fetch

describe('Session state', () => {
  beforeEach(() => {
    // The state is a module singleton, as it is in the browser. Each test
    // starts from the signed-out state rather than from whatever the previous
    // one left behind.
    forgetSession()
    onSessionExpired(null)
  })

  afterEach(() => {
    globalThis.fetch = realFetch
    vi.restoreAllMocks()
  })

  it('takes account and workspaces from the answer of the server', async () => {
    installFakeServer(signedInRoutes())

    await loadSession()

    expect(isSignedIn()).toBe(true)
    expect(session.user.name).toBe('Martin')
    expect(session.workspaces).toHaveLength(3)
    // What the server remembers, not the first entry in the list.
    expect(session.selectedWorkspaceId).toBe(9)
    expect(selectedWorkspace().name).toBe('Marketing')
  })

  it('reports a browser without a session as signed out, not as an error', async () => {
    installFakeServer([
      { method: 'GET', path: '/auth/me', ...apiError(401, 'unauthorized') },
      { method: 'GET', path: '/setup/status', body: { setup_required: false } }
    ])

    await expect(loadSession()).resolves.toBe('signed-out')
    expect(isSignedIn()).toBe(false)
  })

  // FA-909
  it('recognises an instance without any account', async () => {
    installFakeServer([
      { method: 'GET', path: '/auth/me', ...apiError(401, 'unauthorized') },
      { method: 'GET', path: '/setup/status', body: { setup_required: true } }
    ])

    await expect(loadSession()).resolves.toBe('setup')
  })

  it('passes on an error that is not a missing sign-in', async () => {
    installFakeServer([{ method: 'GET', path: '/auth/me', fail: true }])

    await expect(loadSession()).rejects.toMatchObject({ code: 'network' })
  })

  it('signs in and loads the workspaces along with it', async () => {
    const server = installFakeServer([
      { method: 'POST', path: '/auth/login', body: { user: SIGNED_IN_USER } },
      { method: 'GET', path: '/workspaces', body: WORKSPACES }
    ])

    await signIn('martin@example.test', 'geheim-genug-12')

    expect(isSignedIn()).toBe(true)
    expect(session.workspaces).toHaveLength(3)
    expect(JSON.parse(server.calls[0].options.body)).toEqual({
      email: 'martin@example.test', password: 'geheim-genug-12'
    })
  })

  it('creates the first account during setup and is signed in afterwards', async () => {
    installFakeServer([
      { method: 'POST', path: '/setup', status: 201, body: { user: { ...SIGNED_IN_USER, is_instance_admin: true } } },
      { method: 'GET', path: '/workspaces', body: WORKSPACES }
    ])

    await completeSetup({ name: 'Thomas', email: 't@example.test', password: 'lang-genug-12345' })

    expect(session.user.is_instance_admin).toBe(true)
  })

  it('signs out and clears the state', async () => {
    installFakeServer([...signedInRoutes(), { method: 'POST', path: '/auth/logout', body: { status: 'ok' } }])
    await loadSession()

    await signOut()

    expect(isSignedIn()).toBe(false)
    expect(session.user).toBeNull()
    expect(session.workspaces).toEqual([])
  })

  // A sign-out that the server never heard about must still empty the screen.
  // The other way round — keeping the name on display because the request
  // failed — would leave someone looking at an interface they have just told
  // to let them out.
  it('clears the state even when the server does not answer', async () => {
    installFakeServer([...signedInRoutes(), { method: 'POST', path: '/auth/logout', fail: true }])
    await loadSession()

    await expect(signOut()).rejects.toMatchObject({ code: 'network' })

    expect(isSignedIn()).toBe(false)
    expect(session.user).toBeNull()
  })

  // FA-605, TF-308f: the choice is kept on the server, so a second device
  // lands in the same workspace.
  it('remembers the workspace choice on the server', async () => {
    const server = installFakeServer([
      ...signedInRoutes(),
      { method: 'PUT', path: '/workspaces/selection', body: { selected_workspace_id: 7 } }
    ])
    await loadSession()

    await selectWorkspace(7)

    expect(session.selectedWorkspaceId).toBe(7)
    expect(selectedWorkspace().is_personal).toBe(true)
    expect(JSON.parse(server.callsTo('PUT', '/workspaces/selection')[0].options.body))
      .toEqual({ workspace_id: 7 })
  })
})
