// @vitest-environment node

import { describe, it, expect } from 'vitest'
import {
  emptyDraft, draftFrom, syncVariables, moveVariable, payloadOf, changed, withDefaults, addTag
} from '../../frontend/src/util/draft.js'

// TF-451 — what the editor edits (S3, FA-301, FA-302).
//
// Two rules pull against each other here: the **set** of variables follows
// from the text and from nothing else (FA-301), their **order** belongs to the
// author (FA-302). Where the two meet, `syncVariables` decides — and it does
// so in a way that typing in the text destroys no arrangement somebody made by
// hand.

const variable = (key, rest = {}) => ({
  key, label: '', type: 'text', default_value: '', options: [], required: false, ...rest
})

describe('Turning a prompt into a draft', () => {
  it('orders the variables by position, not by the order of the answer', () => {
    const draft = draftFrom({
      title: 'T',
      body: '{{a}} {{b}} {{c}}',
      variables: [
        { key: 'a', position: 2 },
        { key: 'c', position: 0 },
        { key: 'b', position: 1 }
      ]
    })

    expect(draft.variables.map((entry) => entry.key)).toEqual(['c', 'b', 'a'])
  })

  // A field bound to `null` shows the word "null". That is why missing values
  // become empty strings.
  it('turns missing values into empty fields, not null', () => {
    const draft = draftFrom({ title: 'T', body: 'X', description: null, model_hint: null })

    expect(draft.description).toBe('')
    expect(draft.model_hint).toBe('')
  })

  // Options arrive from the API line by line (14.1), in the exchange format as
  // a list (17.1). The editor works with the list.
  it('takes options in either spelling', () => {
    const fromApi = draftFrom({ variables: [{ key: 'a', type: 'select', options: 'Eins\nZwei' }] })
    const fromPackage = draftFrom({ variables: [{ key: 'a', type: 'select', options: ['Eins', 'Zwei'] }] })

    expect(fromApi.variables[0].options).toEqual(['Eins', 'Zwei'])
    expect(fromPackage.variables[0].options).toEqual(['Eins', 'Zwei'])
  })

  it('catches an unknown type', () => {
    expect(draftFrom({ variables: [{ key: 'a', type: 'erfunden' }] }).variables[0].type).toBe('text')
  })
})

describe('Keeping variables in step with the text', () => {
  it('creates a newly typed variable', () => {
    const result = syncVariables('Über {{neu}}.', [])

    expect(result).toEqual([variable('neu')])
  })

  it('removes one whose occurrence has gone', () => {
    expect(syncVariables('Ganz ohne.', [variable('weg')])).toEqual([])
  })

  it('keeps the entered details of a variable that stays', () => {
    const gepflegt = variable('a', { label: 'Thema', type: 'select', options: ['X'], required: true })

    expect(syncVariables('{{a}} {{b}}', [gepflegt])[0]).toEqual(gepflegt)
  })

  // The heart of it: an order made by hand survives the typing.
  it('leaves a hand-picked order alone', () => {
    const arranged = [variable('b'), variable('a')]

    expect(syncVariables('{{a}} {{b}}', arranged).map((entry) => entry.key)).toEqual(['b', 'a'])
  })

  // And the new variable lands where it was typed — behind the last known one
  // that stands before it in the text. Appending at the end would be simpler
  // and wrong in the normal case: whoever inserts something in the middle of
  // the text does not go looking for it at the bottom.
  it('puts a newly typed variable where it stands in the text', () => {
    const result = syncVariables('{{a}} {{neu}} {{b}}', [variable('a'), variable('b')])

    expect(result.map((entry) => entry.key)).toEqual(['a', 'neu', 'b'])
  })

  it('places it correctly even after the order was rearranged', () => {
    // The author rearranged to [b, a]; in the text `neu` comes after `a`.
    const result = syncVariables('{{a}} {{neu}} {{b}}', [variable('b'), variable('a')])

    expect(result.map((entry) => entry.key)).toEqual(['b', 'a', 'neu'])
  })

  it('puts a variable typed at the very front to the front', () => {
    const result = syncVariables('{{neu}} {{a}}', [variable('a')])

    expect(result.map((entry) => entry.key)).toEqual(['neu', 'a'])
  })

  // FA-301: an escaped occurrence is not a variable.
  it('creates nothing for an escaped occurrence', () => {
    expect(syncVariables('\\{{keine}}', [])).toEqual([])
  })

  it('counts several occurrences of the same key as one variable', () => {
    expect(syncVariables('{{a}} und {{a}}', []).map((entry) => entry.key)).toEqual(['a'])
  })
})

