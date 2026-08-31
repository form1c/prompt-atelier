import { reactive, computed } from 'vue'

// The selection behind the bulk actions (FA-510).
//
// **It is deliberately not kept in the address bar**, unlike the filters. A
// filter describes what one is looking at and is worth sharing; a selection is
// a half-finished action. Restored from a bookmark a week later it would name
// prompts that have since been renamed, moved or deleted, and the first bulk
// action would work on a set nobody assembled.
//
// **And it is dropped whenever the list changes underneath it** — search,
// filter, sort, workspace. That is the rule of FA-510 and the reason this
// module exists rather than a bare `ref(new Set())` in each screen: a
// selection that survives a filter change holds prompts nobody can see any
// more. The bulk action would then reach things the person has no way of
// checking, and the report afterwards would name titles that are not on the
// screen.
export function createSelection () {
  const state = reactive({ ids: new Set(), everything: false })

  // `everything` is the second, explicit control of FA-510: not "the rows I
  // can see" but "all N hits". Kept apart from the id set because the two
  // answer different questions, and merging them is how "select all" comes to
  // mean whichever of the two the reader assumed.
  const count = computed(() => state.ids.size)
  const empty = computed(() => state.ids.size === 0)

  function has (id) {
    return state.ids.has(id)
  }

  function toggle (id) {
    // A new Set rather than mutation: Vue's reactivity tracks Set operations,
    // but a template that reads `has(id)` inside `v-for` only re-renders when
    // the reference it depends on changes. Found by watching a checkbox stay
    // unticked after a click that had really registered.
    const next = new Set(state.ids)
    next.has(id) ? next.delete(id) : next.add(id)
    state.ids = next
    state.everything = false
  }

  // Everything currently on screen. The library has no pages — it shows the
  // first hits and loads more on request — so this grows as the list does, and
  // the label has to say the number rather than the word "page".
  function selectVisible (ids) {
    state.ids = new Set(ids)
    state.everything = false
  }

  function clear () {
    state.ids = new Set()
    state.everything = false
  }

  // The whole result list, beyond what has been loaded. The caller supplies
  // the ids, because only it knows how to ask the server for them.
  function selectEverything (ids) {
    state.ids = new Set(ids)
    state.everything = true
  }

  return { state, count, empty, has, toggle, selectVisible, selectEverything, clear }
}

// Whether every visible row is selected — the state the header checkbox shows.
// False for an empty list, because a checkbox that is ticked over nothing
// invites a bulk action on nothing.
export function allSelected (selection, ids) {
  return ids.length > 0 && ids.every((id) => selection.has(id))
}
