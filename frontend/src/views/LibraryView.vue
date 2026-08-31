<script setup>
import { computed, nextTick, onMounted, onUnmounted, watch, ref, useTemplateRef } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { t } from '@/i18n'
import { session, selectWorkspace } from '@/state/session'
import {
  library, loadPrompts, loadMorePrompts, hasMore, loadTags, toggleFavorite, ALL_WORKSPACES,
  bulkMove, bulkTrash, allMatchingIds
} from '@/state/library'
import { notify } from '@/state/notices'
import { createSelection, allSelected } from '@/util/selection'
import {
  SORTS, filtersFromQuery, queryFromFilters, isFiltered, withoutFilters, toggleTag
} from '@/util/filters'
import AppShell from '@/components/AppShell.vue'
import PromptList from '@/components/PromptList.vue'
import SelectionBar from '@/components/SelectionBar.vue'
import ConfirmDialog from '@/components/ConfirmDialog.vue'
import TagFilter from '@/components/TagFilter.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import ErrorState from '@/components/ErrorState.vue'
import Icon from '@/components/Icon.vue'

// S1 — the library, and the screen this application starts on (E-07).
//
// The filter state lives in the address bar and nowhere else. Everything here
// reads from there and writes back to there; the list follows. That is what
// makes a filtered view shareable (FA-506), and it is why there is no local
// copy that could disagree with the address.

// Long enough that a request is not fired per keystroke, short enough that
// the list feels attached to the keyboard. The same figure as the preview in
// 11.6.
const TYPING_PAUSE = 150

const route = useRoute()
const router = useRouter()

const searchField = useTemplateRef('searchField')
const list = useTemplateRef('list')
const typed = ref('')

const filters = computed(() => filtersFromQuery(route.query, session.selectedWorkspaceId))
const acrossWorkspaces = computed(() => String(filters.value.workspace) === ALL_WORKSPACES)
const filtering = computed(() => isFiltered(filters.value))

const countLabel = computed(() => (
  library.total === 1 ? t('library.count_one') : t('library.count_many', { count: library.total })
))

const remaining = computed(() => library.total - library.prompts.length)

// --- the selection (FA-510, FA-511) ---------------------------------------

// **The checkboxes are not there until they are asked for** (FA-510).
//
// W-1 is the most frequent thing anybody does here and the library is the
// screen the application starts on (E-07); a checkbox in front of every row
// taxes that path for the sake of occasional housekeeping. Worse, it invites
// the question "do I have to tick something first?" from exactly the people
// A-02b is about — somebody seeing the application for the first time.
//
// The mode survives a filter change, the **selection** does not: whoever turns
// it on in order to search and then select must not be thrown out by the
// searching. Leaving the mode drops the selection, because a selection nobody
// can see is a selection nobody can check.
const selecting = ref(false)
const selection = createSelection()
const bulkLimit = ref(null)
const moving = ref(false)
const trashing = ref(false)
const moveTarget = ref('')

const visibleIds = computed(() => library.prompts.map((prompt) => prompt.id))

// Where a selection may be moved to: the same rule as the single move (11.6)
// — the workspaces this person may create in. A target that would be refused
// has no business in the list.
const moveTargets = computed(() => session.workspaces.filter(
  (workspace) => workspace.permissions?.['prompt.create'] !== false &&
    workspace.id !== filters.value.workspace
))
const everyVisibleSelected = computed(() => allSelected(selection, visibleIds.value))
const tooManyToSelect = computed(() => bulkLimit.value !== null && library.total > bulkLimit.value)

// **Dropped whenever the list changes underneath it** (FA-510). A selection
// that survives a filter change holds prompts nobody can see any more, and the
// report afterwards would name titles that are not on the screen. Said out
// loud rather than done quietly: somebody who ticked twelve boxes and then
// narrowed the search has to learn that the twelve are gone.
watch(() => route.fullPath, () => {
  if (selection.empty.value) return

  selection.clear()
  notify(t('selection.dropped'))
})

function toggleSelecting () {
  selecting.value = !selecting.value
  if (!selecting.value) selection.clear()
}

