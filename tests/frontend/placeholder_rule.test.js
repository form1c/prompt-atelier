import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { render, rejectedKeys } from '../../frontend/src/util/rendering.js'

// TF-540 and TF-541 — what counts as a placeholder, and that both sides agree
// (AP-23, Requirements 8.2).
//
// **The rule exists twice.** The server substitutes when it renders and when
// it derives the variable set of a prompt; the browser does the same for the
// live preview and for the fields that appear while somebody types. Two
// notions of "what is a variable" would let a prompt carry metadata for
// something that never renders, or render something that has no metadata —
// and neither would raise anything.
//
// It had no test at all until now, which is how it survived being widened on
// one side only: `\p{L}` without the `u` flag is not a Unicode property, it is
// the four literal characters `p{L}`, so the pattern keeps matching — just
// something else. That is a difference nothing else in this project would see.

const HERE = path.dirname(fileURLToPath(import.meta.url))
const read = (...parts) => readFileSync(path.resolve(HERE, '..', '..', ...parts), 'utf8')

describe('The placeholder rule', () => {
  // TF-541. The case table lives in a file of its own, and the Ruby side
  // answers the very same one — that is what makes this a comparison rather
  // than two independent opinions.
  //
  // Compared through what the pattern **does**, not through its source: the
  // two languages spell a regular expression differently (`[[:alpha:]]` here,
  // `\p{L}` there), so a comparison of the text would either fail on the
  // spelling or be softened until it compared nothing.
  const { cases } = JSON.parse(read('tests', 'fixtures', 'placeholder_cases.json'))

  it('has a table to answer', () => {
    // Without this the loop below would pass over an empty file.
    expect(cases.length).toBeGreaterThan(10)
    expect(cases.some(({ valid }) => valid)).toBe(true)
    expect(cases.some(({ valid }) => !valid)).toBe(true)
  })

  it('accepts exactly what Requirements 8.2 accepts', () => {
    for (const { key, valid, why } of cases) {
      const substituted = render({ body: `{{${key}}}`, variables: [{ key, value: 'X' }] }).text

      expect(substituted === 'X', `{{${key}}}: ${why}`).toBe(valid)
    }
  })

  it('allows whitespace inside the braces', () => {
    expect(render({ body: '{{ name }}', variables: [{ key: 'name', value: 'X' }] }).text).toBe('X')
  })

  // TF-540. The half that used to be silent: a placeholder the rule refuses is
  // **reported**. Before this, `{{2fa}}` was not substituted, not reported as
  // unknown and given no field — the text simply kept it, and whoever wrote
  // the prompt found out when they pasted it into a model.
  it('reports what it refuses instead of leaving it standing', () => {
    const rejected = rejectedKeys('{{name}} {{2fa}} und {{mi variable}} und {{año}}')

    expect(rejected).toEqual(['2fa', 'mi variable'])
  })

  it('takes an escaped placeholder for a deliberate literal, not a mistake', () => {
    expect(rejectedKeys(String.raw`Literal \{{2fa}} bleibt`)).toEqual([])
  })

  // The counter-check: a valid one is never reported, or the warning would
  // stand under every prompt that has variables at all.
  it('reports nothing for a text whose placeholders are all valid', () => {
    expect(rejectedKeys('{{año}} {{prénom}} {{a_1}} {{ name }}')).toEqual([])
  })

  // A stray `{{` must not pair with a `}}` far away and report the paragraph
  // between them as one enormous key.
  it('does not pair braces across lines', () => {
    expect(rejectedKeys('offen {{ hier\nund dort }} zu')).toEqual([])
  })
})
