<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { t } from '@/i18n'
import { get, post, del as remove, ApiError } from '@/api/client'
import { session, selectedWorkspace } from '@/state/session'
import { notify } from '@/state/notices'
import { formatTime, exactTime } from '@/util/time'
import { originName } from '@/util/workspace'
import { bulkRestore, bulkPurge } from '@/state/library'
import { createSelection, allSelected } from '@/util/selection'
import AppShell from '@/components/AppShell.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'
import EmptyState from '@/components/EmptyState.vue'
import ConfirmDialog from '@/components/ConfirmDialog.vue'
import SelectionBar from '@/components/SelectionBar.vue'
import Icon from '@/components/Icon.vue'

// S9 — the trash (FA-703, FA-704, W-9).
//
// The other half of W-9: "Änderung rückgängig" answers a prompt that was
// overwritten, this answers one that was deleted. Both are the safety net of
// E-09, and both exist because the alternative — a deletion that is final —
// makes people careful in the wrong way.
//
// Each line says three things the library never shows: when it was deleted,
// **who** deleted it, and which workspace it came from. The second is the one
// that matters in a team: an admin may delete a prompt of somebody else's, and
// its owner has to be able to see who did.
//
// What may be done with a line comes from the server, per line (SEC-06).
// Restoring is allowed for one's own; purging is admin and owner only
// (FA-704), and it is the one action on this screen that cannot be undone.

const prompts = ref([])
const loading = ref(true)
const failure = ref(null)
const working = ref(false)
const doomed = ref(null)

const workspace = computed(() => selectedWorkspace())
const mayLook = computed(() => workspace.value?.permissions?.trash === true)

// --- the selection (FA-510, FA-703a) --------------------------------------

const selection = createSelection()
const purgingSelection = ref(false)

const visibleIds = computed(() => prompts.value.map((prompt) => prompt.id))
const everyVisibleSelected = computed(() => allSelected(selection, visibleIds.value))

// **The bulk restore is the reason the bulk delete may exist at all** (FA-703a).
// Fifty prompts binned in one go and brought back one at a time would punish
// the person for using the feature — and a way back that is that tedious is a
// way back nobody takes.

// The trash is one list without paging, so there is no second "select all"
// here: what is on screen is everything there is.
function toggleVisible () {
  everyVisibleSelected.value ? selection.clear() : selection.selectVisible(visibleIds.value)
}

// Dropped when the list underneath changes — here that means the workspace.
watch(() => session.selectedWorkspaceId, () => selection.clear())

async function restoreSelection () {
  const report = await bulkRestore([...selection.state.ids])
  notify(t('trash.bulk_restored', { count: report.counts.done }))
  announceRefusals(report)
  selection.clear()
  load()
}

async function purgeSelection () {
  purgingSelection.value = false
  const report = await bulkPurge([...selection.state.ids])
  notify(t('trash.bulk_purged', { count: report.counts.done }))
  announceRefusals(report)
  selection.clear()
  load()
}

// Named with their titles where the caller may see them, counted where not —
// the same rule as in the library, and for the same reason: naming a prompt
// somebody may not see would be the disclosure the uniform refusal prevents.
function announceRefusals (report) {
  if (report.counts.refused === 0) return

  const named = report.refused.filter((entry) => entry.title).map((entry) => entry.title)

  notify(named.length
    ? t('trash.bulk_refused', { names: named.join(', '), count: report.counts.refused })
    : t('trash.bulk_refused_unnamed', { count: report.counts.refused }))
}

onMounted(load)

watch(() => session.selectedWorkspaceId, load)

async function load () {
  if (!session.selectedWorkspaceId) return

  loading.value = true
  failure.value = null

  // A viewer has no trash at all (matrix row "Papierkorb einsehen"), and
  // asking would answer 403. The screen says so instead of showing an error.
  if (!mayLook.value) {
    prompts.value = []
    loading.value = false
    return
  }

  try {
    const payload = await get('/trash', { params: { workspace_id: session.selectedWorkspaceId } })
    prompts.value = payload.prompts ?? []
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    loading.value = false
  }
}

// FA-703: back with the metadata it had. Nothing is asked here — restoring is
// the reversible direction, and a confirmation for it would be a step in the
// way of the thing this screen is for (11.6).
async function restore (prompt) {
  if (working.value) return

  working.value = true

  try {
    await post(`/trash/${prompt.id}/restore`)
    notify(t('trash.restored', { title: prompt.title }))
    await load()
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    working.value = false
  }
}

// FA-704, and the one place on this screen where something goes for good.
async function confirmPurge () {
  if (working.value) return

  working.value = true
  const prompt = doomed.value

  try {
    await remove(`/trash/${prompt.id}`)
    notify(t('trash.purged', { title: prompt.title }))
    doomed.value = null
    await load()
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
    doomed.value = null
  } finally {
    working.value = false
  }
}
</script>

