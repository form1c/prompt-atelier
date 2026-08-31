import { reactive, readonly } from 'vue'
import { get, post, del, ApiError } from '@/api/client'

// The prompt on display, and what is needed to fill it in (Requirements 11.4).
//
// Two sources: the prompt itself with its variables and its default
// keywords, and the keyword catalogue of the workspace the reader may switch
// on. Both are needed before the first preview can be rendered, so they are
// fetched together.

const state = reactive({
  prompt: null,
  keywords: [],
  loading: false,
  error: null
})

export const detail = readonly(state)

export async function loadPrompt (id) {
  state.loading = true
  state.error = null

  try {
    const payload = await get(`/prompts/${id}`)
    state.prompt = payload.prompt
    await loadKeywords(state.prompt)
  } catch (error) {
    if (!(error instanceof ApiError)) throw error

    state.error = error
    state.prompt = null
    state.keywords = []
  } finally {
    state.loading = false
  }
}

// The switchable keywords come from the workspace of the prompt — for a
// prompt of one's own that is one's own catalogue.
//
// For a foreign prompt from the view across all workspaces there is none to
// read (TF-426): its keywords belong to a workspace the reader is not in.
// What stays are the ones already attached to the prompt, which the server
// allows to be rendered because they are part of it. They are shown, they
// work, and nothing further can be switched on.
async function loadKeywords (prompt) {
  if (!prompt) return

  try {
    const payload = await get('/keywords', { params: { workspace_id: prompt.workspace_id } })
    state.keywords = payload.keywords ?? []
  } catch (error) {
    if (!(error instanceof ApiError)) throw error

    state.keywords = []
  }
}

export async function toggleFavorite (prompt) {
  const wanted = !prompt.favorite
  if (wanted) await post(`/prompts/${prompt.id}/favorite`)
  else await del(`/prompts/${prompt.id}/favorite`)

  if (state.prompt?.id === prompt.id) state.prompt = { ...state.prompt, favorite: wanted }
  return wanted
}

export function forgetPrompt () {
  state.prompt = null
  state.keywords = []
  state.loading = false
  state.error = null
}

// --- what the reader typed (FA-306) -----------------------------------------

// Kept in the browser, per prompt. The requirement says so outright, and the
// reason is that these are drafts, not data: half-filled values of one person
// on one device, worth nothing to anyone else and not worth a round trip.
//
// A failure here is silently ignored. Private browsing, a full quota or a
// storage setting are all normal, and none of them is a reason to interrupt
// somebody who only wants to copy a prompt.
const STORAGE_PREFIX = 'promptatelier.values.'

export function rememberValues (promptId, values, storage = safeStorage()) {
  if (!storage) return

  try {
    storage.setItem(STORAGE_PREFIX + promptId, JSON.stringify(values))
  } catch {
    // see above
  }
}

export function recallValues (promptId, storage = safeStorage()) {
  if (!storage) return {}

  try {
    const stored = storage.getItem(STORAGE_PREFIX + promptId)
    const parsed = stored ? JSON.parse(stored) : {}
    // A stored value has to be an object of strings. Anything else is a
    // leftover of an older version or somebody's experiment, and prefilling a
    // form from it would produce fields nobody can explain.
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {}
  } catch {
    return {}
  }
}

export function forgetValues (promptId, storage = safeStorage()) {
  if (!storage) return

  try {
    storage.removeItem(STORAGE_PREFIX + promptId)
  } catch {
    // see above
  }
}

function safeStorage () {
  try {
    return globalThis.localStorage ?? null
  } catch {
    // Reading the property itself throws in a browser that has storage
    // switched off for this site.
    return null
  }
}

// --- the workbench under the prompt (FA-307) --------------------------------

// The same reasoning as for the values above, and the same failure handling:
// this is a draft of one person on one device. What differs is only what it
// holds — a whole text rather than a mapping.
const WORKBENCH_PREFIX = 'promptatelier.workbench.'

export function rememberWorkbench (promptId, text, storage = safeStorage()) {
  if (!storage) return

  try {
    storage.setItem(WORKBENCH_PREFIX + promptId, String(text))
  } catch {
    // see rememberValues
  }
}

export function recallWorkbench (promptId, storage = safeStorage()) {
  if (!storage) return null

  try {
    const stored = storage.getItem(WORKBENCH_PREFIX + promptId)
    return typeof stored === 'string' ? stored : null
  } catch {
    return null
  }
}

export function forgetWorkbench (promptId, storage = safeStorage()) {
  if (!storage) return

  try {
    storage.removeItem(WORKBENCH_PREFIX + promptId)
  } catch {
    // see rememberValues
  }
}
