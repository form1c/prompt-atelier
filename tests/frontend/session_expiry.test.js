import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import Harness from './support/ExpiryHarness.vue'
import { createAppRouter } from '../../frontend/src/router/index.js'
import { installExpiryHandler, loadSession, forgetSession, session } from '../../frontend/src/state/session.js'
import { requestSignIn } from '../../frontend/src/state/reauthentication.js'
import { onSessionExpired } from '../../frontend/src/api/client.js'
import { clearNotices } from '../../frontend/src/state/notices.js'
import { installFakeServer, signedInRoutes, apiError, SIGNED_IN_USER, WORKSPACES } from './support/fake_server.js'

// TF-415 — the session expires while someone is working.
//
// The expectation from the test concept has two halves, and the second is the
// one an implementation gets wrong: the inputs survive, *and* the interrupted
// action carries on afterwards. A sign-in that lands the user on an empty
// library has met the first half and lost the work all the same.

const realFetch = globalThis.fetch

async function signedInHarness () {
  const router = createAppRouter(createMemoryHistory())
  await router.push('/')
  await router.isReady()

  return mount(Harness, { global: { plugins: [router] } })
}

// flushPromises drains the microtask queue, which is enough for everything
// here except a route change: the router loads the target screen with a
// dynamic import, and that resolves a macrotask later. Without the extra turn
// the navigation would finish after the test has torn down its environment,
// and report as an unhandled rejection in an unrelated file.
async function settle () {
  await flushPromises()
  await new Promise((resolve) => setTimeout(resolve, 0))
  await flushPromises()
}

describe('An expired session while working', () => {
  beforeEach(() => {
    forgetSession()
    clearNotices()
    installExpiryHandler(requestSignIn)
  })

  afterEach(() => {
    globalThis.fetch = realFetch
    onSessionExpired(null)
    vi.restoreAllMocks()
  })

  it('holds the entries and carries on the interrupted action', async () => {
    const server = installFakeServer([
      ...signedInRoutes(),
      { method: 'POST', path: '/prompts', once: true, ...apiError(401, 'unauthorized') },
      { method: 'POST', path: '/auth/login', body: { user: SIGNED_IN_USER } },
      { method: 'GET', path: '/workspaces', body: WORKSPACES },
      { method: 'POST', path: '/prompts', status: 201, body: { prompt: { id: 5, title: 'Entwurf' } } }
    ])
    await loadSession()

    const wrapper = await signedInHarness()
    await wrapper.find('[data-test="draft"]').setValue('Draft')
    await wrapper.find('[data-test="save"]').trigger('click')
    await flushPromises()

    // The overlay is up, and the screen behind it is untouched.
    expect(wrapper.find('[role="dialog"]').exists()).toBe(true)
    expect(wrapper.find('[data-test="draft"]').element.value).toBe('Draft')

    // The address is already there — after an expiry it is known, and
    // retyping it would be friction with no purpose.
    const fields = wrapper.find('[role="dialog"]').findAll('input')
    expect(fields[0].element.value).toBe(SIGNED_IN_USER.email)

    await fields[1].setValue('richtig-und-lang-12')
    await wrapper.find('[role="dialog"] form').trigger('submit')
    await flushPromises()

    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
    expect(wrapper.find('[data-test="draft"]').element.value).toBe('Draft')
    expect(wrapper.vm.saved).toEqual({ prompt: { id: 5, title: 'Entwurf' } })
    expect(server.callsTo('POST', '/prompts')).toHaveLength(2)
  })

  // The counter-check. Without it the assertions above would also pass for an
  // overlay that appears on every write, whether or not a session expired.
  it('does not appear when the action succeeds', async () => {
    installFakeServer([
      ...signedInRoutes(),
      { method: 'POST', path: '/prompts', status: 201, body: { prompt: { id: 5 } } }
    ])
    await loadSession()

    const wrapper = await signedInHarness()
    await wrapper.find('[data-test="save"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
    expect(wrapper.vm.saved).toEqual({ prompt: { id: 5 } })
  })

  it('reports a wrong password in the toast without losing the screen', async () => {
    installFakeServer([
      ...signedInRoutes(),
      { method: 'POST', path: '/prompts', once: true, ...apiError(401, 'unauthorized') },
      { method: 'POST', path: '/auth/login', ...apiError(401, 'invalid_credentials') }
    ])
    await loadSession()

    const wrapper = await signedInHarness()
    await wrapper.find('[data-test="draft"]').setValue('Draft')
    await wrapper.find('[data-test="save"]').trigger('click')
    await flushPromises()

    const dialog = wrapper.find('[role="dialog"]')
    await dialog.findAll('input')[1].setValue('falsch')
    await dialog.find('form').trigger('submit')
    await flushPromises()

    expect(wrapper.find('[role="dialog"]').exists()).toBe(true)
    expect(wrapper.find('[role="dialog"]').text()).toContain('not correct')
    expect(wrapper.find('[data-test="draft"]').element.value).toBe('Draft')
  })

  it('releases the waiting call when the user signs out instead', async () => {
    installFakeServer([
      ...signedInRoutes(),
      { method: 'POST', path: '/prompts', ...apiError(401, 'unauthorized') },
      { method: 'POST', path: '/auth/logout', body: { status: 'ok' } }
    ])
    await loadSession()

    const wrapper = await signedInHarness()
    await wrapper.find('[data-test="save"]').trigger('click')
    await flushPromises()

    const buttons = wrapper.find('[role="dialog"]').findAll('button')
    await buttons[buttons.length - 1].trigger('click')
    await settle()

    // A promise nobody settles would leave the screen waiting for ever, with
    // a spinner that never stops and no way to tell what happened.
    expect(wrapper.vm.failure).toMatchObject({ status: 401 })
    expect(session.user).toBeNull()
  })
})
