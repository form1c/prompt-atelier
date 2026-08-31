// @vitest-environment node
//
// Plain data in, plain data out — the same rule as rendering.test.js.

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { render, renderMarked, normalizeText } from '../../frontend/src/util/rendering.js'
import { pieces } from '../../frontend/src/util/preview.js'

// TF-443 — where the finished text came from.
//
// Requirements 8.3 asks the preview to mark the spot of a missing mandatory
// value. Until now only the *form field* was marked, and TF-401 checked that
// half of the sentence, so the other half could go missing without anything
// saying so. What is tested here is the part that was missing: the pipeline
// reports positions in the finished text, and those positions have to survive
// the three steps that follow the substitution.

const HERE = path.dirname(fileURLToPath(import.meta.url))
const DATA = JSON.parse(readFileSync(path.resolve(HERE, '..', 'vectors', 'rendering.json'), 'utf8'))

function marked (body, variables = [], keywords = [], showPlaceholders = false) {
  return renderMarked({ body, variables, keywords, showPlaceholders })
}

// The keywords of the vectors, resolved to their definitions.
function keywordsOf (vector) {
  return (vector.keywords ?? []).map((name) => ({
    ...((vector.extra_keywords ?? {})[name] ?? DATA.keywords[name]), name
  }))
}

// The mark as it reads on the screen: the stretch of finished text it covers.
function covered (result) {
  return result.marks.map((mark) => ({
    key: mark.key,
    text: result.text.slice(mark.start, mark.end),
    filled: mark.filled
  }))
}

describe('Provenance marks', () => {
  it('cover exactly the value that was put in', () => {
    const result = marked('Schreibe über {{thema}} für {{gruppe}}.', [
      { key: 'thema', value: 'Kaffee' },
      { key: 'gruppe', value: 'Einsteiger' }
    ])

    expect(result.text).toBe('Schreibe über Kaffee für Einsteiger.')
    expect(covered(result)).toEqual([
      { key: 'thema', text: 'Kaffee', filled: true },
      { key: 'gruppe', text: 'Einsteiger', filled: true }
    ])
  })

  // Spelling and spaces inside the braces belong to the occurrence (8.2).
  // The mark has to cover the *value*, not the braces.
  it('follow the spelling and spacing inside the braces', () => {
    const result = marked('A {{ Thema }} B', [{ key: 'thema', value: 'X' }])

    expect(result.text).toBe('A X B')
    expect(covered(result)).toEqual([{ key: 'thema', text: 'X', filled: true }])
  })

  it('appear for the same key at every occurrence', () => {
    const result = marked('{{a}} und {{a}}', [{ key: 'a', value: 'X' }])

    expect(result.marks).toHaveLength(2)
    expect(result.marks.map((mark) => mark.start)).toEqual([0, 6])
  })

  it('do not appear for unknown or escaped occurrences', () => {
    expect(marked('{{fremd}} \\{{keine}}').marks).toEqual([])
  })

  // The three steps after the substitution still move the text about. Every
  // check below would fail if the mark stayed at the position it had after
  // step 2.
  it('shift along with a resolved escape in front of them', () => {
    const result = marked('\\{{wörtlich}} {{a}}', [{ key: 'a', value: 'X' }])

    expect(result.text).toBe('{{wörtlich}} X')
    expect(covered(result)).toEqual([{ key: 'a', text: 'X', filled: true }])
  })

  it('shift by the keyword block placed in front', () => {
    const result = marked('{{a}}', [{ key: 'a', value: 'X' }], [
      { name: 'rolle', text: 'Du bist Fachautor.', position: 'prepend', sort_order: 10 }
    ])

    expect(result.text).toBe('Du bist Fachautor.\n\nX')
    expect(covered(result)).toEqual([{ key: 'a', text: 'X', filled: true }])
  })

  it('shift when leading blank lines are removed', () => {
    const result = marked('\n\n{{a}}', [{ key: 'a', value: 'X' }])

    expect(result.text).toBe('X')
    expect(covered(result)).toEqual([{ key: 'a', text: 'X', filled: true }])
  })

  // The case that does not merely move the mark but cuts into it: the value
  // ends in spaces, and step 4 takes those off at the end of the line.
  it('shrink along when the normalisation cuts into the value', () => {
    const result = marked('Wert: {{a}}\nEnde', [{ key: 'a', value: 'X  ' }])

    expect(result.text).toBe('Wert: X\nEnde')
    expect(covered(result)).toEqual([{ key: 'a', text: 'X', filled: true }])
  })

  // The harder relative of that one: here the normalisation *replaces* rather
  // than deletes — the line break out of the value collapses together with
  // those of the text into a single blank line. The mark gives the collapsed
  // spot up instead of taking it over; otherwise there would be colour on an
  // empty line, and nobody can read anything into that.
  //
  // Both directions, because the mark can run into a replacement at either
  // end and the two cases sit in different branches.
  it('give up a collapsed blank line at the end', () => {
    const result = marked('{{a}}\n\nEnde', [{ key: 'a', value: 'X\n' }])

    expect(result.text).toBe('X\n\nEnde')
    expect(covered(result)).toEqual([{ key: 'a', text: 'X', filled: true }])
  })

  it('give up a collapsed blank line at the start', () => {
    const result = marked('A\n\n{{a}}', [{ key: 'a', value: '\nX' }])

    expect(result.text).toBe('A\n\nX')
    expect(covered(result)).toEqual([{ key: 'a', text: 'X', filled: true }])
  })

  // A value the normalisation has eaten up entirely: both ends of the mark
  // lie inside the same replacement, one is pulled forward and the other
  // back. Without the clamp the end would stand **before** the start.
  //
  // Checked here and not on the preview pieces: those clear an inside-out
  // mark away by themselves, and the effect on screen would be the same. That
  // is exactly why a mutation on the clamp ran through the entire display
  // check untouched.
  it('never yield a mark whose end lies before its start', () => {
    const result = marked('A\n\n{{a}}\n\nB', [{ key: 'a', value: '\n' }])

    expect(result.text).toBe('A\n\nB')
    expect(result.marks).toEqual([{ key: 'a', start: 3, end: 3, filled: true }])
  })

  it('stay as an empty spot when nothing was put in', () => {
    const result = marked('Über {{a}}.', [{ key: 'a', required: true }])

    expect(result.text).toBe('Über .')
    expect(result.marks).toEqual([{ key: 'a', start: 5, end: 5, filled: false }])
  })
})

