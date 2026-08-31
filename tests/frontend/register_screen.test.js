import { describe, it, expect, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import { installFakeServer, apiError, SIGNED_IN_USER, WORKSPACES } from './support/fake_server.js'

// S11 — a way in of one's own (FA-107).
//
// The setting belongs to the instance and is delivered switched off. What is
// checked here is that the screen never decides it for itself: the link on the
// sign-in screen, the form, and what happens after submitting all follow the
// server's answer.

const realFetch = globalThis.fetch

function registration (mode) {
  return {
    method: 'GET',
    path: '/auth/registration',
    body: {
      registration: {
        enabled: mode !== 'off',
        approval_required: mode === 'approval'
      }
    }
  }
}

function signedOut (mode, extra = []) {
  return [
    ...extra,
    { method: 'GET', path: '/auth/me', ...apiError(401, 'unauthorized') },
    { method: 'GET', path: '/setup/status', body: { setup_required: false } },
    registration(mode)
  ]
}

const mounted = []

async function screen (at, routes) {
  const server = installFakeServer(routes)
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')

  const router = createAppRouter(createMemoryHistory())
  const wrapper = mount(App, { global: { plugins: [router] }, attachTo: document.body })
  mounted.push(wrapper)
  await router.push(at)
  await settle()

  return { wrapper, router, server }
}

afterEach(() => {
  for (const wrapper of mounted.splice(0)) wrapper.unmount()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('The way to registration (FA-107)', () => {
  it('offers a way on the sign-in page as soon as the instance has one', async () => {
    const { wrapper } = await screen('/login', signedOut('approval'))

    expect(wrapper.find('[data-test="to-register"]').exists()).toBe(true)
  })

  // The counter-case, and without it the one above proves nothing: a link
  // rendered unconditionally would pass it just as well.
  it('does not offer it while the instance does not have it', async () => {
    const { wrapper } = await screen('/login', signedOut('off'))

    expect(wrapper.find('[data-test="to-register"]').exists()).toBe(false)
    expect(wrapper.text()).toContain('Forgotten your password?')
  })

  // A bookmark outlives a change of configuration. The address stays
  // reachable and says what is going on, rather than showing a form whose
  // every submission would answer 403.
  it('declines on the registration page when it is switched off', async () => {
    const { wrapper } = await screen('/register', signedOut('off'))

    expect(wrapper.find('[data-test="closed"]').exists()).toBe(true)
    expect(wrapper.find('[data-test="register"]').exists()).toBe(false)
  })
})

describe('Registering with approval', () => {
  const ROUTES = () => signedOut('approval', [
    { method: 'POST', path: '/auth/register', status: 201, body: { pending: true, code: 'registered_pending' } }
  ])

  it('says beforehand that approval is needed', async () => {
    const { wrapper } = await screen('/register', ROUTES())

    expect(wrapper.find('[data-test="approval-notice"]').exists()).toBe(true)
  })

  it('reports afterwards that waiting is on, and signs nobody in', async () => {
    const { wrapper, router, server } = await screen('/register', ROUTES())

    await fill(wrapper, { name: 'Nina', email: 'nina@example.test' })
    await wrapper.find('[data-test="register"]').trigger('submit')
    await settle()

    expect(wrapper.find('[data-test="pending"]').text()).toContain('waiting to be approved')
    expect(router.currentRoute.value.name).toBe('register')
    // A session that every following call would refuse is worse than none.
    expect(server.callsTo('GET', '/workspaces')).toHaveLength(0)
  })
})

describe('Registering without approval', () => {
  it('signs in and leads into the library', async () => {
    const { wrapper, router, server } = await screen('/register', signedOut('open', [
      {
        method: 'POST',
        path: '/auth/register',
        status: 201,
        body: { pending: false, user: SIGNED_IN_USER }
      },
      { method: 'GET', path: '/workspaces', body: WORKSPACES },
      { method: 'GET', path: '/prompts', body: { prompts: [], meta: { total: 0, page: 1, per_page: 50 } } },
      { method: 'GET', path: '/tags', body: { tags: [] } }
    ]))

    await fill(wrapper, { name: 'Otto', email: 'otto@example.test' })
    await wrapper.find('[data-test="register"]').trigger('submit')
    await settle()

    expect(router.currentRoute.value.name).toBe('library')

    const sent = JSON.parse(server.callsTo('POST', '/auth/register')[0].options.body)
    expect(sent).toEqual({
      name: 'Otto', email: 'otto@example.test', password: 'Ein-gutes-Passwort-2026!'
    })
  })
})

describe('What the form catches itself', () => {
  // The repetition never reaches the server — it is a guard against a typo,
  // not a rule about passwords, and the rules stay where they belong (SEC-02).
  it('catches two different passwords without asking', async () => {
    const { wrapper, server } = await screen('/register', signedOut('open'))

    await fill(wrapper, { name: 'Otto', email: 'otto@example.test', repetition: 'etwas-anderes' })
    await wrapper.find('[data-test="register"]').trigger('submit')
    await settle()

    expect(wrapper.text()).toContain('do not match')
    expect(server.callsTo('POST', '/auth/register')).toHaveLength(0)
  })

  it('shows the refusal of the server at the field it concerns', async () => {
    const { wrapper } = await screen('/register', signedOut('open', [
      {
        method: 'POST',
        path: '/auth/register',
        ...apiError(422, 'validation_failed', undefined, { email: 'email_taken' })
      }
    ]))

    await fill(wrapper, { name: 'Zwilling', email: 'martin@example.test' })
    await wrapper.find('[data-test="register"]').trigger('submit')
    await settle()

    expect(wrapper.text()).toContain('already in use')
  })
})

async function fill (wrapper, { name, email, password = 'Ein-gutes-Passwort-2026!', repetition = null }) {
  await wrapper.find('input[name="name"]').setValue(name)
  await wrapper.find('input[name="email"]').setValue(email)
  await wrapper.find('input[name="password"]').setValue(password)
  await wrapper.find('input[name="password_repeat"]').setValue(repetition ?? password)
}