function toggleVisible () {
  everyVisibleSelected.value ? selection.clear() : selection.selectVisible(visibleIds.value)
}

// The second, explicit control: not the rows on screen but the whole result
// list. The ids come from the server, because the rows beyond the first fifty
// have never been loaded.
async function selectEverything () {
  const { ids, limit } = await allMatchingIds(filters.value)
  bulkLimit.value = limit

  // **A truncated selection is the dangerous outcome, not the slow one.** The
  // server answers at most `limit` ids; taking them anyway would tick a box
  // saying "alle 6.000 Treffer" over five thousand of them, and the bulk
  // action would quietly leave a thousand behind. Refused instead, with the
  // number, so the answer is to narrow the search.
  if (library.total > limit) {
    notify(t('selection.too_many', { count: library.total }))
    return
  }

  selection.selectEverything(ids)
}

// --- the two actions (FA-511) ---------------------------------------------

// FA-207 holds per prompt: a workspace-visible prompt becomes private again.
// The warning is given **once**, before, and names how many are affected —
// fifty separate notices would be the same sentence fifty times.
async function moveSelection (workspaceId) {
  moving.value = false
  moveTarget.value = ''
  const report = await bulkMove([...selection.state.ids], workspaceId)
  notify(t('library.bulk_moved', { count: report.counts.done }))
  announceRefusals(report)
  selection.clear()
  refresh()
}

async function trashSelection () {
  trashing.value = false
  const report = await bulkTrash([...selection.state.ids])
  notify(t('library.bulk_trashed', { count: report.counts.done }))
  announceRefusals(report)
  selection.clear()
  refresh()
}

// What was **not** done. Named with their titles — "2 abgelehnt" is a figure,
// two titles are an answer (FA-511). Entries the caller may not see carry no
// title and are counted instead, because naming them would be the disclosure
// the uniform refusal exists to prevent.
//
// The success sentence stays with the caller rather than being looked up here
// by a key. The check behind TF-713 reads the sources for the literal shape
// `t('…')`, and a key handed in as an argument is a text it reports as unused
// — the same reason TransferView writes its labels out.
function announceRefusals (report) {
  if (report.counts.refused === 0) return

  const named = report.refused.filter((entry) => entry.title).map((entry) => entry.title)
  const unnamed = report.counts.refused - named.length

  notify(named.length
    ? t('library.bulk_refused', { names: named.join(', '), count: report.counts.refused })
    : t('library.bulk_refused_unnamed', { count: unnamed }))
}

// The offers of an empty state need a screen to lead to (TF-420, W-6). The
// editor is AP-12 and the import AP-14; until they exist the offers stay away
// rather than becoming buttons that do nothing. The same rule as in the
// navigation, and it means those packages have nothing left to do here.
const canCreate = computed(() => router.hasRoute('prompt-new'))
const canImport = computed(() => router.hasRoute('transfer'))

const selectedTags = computed(() => (
  library.tags.filter((tag) => filters.value.tags.includes(tag.id))
))

// Relevance only means something with a search term (FA-507).
const sorts = computed(() => SORTS.filter((entry) => !entry.needsSearch || filters.value.search))

let typingTimer = null
// The load that is currently running. Pressing Enter has to wait for it, or
// it would move the focus into the list that is about to be replaced.
let running = Promise.resolve()

onMounted(async () => {
  typed.value = filters.value.search
  // 11.3: the focus starts in the search field. Someone who opens the library
  // is looking for something; anything else costs a click first.
  searchField.value?.focus()
  window.addEventListener('keydown', onShortcut)
  await refresh()
})

onUnmounted(() => {
  clearTimeout(typingTimer)
  window.removeEventListener('keydown', onShortcut)
})

// The address is the state, so this is the only place that reacts to it —
// whether it changed through a control here, the back button or a pasted link.
watch(() => route.fullPath, async () => {
  if (typed.value !== filters.value.search) typed.value = filters.value.search
  await refresh()
})

// The workspace can also be changed in the header, which knows nothing about
// filters. Following it here keeps the two in step.
watch(() => session.selectedWorkspaceId, (id) => {
  if (id && !route.query.workspace) apply({ ...filters.value, workspace: id })
})

