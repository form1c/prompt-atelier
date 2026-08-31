// @vitest-environment node
//
// No DOM is involved: the pipeline is plain data in, plain data out (NFA-14),
// and it stays that way only as long as nothing here needs a browser.

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { render, variableKeys, measure } from '../../frontend/src/util/rendering.js'

// TF-101 to TF-134 — the same 34 vectors the Minitest suite runs.
//
// This is the proof for A-12 and the safeguard against R-01. Both sides read
// **this file**, not a copy: two lists of expected values would drift apart,
// and the whole point is that the two implementations answer to one source.
//
// A failure means one of three things (test concept 5.6):
//   both sides wrong the same way  -> specification misread, fix both
//   only JavaScript wrong          -> fix here
//   the two sides differ           -> risk R-01, delivery blocked

const HERE = path.dirname(fileURLToPath(import.meta.url))
const VECTOR_FILE = path.resolve(HERE, '..', 'vectors', 'rendering.json')
const DATA = JSON.parse(readFileSync(VECTOR_FILE, 'utf8'))
const VECTORS = DATA.vectors

function renderVector (vector) {
  const keywords = (vector.keywords ?? []).map((name) => {
    const definition = (vector.extra_keywords ?? {})[name] ?? DATA.keywords[name]
    return { ...definition, name }
  })

  return render({
    body: vector.body,
    variables: vector.variables ?? [],
    keywords
  })
}

describe('Rendering vectors', () => {
  // One case per vector rather than one loop, so a failure names the vector:
  // "TF-119 failed" is a place to look, "the vector test failed" is not.
  for (const vector of VECTORS) {
    it(`${vector.id} — ${vector.title}`, () => {
      const result = renderVector(vector)

      expect(result.text).toBe(vector.expected)

      if ('unknown_keys' in vector) expect(result.unknownKeys).toEqual(vector.unknown_keys)
      if ('missing_required' in vector) expect(result.missingRequired).toEqual(vector.missing_required)
    })
  }
})

describe('The vector file', () => {
  // A-12 promises 34 vectors. If one were dropped the suite above would
  // simply run one case fewer and stay green — silently.
  it('carries exactly the 34 documented vectors', () => {
    const ids = VECTORS.map((vector) => vector.id)

    expect(ids).toHaveLength(34)
    expect(ids).toEqual(Array.from({ length: 34 }, (unused, index) => `TF-${101 + index}`))
  })

  // The file is the shared source. If this side ever read a copy of its own,
  // the safeguard against R-01 would be gone and nothing would say so.
  it('reads the same file as the Ruby side', () => {
    expect(VECTOR_FILE).toBe(path.resolve(HERE, '..', 'vectors', 'rendering.json'))
    expect(readFileSync(VECTOR_FILE, 'utf8')).toContain('Diese Datei wird von Minitest UND von Vitest gelesen')
  })
})

// The properties the vectors do not pin down — the same set the Minitest
// suite checks, case for case.
//
// They belong on both sides for the same reason the vectors do: a rule that
// only one implementation is held to is a rule the other may break. A
// mutation probe found three of these missing here while Ruby had them, which
// is exactly the asymmetry R-01 warns about.
describe('Key detection (8.2)', () => {
  it('takes a key with a space for no key and warns about nothing', () => {
    const result = render({ body: 'Nutze {{Mein Thema}} hier.' })

    expect(result.text).toBe('Nutze {{Mein Thema}} hier.')
    expect(result.unknownKeys).toEqual([])
  })

  it('limits a key to forty characters', () => {
    const fits = 'a'.repeat(40)
    const tooBig = 'a'.repeat(41)

    expect(render({ body: `{{${fits}}}`, variables: [{ key: fits, value: 'X' }] }).text).toBe('X')

    const result = render({ body: `{{${tooBig}}}`, variables: [{ key: tooBig, value: 'X' }] })
    expect(result.text).toBe(`{{${tooBig}}}`)
    expect(result.unknownKeys).toEqual([])
  })

  it('does not let hyphen, dot and emptiness count as a key', () => {
    for (const text of ['{{mein-thema}}', '{{mein.thema}}', '{{ }}', '{{}}']) {
      expect(render({ body: text }).text).toBe(text)
    }
  })

  it('allows underscores and digits after the first letter', () => {
    expect(render({ body: '{{thema_2}}', variables: [{ key: 'thema_2', value: 'Kaffee' }] }).text)
      .toBe('Kaffee')
  })

  // 8.2 asks for the lower-casing on **both** sides of the comparison: in the
  // text and in the record. The text is covered by the vectors, the record was
  // covered on neither side — both versions lower-case, neither was ever held
  // to it. Exactly the construction R-01 warns about, only doubled: whoever
  // strikes one of the two lines notices it nowhere.
  it('compares the key of the record without regard to case as well', () => {
    const result = render({ body: '{{thema}}', variables: [{ key: 'THEMA', value: 'Kaffee' }] })

    expect(result.text).toBe('Kaffee')
    expect(result.unknownKeys).toEqual([])
  })

  // The same unknown key twice is one warning, not two — and in the order of
  // first occurrence. Neither side pinned this until a mutation probe removed
  // the check and every vector stayed green.
  it('names an unknown key once, in the order of appearance', () => {
    const result = render({ body: '{{b}} {{a}} {{b}} {{a}}' })

    expect(result.unknownKeys).toEqual(['b', 'a'])
  })
})

