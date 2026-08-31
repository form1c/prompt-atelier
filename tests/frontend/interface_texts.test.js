import { describe, it, expect, afterEach } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { t, texts, failOnMissingTexts } from '../../frontend/src/i18n/index.js'

// NFA-15 and E-12: no user-facing text in the code.
//
// The lookup itself is three lines and would hardly deserve a suite. What
// deserves one is the rule around it, and the rule has two halves that a test
// on the lookup would miss entirely: every key that is used must exist, and
// no text may bypass the table. The first half turns a typo into a failing
// test instead of a blank spot on the screen; the second is what keeps the
// promise from being quietly abandoned in the next component.

// Assembled with path.resolve rather than with `new URL(..., import.meta.url)`:
// Vite rewrites that pattern into an asset reference during transformation,
// and the rewritten value is no longer a file path.
const HERE = path.dirname(fileURLToPath(import.meta.url))
const SOURCE = path.resolve(HERE, '..', '..', 'frontend', 'src')

function sourceFiles (directory = SOURCE, collected = []) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name)
    if (entry.isDirectory()) sourceFiles(full, collected)
    else if (/\.(vue|js)$/.test(entry.name)) collected.push(full)
  }
  return collected
}

const relative = (file) => path.relative(SOURCE, file)

describe('Text lookup', () => {
  afterEach(() => failOnMissingTexts(true))

  it('finds a text through the dotted path', () => {
    expect(t('login.submit')).toBe('Sign in')
  })

  it('puts placeholders in and leaves unknown ones standing', () => {
    expect(t('setup.password_hint', { minimum: 12 })).toContain('12 characters')
    expect(t('setup.password_hint')).toContain('{minimum}')
  })

  it('fails loudly on an unknown key', () => {
    expect(() => t('login.gibt_es_nicht')).toThrow(/Unknown text key/)
  })

  // The production build must not answer a missing key with a blank page: an
  // exception thrown during render takes the whole screen with it, which is a
  // worse outcome than the untranslated key. The mode above is where the
  // mistake is meant to surface — this is the safety net behind it.
  it('returns the key instead of failing in a production build', () => {
    failOnMissingTexts(false)

    expect(t('login.gibt_es_nicht')).toBe('login.gibt_es_nicht')
  })
})