// The route the screen really takes: the preview renders **with** the
// placeholders put in, so the text lays itself out around them.
describe('Preview with placeholders', () => {
  // Found by the client on one of the example prompts. A multiline variable
  // stands alone between two blank lines — the most common shape there is for
  // this type of variable.
  //
  // If it puts nothing in, the four line breaks collapse to two at step 4. A
  // placeholder drawn in afterwards stuck to the sentence that followed:
  // "{{auszug}}Was ist passiert". Every check on the marks was green, because
  // they all used single-line texts — the mark did sit in the right place, the
  // place was just in the wrong text.
  it('leaves the blank lines around an empty multiline variable alone', () => {
    const body = 'Deute diesen Protokollauszug:\n\n{{auszug}}\n\nWas ist passiert?'
    const variables = [{ key: 'auszug', type: 'multiline', required: true }]

    const result = marked(body, variables, [], true)

    expect(result.text).toBe('Deute diesen Protokollauszug:\n\n{{auszug}}\n\nWas ist passiert?')
    expect(covered(result)).toEqual([{ key: 'auszug', text: '{{auszug}}', filled: false }])

    // And the counter-check: the finished text, the thing that gets copied,
    // still has the gap — there is nothing there to hold the lines apart.
    expect(render({ body, variables }).text).toBe('Deute diesen Protokollauszug:\n\nWas ist passiert?')
  })

  it('puts the placeholder only where there really is nothing', () => {
    const result = marked('{{a}} und {{b}}', [
      { key: 'a', value: 'X' },
      { key: 'b' }
    ], [], true)

    expect(result.text).toBe('X und {{b}}')
    expect(result.marks.map((mark) => mark.filled)).toEqual([true, false])
  })

  // A default value is a value. Whoever set one has filled the spot, even
  // without touching it.
  it('puts in no placeholder where a default value applies', () => {
    const result = marked('{{a}}', [{ key: 'a', default_value: 'Einsteiger' }], [], true)

    expect(result.text).toBe('Einsteiger')
    expect(covered(result)).toEqual([{ key: 'a', text: 'Einsteiger', filled: true }])
  })

  // The placeholder must not obscure the decisions: what is missing is still
  // missing, and the block on copying hangs off that (8.3).
  it('changes nothing about the missing required values', () => {
    const result = marked('{{a}}', [{ key: 'a', required: true }], [], true)

    expect(result.missingRequired).toEqual(['a'])
    expect(result.complete).toBe(false)
  })

  it('leaves render untouched — no placeholder is ever put in there', () => {
    expect(render({ body: '{{a}}', variables: [{ key: 'a' }] }).text).toBe('')
  })
})

