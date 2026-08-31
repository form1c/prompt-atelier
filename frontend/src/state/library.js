import { reactive, readonly } from 'vue'
import { get, post, del, ApiError } from '@/api/client'

// What the library screen shows (Requirements 11.3, FA-501 to FA-509).
//
// The filters themselves are not kept here. They live in the address bar,
// because FA-506 asks for a state that can be bookmarked and shared, and two
// copies of the same truth would drift apart the moment someone uses the back
// button. This module holds only what came back from the server.

const state = reactive({
  prompts: [],
  total: 0,
  page: 1,
  tags: [],
  loading: false,
  error: null
})

// The server caps a page at 200 (15.1); fifty is what a screen can carry
// without the first hit scrolling out of sight.
export const PER_PAGE = 50

export const library = readonly(state)

// Requests overtake each other. Typing "blog" fires four searches, and the
// answer to "blo" can arrive after the answer to "blog" — without a sequence
// number the list would end up showing the older result, and only sometimes,
// which is the kind of defect that gets reported as "the search is flaky".
let latest = 0

export async function loadPrompts (filters, { page = 1 } = {}) {
  const mine = ++latest
  state.loading = true
  state.error = null

  try {
    const payload = await get('/prompts', {
      params: { ...queryFor(filters), page: page, per_page: PER_PAGE }
    })
    if (mine !== latest) return

    const rows = payload.prompts ?? []
    // Page one replaces, every further page appends. Replacing would make the
    // button read "load more" and then show less.
    state.prompts = page === 1 ? rows : [...state.prompts, ...rows]
    state.page = page
    state.total = payload.meta?.total ?? state.prompts.length
  } catch (error) {
    if (mine !== latest) return
    if (!(error instanceof ApiError)) throw error

    state.error = error
    state.prompts = []
    state.total = 0
  } finally {
    if (mine === latest) state.loading = false
  }
}

// The rest of the list. Without it everything past the first fifty would be
// unreachable — the count on the screen would name prompts that no click can
// get to (FA-506, NFA-08).
export function loadMorePrompts (filters) {
  return loadPrompts(filters, { page: state.page + 1 })
}

export function hasMore () {
  return state.prompts.length < state.total
}

// The tags of one workspace with their counts, for the sidebar (11.3).
//
// Not available in the view across all workspaces: tags belong to a
// workspace, and a list mixing several would offer filters that cannot be
// applied. The same reason the management entries disappear there (11.2).
export async function loadTags (workspaceId) {
  if (workspaceId === ALL_WORKSPACES) {
    state.tags = []
    return
  }

  try {
    const payload = await get('/tags', { params: { workspace_id: workspaceId } })
    state.tags = payload.tags ?? []
  } catch (error) {
    if (!(error instanceof ApiError)) throw error

    // A missing tag list costs a filter, not the screen. The list itself is
    // already on display by then.
    state.tags = []
  }
}

// FA-505. The row is updated from the answer rather than guessed at, so a
// refused call leaves the star where it was instead of where it was clicked.
export async function toggleFavorite (prompt) {
  const path = `/prompts/${prompt.id}/favorite`
  const wanted = !prompt.favorite

  if (wanted) await post(path)
  else await del(path)

  const row = state.prompts.find((entry) => entry.id === prompt.id)
  if (row) row.favorite = wanted
  return wanted
}

export const ALL_WORKSPACES = 'all'

export function queryFor (filters) {
  return {
    workspace_id: filters.workspace,
    q: filters.search || null,
    tags: filters.tags?.length ? filters.tags : null,
    favorites_only: filters.favorites ? 'true' : null,
    // 11.3: archived prompts appear only when they are asked for. Without
    // this the server leaves them out.
    status: filters.archived ? 'archived' : null,
    sort: filters.sort || null
  }
}

// --- bulk actions (FA-511) ---------------------------------------------
//
// **One call, not a loop.** SEC-19 allows 120 writing calls per minute and
// session; fifty prompts moved one at a time would be fine and five hundred
// would stop halfway with no report saying where. The split into "done" and
// "refused with a reason" is made by the server, where the permission check
// already happens — assembling it here would be a second, differing reading of
// chapter 6.2.

export function bulkMove (promptIds, workspaceId) {
  return post('/prompts/bulk/move', { body: { prompt_ids: promptIds, workspace_id: workspaceId } })
}

export function bulkTrash (promptIds) {
  return post('/prompts/bulk/trash', { body: { prompt_ids: promptIds } })
}

export function bulkRestore (promptIds) {
  return post('/trash/bulk/restore', { body: { prompt_ids: promptIds } })
}

export function bulkPurge (promptIds) {
  return post('/trash/bulk/purge', { body: { prompt_ids: promptIds } })
}

// The ids of a whole result list, for the second control of FA-510. Its own
// endpoint, because a page is capped at 200 (15.1) and raising that would mean
// fetching seventeen hundred full prompt rows to arrive at seventeen hundred
// integers. Returns the ids and the limit the server is willing to act on, so
// the interface can say "too many" instead of offering a button that would be
// refused.
export async function allMatchingIds (filters) {
  const payload = await get('/prompts/ids', { params: queryFor(filters) })
  return { ids: payload.ids, limit: payload.limit }
}

// For tests and for a screen that is being left: the next mount starts from
// an empty list rather than from the previous workspace's.
export function forgetLibrary () {
  state.prompts = []
  state.total = 0
  state.page = 1
  state.tags = []
  state.loading = false
  state.error = null
}