function refresh () {
  if (!filters.value.workspace) return Promise.resolve()

  running = Promise.all([
    loadPrompts(filters.value),
    loadTags(filters.value.workspace)
  ])
  return running
}

// `replace`, not `push`. Otherwise every keystroke would leave an entry, and
// the back button would walk letter by letter out of a search instead of
// leaving the screen.
function apply (next) {
  return router.replace({ name: 'library', query: queryFromFilters(next) })
}

function onTyping () {
  clearTimeout(typingTimer)
  typingTimer = setTimeout(() => apply({ ...filters.value, search: typed.value }), TYPING_PAUSE)
}

function chooseSort (event) {
  apply({ ...filters.value, sort: event.target.value || null })
}

async function chooseWorkspace (value) {
  // The screen follows first. Tags belong to a workspace, so a selection made
  // in one is meaningless in the next — carried over it would filter by an
  // identifier the new workspace does not know and show an empty list for no
  // visible reason.
  apply({ ...filters.value, workspace: value, tags: [] })

  if (value === ALL_WORKSPACES) return

  try {
    await selectWorkspace(Number(value))
  } catch {
    // Remembering the choice for the next sign-in is a convenience (FA-605);
    // the switch itself has already happened. If something is genuinely
    // wrong, the list request that follows says so — an error box about the
    // memory while the screen shows the right workspace would explain
    // nothing.
  }
}

function open (prompt) {
  // The detail screen arrives with AP-11. Until then the line is reachable and
  // selectable but leads nowhere — better than a link into a void.
  if (router.hasRoute('prompt')) router.push({ name: 'prompt', params: { id: prompt.id } })
}

async function star (prompt) {
  await toggleFavorite(prompt)
  // Under "favourites only" the row that just lost its star has to leave the
  // list — otherwise the filter says one thing and the list another.
  if (filters.value.favorites) await loadPrompts(filters.value)
}

// 11.6: single-key shortcuts only outside input fields, or they would type
// their own character. `/` puts the cursor in the search field, Escape is the
// way out of it — which the library needs, because that is where the focus
// starts.
function onShortcut (event) {
  const inField = ['INPUT', 'TEXTAREA', 'SELECT'].includes(event.target?.tagName)

  if (event.key === '/' && !inField && !event.ctrlKey && !event.metaKey) {
    event.preventDefault()
    searchField.value?.focus()
  }
}

function onSearchKey (event) {
  if (event.key === 'Escape') {
    typed.value = ''
    apply({ ...filters.value, search: '' })
    event.target.blur()
    return
  }

  // Enter and arrow down both lead from the field into the list. Enter is the
  // faster way: type, press it, and the first hit is where the focus is
  // (A-02, the workflow behind NFA-01).
  if (event.key === 'Enter' || event.key === 'ArrowDown') {
    event.preventDefault()
    enterList()
  }
}

// Typing and pressing Enter straight away is what people do, and the pause
// after the last keystroke is still running at that moment. Without this the
// focus would land on the first line of the *previous* result, and the list
// would be replaced underneath it a moment later — the focused row is gone,
// and the browser drops the focus onto the page body. Found in the browser;
// in jsdom the detached node stays focusable and everything looked fine.
async function enterList () {
  await flushTyping()
  list.value?.focusFirst()
}

async function flushTyping () {
  clearTimeout(typingTimer)
  if (typed.value === filters.value.search) return

  // Four steps, and each one has to be waited for. The navigation is a
  // promise of its own — without waiting for it the address has not changed
  // yet, the watch below has not run, and `running` is still the load that
  // fetched the list about to be replaced. That was the first attempt, and it
  // moved the focus onto a row that vanished a moment later.
  await apply({ ...filters.value, search: typed.value })
  await nextTick()
  await running
  await nextTick()
}
</script>