describe('Preview pieces', () => {
  // As on screen: with the placeholders put in.
  function cut (body, variables = [], keywords = []) {
    const result = marked(body, variables, keywords, true)
    return pieces(result.text, result.marks, result.missingRequired)
  }

  it('mark the values that were put in', () => {
    expect(cut('Über {{a}}.', [{ key: 'a', value: 'Kaffee' }])).toEqual([
      { kind: 'plain', text: 'Über ' },
      { kind: 'value', key: 'a', text: 'Kaffee' },
      { kind: 'plain', text: '.' }
    ])
  })

  // The distinction 8.3 asks for: the unfilled required variable is the spot
  // that has to be marked. The one left empty by choice is only a hint.
  it('tell an empty required variable from an empty optional one', () => {
    const result = cut('{{pflicht}} und {{frei}}', [
      { key: 'pflicht', required: true },
      { key: 'frei', required: false }
    ])

    // The opening and the closing quote with both spaces. In the finished
    // text the second one is gone — the line ends on it there, and step 4
    // takes spaces off the end of a line. On screen the placeholder stands
    // between them, so the line does not end and the gap stays. Both are
    // right, and precisely that difference is the point of the whole thing.
    expect(result).toEqual([
      { kind: 'missing', key: 'pflicht', text: '{{pflicht}}' },
      { kind: 'plain', text: ' und ' },
      { kind: 'empty', key: 'frei', text: '{{frei}}' }
    ])

    expect(render({
      body: '{{pflicht}} und {{frei}}',
      variables: [{ key: 'pflicht', required: true }, { key: 'frei' }]
    }).text).toBe(' und')
  })

  it('show the placeholder in lower case, the way the key is stored', () => {
    expect(cut('{{Thema}}', [{ key: 'thema' }])[0]).toEqual({
      kind: 'empty', key: 'thema', text: '{{thema}}'
    })
  })

  it('yield a single piece for a text without marks', () => {
    expect(pieces('Nur Text.', [])).toEqual([{ kind: 'plain', text: 'Nur Text.' }])
  })

  it('yield nothing at all for empty text', () => {
    expect(pieces('', [])).toEqual([])
  })

  // A mark the normalisation has eaten up entirely: it was filled, but
  // nothing of the value is left. A placeholder for it would be wrong — the
  // value was there, it just came to nothing.
  //
  // And the two neighbours stay one piece: two `plain` next to each other
  // would be the same characters in two elements with nothing between them.
  it('show no placeholder for a value that was consumed', () => {
    const result = cut('A{{a}}\nB', [{ key: 'a', value: '  ' }])

    expect(result).toEqual([{ kind: 'plain', text: 'A\nB' }])
  })

  // The assurance everything else rests on: **the display is the finished
  // text plus placeholders and nothing else.** Take the placeholders out and
  // normalise (step 4), and exactly the text that gets copied and counted has
  // to come back.
  //
  // The normalising belongs to it and is the heart of the matter: a
  // placeholder holds lines apart that collapse without it. That is precisely
  // what the first version came to grief on — it drew the placeholder into the
  // text that had already collapsed.
  //
  // The earlier check demanded the pieces give the text back **verbatim**. It
  // was green across all 34 vectors and blind to the fault, because a
  // placeholder did not count there at all: it checked that nothing gets lost,
  // not that the result is readable.
  it('are the finished text plus placeholders — across all 34 vectors', () => {
    for (const vector of DATA.vectors) {
      const input = { body: vector.body, variables: vector.variables ?? [], keywords: keywordsOf(vector) }
      const shown = renderMarked({ ...input, showPlaceholders: true })

      const withoutSlots = pieces(shown.text, shown.marks, shown.missingRequired)
        .filter((piece) => piece.kind === 'plain' || piece.kind === 'value')
        .map((piece) => piece.text)
        .join('')

      expect(normalizeText(withoutSlots), `${vector.id} — ${vector.title}`).toBe(vector.expected)
    }
  })

  // The same assurance on the shapes it is about: an empty variable alone on
  // its line, at the start, at the end, twice in a row. Not one of these cases
  // is among the vectors, and the reported fault was the first of them.
  it('are the finished text plus placeholders — for variables on their own line too', () => {
    const shapes = [
      'A:\n\n{{x}}\n\nB',
      '{{x}}\n\nB',
      'A:\n\n{{x}}',
      'A:\n\n{{x}}\n\n{{y}}\n\nB',
      '{{x}}',
      'A {{x}} B'
    ]

    for (const body of shapes) {
      const variables = [{ key: 'x' }, { key: 'y' }]
      const shown = renderMarked({ body, variables, showPlaceholders: true })

      const withoutSlots = pieces(shown.text, shown.marks, shown.missingRequired)
        .filter((piece) => piece.kind === 'plain' || piece.kind === 'value')
        .map((piece) => piece.text)
        .join('')

      expect(normalizeText(withoutSlots), JSON.stringify(body)).toBe(render({ body, variables }).text)
    }
  })

  // And the counter-check to that assurance: the placeholder really does
  // stand as a piece of its own and has not ended up inside the text.
  it('carry the placeholder as a piece of its own, not as text', () => {
    const parts = cut('A:\n\n{{x}}\n\nB', [{ key: 'x' }])

    expect(parts).toEqual([
      { kind: 'plain', text: 'A:\n\n' },
      { kind: 'empty', key: 'x', text: '{{x}}' },
      { kind: 'plain', text: '\n\nB' }
    ])
  })
})

