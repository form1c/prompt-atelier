import { describe, it, expect, afterEach, vi } from 'vitest'
import { settle } from './support/flush.js'
import { apiError } from './support/fake_server.js'
import {
  adminScreen, unmountAll, rowOf, buttonNamed, dialog, ACCOUNTS, PENDING
} from './support/admin.js'

// S6, accounts (FA-901 to FA-906, FA-107a, W-7).
//
// The rules are the server's and are checked there. What is checked here is
// what the screen does with them, and one thing it must never do: let the
// one-time password of FA-901 and FA-903 slip past. It exists in readable form
// exactly once, in that answer, and a message that fades after two seconds
// would lose it for good.

const realFetch = globalThis.fetch

const screen = (options = {}) => adminScreen('/administration/accounts', options)

afterEach(() => {
  unmountAll()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('The account list (FA-906)', () => {
  it('shows per account what the overview asks for', async () => {
    const { wrapper } = await screen()

    const row = rowOf(wrapper, 'Martin')
    expect(row.text()).toContain('editor@test')
    expect(row.text()).toContain('Active')
    expect(row.text()).toContain('2 workspaces')
    expect(row.text()).toContain('4 prompts')
    expect(rowOf(wrapper, 'Lisa').text()).toContain('Locked')
  })

  // A column that says "nie" is more useful than an empty one: it is the
  // answer to "has this account ever been used?".
  it('says so when somebody has never signed in', async () => {
    const { wrapper } = await screen()

    expect(rowOf(wrapper, 'Lisa').text()).toContain('never signed in')
  })

  it('searches on the server, not in the loaded list', async () => {
    const { wrapper, server } = await screen()

    await wrapper.find('[data-test="search"]').setValue('lisa')
    await settle()

    expect(server.callsTo('GET', '/admin/users').at(-1).path).toContain('q=lisa')
  })
})

describe('The one-time password (FA-901, FA-903)', () => {
  // It exists in readable form once. The dialogue has to be dismissed by
  // hand — a notice that disappears after two seconds would take it along.
  it('stands in a dialogue somebody has to dismiss', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'POST', path: '/admin/users', status: 201,
        body: { user: { id: 7, name: 'Neu' }, initial_password: 'geheim-einmalig-1234' }
      }]
    })

    await wrapper.find('[data-test="create-account"]').trigger('click')
    await settle()

    expect(wrapper.find('[data-test="initial-password"]').text()).toBe('geheim-einmalig-1234')
    expect(dialog(wrapper).text()).toContain('shown exactly once')

    await wrapper.find('[data-test="confirm"]').trigger('click')
    await settle()
    expect(dialog(wrapper).exists()).toBe(false)
  })

  it('shows it after a reset as well', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'POST', path: '/admin/users/1/reset-password',
        body: { initial_password: 'neues-einmalpasswort' }
      }]
    })

    await buttonNamed(rowOf(wrapper, 'Martin'), 'Reset password').trigger('click')
    await settle()
    // Asked first: the sessions of that account end at once, and the person is
    // locked out of their own work until somebody hands them the new one.
    expect(dialog(wrapper).text()).toContain('Every session of this account is dropped at once')

    await wrapper.find('[data-test="confirm"]').trigger('click')
    await settle()

    expect(wrapper.find('[data-test="initial-password"]').text()).toBe('neues-einmalpasswort')
  })
})

describe('Locking and unlocking (FA-902)', () => {
  it('offers per row the action that fits the state', async () => {
    const { wrapper } = await screen()

    expect(buttonNamed(rowOf(wrapper, 'Martin'), 'Lock')).toBeDefined()
    expect(buttonNamed(rowOf(wrapper, 'Martin'), 'Unlock')).toBeUndefined()
    expect(buttonNamed(rowOf(wrapper, 'Lisa'), 'Unlock')).toBeDefined()
  })

  it('reports a refusal instead of leaving the row quiet', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'POST', path: '/admin/users/1/lock',
        ...apiError(403, 'last_instance_admin')
      }]
    })

    await buttonNamed(rowOf(wrapper, 'Martin'), 'Lock').trigger('click')
    await settle()

    expect(wrapper.find('.alert').text()).toContain('last active instance administrator')
  })
})

