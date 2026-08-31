import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { segments } from '../../frontend/src/util/highlight.js'
import PromptList from '../../frontend/src/components/PromptList.vue'
import { promptRow } from './support/fake_server.js'

// FA-501 — the hits appear with the found place marked.
//
// The server sends positions in the original text; the browser cuts the text
// there. What it must never do is receive marked-up text and put it into the
// page as HTML — that is the one place where SEC-10 would stop holding.

describe('Matches', () => {
  it('splits the text into marked and unmarked pieces', () => {
    expect(segments('Blogartikel-Generator', [[0, 11]])).toEqual([
      { text: 'Blogartikel', marked: true },
      { text: '-Generator', marked: false }
    ])
  })

  it('copes with several matches and with none', () => {
    expect(segments('seo und blog', [[0, 3], [8, 4]])).toEqual([
      { text: 'seo', marked: true },
      { text: ' und ', marked: false },
      { text: 'blog', marked: true }
    ])
    expect(segments('nichts', [])).toEqual([{ text: 'nichts', marked: false }])
    expect(segments(null)).toEqual([{ text: '', marked: false }])
  })

  // Two terms can find overlapping words. A range starting before the
  // previous one ended would cut a piece of negative length — which renders
  // as nothing at all and loses text without a trace.
  it('merges overlapping entries instead of losing text', () => {
    const pieces = segments('Blogartikel', [[0, 4], [0, 11], [2, 5]])

    expect(pieces).toEqual([{ text: 'Blogartikel', marked: true }])
    expect(pieces.map((piece) => piece.text).join('')).toBe('Blogartikel')
  })

  it('skips unusable entries instead of breaking on them', () => {
    const text = 'Blogartikel'

    expect(segments(text, [[-1, 3], [5, 0], [99, 2]])).toEqual([{ text, marked: false }])
    // A length reaching past the end is cut back rather than dropped.
    expect(segments(text, [[8, 99]]).map((piece) => piece.text).join('')).toBe(text)
  })

  // Every rearrangement has to give the original back. A marking that loses a
  // character would be a display that quietly differs from what is stored.
  it('yields the original text again', () => {
    const text = 'Größe und Maßangaben für alle'

    for (const ranges of [[[0, 5]], [[0, 5], [10, 10]], [[6, 3], [26, 4]]]) {
      expect(segments(text, ranges).map((piece) => piece.text).join('')).toBe(text)
    }
  })
})

describe('Matches in the list', () => {
  const list = (prompt) => mount(PromptList, { props: { prompts: [prompt] } })

  it('highlights the match in the title', () => {
    const wrapper = list(promptRow({ highlights: { title: [[0, 11]], description: [] } }))

    expect(wrapper.find('.hit__title mark').text()).toBe('Blogartikel')
    expect(wrapper.find('.hit__title').text()).toBe('Blogartikel-Generator')
  })

  it('leaves everything unmarked when there is no match', () => {
    const wrapper = list(promptRow())

    expect(wrapper.find('mark').exists()).toBe(false)
    expect(wrapper.find('.hit__title').text()).toBe('Blogartikel-Generator')
  })

  // SEC-10. The marking is the one feature that could tempt someone into
  // v-html, and a title is a piece of prompt content like any other.
  it('shows markup in the title as text, not as markup', () => {
    const wrapper = list(promptRow({
      title: '<script>alert(1)</script>',
      highlights: { title: [[0, 8]], description: [] }
    }))

    expect(wrapper.find('.hit__title').text()).toBe('<script>alert(1)</script>')
    expect(wrapper.find('.hit__title').element.querySelector('script')).toBeNull()
    // The marking itself still works on that text — the point is that it is
    // the *text* that gets marked.
    expect(wrapper.find('.hit__title mark').text()).toBe('<script>')
  })
})