describe('Order by hand', () => {
  const drei = [variable('a'), variable('b'), variable('c')]

  it('moves up and down', () => {
    expect(moveVariable(drei, 'c', -1).map((entry) => entry.key)).toEqual(['a', 'c', 'b'])
    expect(moveVariable(drei, 'a', 1).map((entry) => entry.key)).toEqual(['b', 'a', 'c'])
  })

  it('does not run over at the edges', () => {
    expect(moveVariable(drei, 'a', -1)).toBe(drei)
    expect(moveVariable(drei, 'c', 1)).toBe(drei)
    expect(moveVariable(drei, 'gibtesnicht', 1)).toBe(drei)
  })
})

describe('What goes to the server', () => {
  // Without the position sent along, every variable would fall back to the
  // order of the text — the service takes the entry as the decision of the
  // author and numbers from 0..n-1 (FA-302).
  it('records the order as position', () => {
    const draft = { ...emptyDraft(), body: '{{a}} {{b}}', variables: [variable('b'), variable('a')] }

    expect(payloadOf(draft).variables.map((entry) => [entry.key, entry.position]))
      .toEqual([['b', 0], ['a', 1]])
  })

  // Options on a text field would be a promise no form redeems — the same rule
  // TF-449 checks on the example package.
  it('sends options only for a select', () => {
    const draft = {
      ...emptyDraft(),
      variables: [
        variable('wahl', { type: 'select', options: ['Eins', 'Zwei'] }),
        variable('frei', { type: 'text', options: ['Rest einer frueheren Wahl'] })
      ]
    }
    const sent = payloadOf(draft).variables

    expect(sent[0].options).toEqual(['Eins', 'Zwei'])
    expect(sent[1].options).toEqual([])
  })

  it('trims whitespace off the title', () => {
    expect(payloadOf({ ...emptyDraft(), title: '  Titel  ' }).title).toBe('Titel')
  })
})

describe('Unsaved changes', () => {
  const original = () => ({ ...emptyDraft({ title: 'T' }), body: '{{a}}', variables: [variable('a')] })

  it('reports nothing as long as nothing was touched', () => {
    expect(changed(original(), original())).toBe(false)
  })

  it('notices a changed detail on a variable', () => {
    const draft = original()
    draft.variables = [variable('a', { required: true })]

    expect(changed(draft, original())).toBe(true)
  })

  it('notices a rearranged order', () => {
    const zwei = { ...emptyDraft(), body: '{{a}} {{b}}', variables: [variable('a'), variable('b')] }
    const gedreht = { ...zwei, variables: [variable('b'), variable('a')] }

    expect(changed(gedreht, zwei)).toBe(true)
  })

  // The counter-check to the basis of comparison: what is compared is what a
  // save would send. Whatever the payload does not see is by definition not a
  // change — otherwise the editor would ask on leaving about a difference
  // nobody meant to make.
  it('does not take whitespace on the title for a change', () => {
    expect(changed({ ...original(), title: 'T  ' }, original())).toBe(false)
  })
})

describe('Preview in the editor', () => {
  it('puts the default values in as values (11.5)', () => {
    const draft = { ...emptyDraft(), variables: [variable('a', { default_value: 'Einsteiger' })] }

    expect(withDefaults(draft)[0].value).toBe('Einsteiger')
  })
})

describe('Tags', () => {
  it('takes a new one, trimmed', () => {
    expect(addTag([], '  seo  ')).toEqual(['seo'])
  })

  it('takes nothing empty and nothing duplicated', () => {
    expect(addTag(['seo'], 'seo')).toEqual(['seo'])
    expect(addTag(['seo'], '   ')).toEqual(['seo'])
    expect(addTag(['seo'], null)).toEqual(['seo'])
  })
})
