import { describe, it, expect, afterEach } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { mount } from '@vue/test-utils'
import Icon from '../../frontend/src/components/Icon.vue'
import { SHAPES, NAMES } from '../../frontend/src/components/icons.js'

// TF-444 — the icon registry and the templates, held together.
//
// An icon that draws nothing draws *nothing*: no error, no gap, no sign that
// anything is wrong. A button ends up with a label and an empty space in front
// of it and looks merely a little odd. That is the kind of mistake nobody
// reports and nobody finds, so it is checked here.
//
// Both directions, for the same reason as with the interface texts (TF-713): a
// name nobody defined is an invisible hole, a shape nobody draws is weight in
// the bundle for nothing.

// path.resolve rather than `new URL(..., import.meta.url)`, which Vite
// rewrites into an asset reference during transformation.
const HERE = path.dirname(fileURLToPath(import.meta.url))
const SOURCE = path.resolve(HERE, '..', '..', 'frontend', 'src')

function templateFiles (directory = SOURCE, collected = []) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name)
    if (entry.isDirectory()) templateFiles(full, collected)
    else if (entry.name.endsWith('.vue')) collected.push(full)
  }
  return collected
}

// Both spellings occur: a fixed name as an attribute, and a bound one that
// chooses between two — the star that is filled once it is a favourite. The
// second is read as the literals inside it, which is as far as reading source
// text can go and covers every case in this code base.
function iconNamesIn (source) {
  const names = new Set()

  for (const [tag] of source.matchAll(/<Icon\b[^>]*>/g)) {
    const fixed = tag.match(/(?<![:\w-])name="([^"]+)"/)
    if (fixed) {
      names.add(fixed[1])
      continue
    }

    const bound = tag.match(/:name="([^"]+)"/)
    if (bound) {
      for (const [, literal] of bound[1].matchAll(/'([^']+)'/g)) names.add(literal)
    }
  }

  return names
}

function usedNames () {
  const used = new Set()

  for (const file of templateFiles()) {
    iconNamesIn(readFileSync(file, 'utf8')).forEach((name) => used.add(name))
  }
  return used
}

describe('Icon coverage', () => {
  it('knows every name a template asks for', () => {
    const unknown = [...usedNames()].filter((name) => !NAMES.includes(name))

    expect(unknown).toEqual([])
  })

  it('draws every shape the table carries', () => {
    const used = usedNames()

    expect(NAMES.filter((name) => !used.has(name))).toEqual([])
  })

  // The counter-check: without it, a search pattern that finds nothing at all
  // would report a clean state for an interface full of wrong names.
  it('finds the names at all', () => {
    const used = usedNames()

    expect(used.size).toBeGreaterThan(10)
    expect(used).toContain('clipboard')
    expect(used).toContain('star-fill')
  })

  it('spots an invented name', () => {
    expect(iconNamesIn('<Icon name="gibt-es-nicht" />')).toContain('gibt-es-nicht')
    expect(iconNamesIn('<Icon :name="an ? \'star\' : \'star-fill\'" />')).toContain('star-fill')
  })
})

describe('Icon shapes', () => {
  it('all have at least one path with drawing data', () => {
    for (const name of NAMES) {
      expect(SHAPES[name].length, name).toBeGreaterThan(0)

      for (const part of SHAPES[name]) {
        expect(part.d, name).toMatch(/^[Mm]/)
        expect(part.rule ?? 'evenodd', name).toBe('evenodd')
      }
    }
  })
})

describe('A drawn icon', () => {
  const mounted = []

  afterEach(() => {
    while (mounted.length) mounted.pop().unmount()
  })

  function draw (name) {
    const wrapper = mount(Icon, { props: { name } })
    mounted.push(wrapper)
    return wrapper
  }

  // Requirements 11.6: an icon is decoration. It must not turn up in the
  // reading order beside the word it illustrates, which would have a screen
  // reader announce everything twice.
  it('stays out of the reading order', () => {
    const svg = draw('clipboard').find('svg')

    expect(svg.attributes('aria-hidden')).toBe('true')
    expect(svg.attributes('focusable')).toBe('false')
  })

  it('draws every path of its shape', () => {
    expect(draw('clipboard').findAll('path')).toHaveLength(SHAPES.clipboard.length)
    expect(draw('search').findAll('path')).toHaveLength(1)
  })

  // The fill rule belongs to the shape: without it the ring of the account
  // symbol becomes a full disc, and the arrow in the menu a blob.
  it('takes over the fill rule where the shape needs it', () => {
    const paths = draw('person-circle').findAll('path')

    expect(paths[0].attributes('fill-rule')).toBeUndefined()
    expect(paths[1].attributes('fill-rule')).toBe('evenodd')
  })
})