<template>
  <AppShell>
    <h1>{{ t('trash.title') }}</h1>
    <p class="trash__intro">{{ t('trash.intro') }}</p>

    <ErrorState v-if="failure" :error="failure" :on-retry="load" />
    <LoadingState v-else-if="loading" :rows="4" />

    <EmptyState
      v-else-if="!mayLook"
      :title="t('trash.closed_title')"
      :description="t('trash.closed_hint')"
    >
      <RouterLink class="button button--quiet" :to="{ name: 'library' }">
        {{ t('trash.to_library') }}
      </RouterLink>
    </EmptyState>

    <section v-else-if="prompts.length" class="panel" aria-labelledby="trash-heading">
      <h2 id="trash-heading">{{ t('trash.heading', { count: prompts.length }) }}</h2>

      <label class="trash__select-all">
        <input
          type="checkbox"
          :checked="everyVisibleSelected"
          data-test="select-visible"
          @change="toggleVisible"
        >
        {{ t('selection.all_visible', { count: prompts.length }) }}
      </label>

      <SelectionBar
        v-if="!selection.empty.value"
        :count="selection.count.value"
        @clear="selection.clear()"
      >
        <button
          type="button"
          class="button button--quiet"
          data-test="bulk-restore"
          @click="restoreSelection"
        >
          <Icon name="arrow-counterclockwise" /> {{ t('trash.bulk_restore') }}
        </button>
        <button
          type="button"
          class="button button--quiet"
          data-test="bulk-purge"
          @click="purgingSelection = true"
        >
          <Icon name="trash" /> {{ t('trash.bulk_purge') }}
        </button>
      </SelectionBar>

      <ul class="entries">
        <li v-for="prompt in prompts" :key="prompt.id" class="entry">
          <label class="entry__select">
            <input
              type="checkbox"
              :checked="selection.has(prompt.id)"
              :aria-label="t('selection.for', { title: prompt.title })"
              @change="selection.toggle(prompt.id)"
            >
          </label>

          <span class="entry__name">{{ prompt.title }}</span>

          <!-- The three facts FA-703 asks for. The exact instant sits in the
               title attribute, as everywhere else times are shown (TF-427). -->
          <span class="entry__detail" :title="exactTime(prompt.deleted_at)">
            {{ t('trash.deleted_by', {
              when: formatTime(prompt.deleted_at),
              who: prompt.deleted_by_name ?? t('trash.unknown_user')
            }) }}
            · {{ t('trash.origin', { name: originName(prompt) }) }}
          </span>

          <span class="entry__actions">
            <button
              v-if="prompt.permissions?.restore"
              type="button"
              class="button button--quiet"
              :aria-label="t('trash.restore_one', { title: prompt.title })"
              @click="restore(prompt)"
            >
              <Icon name="arrow-counterclockwise" /> {{ t('trash.restore') }}
            </button>

            <button
              v-if="prompt.permissions?.purge"
              type="button"
              class="button button--quiet"
              :aria-label="t('trash.purge_one', { title: prompt.title })"
              @click="doomed = prompt"
            >
              <Icon name="trash" /> {{ t('trash.purge') }}
            </button>
          </span>
        </li>
      </ul>
    </section>

    <EmptyState
      v-else
      :title="t('trash.empty_title')"
      :description="t('trash.empty_hint')"
    >
      <RouterLink class="button button--quiet" :to="{ name: 'library' }">
        {{ t('trash.to_library') }}
      </RouterLink>
    </EmptyState>

    <ConfirmDialog
      v-if="doomed"
      :title="t('trash.purge_title', { title: doomed.title })"
      :description="t('trash.purge_hint')"
      :confirm-label="t('trash.purge_confirm')"
      :danger="true"
      :busy="working"
      @confirm="confirmPurge"
      @cancel="doomed = null"
    />

    <!-- FA-703a: the only irreversible action of the application, and the only
         one that must never have a path without a question. The title carries
         the **number**, because "12 Prompts endgültig löschen" is the fact the
         person has to weigh — a list of twelve titles in a dialogue is read by
         nobody. -->
    <ConfirmDialog
      v-if="purgingSelection"
      :title="t('trash.bulk_purge_title', { count: selection.count.value })"
      :description="t('trash.bulk_purge_hint')"
      :confirm-label="t('trash.bulk_purge_confirm')"
      :danger="true"
      @confirm="purgeSelection"
      @cancel="purgingSelection = false"
    />
  </AppShell>
</template>

<style scoped>
.trash__intro {
  max-width: 46rem;
  color: var(--muted);
}
</style>
