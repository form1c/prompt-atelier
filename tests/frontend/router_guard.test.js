import { describe, it, expect, afterEach, vi } from 'vitest'
import { installFakeServer, signedInRoutes, apiError } from './support/fake_server.js'

// Which screen may be shown (FA-101, FA-103, FA-909, NT-2).
//
// This is not protection — the server refuses every unauthorised call
// regardless (SEC-06). It decides what someone sees instead: the sign-in
// screen, or a library that would fill up with 401s.
//
// Each test starts from a fresh module registry, because the session is a
// singleton in the browser too and its "not asked yet" state exists exactly
// once per page load.

const realFetch = globalThis.fetch

async function fresh () {
  vi.resetModules()
  const state = await import('../../frontend/src/state/session.js')
  const router = await import('../../frontend/src/router/index.js')
  return { ...state, ...router }
}

afterEach(() => {
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('The access guard', () => {
  it('asks the server on the first call who is signed in', async () => {
    const server = installFakeServer(signedInRoutes())
    const { guard } = await fresh()

    await expect(guard({ name: 'library', fullPath: '/', meta: {} })).resolves.toBe(true)
    expect(server.callsTo('GET', '/auth/me')).toHaveLength(1)
  })

  it('sends somebody not signed in to the sign-in and remembers the target', async () => {
    installFakeServer([
      { method: 'GET', path: '/auth/me', ...apiError(401, 'unauthorized') },
      { method: 'GET', path: '/setup/status', body: { setup_required: false } }
    ])
    const { guard } = await fresh()

    const verdict = await guard({ name: 'trash', fullPath: '/trash', meta: {} })

    expect(verdict).toEqual({ name: 'login', query: { next: '/trash' } })
  })

  it('keeps somebody signed in away from the sign-in page', async () => {
    installFakeServer(signedInRoutes())
    const { guard } = await fresh()

    const verdict = await guard({ name: 'login', fullPath: '/login', meta: { public: true } })

    expect(verdict).toEqual({ name: 'library' })
  })

  // FA-909: an instance without a single account can do exactly one thing.
  it('leads every route to the setup for an empty instance', async () => {
    installFakeServer([
      { method: 'GET', path: '/auth/me', ...apiError(401, 'unauthorized') },
      { method: 'GET', path: '/setup/status', body: { setup_required: true } }
    ])
    const { guard } = await fresh()

    expect(await guard({ name: 'library', fullPath: '/', meta: {} })).toEqual({ name: 'setup' })
    expect(await guard({ name: 'login', fullPath: '/login', meta: { public: true } })).toEqual({ name: 'setup' })
    expect(await guard({ name: 'setup', fullPath: '/setup', meta: { public: true } })).toBe(true)
  })

  // The counter-check to the case above: once the instance has an account,
  // the setup page is closed. Without this the first administrator could be
  // replaced by anyone who guessed the address.
  it('closes the setup page as soon as an account exists', async () => {
    installFakeServer([
      { method: 'GET', path: '/auth/me', ...apiError(401, 'unauthorized') },
      { method: 'GET', path: '/setup/status', body: { setup_required: false } }
    ])
    const { guard } = await fresh()

    expect(await guard({ name: 'setup', fullPath: '/setup', meta: { public: true } }))
      .toEqual({ name: 'login' })
  })

  it('takes only paths of the application itself as a continuation', async () => {
    const { continuation } = await fresh()

    expect(continuation('/prompts/12')).toEqual({ next: '/prompts/12' })
    // A protocol-relative address is a foreign host. Carried into the
    // sign-in screen it would turn it into a redirector to any site that
    // asks — with the sign-in of this instance as the bait.
    expect(continuation('//example.test/phish')).toEqual({})
    expect(continuation('https://example.test')).toEqual({})
    // The library is where an unmarked sign-in goes anyway.
    expect(continuation('/')).toEqual({})
  })
})

// NT-2: after signing out, the back button must not lead back into the
// application. Inside the application that is the guard's job. What the guard
// never sees is a page the browser restored from its cache — no navigation,
// no guard, the old screen simply reappears.
describe('Coming back from the browser cache', () => {
  function listenerTarget () {
    const listeners = {}
    return {
      addEventListener: (name, handler) => { listeners[name] = handler },
      fire: (name, event) => listeners[name]?.(event)
    }
  }

  it('checks the session again and sends somebody signed out to the sign-in', async () => {
    installFakeServer([
      { method: 'GET', path: '/auth/me', ...apiError(401, 'unauthorized') },
      { method: 'GET', path: '/setup/status', body: { setup_required: false } }
    ])
    const { revalidateOnRestore } = await fresh()
    const router = { replace: vi.fn() }
    const target = listenerTarget()

    revalidateOnRestore(router, target)
    await target.fire('pageshow', { persisted: true })

    expect(router.replace).toHaveBeenCalledWith({ name: 'login' })
  })

  it('leaves an ordinary display untouched', async () => {
    const server = installFakeServer(signedInRoutes())
    const { revalidateOnRestore } = await fresh()
    const router = { replace: vi.fn() }
    const target = listenerTarget()

    revalidateOnRestore(router, target)
    await target.fire('pageshow', { persisted: false })

    // Not restored from the cache means the application has just started and
    // is asking the server anyway. A second round trip on every load would be
    // waste, and one that redirects would be a bug.
    expect(server.calls).toHaveLength(0)
    expect(router.replace).not.toHaveBeenCalled()
  })

  it('lets somebody still signed in carry on working', async () => {
    installFakeServer(signedInRoutes())
    const { revalidateOnRestore } = await fresh()
    const router = { replace: vi.fn() }
    const target = listenerTarget()

    revalidateOnRestore(router, target)
    await target.fire('pageshow', { persisted: true })

    expect(router.replace).not.toHaveBeenCalled()
  })
})
