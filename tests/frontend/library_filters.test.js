import { describe, it, expect } from 'vitest'
import {
  filtersFromQuery, queryFromFilters, isFiltered, withoutFilters, toggleTag, SORTS
} from '../../frontend/src/util/filters.js'
import { queryFor } from '../../frontend/src/state/library.js'

// FA-506 — the filter state lives in the address bar.
//
// It is worth its own suite because it is the one piece of the library that
// has to survive leaving the screen: a bookmark, a link in a chat, the back
// button. Everything else can be rebuilt from the server; this cannot.

describe('Filters from the address', () => {
  it('reads every filter out of the parameters', () => {
    const filters = filtersFromQuery({
      workspace: '9', search: 'blog', tags: '3,7', favorites: '1',
      archived: '1', sort: 'title'
    })

    expect(filters).toEqual({
      workspace: '9', search: 'blog', tags: [3, 7],
      favorites: true, archived: true, sort: 'title'
    })
  })

  it('falls back to the remembered workspace when none is given', () => {
    expect(filtersFromQuery({}, 7).workspace).toBe(7)
    expect(filtersFromQuery({ workspace: 'all' }, 7).workspace).toBe('all')
  })

  // The server has an allow-list of its own (TF-510c). This one exists so the
  // screen never offers a sort it cannot show — a select with a value nobody
  // knows renders as empty and looks broken.
  it('discards an unknown sort order', () => {
    expect(filtersFromQuery({ sort: 'irgendwas' }).sort).toBeNull()
    expect(filtersFromQuery({ sort: 'title' }).sort).toBe('title')
    expect(SORTS.map((entry) => entry.value)).toEqual(['relevance', 'changed', 'title'])
  })

  it('skips unusable tag entries instead of passing them on', () => {
    expect(filtersFromQuery({ tags: '3, ,x,-1,7' }).tags).toEqual([3, 7])
    expect(filtersFromQuery({}).tags).toEqual([])
  })

  // A parameter can arrive twice. vue-router hands that over as an array, and
  // an array reaching the server would be a filter nobody asked for.
  it('takes one value when a parameter is given twice', () => {
    expect(filtersFromQuery({ search: ['a', 'b'] }).search).toBe('b')
  })

  it('writes back only what is set', () => {
    const bare = queryFromFilters(filtersFromQuery({}, 9))

    expect(bare).toEqual({ workspace: '9' })
    expect(queryFromFilters(filtersFromQuery({ workspace: '9', search: 'blog', tags: '3,7' })))
      .toEqual({ workspace: '9', search: 'blog', tags: '3,7' })
  })

  // Round trip: what is written must read back the same, or a shared link
  // would mean something else than the screen it was copied from.
  it('reads back what it wrote', () => {
    const filters = filtersFromQuery({
      workspace: 'all', search: 'größe', tags: '3,7', favorites: '1', sort: 'changed'
    })

    expect(filtersFromQuery(queryFromFilters(filters))).toEqual(filters)
  })

  it('tells filtered from empty', () => {
    const plain = filtersFromQuery({ workspace: '9' })

    expect(isFiltered(plain)).toBe(false)
    expect(isFiltered({ ...plain, search: 'blog' })).toBe(true)
    expect(isFiltered({ ...plain, tags: [3] })).toBe(true)
    expect(isFiltered({ ...plain, favorites: true })).toBe(true)
    expect(isFiltered({ ...plain, archived: true })).toBe(true)
  })

  it('does not take the workspace along when resetting', () => {
    const filters = filtersFromQuery({ workspace: '9', search: 'blog', favorites: '1' })

    expect(withoutFilters(filters)).toMatchObject({ workspace: '9', search: '', favorites: false })
  })

  it('switches a tag on and off again', () => {
    const filters = filtersFromQuery({ workspace: '9' })

    expect(toggleTag(filters, 3).tags).toEqual([3])
    expect(toggleTag(toggleTag(filters, 3), 3).tags).toEqual([])
    expect(toggleTag(toggleTag(filters, 3), 7).tags).toEqual([3, 7])
  })
})

describe('The query to the server', () => {
  it('translates the filters into the language of the interface', () => {
    const query = queryFor(filtersFromQuery({
      workspace: '9', search: 'blog', tags: '3,7', favorites: '1', archived: '1', sort: 'title'
    }))

    expect(query).toEqual({
      workspace_id: '9', q: 'blog', tags: [3, 7],
      favorites_only: 'true', status: 'archived', sort: 'title'
    })
  })

  // What is *not* sent matters as much: 11.3 says archived prompts appear
  // only when asked for, and the server leaves them out unless a status
  // arrives. Sending an empty one would show them all the time.
  it('leaves out what is not being filtered', () => {
    const query = queryFor(filtersFromQuery({ workspace: '9' }))

    expect(query).toEqual({
      workspace_id: '9', q: null, tags: null,
      favorites_only: null, status: null, sort: null
    })
  })
})
