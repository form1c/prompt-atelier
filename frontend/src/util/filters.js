// The filter state of the library, as it stands in the address bar (FA-506).
//
// The address is the one place this state lives. A copy in a component would
// mean two truths that part company the first time someone uses the back
// button or opens a link somebody sent them — and being able to send that
// link is the point of the requirement.
//
// The parameter names are English, like every identifier here. The **values**
// are not: `sort=changed` carries a domain term the database and the API
// both speak (14.1), and translating it would be a schema change rather than
// a rename.

export const SORTS = [
  { value: 'relevance', label: 'library.sort.relevance', needsSearch: true },
  { value: 'changed', label: 'library.sort.changed' },
  { value: 'title', label: 'library.sort.title' }
]

const SORT_VALUES = SORTS.map((entry) => entry.value)

export function filtersFromQuery (query = {}, fallbackWorkspace = null) {
  return {
    workspace: single(query.workspace) ?? fallbackWorkspace,
    search: single(query.search) ?? '',
    tags: identifiers(query.tags),
    favorites: single(query.favorites) === '1',
    archived: single(query.archived) === '1',
    // An unknown value is dropped rather than passed on: the server has an
    // allow-list of its own (TF-510c), and a filter the screen cannot show is
    // worse than none.
    sort: SORT_VALUES.includes(single(query.sort)) ? single(query.sort) : null
  }
}

// Everything that is not at its default. A short address is not vanity: it is
// what makes a shared link readable, and what keeps the parameters that are
// set from disappearing among a dozen that are not.
export function queryFromFilters (filters) {
  const query = { workspace: String(filters.workspace) }

  if (filters.search) query.search = filters.search
  if (filters.tags?.length) query.tags = filters.tags.join(',')
  if (filters.favorites) query.favorites = '1'
  if (filters.archived) query.archived = '1'
  if (filters.sort) query.sort = filters.sort

  return query
}

// Whether anything is filtering at all — the difference between "nothing
// matches" and "there is nothing here", which are two different empty states
// with two different ways out (11.6).
export function isFiltered (filters) {
  return Boolean(filters.search) || filters.tags.length > 0 ||
    filters.favorites || filters.archived
}

export function withoutFilters (filters) {
  return { ...filters, search: '', tags: [], favorites: false, archived: false }
}

export function toggleTag (filters, tagId) {
  const id = Number(tagId)
  const tags = filters.tags.includes(id)
    ? filters.tags.filter((entry) => entry !== id)
    : [...filters.tags, id]

  return { ...filters, tags }
}

// A query parameter can arrive more than once ("?search=a&search=b"), and
// vue-router hands that over as an array. Taking the last one is arbitrary but
// defined; letting an array through would reach the server as a filter nobody
// asked for.
function single (value) {
  if (Array.isArray(value)) return value[value.length - 1] ?? undefined

  return value ?? undefined
}

function identifiers (value) {
  return String(single(value) ?? '')
    .split(',')
    .map((entry) => Number(entry.trim()))
    .filter((entry) => Number.isInteger(entry) && entry > 0)
}
