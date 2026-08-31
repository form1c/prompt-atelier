import { describe, it, expect, afterEach, vi } from 'vitest'
import { settle } from './support/flush.js'
import { adminScreen, unmountAll, auditAnswer, AUDIT } from './support/admin.js'

// S6, the log (FA-908).
//
// The filters are not a convenience. The table is bounded by time and nothing
// pushes an entry out of it — but a burst of refused logins pushes every
// administrative entry out of *sight*, and an administrator looks at the log
// precisely when something has happened.

const realFetch = globalThis.fetch

const screen = (options = {}) => adminScreen('/administration/audit', options)

const many = (count) => Array.from({ length: count }, (_, index) => ({
  id: 1000 - index, actor_name: 'Thomas', action: 'user.created',
  target_type: 'user', target_id: 1, created_at: new Date().toISOString()
}))

const lastAudit = (server) => server.callsTo('GET', '/admin/audit').at(-1).path

afterEach(() => {
  unmountAll()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('The log filter (FA-908)', () => {
  it('sends person and action to the server', async () => {
    const { wrapper, server } = await screen()

    await wrapper.find('[data-test="audit-actor"]').setValue('1')
    await wrapper.find('[data-test="audit-action"]').setValue('user.approved')
    await wrapper.find('[data-test="audit-filter"]').trigger('submit')
    await settle()

    expect(lastAudit(server)).toContain('actor_id=1')
    expect(lastAudit(server)).toContain('action=user.approved')
  })

  // The filter lives in the address. That is what makes a view of the log
  // something one can bookmark, reload and hand to a colleague — and it is
  // why paging works at all.
  it('writes the filter into the address', async () => {
    const { wrapper, router } = await screen()

    await wrapper.find('[data-test="audit-action"]').setValue('user.approved')
    await wrapper.find('[data-test="audit-filter"]').trigger('submit')
    await settle()

    expect(router.currentRoute.value.query.action).toBe('user.approved')
  })

  // The other direction, and it is the one that matters for a pasted link or
  // a reload: the address alone has to produce the filtered request, without
  // anybody touching a control. The screen therefore reacts to the query, not
  // to the button.
  it('follows a filter that is already in the address', async () => {
    const { wrapper, server } = await adminScreen('/administration/audit?action=user.approved')

    expect(lastAudit(server)).toContain('action=user.approved')
    // And the controls show it, so the person can see what they are looking
    // at rather than an empty form over a filtered list.
    expect(wrapper.find('[data-test="audit-action"]').element.value).toBe('user.approved')
  })

  // The boundaries of a day belong to the reader's calendar, and the browser
  // is the only party that knows it (11.6). "Up to the 5th" has to reach the
  // evening of the 5th — sending its first instant would silently drop
  // everything that happened that day.
  it('turns the until date into the end of that day, not its start', async () => {
    const { wrapper, server } = await screen()

    await wrapper.find('[data-test="audit-from"]').setValue('2026-07-01')
    await wrapper.find('[data-test="audit-to"]').setValue('2026-07-05')
    await wrapper.find('[data-test="audit-filter"]').trigger('submit')
    await settle()

    const sent = new URL(lastAudit(server), 'http://x')
    const from = new Date(sent.searchParams.get('from'))
    const to = new Date(sent.searchParams.get('to'))

    expect(from.getFullYear()).toBe(2026)
    expect(from.getHours()).toBe(0)
    expect(to.getDate()).toBe(5)
    expect(to.getHours()).toBe(23)
  })

  // The address changing **while the screen is open** — through "clear", the
  // back button, a click on the tab. The controls have to follow it, or they
  // keep showing a filter that is no longer in force: the list is unfiltered
  // and the field still says `user.approved`.
  //
  // Mounting with a query does not cover this: the initial value is set once
  // when the screen is built, and a mutation probe walked straight through
  // the case above.
  it('clears the controls along when the filter is reset', async () => {
    const { wrapper } = await screen()

    await wrapper.find('[data-test="audit-action"]').setValue('user.approved')
    await wrapper.find('[data-test="audit-filter"]').trigger('submit')
    await settle()
    expect(wrapper.find('[data-test="audit-action"]').element.value).toBe('user.approved')

    await wrapper.findAll('button').find((entry) => entry.text().includes('Clear filter'))
      .trigger('click')
    await settle()

    expect(wrapper.find('[data-test="audit-action"]').element.value).toBe('')
  })

  it('offers every kind of action the server names', async () => {
    const { wrapper } = await screen()

    const options = wrapper.find('[data-test="audit-action"]').findAll('option')
      .map((entry) => entry.element.value)
    expect(options).toContain('user.approved')
    expect(options).toContain('')
  })

  // Asked of the account list rather than derived from the entries: a person
  // who has done nothing yet would otherwise be missing from the very filter
  // one uses to check whether they have done anything.
  it('offers people who have not done anything yet as well', async () => {
    const { wrapper } = await screen()

    const names = wrapper.find('[data-test="audit-actor"]').findAll('option')
      .map((entry) => entry.text())
    expect(names).toContain('Lisa')
  })
})

describe('Paging through the log (FA-908)', () => {
  // A page out of many must say so, or the filter looks as though it found
  // everything there is.
  it('names the total beside the page being shown', async () => {
    const { wrapper } = await screen({
      routes: [auditAnswer(many(50), { total: 4212 })]
    })

    expect(wrapper.find('[data-test="audit-count"]').text()).toContain('4212')
  })

  it('shows no paging while everything fits on one page', async () => {
    const { wrapper } = await screen({ routes: [auditAnswer(AUDIT, { total: 1 })] })

    expect(wrapper.find('[data-test="audit-next"]').exists()).toBe(false)
  })

  // The half that was missing entirely until AP-15b: the newest page was all
  // anybody could reach, and older entries were findable only by guessing the
  // right day in the date filter.
  it('fetches the next page and keeps it in the address', async () => {
    const { wrapper, router, server } = await screen({
      routes: [auditAnswer(many(50), { total: 4212 })]
    })

    await wrapper.find('[data-test="audit-next"]').trigger('click')
    await settle()

    expect(router.currentRoute.value.query.page).toBe('2')
    expect(lastAudit(server)).toContain('page=2')
  })

  it('disables back on the first page and forward on the last', async () => {
    const { wrapper } = await screen({
      routes: [auditAnswer(many(50), { total: 100, page: 1 })]
    })
    expect(wrapper.find('[data-test="audit-previous"]').attributes('disabled')).toBeDefined()
    expect(wrapper.find('[data-test="audit-next"]').attributes('disabled')).toBeUndefined()

    unmountAll()
    const last = await screen({ routes: [auditAnswer(many(50), { total: 100, page: 2 })] })
    expect(last.wrapper.find('[data-test="audit-next"]').attributes('disabled')).toBeDefined()
  })

  it('says which page one is on', async () => {
    const { wrapper } = await screen({
      routes: [auditAnswer(many(50), { total: 100, page: 2 })]
    })

    expect(wrapper.find('[data-test="audit-page"]').text()).toContain('2')
  })
})

describe('The entries themselves (A-15)', () => {
  // Readable, not changeable. What must carry no control is the **entry**:
  // the section around it carries the filter, which changes nothing.
  it('shows log entries with no control on them at all', async () => {
    const { wrapper } = await screen()

    const section = wrapper.find('[aria-labelledby="audit-heading"]')
    expect(section.text()).toContain('user.created')

    const rows = section.findAll('.entry')
    expect(rows.length).toBeGreaterThan(0)
    for (const row of rows) {
      expect(row.findAll('button')).toHaveLength(0)
      expect(row.findAll('a')).toHaveLength(0)
      expect(row.findAll('input, select, textarea')).toHaveLength(0)
    }
  })

  // The count is the entire content of a collapsed entry (SEC-07): it is what
  // separates an attacker with fifty thousand attempts from a colleague who
  // mistyped five times.
  it('shows for a collapsed entry how many there were', async () => {
    const { wrapper } = await screen({
      routes: [auditAnswer([{
        id: 9, actor_name: null, action: 'login.failed.collapsed', target_type: 'ip',
        meta_json: JSON.stringify({ key: '203.0.113.9', count: 41299 }),
        created_at: new Date().toISOString()
      }])]
    })

    expect(wrapper.find('[aria-labelledby="audit-heading"]').text()).toContain('41299')
  })
})
