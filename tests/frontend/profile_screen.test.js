import { describe, it, expect, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import { installFakeServer, signedInRoutes, apiError, SIGNED_IN_USER, WORKSPACES } from './support/fake_server.js'

// S7 — one's own account (FA-105, FA-106, FA-903, SEC-18).
//
// Two of the three sections are ordinary forms. The third is the one worth
// testing hard: after an administrator reset the application is closed until a
// password of one's own is set, and "closed" has to mean every screen — a
// guard that misses one route is no guard.

const realFetch = globalThis.fetch

const mounted = []

async function screen ({ routes = [], user = SIGNED_IN_USER, at = '/profile' } = {}) {
  const server = installFakeServer([
    ...routes,
    { method: 'GET', path: '/auth/me', body: { user } },
    { method: 'GET', path: '/workspaces', body: WORKSPACES },
    ...signedInRoutes()
  ])
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

const field = (wrapper, label) => wrapper.findAll('label').find((entry) => entry.text().startsWith(label))
const inputFor = (wrapper, label) => field(wrapper, label).find('input')
const sent = (server, fragment) => JSON.parse(server.callsTo('POST', fragment).at(-1).options.body)

afterEach(() => {
  while (mounted.length) mounted.pop().unmount()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('Name and address (FA-106)', () => {
  it('comes with what the session already knows and sends changes', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'PUT', path: '/auth/me', body: { user: SIGNED_IN_USER } }]
    })

    expect(inputFor(wrapper, 'Name').element.value).toBe('Martin')
    expect(inputFor(wrapper, 'Email address').element.value).toBe('martin@example.test')

    await inputFor(wrapper, 'Name').setValue('Martin M.')
    await wrapper.find('[data-test="save-account"]').trigger('click')
    await settle()

    const body = JSON.parse(server.callsTo('PUT', '/auth/me').at(-1).options.body)
    expect(body.name).toBe('Martin M.')
  })

  it('names a refusal of the server', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'PUT', path: '/auth/me',
        ...apiError(422, 'validation_failed', undefined, { email: 'email_taken' })
      }]
    })

    await wrapper.find('[data-test="save-account"]').trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('already in use')
  })
})

describe('Changing the password (FA-105)', () => {
  it('sends the current and the new password', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'POST', path: '/auth/password', body: { status: 'ok' } }]
    })

    await inputFor(wrapper, 'Current password').setValue('altes-passwort')
    await inputFor(wrapper, 'New password').setValue('ein-langes-neues-passwort')
    await inputFor(wrapper, 'Repeat new password').setValue('ein-langes-neues-passwort')
    await wrapper.find('[data-test="change-password"]').trigger('click')
    await settle()

    expect(sent(server, '/auth/password')).toEqual({
      current_password: 'altes-passwort', new_password: 'ein-langes-neues-passwort'
    })
  })

  // The repetition never reaches the server — it is a guard against a typo,
  // not a rule about passwords. So it is checked here, and nothing is sent.
  it('does not even ask when the repeat does not match', async () => {
    const { wrapper, server } = await screen()

    await inputFor(wrapper, 'New password').setValue('ein-langes-neues-passwort')
    await inputFor(wrapper, 'Repeat new password').setValue('vertippt')
    await wrapper.find('[data-test="change-password"]').trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('do not match')
    expect(server.callsTo('POST', '/auth/password')).toHaveLength(0)
  })

  it('clears the fields after a successful change', async () => {
    const { wrapper } = await screen({
      routes: [{ method: 'POST', path: '/auth/password', body: { status: 'ok' } }]
    })

    await inputFor(wrapper, 'Current password').setValue('alt')
    await inputFor(wrapper, 'New password').setValue('ein-langes-neues-passwort')
    await inputFor(wrapper, 'Repeat new password').setValue('ein-langes-neues-passwort')
    await wrapper.find('[data-test="change-password"]').trigger('click')
    await settle()

    expect(inputFor(wrapper, 'Current password').element.value).toBe('')
  })
})

describe('The forced change (FA-903)', () => {
  const reset = { ...SIGNED_IN_USER, must_change_password: true }

  it('says why nothing else works', async () => {
    const { wrapper } = await screen({ user: reset })

    expect(wrapper.text()).toContain('Please choose a new password')
    expect(wrapper.text()).toContain('the application is locked')
  })

  // "Kann die Anwendung erst danach benutzen" is a statement about **every**
  // screen, so it is a guard and not a decision on one of them. Checked on
  // three different destinations, because a guard that misses one route is no
  // guard at all.
  it('allows no other screen', async () => {
    const { router } = await screen({ user: reset, at: '/' })
    expect(router.currentRoute.value.name).toBe('profile')

    for (const target of ['/keywords', '/administration', '/prompt/new']) {
      await router.push(target)
      await settle()
      expect(router.currentRoute.value.name, target).toBe('profile')
    }
  })

  // And it opens again the moment the password has been changed — the session
  // is reloaded for exactly that reason.
  it('releases the application again after the change', async () => {
    // The first answer carries the flag, every later one does not — which is
    // what the server does once the password has been changed. The `once`
    // route stands in front, so it serves the mount and the reload afterwards
    // falls through to the cleared one.
    const { wrapper, router } = await screen({
      routes: [
        { method: 'GET', path: '/auth/me', body: { user: reset }, once: true },
        { method: 'POST', path: '/auth/password', body: { status: 'ok' } }
      ]
    })
    expect(router.currentRoute.value.name).toBe('profile')

    await inputFor(wrapper, 'Current password').setValue('einmalpasswort')
    await inputFor(wrapper, 'New password').setValue('ein-langes-neues-passwort')
    await inputFor(wrapper, 'Repeat new password').setValue('ein-langes-neues-passwort')
    await wrapper.find('[data-test="change-password"]').trigger('click')
    await settle()

    await router.push('/keywords')
    await settle()
    expect(router.currentRoute.value.name).toBe('keywords')
  })
})

describe('Personal data report (SEC-18, TF-650)', () => {
  it('fetches the own data and hands it on as a file', async () => {
    const clicks = []
    URL.createObjectURL = () => 'blob:test'
    URL.revokeObjectURL = () => {}
    const original = document.createElement.bind(document)
    vi.spyOn(document, 'createElement').mockImplementation((tag) => {
      const element = original(tag)
      if (tag === 'a') element.click = () => clicks.push(element.download)
      return element
    })

    const { wrapper, server } = await screen({
      routes: [{
        method: 'GET', path: '/auth/me/data-export',
        body: { disclosure: { account: { email: 'martin@example.test' }, prompts: [] } }
      }]
    })

    await wrapper.find('[data-test="disclosure"]').trigger('click')
    await settle()

    expect(server.callsTo('GET', '/auth/me/data-export')).toHaveLength(1)
    expect(clicks).toEqual(['selbstauskunft.json'])
  })

  it('explains what is in it before anybody presses it', async () => {
    const { wrapper } = await screen()

    const section = wrapper.find('[aria-labelledby="disclosure-heading"]')
    expect(section.text()).toContain('your own prompts including their content')
    expect(section.text()).toContain('log entries')
  })
})
