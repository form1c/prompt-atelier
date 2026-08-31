import { reactive, readonly } from 'vue'

// Short confirmations after a successful action (Requirements 11.6): two
// seconds, and they must not interrupt the flow — no dialogue, no focus
// change, nothing to click away.
//
// Failures do not come through here. A message that disappears on its own is
// the wrong place for something the user has to act on; those belong on the
// screen that caused them.

export const NOTICE_MILLISECONDS = 2000

let nextId = 1
const list = reactive([])

export const notices = readonly(list)

export function notify (message, { milliseconds = NOTICE_MILLISECONDS } = {}) {
  const id = nextId++
  list.push({ id, message })

  const timer = setTimeout(() => dismiss(id), milliseconds)
  // Node keeps the process alive for a pending timer; the browser does not
  // care. Without this a test run would hang for two seconds per notice.
  timer?.unref?.()

  return id
}

export function dismiss (id) {
  const index = list.findIndex((notice) => notice.id === id)
  if (index >= 0) list.splice(index, 1)
}

export function clearNotices () {
  list.splice(0, list.length)
}
