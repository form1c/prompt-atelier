import { describe, it, expect, afterEach, vi } from 'vitest'
import { h } from 'vue'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import {
  installFakeServer, signedInRoutes, apiError, SIGNED_IN_USER, WORKSPACES
} from './support/fake_server.js'

// S8 — the sign-in screen (FA-101), and FA-909 behind it.
//
// Mounted through the real router rather than on its own: the guard decides
// which of the two screens is on display, and half of what is worth testing
// here is exactly that decision.
//
// Every test starts from a fresh module registry. The session is a singleton
// in the browser as well, and its first state — "not asked yet" — exists once
// per page load. A test that reused the previous one would skip the very
// question the guard asks first.

const realFetch = globalThis.fetch

// The registration question belongs here because the real server answers it
// on every visit to the sign-in screen (FA-107). Leaving it out would let
// every case below run through the error path of `registrationState` instead
// of the one a browser really takes — a stand-in has to answer as the server
// does, or the test is green over a fiction.
const REGISTRATION_OFF = {
  method: 'GET', path: '/auth/registration',
  body: { registration: { enabled: false, approval_required: false } }
}

const SIGNED_OUT = [
  { method: 'GET', path: '/auth/me', ...apiError(401, 'unauthorized') },
  { method: 'GET', path: '/setup/status', body: { setup_required: false } },
  REGISTRATION_OFF
]

const EMPTY_INSTANCE = [
  { method: 'GET', path: '/auth/me', ...apiError(401, 'unauthorized') },
  { method: 'GET', path: '/setup/status', body: { setup_required: true } },
  REGISTRATION_OFF
]

async function screen (at = '/', extraRoutes = []) {
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')
  const state = await import('../../frontend/src/state/session.js')

  const router = createAppRouter(createMemoryHistory())
  // Screens from the later packages, so a test can address a route that does
  // not exist yet without waiting for the package that brings it.
  for (const route of extraRoutes) router.addRoute(route)

  const wrapper = mount(App, { global: { plugins: [router] } })
  await router.push(at)
  await settle()

  return { wrapper, router, state }
}

