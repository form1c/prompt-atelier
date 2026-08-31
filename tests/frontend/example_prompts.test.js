// @vitest-environment node

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { render, renderMarked, normalizeText } from '../../frontend/src/util/rendering.js'
import { pieces } from '../../frontend/src/util/preview.js'

// TF-448 — the preview against the shipped example package.
//
// Grown out of a finding by the client, and the reason for this file is the
// reason it got through: the checks on the preview used **invented,
// single-line** texts. The marks sat in the right place, the place was just in
// the wrong text — an empty multiline variable on its own line let the blank
// lines around it collapse, and the placeholder stuck to the next sentence.
//
// 22 of the prompts in the package have exactly this shape. An invented case
// covers what one thinks of; the shipped package covers what people really
// write — and it lies in the tree anyway (BT-17, FA-802).

const HERE = path.dirname(fileURLToPath(import.meta.url))
const PACKAGE = JSON.parse(
  readFileSync(path.resolve(HERE, '..', '..', 'examples', 'examples.json'), 'utf8')
)

const KEYWORDS = Object.fromEntries(PACKAGE.keywords.map((keyword) => [keyword.name, keyword]))

function inputFor (prompt, values) {
  return {
    body: prompt.body,
    variables: (prompt.variables ?? []).map((variable) => ({ ...variable, value: values(variable) })),
    keywords: (prompt.default_keywords ?? []).map((name) => KEYWORDS[name]).filter(Boolean)
  }
}

const nothing = () => ''

// In the exchange format the options are a list (17.1); in the database, and
// therefore in the answer of the API, there is one option per line (14.1). The
// pipeline never sees options at all — it knows only values — but a "value"
// that turned out to be the whole list would quietly make the case below into
// something other than what it is called.
const something = (variable) => (variable.type === 'select'
  ? [Array.isArray(variable.options) ? variable.options[0] : variable.options].flat()[0]
  : 'WERT')

// What stands on the screen, without the placeholders drawn into it.
function withoutSlots (shown) {
  return pieces(shown.text, shown.marks, shown.missingRequired)
    .filter((piece) => piece.kind === 'plain' || piece.kind === 'value')
    .map((piece) => piece.text)
    .join('')
}

describe('The example package in the preview', () => {
  // Without this check the package could shrink or lose its shapes, and
  // everything below would stay green without checking anything any more.
  it('contains the shapes it is about', () => {
    const types = new Set(PACKAGE.prompts.flatMap((prompt) => (prompt.variables ?? []).map((v) => v.type)))
    const ownLine = PACKAGE.prompts.filter((prompt) => /\n\n\{\{/.test(prompt.body))

    expect(PACKAGE.prompts.length).toBeGreaterThanOrEqual(40)
    expect([...types].sort()).toEqual(['multiline', 'number', 'select', 'text'])
    expect(ownLine.length).toBeGreaterThanOrEqual(10)
  })

  // The load-bearing assurance: the display is the finished text plus
  // placeholders and nothing else. Take the placeholders out and normalise,
  // and exactly what gets copied and counted has to come back.
  it('shows for every prompt the finished text plus placeholders — empty', () => {
    for (const prompt of PACKAGE.prompts) {
      const input = inputFor(prompt, nothing)
      const shown = renderMarked({ ...input, showPlaceholders: true })

      expect(normalizeText(withoutSlots(shown)), prompt.title).toBe(render(input).text)
    }
  })

  // Filled in there are no placeholders left, and then display and finished
  // text have to be **the same** character for character. That is the sharper
  // half: it would let no deviation through that the normalising above levels
  // out again.
  it('shows for every prompt exactly the finished text — filled in', () => {
    for (const prompt of PACKAGE.prompts) {
      const input = inputFor(prompt, something)
      const shown = renderMarked({ ...input, showPlaceholders: true })

      expect(shown.text, prompt.title).toBe(render(input).text)
      expect(pieces(shown.text, shown.marks, shown.missingRequired)
        .some((piece) => piece.kind === 'empty' || piece.kind === 'missing'), prompt.title).toBe(false)
    }
  })

  // The reported fault, as a rule over the whole package: if a variable stands
  // on its own line in the text, its placeholder stands there in the preview
  // too. That is precisely what was lost, because the empty variable puts
  // nothing into the finished text and the blank lines collapse.
  it('leaves every variable on its own line there in the preview too', () => {
    for (const prompt of PACKAGE.prompts) {
      const shown = renderMarked({ ...inputFor(prompt, nothing), showPlaceholders: true })

      for (const variable of prompt.variables ?? []) {
        const slot = `{{${variable.key}}}`

        if (prompt.body.includes(`\n\n${slot}`)) {
          expect(shown.text, `${prompt.title} / ${variable.key} davor`).toContain(`\n\n${slot}`)
        }
        if (prompt.body.includes(`${slot}\n\n`)) {
          expect(shown.text, `${prompt.title} / ${variable.key} danach`).toContain(`${slot}\n\n`)
        }
      }
    }
  })

  // And the counter-check to it, so the rule above does not hold merely
  // because the preview passes everything through unchanged: in the finished
  // text the blank line is gone, because nothing stands there to hold it.
  it('lets them collapse in the finished text — nothing stands there after all', () => {
    const auszug = PACKAGE.prompts.find((prompt) => prompt.title === 'Protokollauszug deuten')

    expect(auszug, 'der gemeldete Prompt gehört zum Paket').toBeDefined()
    expect(auszug.body).toContain('\n\n{{auszug}}\n\n')

    const finished = render(inputFor(auszug, nothing)).text
    expect(finished).not.toContain('{{auszug}}')
    expect(finished).toContain('Protokollauszug:\n\nWas ist passiert')
  })
})