<template>
  <AppShell
    :workspace-value="String(filters.workspace ?? '')"
    :all-workspaces="true"
    @choose-workspace="chooseWorkspace"
  >
    <template #search>
      <label class="search">
        <span class="visually-hidden">{{ t('library.search_label') }}</span>
        <Icon name="search" class="search__icon" />
        <input
          ref="searchField"
          v-model="typed"
          type="search"
          :placeholder="t('library.search_placeholder')"
          @input="onTyping"
          @keydown="onSearchKey"
        >
      </label>
    </template>

    <template #sidebar>
      <TagFilter
        v-if="!acrossWorkspaces"
        :tags="library.tags"
        :selected="filters.tags"
        @toggle="(id) => apply(toggleTag(filters, id))"
      />
    </template>

    <h1 class="visually-hidden">{{ t('library.title') }}</h1>

    <div class="toolbar">
      <p class="toolbar__count" aria-live="polite">{{ countLabel }}</p>

      <button
        v-for="tag in selectedTags"
        :key="tag.id"
        type="button"
        class="button button--quiet toolbar__chip"
        :aria-label="t('library.remove_tag', { name: tag.name })"
        @click="apply(toggleTag(filters, tag.id))"
      >
        {{ tag.name }} <Icon name="x-lg" class="toolbar__chip-remove" />
      </button>

      <!-- `aria-pressed` was here from the start and told a screen reader
           which filters are on; nothing told the eye until base.css got the
           rule for it. -->
      <button
        type="button"
        class="button button--quiet"
        :aria-pressed="filters.favorites"
        @click="apply({ ...filters, favorites: !filters.favorites })"
      >
        <Icon :name="filters.favorites ? 'star-fill' : 'star'" /> {{ t('library.favorites_only') }}
      </button>

      <button
        type="button"
        class="button button--quiet"
        :aria-pressed="filters.archived"
        @click="apply({ ...filters, archived: !filters.archived })"
      >
        <Icon name="archive" /> {{ t('library.archived_only') }}
      </button>

      <button
        type="button"
        class="button button--quiet"
        :aria-pressed="selecting"
        data-test="selection-mode"
        @click="toggleSelecting"
      >
        <Icon name="check-lg" /> {{ t('selection.mode') }}
      </button>

      <label class="toolbar__sort">
        <span class="visually-hidden">{{ t('library.sort_label') }}</span>
        <select :value="filters.sort ?? ''" @change="chooseSort">
          <option v-for="entry in sorts" :key="entry.value" :value="entry.value">
            {{ t(entry.label) }}
          </option>
        </select>
      </label>
    </div>

    <ErrorState v-if="library.error" :error="library.error" :on-retry="refresh" />

    <LoadingState v-else-if="library.loading && library.prompts.length === 0" :rows="5" />

    <template v-else-if="library.prompts.length">
      <div v-if="selecting" class="toolbar toolbar--select">
        <label class="toolbar__select-all">
          <input
            type="checkbox"
            :checked="everyVisibleSelected"
            data-test="select-visible"
            @change="toggleVisible"
          >
          {{ t('selection.all_visible', { count: library.prompts.length }) }}
        </label>
      </div>

      <SelectionBar
        v-if="selecting && !selection.empty.value"
        :count="selection.count.value"
        :total="library.total"
        :too-many="tooManyToSelect"
        data-test="selection-bar"
        @clear="selection.clear()"
        @select-all="selectEverything"
      >
        <button
          v-if="moveTargets.length"
          type="button"
          class="button button--quiet"
          data-test="bulk-move"
          @click="moving = true"
        >
          <Icon name="folder-symlink" /> {{ t('library.bulk_move') }}
        </button>
        <button
          type="button"
          class="button button--quiet"
          data-test="bulk-trash"
          @click="trashing = true"
        >
          <Icon name="trash" /> {{ t('library.bulk_trash') }}
        </button>
      </SelectionBar>

      <PromptList
        ref="list"
        :prompts="library.prompts"
        :show-origin="acrossWorkspaces"
        :selectable="selecting"
        :is-selected="selection.has"
        @open="open"
        @favorite="star"
        @toggle-select="selection.toggle"
      />

      <!-- Without this the count in the heading would name prompts that no
           click can reach: the server answers a page at a time (15.1). -->
      <p v-if="remaining > 0" class="more">
        <button
          type="button"
          class="button button--quiet"
          :disabled="library.loading"
          @click="loadMorePrompts(filters)"
        >
          {{ t('library.load_more', { count: remaining }) }}
        </button>
      </p>
    </template>

    <!-- Two empty states, because there are two situations and they have
         different ways out (11.6). "Nothing matches" is answered by changing
         the filter; "there is nothing here" is answered by creating
         something. Offering the wrong one is worse than offering none. -->
    <EmptyState
      v-else-if="filtering && filters.search"
      :title="t('library.empty_search_title')"
      :description="t('library.empty_search_hint', { term: filters.search })"
    >
      <button type="button" class="button button--quiet" @click="apply(withoutFilters(filters))">
        {{ t('library.clear_filters') }}
      </button>
      <button
        v-if="canCreate"
        type="button"
        class="button"
        @click="router.push({ name: 'prompt-new', query: { title: filters.search } })"
      >
        {{ t('library.empty_search_create', { term: filters.search }) }}
      </button>
    </EmptyState>

    <EmptyState
      v-else-if="filtering"
      :title="t('library.empty_filter_title')"
      :description="t('library.empty_filter_hint')"
    >
      <button type="button" class="button button--quiet" @click="apply(withoutFilters(filters))">
        {{ t('library.clear_filters') }}
      </button>
    </EmptyState>

    <EmptyState
      v-else
      :title="t('library.empty_title')"
      :description="t('library.empty_hint')"
    >
      <button
        v-if="canCreate"
        type="button"
        class="button"
        @click="router.push({ name: 'prompt-new' })"
      >
        {{ t('library.empty_create') }}
      </button>
      <button
        v-if="canImport"
        type="button"
        class="button button--quiet"
        @click="router.push({ name: 'transfer' })"
      >
        {{ t('library.empty_examples') }}
      </button>
    </EmptyState>
    <!-- FA-511: the warning about FA-207 is given **once**, before, and names
         how many prompts it concerns. Fifty separate notices afterwards would
         be the same sentence fifty times, and by then it would be too late to
         be a warning at all. -->
    <ConfirmDialog
      v-if="moving"
      :title="t('library.bulk_move_title', { count: selection.count.value })"
      :description="t('library.bulk_move_hint')"
      :confirm-label="t('library.bulk_move_confirm')"
      :ready="moveTarget !== ''"
      @cancel="moving = false"
      @confirm="moveSelection(Number(moveTarget))"
    >
      <label class="field">
        <span>{{ t('library.bulk_move_target') }}</span>
        <select v-model="moveTarget" data-test="bulk-move-target">
          <option value="" disabled>{{ t('library.bulk_move_choose') }}</option>
          <option v-for="workspace in moveTargets" :key="workspace.id" :value="workspace.id">
            {{ workspace.name }}
          </option>
        </select>
      </label>
    </ConfirmDialog>

    <ConfirmDialog
      v-if="trashing"
      :title="t('library.bulk_trash_title', { count: selection.count.value })"
      :description="t('library.bulk_trash_hint')"
      :confirm-label="t('library.bulk_trash_confirm')"
      @cancel="trashing = false"
      @confirm="trashSelection"
    />
  </AppShell>
</template>

<style scoped>
/* The icon sits in the field rather than beside it, so the field keeps the
   full width of the header slot. */
.search {
  position: relative;
  display: block;
}

.search__icon {
  position: absolute;
  top: 50%;
  left: 0.625rem;
  color: var(--muted);
  transform: translateY(-50%);
  pointer-events: none;
}

.search input {
  width: 100%;
  min-width: 12rem;
  padding: 0.375rem 0.625rem 0.375rem 2rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
}

.toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 1rem;
}

.toolbar__count {
  margin: 0 0.5rem 0 0;
  font-weight: 600;
}

.toolbar__chip { font-weight: 400; }

.toolbar__chip-remove {
  font-size: 0.75em;
  opacity: 0.7;
}

.toolbar__sort { margin-left: auto; }

.more {
  margin-top: 1rem;
  text-align: center;
}

.toolbar__sort select {
  padding: 0.375rem 0.5rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
}
</style>