afterEach(() => {
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('Sign-in screen', () => {
  // TF-421
  it('names the administrative route and offers no self-service link', async () => {
    installFakeServer(SIGNED_OUT)
    const { wrapper } = await screen()

    expect(wrapper.text()).toContain('Forgotten your password?')
    expect(wrapper.text()).toContain('administers this instance')

    // E-13: there is no self-service reset in v1. A link that promises one
    // would send the user looking for a page that does not exist — and the
    // administrator would hear about it only when the user gives up.
    expect(wrapper.findAll('a')).toHaveLength(0)

    const buttons = wrapper.findAll('button')
    expect(buttons).toHaveLength(1)
    expect(buttons[0].attributes('type')).toBe('submit')
  })

  it('does not ask the server when a field is empty', async () => {
    const server = installFakeServer(SIGNED_OUT)
    const { wrapper } = await screen()

    await wrapper.find('input[type="email"]').setValue('martin@example.test')
    await wrapper.find('form').trigger('submit')
    await settle()

    expect(wrapper.text()).toContain('Please enter your password.')
    expect(server.callsTo('POST', '/auth/login')).toHaveLength(0)
  })

  it('shows the message of the server without giving away which entry was wrong', async () => {
    installFakeServer([
      ...SIGNED_OUT,
      { method: 'POST', path: '/auth/login', ...apiError(401, 'invalid_credentials') }
    ])
    const { wrapper } = await screen()

    await wrapper.find('input[type="email"]').setValue('martin@example.test')
    await wrapper.find('input[type="password"]').setValue('falsch')
    await wrapper.find('form').trigger('submit')
    await settle()

    const shown = wrapper.find('[role="alert"]').text()
    expect(shown).toBe('Email address or password is not correct.')
    // SEC-07 keeps the two cases indistinguishable. Anything the screen adds
    // about which field was wrong would hand back what the server withheld.
    expect(shown).not.toMatch(/unbekannt|nicht vorhanden|kein Konto/i)
  })

  it('leads into the library after signing in', async () => {
    installFakeServer([
      ...SIGNED_OUT,
      { method: 'POST', path: '/auth/login', body: { user: SIGNED_IN_USER } },
      { method: 'GET', path: '/workspaces', body: WORKSPACES }
    ])
    const { wrapper, router } = await screen()
    expect(router.currentRoute.value.name).toBe('login')

    await wrapper.find('input[type="email"]').setValue('martin@example.test')
    await wrapper.find('input[type="password"]').setValue('richtig-und-lang-12')
    await wrapper.find('form').trigger('submit')
    await settle()

    expect(router.currentRoute.value.name).toBe('library')
    expect(wrapper.text()).toContain('Library')
    expect(wrapper.text()).toContain('Martin')
    // The workspace the server remembers, not the first one in the list.
    expect(wrapper.text()).toContain('Marketing')
  })

  it('resumes the interrupted route after signing in', async () => {
    installFakeServer([
      ...SIGNED_OUT,
      { method: 'POST', path: '/auth/login', body: { user: SIGNED_IN_USER } },
      { method: 'GET', path: '/workspaces', body: WORKSPACES }
    ])
    // The guard sent the user here from somewhere else; the address it noted
    // is where the sign-in has to lead back to.
    const { wrapper, router } = await screen('/login?next=/trash', [
      { path: '/trash', name: 'trash', component: { render: () => h('p', 'Papierkorb') } }
    ])

    await wrapper.find('input[type="email"]').setValue('martin@example.test')
    await wrapper.find('input[type="password"]').setValue('richtig-und-lang-12')
    await wrapper.find('form').trigger('submit')
    await settle()

    expect(router.currentRoute.value.fullPath).toBe('/trash')
  })
})

describe('Setup page', () => {
  // FA-909
  it('appears instead of the sign-in for an instance without an account', async () => {
    installFakeServer(EMPTY_INSTANCE)
    const { wrapper, router } = await screen()

    expect(router.currentRoute.value.name).toBe('setup')
    expect(wrapper.text()).toContain('First-time setup')
  })

  it('checks the repeated password before anything is sent', async () => {
    const server = installFakeServer(EMPTY_INSTANCE)
    const { wrapper } = await screen()

    await wrapper.find('input[name="name"]').setValue('Thomas')
    await wrapper.find('input[name="email"]').setValue('thomas@example.test')
    await wrapper.find('input[name="password"]').setValue('lang-genug-12345')
    await wrapper.find('input[name="password_repeat"]').setValue('vertippt-12345')
    await wrapper.find('form').trigger('submit')
    await settle()

    expect(wrapper.text()).toContain('do not match')
    expect(server.callsTo('POST', '/setup')).toHaveLength(0)
  })

  it('creates the first account and is signed in afterwards', async () => {
    installFakeServer([
      ...EMPTY_INSTANCE,
      { method: 'POST', path: '/setup', status: 201, body: { user: { ...SIGNED_IN_USER, name: 'Thomas', is_instance_admin: true } } },
      { method: 'GET', path: '/workspaces', body: WORKSPACES }
    ])
    const { wrapper, router, state } = await screen()

    await wrapper.find('input[name="name"]').setValue('Thomas')
    await wrapper.find('input[name="email"]').setValue('thomas@example.test')
    await wrapper.find('input[name="password"]').setValue('lang-genug-12345')
    await wrapper.find('input[name="password_repeat"]').setValue('lang-genug-12345')
    await wrapper.find('form').trigger('submit')
    await settle()

    expect(router.currentRoute.value.name).toBe('library')
    expect(state.session.user.is_instance_admin).toBe(true)
  })
})

// SEC-02. The setup screen names the minimum length before the user types,
// which means the number exists twice: once as the rule in the backend, once
// as a hint in the browser. A hint that has drifted is worse than none — it
// invites a password the server then rejects.
//
// So the two are compared here rather than trusted. Reading the Ruby source
// from a JavaScript test is unusual; the alternative would be an endpoint
// that exists only to publish a constant.
describe('Minimum length of the password', () => {
  const HERE = path.dirname(fileURLToPath(import.meta.url))
  const read = (...parts) => readFileSync(path.resolve(HERE, '..', '..', ...parts), 'utf8')

  it('names the same number as the rule in the backend', () => {
    const backend = read('backend', 'services', 'password.rb').match(/MINIMUM_LENGTH\s*=\s*(\d+)/)
    const screen = read('frontend', 'src', 'views', 'SetupView.vue').match(/PASSWORD_MINIMUM\s*=\s*(\d+)/)

    expect(backend).not.toBeNull()
    expect(screen).not.toBeNull()
    expect(screen[1]).toBe(backend[1])
  })
})

describe('Signing out', () => {
  // FA-102 and NT-2: after signing out there is no way back in.
  //
  // Note what is *not* asserted here: that the library is absent from the
  // browser history. It may well be in it — the guard is what keeps the
  // screen shut, and it runs on every navigation, including the one a back
  // button starts. An assertion on the history would have tested the
  // mechanism instead of the effect, and it would have passed on a memory
  // history whatever the code did.
  it('leads to the sign-in, and the way back stays barred', async () => {
    installFakeServer([
      ...signedInRoutes(),
      { method: 'POST', path: '/auth/logout', body: { status: 'ok' } }
    ])
    const { wrapper, router, state } = await screen()
    expect(router.currentRoute.value.name).toBe('library')

    const clickContaining = async (label) => {
      const button = wrapper.findAll('button').find((candidate) => candidate.text().includes(label))
      await button.trigger('click')
      await settle()
    }

    // By the accessible label of the menu, not by the name on it: the
    // workspace switcher next to it reads "Personal workspace" and would
    // answer to the name just as readily.
    await clickContaining('Account')
    // The label on the screen, not the name of this test case: the interface
    // is and stays German (E-12).
    await clickContaining('Sign out')

    expect(router.currentRoute.value.name).toBe('login')
    expect(state.session.user).toBeNull()

    await router.push('/')
    await settle()

    expect(router.currentRoute.value.name).toBe('login')
    expect(wrapper.text()).not.toContain('Library')
  })
})