// `pieces` gets whatever the screen put down last, and marks and text could
// come from two different runs. The safeguards against that stood in the file
// unchecked — a mutation probe went through all three of them without a
// single test noticing. An unchecked safeguard is a claim, not a protection.
describe('Preview pieces from unclean marks', () => {
  const mark = (start, end, key = 'a') => ({ key, start, end, filled: true })

  it('bring unsorted marks into the order of the text', () => {
    expect(pieces('abcdef', [mark(4, 6, 'b'), mark(0, 2, 'a')])).toEqual([
      { kind: 'value', key: 'a', text: 'ab' },
      { kind: 'plain', text: 'cd' },
      { kind: 'value', key: 'b', text: 'ef' }
    ])
  })

  // The case that would duplicate characters: the second mark begins while
  // the first is still running.
  it('duplicate no text when marks overlap', () => {
    const parts = pieces('abcdef', [mark(0, 4, 'a'), mark(2, 6, 'b')])

    expect(parts.map((piece) => piece.text).join('')).toBe('abcdef')
  })

  it('skip marks that cannot exist in that shape', () => {
    const nonsense = [mark(-1, 2), mark(9, 9), { key: 'ohne', filled: false }]

    expect(pieces('abc', nonsense)).toEqual([{ kind: 'plain', text: 'abc' }])
  })
})

// The marks must not touch the text. Structurally that is guaranteed,
// because `render` is nothing but `renderMarked` without marks — it is
// checked all the same, because that very structure is the point at which
// somebody could later stand a second pipeline beside it (R-01).
describe('render and renderMarked', () => {
  it('yield the same text across all 34 vectors', () => {
    for (const vector of DATA.vectors) {
      const keywords = (vector.keywords ?? []).map((name) => ({
        ...((vector.extra_keywords ?? {})[name] ?? DATA.keywords[name]), name
      }))
      const input = { body: vector.body, variables: vector.variables ?? [], keywords }

      expect(render(input).text, vector.id).toBe(renderMarked(input).text)
    }
  })

  it('differ only in the marks', () => {
    const input = { body: '{{a}}', variables: [{ key: 'a', value: 'X' }] }

    expect(Object.keys(render(input)).sort())
      .toEqual(['complete', 'missingRequired', 'rejectedKeys', 'text', 'unknownKeys'])
    expect(renderMarked(input).marks).toHaveLength(1)
  })
})
