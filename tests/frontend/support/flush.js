import { flushPromises } from '@vue/test-utils'

// flushPromises drains the microtask queue, which covers everything the
// interface does except a route change: the router loads the target screen
// with a dynamic import, and that resolves a macrotask later.
//
// Without the extra turn a test would assert on the screen it came from, or
// the navigation would finish after the environment was torn down and report
// as an unhandled rejection in whichever file happened to run next.
export async function settle () {
  await flushPromises()
  await new Promise((resolve) => setTimeout(resolve, 0))
  await flushPromises()
}
