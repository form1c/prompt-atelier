import { reactive, readonly } from 'vue'
import { ApiError } from '@/api/client'

// The overlay that appears when a session has expired mid-work (FA-103,
// TF-415), expressed as a promise: the API client waits for it, and what the
// user does decides whether the interrupted request is repeated or dropped.
//
// The promise lives here rather than in the component so that the component
// can be unmounted and remounted without losing the caller that is waiting.

const state = reactive({ open: false })

export const reauthentication = readonly(state)

let settle = null

// Called by the client on a 401. Resolves once the user has signed in again.
export function requestSignIn () {
  state.open = true

  // A second expired call while the overlay is already up joins the first
  // one instead of replacing it — otherwise the earlier caller would wait
  // for a promise nobody settles any more.
  if (settle) return settle.promise

  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  settle = { promise, resolve, reject }
  return promise
}

export function completeSignIn () {
  state.open = false
  const pending = settle
  settle = null
  pending?.resolve()
}

// The user chooses to sign out instead. The waiting request must not hang, so
// it fails the way it originally did — with the 401 that started all this.
export function abandonSignIn () {
  state.open = false
  const pending = settle
  settle = null
  pending?.reject(new ApiError({ status: 401, code: 'unauthorized' }))
}