describe('Deleting with a choice (FA-904, TF-409)', () => {
  it('asks what should happen to the prompts and names how many', async () => {
    const { wrapper } = await screen()

    await buttonNamed(rowOf(wrapper, 'Martin'), 'Delete').trigger('click')
    await settle()

    expect(dialog(wrapper).text()).toContain('4 prompts')
    expect(dialog(wrapper).text()).toContain('Delete the prompts as well')
    expect(dialog(wrapper).text()).toContain('Hand the prompts over to')
  })

  it('sends the chosen route along', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'DELETE', path: '/admin/users/1', body: { status: 'ok' } }]
    })

    await buttonNamed(rowOf(wrapper, 'Martin'), 'Delete').trigger('click')
    await settle()
    await wrapper.find('[data-test="confirm"]').trigger('click')
    await settle()

    const sent = JSON.parse(server.callsTo('DELETE', '/admin/users/1').at(-1).options.body)
    expect(sent.prompts_action).toBe('delete')
  })

  // The successor list must not offer the account that is about to go — the
  // server refuses it, and offering it is offering a refusal.
  it('offers every account except the one being deleted when handing over', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'DELETE', path: '/admin/users/1', body: { status: 'ok' } }]
    })

    await buttonNamed(rowOf(wrapper, 'Martin'), 'Delete').trigger('click')
    await settle()
    await dialog(wrapper).findAll('input[type="radio"]')[1].setValue(true)
    await settle()

    const options = wrapper.find('[data-test="successor"]').findAll('option')
    expect(options.map((option) => option.text())).toEqual(['Lisa'])

    await wrapper.find('[data-test="confirm"]').trigger('click')
    await settle()

    const sent = JSON.parse(server.callsTo('DELETE', '/admin/users/1').at(-1).options.body)
    expect(sent).toEqual({ prompts_action: 'transfer', successor_id: 2 })
  })
})

describe('Waiting registrations (FA-107)', () => {
  const WITH_PENDING = () => ({
    accounts: [PENDING, ...ACCOUNTS],
    routes: [{ method: 'POST', path: '/admin/users/3/approve', body: { user: { ...PENDING, status: 'active', pending_since: null } } }]
  })

  // The application cannot call the administrator — it sends no e-mail
  // (E-13). A registration nobody looks at is a person who concludes the tool
  // is broken, so the count sits where he is already looking.
  it('names the number of those waiting in the heading', async () => {
    const { wrapper } = await screen(WITH_PENDING())

    expect(wrapper.find('[data-test="pending-count"]').text()).toContain('1')
  })

  it('shows no number when nobody is waiting', async () => {
    const { wrapper } = await screen()

    expect(wrapper.find('[data-test="pending-count"]').exists()).toBe(false)
  })

  // Waiting and locked are the same row in the database and two different
  // things to a person. Lisa is locked, Nina is waiting, and the screen has
  // to say which is which.
  it('tells those waiting from those locked out', async () => {
    const { wrapper } = await screen(WITH_PENDING())

    expect(rowOf(wrapper, 'Nina').text()).toContain('Waiting for approval')
    expect(rowOf(wrapper, 'Lisa').text()).toContain('Locked')
    expect(rowOf(wrapper, 'Lisa').text()).not.toContain('Waiting for approval')
  })

  // Two administrative acts, two buttons. Somebody waiting is not offered
  // "unlock" — that is the endpoint for a lock the administrator imposed
  // himself, and it refuses here.
  it('offers approval rather than unlocking for those waiting', async () => {
    const { wrapper } = await screen(WITH_PENDING())

    const row = rowOf(wrapper, 'Nina')
    expect(row.find('[data-test="approve"]').exists()).toBe(true)
    expect(buttonNamed(row, 'Unlock')).toBeUndefined()

    expect(rowOf(wrapper, 'Lisa').find('[data-test="approve"]').exists()).toBe(false)
    expect(buttonNamed(rowOf(wrapper, 'Lisa'), 'Unlock')).toBeDefined()
  })

  it('approves through the endpoint of its own and reloads the list', async () => {
    const { wrapper, server } = await screen(WITH_PENDING())

    await rowOf(wrapper, 'Nina').find('[data-test="approve"]').trigger('click')
    await settle()

    expect(server.callsTo('POST', '/admin/users/3/approve')).toHaveLength(1)
    expect(server.callsTo('POST', '/admin/users/3/unlock')).toHaveLength(0)
    expect(server.callsTo('GET', '/admin/users').length).toBeGreaterThan(1)
  })
})