describe('Text coverage', () => {
  // The two ways a key is written in this code base: passed to t(), or
  // carried as data next to the thing it labels (the navigation entries, the
  // sort options).
  //
  // Deliberately not "every dotted lowercase string": that caught expressions
  // like v-if="library.error" as well, because a state object may share a
  // name with a section of the table. A check that reports the innocent is a
  // check people learn to ignore.
  const PATTERNS = [
    /\bt\(\s*['"]([\w.]+)['"]/g,
    /\blabel:\s*['"]([\w.]+)['"]/g
  ]

  function keysIn (source) {
    return PATTERNS.flatMap((pattern) => [...source.matchAll(pattern)].map(([, key]) => key))
  }

  // Every dotted path in the table that leads to a text. Keys starting with an
  // underscore are notes to the translator, not texts.
  function paths (node, prefix = '') {
    return Object.entries(node).flatMap(([key, value]) => {
      if (key.startsWith('_')) return []

      const full = prefix ? `${prefix}.${key}` : key
      return typeof value === 'object' ? paths(value, full) : [full]
    })
  }

  it('knows every key the code uses', () => {
    const unknown = []

    for (const file of sourceFiles()) {
      for (const key of keysIn(readFileSync(file, 'utf8'))) {
        try {
          t(key)
        } catch {
          unknown.push(`${relative(file)}: ${key}`)
        }
      }
    }

    expect(unknown).toEqual([])
  })

  // The counter-check: the search has to be able to find something at all.
  // Without it a pattern that matched nothing would report a clean result for
  // a code base full of broken keys.
  it('finds the keys at all', () => {
    const found = new Set()

    for (const file of sourceFiles()) {
      keysIn(readFileSync(file, 'utf8')).forEach((key) => found.add(key))
    }

    expect(found.size).toBeGreaterThan(30)
    expect(found).toContain('login.forgotten_hint')
    expect(found).toContain('shell.nav.library')
    expect(found).toContain('library.sort.changed')
  })

  // The other direction, and the one that found something: a text nobody uses
  // is a promise the interface does not keep. `library.empty_search_create`
  // sat in the table for a whole package before the offer it belongs to was
  // wired up — visible in the file, invisible on the screen.
  //
  // No list of exceptions on purpose. A text and the place it appears belong
  // in the same change; anything else is a translation cost for words nobody
  // reads.
  // Two families are looked up by a key that is only known at run time —
  // `t(`admin.setting_${key}`)` for the editable settings and
  // `t(`admin.choice_${mode}`)` for their choices. A scan of the source
  // cannot see those, and writing the list out in the component would only
  // move the duplication.
  //
  // They are named here rather than exempted quietly, and each is covered by
  // an assertion of its own that is **stronger** than this scan: the settings
  // screen suite reads the list of editable keys from the server's own source
  // and insists that every one of them has a label and a hint.
  // Since AP-19 two whole namespaces join them, and for the same reason: the
  // server answers with a **code**, and the sentence is fetched as
  // `t(`server.${code}`)` / `t(`field.${code}`)`. A scan of the source can see
  // neither. They are not exempted quietly either — TF-534 is stronger than
  // this scan, because it reads the codes the server can actually send out of
  // the server's own source and insists every one of them has a sentence.
  const DYNAMIC = ['admin.setting_', 'admin.choice_', 'admin.kind_', 'server.', 'field.',
                   'error.network', 'error.unreadable', 'error.unexpected']

  it('uses every text the table carries', () => {
    const used = new Set()
    for (const file of sourceFiles()) {
      keysIn(readFileSync(file, 'utf8')).forEach((key) => used.add(key))
    }

    const orphaned = paths(texts)
      .filter((key) => !used.has(key))
      .filter((key) => !DYNAMIC.some((prefix) => key.startsWith(prefix)))

    expect(orphaned).toEqual([])
  })

  // And it must notice a key that does not exist — proven on a sample, since
  // the code base is meant to be clean.
  it('spots an invented key', () => {
    expect(keysIn("t('library.gibt_es_nicht')")).toEqual(['library.gibt_es_nicht'])
    expect(() => t('library.gibt_es_nicht')).toThrow()
  })
})

describe('No display text in the code', () => {
  const LETTER = /[A-Za-zÄÖÜäöüß]/

  function templateOf (source) {
    const match = source.match(/^<template>\n([\s\S]*?)^<\/template>/m)
    return match ? match[1] : ''
  }

  // Deliberately a small scanner rather than replacing everything between
  // angle brackets. Such an expression ends a tag at the first ">" it meets,
  // and a real template has plenty of them inside attribute values:
  // @toggle="(id) => apply(id)" would leave apply(id)" behind and be reported
  // as visible text. Tracking the quotes is what makes this check usable on
  // the templates that exist instead of only on tidy ones.
  function skipTag (source, start) {
    let index = start + 1
    let quote = null

    while (index < source.length) {
      const character = source[index]
      if (quote) {
        if (character === quote) quote = null
      } else if (character === '"' || character === "'") {
        quote = character
      } else if (character === '>') {
        return index + 1
      }
      index += 1
    }
    return index
  }

  function textNodes (template) {
    const source = template.replace(/<!--[\s\S]*?-->/g, ' ')
    const pieces = []
    let text = ''
    let index = 0

    while (index < source.length) {
      if (source[index] === '<') {
        pieces.push(text)
        text = ''
        index = skipTag(source, index)
        continue
      }
      text += source[index]
      index += 1
    }
    pieces.push(text)

    return pieces.join(' ')
      .replace(/\{\{[\s\S]*?\}\}/g, ' ')
      .split(/\s+/)
      .filter((part) => part !== '')
  }

  it('keeps every visible text of the templates in the lookup', () => {
    const offenders = []

    for (const file of sourceFiles().filter((name) => name.endsWith('.vue'))) {
      for (const text of textNodes(templateOf(readFileSync(file, 'utf8')))) {
        if (LETTER.test(text)) offenders.push(`${relative(file)}: ${text}`)
      }
    }

    expect(offenders).toEqual([])
  })

  // Attributes are the hiding place the check above does not look at: a
  // placeholder or a title is as visible as any text node, but it sits inside
  // the tag rather than between two of them. Bound (":placeholder") is fine,
  // written out is not.
  it('keeps visible attributes in the lookup too', () => {
    const VISIBLE_ATTRIBUTE = /\s(?:placeholder|title|alt|aria-label)="([^"]*)"/g
    const offenders = []

    for (const file of sourceFiles().filter((name) => name.endsWith('.vue'))) {
      const template = templateOf(readFileSync(file, 'utf8'))
      for (const [, value] of template.matchAll(VISIBLE_ATTRIBUTE)) {
        if (LETTER.test(value)) offenders.push(`${relative(file)}: ${value}`)
      }
    }

    expect(offenders).toEqual([])
  })

  // The counter-check for both of the above: they have to notice a text that
  // is written into the template. Proven on a sample rather than on the code
  // base, because the code base is supposed to be clean.
  it('spots a hard-coded text', () => {
    const sample = '<template>\n  <p>Gespeichert</p>\n  <input placeholder="Suchen">\n</template>\n'

    expect(textNodes(templateOf(sample))).toEqual(['Gespeichert'])
    expect(templateOf(sample)).toMatch(/placeholder="Suchen"/)
  })

  // And it must not report what only stands inside an attribute. Without this
  // the scanner drowns in arrow functions, and an empty list — the honest
  // answer for clean templates — stops being reachable.
  it('does not take an expression in an attribute for visible text', () => {
    const sample = '<template>\n  <b @tap="(id) => go(id)">{{ x }}</b>\n</template>\n'

    expect(textNodes(templateOf(sample))).toEqual([])
  })
})
