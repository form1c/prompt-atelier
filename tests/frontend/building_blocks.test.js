import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import LoadingState from '../../frontend/src/components/LoadingState.vue'
import EmptyState from '../../frontend/src/components/EmptyState.vue'
import ErrorState from '../../frontend/src/components/ErrorState.vue'
import NoticeHost from '../../frontend/src/components/NoticeHost.vue'
import { notify, clearNotices, notices, NOTICE_MILLISECONDS } from '../../frontend/src/state/notices.js'
import { ApiError } from '../../frontend/src/api/client.js'

// The four states every screen from AP-10 onwards will be in at some point
// (Requirements 11.6). Built once, so the rules hold everywhere instead of
// being decided again per screen.

describe('Loading state', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('stays invisible while the wait is not noticeable', async () => {
    const wrapper = mount(LoadingState)

    vi.advanceTimersByTime(299)
    // Without this the assertion would hold whatever the threshold is: the
    // timer may well have fired, but the rendering that follows it happens a
    // tick later, and the test would be looking at the DOM from before.
    await flushPromises()

    // Below the threshold a placeholder does not reassure anyone: it appears
    // and vanishes, and the flicker is what people report.
    expect(wrapper.find('[role="status"]').exists()).toBe(false)
  })

  it('shows a skeleton rather than a spinner past the threshold', async () => {
    const wrapper = mount(LoadingState, { props: { rows: 4 } })

    vi.advanceTimersByTime(300)
    await flushPromises()

    expect(wrapper.find('[role="status"]').attributes('aria-busy')).toBe('true')
    expect(wrapper.findAll('.loading__row')).toHaveLength(4)
  })
})

describe('Empty state', () => {
  it('explains and offers an action', () => {
    const wrapper = mount(EmptyState, {
      props: { title: 'Keine Prompts', description: 'In diesem Workspace liegt noch nichts.' },
      slots: { default: '<button type="button">Ersten Prompt anlegen</button>' }
    })

    expect(wrapper.text()).toContain('Keine Prompts')
    expect(wrapper.text()).toContain('In diesem Workspace liegt noch nichts.')
    expect(wrapper.find('button').text()).toBe('Ersten Prompt anlegen')
  })

  it('says a sentence even without a description of its own', () => {
    const wrapper = mount(EmptyState, { props: { title: 'No matches' } })

    // 11.6: never a bare surface. The fallback is thin, but it is a sentence
    // rather than an empty box.
    expect(wrapper.text().replace('No matches', '').trim()).not.toBe('')
  })
})

describe('Error state', () => {
  it('shows the message of the server and keeps the technical part collapsed', () => {
    const error = new ApiError({ status: 409, code: 'conflict', message: 'Der Name ist bereits vergeben.' })
    const wrapper = mount(ErrorState, { props: { error } })

    expect(wrapper.find('[role="alert"]').text()).toContain('Der Name ist bereits vergeben.')
    // SEC-13 keeps paths and stack traces out of the answer; what is left is
    // enough to name the case in a report and nothing more.
    expect(wrapper.find('details').text()).toContain('conflict')
    expect(wrapper.find('details').attributes('open')).toBeUndefined()
  })

  it('offers the retry only when there is something to retry', async () => {
    const retry = vi.fn()
    const error = new ApiError({ status: 0, code: 'network', message: 'Nicht erreichbar.' })

    const without = mount(ErrorState, { props: { error } })
    expect(without.find('button').exists()).toBe(false)

    const withRetry = mount(ErrorState, { props: { error, onRetry: retry } })
    await withRetry.find('button').trigger('click')
    expect(retry).toHaveBeenCalledTimes(1)
  })
})

describe('Toast', () => {
  beforeEach(() => {
    clearNotices()
    vi.useFakeTimers()
  })

  afterEach(() => vi.useRealTimers())

  it('appears and disappears by itself', async () => {
    const wrapper = mount(NoticeHost)

    notify('Saved.')
    await flushPromises()
    expect(wrapper.text()).toContain('Saved.')

    vi.advanceTimersByTime(NOTICE_MILLISECONDS)
    await flushPromises()

    // 11.6: it must not interrupt the flow — which means it must also go
    // away without being clicked.
    expect(wrapper.text()).not.toContain('Saved.')
    expect(notices).toHaveLength(0)
  })

  it('keeps several messages apart', async () => {
    const wrapper = mount(NoticeHost)

    notify('Erste.')
    notify('Zweite.')
    await flushPromises()

    expect(wrapper.findAll('.notices__item')).toHaveLength(2)
  })
})
