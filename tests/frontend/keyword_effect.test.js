import { describe, it, expect } from 'vitest'
import { effectParts, sameAsPipeline } from '../../frontend/src/util/keyword.js'
import { render } from '../../frontend/src/util/rendering.js'

// The preview W-4 asks for, at the level where it can be stated exactly.
//
// The screen draws two blocks and says which is which. What has to be true of
// them is that the order is the answer to "prepend or append", and that the
// two put back together are what the pipeline actually produces — otherwise
// the example would promise something a real prompt then does differently.

const BODY = 'Summarise the following passage in three sentences.'

const keyword = (overrides = {}) => ({
  name: 'formal', text: 'Antworte in förmlichem Deutsch.',
  position: 'prepend', sort_order: 0, ...overrides
})

describe('The effect of a keyword (W-4, TF-353)', () => {
  it('puts the text block in front of the prompt', () => {
    const parts = effectParts({ body: BODY, keyword: keyword() })

    expect(parts.map((part) => part.kind)).toEqual(['keyword', 'prompt'])
    expect(parts[0].text).toBe('Antworte in förmlichem Deutsch.')
  })

  it('and behind the prompt when the position says so', () => {
    const parts = effectParts({ body: BODY, keyword: keyword({ position: 'append' }) })

    expect(parts.map((part) => part.kind)).toEqual(['prompt', 'keyword'])
  })

  // While it is being written there is no text yet, and a block of nothing
  // between two rules would be a gap nobody asked for.
  it('leaves an empty block out entirely', () => {
    expect(effectParts({ body: BODY, keyword: keyword({ text: '' }) }))
      .toEqual([{ kind: 'prompt', text: BODY }])

    expect(effectParts({ body: BODY, keyword: keyword({ text: '   \n  ' }) }))
      .toEqual([{ kind: 'prompt', text: BODY }])
  })

  // The promise the screen makes: what is drawn is what would be rendered.
  //
  // Run over the shapes a person types on the way to a finished keyword —
  // a trailing newline after pressing Enter, a doubled blank line, spaces at
  // the end of a line, nothing at all. Each of those is a moment the preview
  // is on display, and each is a chance for the drawing to part from the
  // pipeline.
  it('assembled it gives exactly what the pipeline renders', () => {
    const texts = [
      'Antworte in förmlichem Deutsch.',
      'Erste Zeile\nZweite Zeile',
      'Mit Absatz.\n\n\n\nUnd noch einem.',
      'Zeile mit Leerzeichen am Ende   \nund noch eine   ',
      '\n\nMit Umbruch am Anfang',
      'Mit Umbruch am Ende\n\n',
      '',
      '   '
    ]

    for (const position of ['prepend', 'append']) {
      for (const text of texts) {
        const input = { body: BODY, keyword: keyword({ text, position }) }
        expect(sameAsPipeline(input), `${position}: ${JSON.stringify(text)}`).toBe(true)
      }
    }
  })

  // The counter-check to the invariant above: it has to be able to fail.
  // An invariant nothing can break is an invariant that proves nothing — and
  // this one is the only thing holding the drawing to the pipeline.
  it('shows up when the order does not match the position', () => {
    const wrong = { body: BODY, keyword: keyword({ position: 'append' }) }
    const swapped = [
      { kind: 'keyword', text: wrong.keyword.text },
      { kind: 'prompt', text: BODY }
    ].map((part) => part.text).join('\n\n')

    expect(swapped).not.toBe(render({ body: BODY, variables: [], keywords: [wrong.keyword] }).text)
  })

  // A prompt whose own text is empty leaves the keyword standing alone — the
  // pipeline drops the empty block, so the preview must not draw a gap for it
  // either.
  it('copes with an empty example', () => {
    const parts = effectParts({ body: '', keyword: keyword() })

    expect(parts).toEqual([{ kind: 'keyword', text: 'Antworte in förmlichem Deutsch.' }])
    expect(sameAsPipeline({ body: '', keyword: keyword() })).toBe(true)
  })
})