describe('Values', () => {
  it('falls back to the default value and then to empty text', () => {
    expect(render({ body: '{{a}}.', variables: [{ key: 'a', default_value: 'D' }] }).text).toBe('D.')
    expect(render({ body: '{{a}}.', variables: [{ key: 'a' }] }).text).toBe('.')
  })

  // A value of "0" is a value. Falling back to the default there would be the
  // classic truthiness mistake — and in JavaScript it is one line away.
  it('takes zero as a value', () => {
    expect(render({ body: '{{a}}', variables: [{ key: 'a', value: '0', default_value: 'D' }] }).text)
      .toBe('0')
    expect(render({ body: '{{a}}', variables: [{ key: 'a', value: 0, default_value: 'D' }] }).text)
      .toBe('0')
  })
})

describe('Required variables (8.3)', () => {
  it('does not report a required variable with a default as unfilled', () => {
    const result = render({ body: '{{a}}', variables: [{ key: 'a', required: true, default_value: 'D' }] })

    expect(result.text).toBe('D')
    expect(result.missingRequired).toEqual([])
    expect(result.complete).toBe(true)
  })

  it('produces the preview even without the required value', () => {
    const result = render({
      body: 'Schreibe über {{thema}}.',
      variables: [{ key: 'thema', required: true }]
    })

    expect(result.text).toBe('Schreibe über .')
    expect(result.missingRequired).toEqual(['thema'])
    // Copying is what gets blocked, not the rendering.
    expect(result.complete).toBe(false)
  })
})

describe('Keywords', () => {
  it('inserts no separator for an empty keyword text', () => {
    const result = render({
      body: 'Text.',
      keywords: [{ name: 'leer', text: '', position: 'append', sort_order: 10 }]
    })

    expect(result.text).toBe('Text.')
  })

  it('does not depend on the order in which the keywords arrive', () => {
    const keywords = [
      { name: 'b', text: 'Zweitens.', position: 'append', sort_order: 20 },
      { name: 'a', text: 'Erstens.', position: 'append', sort_order: 10 }
    ]

    const forwards = render({ body: 'Text.', keywords }).text
    const backwards = render({ body: 'Text.', keywords: [...keywords].reverse() }).text

    expect(forwards).toBe('Text.\n\nErstens.\n\nZweitens.')
    expect(backwards).toBe(forwards)
  })
})

describe('Properties beyond the vectors', () => {
  it('yields the same result for the same input', () => {
    for (const vector of VECTORS) {
      expect(renderVector(vector).text).toBe(renderVector(vector).text)
    }
  })

  // The order of the two rules in step 4 that the vectors pin down for the
  // Ruby side. Repeated here because a JavaScript `$` without the m flag
  // matches only the end of the whole text — the single most likely way for
  // the two sides to part company.
  it('removes whitespace at the end of **every** line, not only the last', () => {
    const result = render({ body: 'Zeile A   \nZeile B\t\nZeile C  ' })

    expect(result.text).toBe('Zeile A\nZeile B\nZeile C')
  })

  it('detects the keys of a text in the order of appearance', () => {
    expect(variableKeys('{{Thema}} und {{zielgruppe}} und nochmal {{THEMA}}'))
      .toEqual(['thema', 'zielgruppe'])
    expect(variableKeys('\\{{kein}} Schluessel')).toEqual([])
  })

  // 11.4: characters and words below the preview, for models with a limit.
  it('counts the characters and words of the result', () => {
    expect(measure('Fasse dich kurz.')).toEqual({ characters: 16, words: 3 })
    expect(measure('  mehrere   Leerraeume\n\nund Zeilen ')).toEqual({ characters: 35, words: 4 })
    expect(measure('')).toEqual({ characters: 0, words: 0 })
    // Counted in characters, not in UTF-16 units: an emoji is one character
    // to the reader and two to `String#length`.
    expect(measure('Grüße 😀').characters).toBe(7)
  })
})
