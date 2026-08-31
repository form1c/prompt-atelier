<script setup>
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { t } from '@/i18n'
import { get, ApiError } from '@/api/client'
import { formatTime, exactTime } from '@/util/time'
import AppShell from '@/components/AppShell.vue'
import AdminTabs from '@/components/AdminTabs.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'

// S6, the log (FA-908, A-15).
//
// Readable, filterable, not changeable. There is no writing endpoint on the
// log, and no entry carries a control.
//
// The filters are not a convenience. The table is bounded by time and nothing
// pushes an entry out of it — but a burst of refused logins pushes every
// administrative entry out of *sight*, and an administrator looks at the log
// precisely when something has happened.
//
// **The filter lives in the address.** That is what makes a view of the log
// something one can bookmark, reload and hand to a colleague — and it is why
// paging works at all: the page number is a query parameter like the rest,
// not a variable that a reload forgets.

const route = useRoute()
const router = useRouter()

const entries = ref([])
const actions = ref([])
const people = ref([])
const meta = ref({ total: 0, page: 1, per_page: 50 })
const loading = ref(true)
const failure = ref(null)

const draft = ref(fromQuery())

const pages = computed(() => Math.max(1, Math.ceil(meta.value.total / (meta.value.per_page || 50))))
const page = computed(() => meta.value.page ?? 1)

// Reacts to the address rather than to the button. A reload, the back button
// and a pasted link then all take the same path as a click.
watch(() => route.query, load, { immediate: true })

function fromQuery () {
  return {
    actor_id: route.query.actor_id ?? '',
    action: route.query.action ?? '',
    from: route.query.from ?? '',
    to: route.query.to ?? ''
  }
}

// The dates come from date fields, which speak the reader's calendar. The
// boundaries of "the 3rd" are therefore turned into moments **here**, where
// the time zone is known — the server has no way to know it (11.6).
function params () {
  const query = route.query

  return {
    actor_id: query.actor_id || null,
    action: query.action || null,
    from: query.from ? new Date(`${query.from}T00:00:00`).toISOString() : null,
    to: query.to ? new Date(`${query.to}T23:59:59.999`).toISOString() : null,
    page: query.page || null
  }
}

async function load () {
  loading.value = true
  failure.value = null
  draft.value = fromQuery()

  try {
    const [audit, users] = await Promise.all([
      get('/admin/audit', { params: params() }),
      // For the "who" list. Asked here rather than derived from the entries:
      // a person who has done nothing yet would otherwise be missing from the
      // very filter one uses to check whether they have done anything.
      people.value.length ? Promise.resolve({ users: people.value }) : get('/admin/users')
    ])
    entries.value = audit.entries ?? []
    actions.value = audit.actions ?? []
    meta.value = audit.meta ?? { total: entries.value.length, page: 1, per_page: 50 }
    people.value = users.users ?? []
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    loading.value = false
  }
}

// A changed filter always returns to page one. Staying on page seven of a
// result that now has two would show an empty screen and look like "nothing
// found".
function apply () {
  const query = {}
  for (const [key, value] of Object.entries(draft.value)) {
    if (value) query[key] = value
  }
  router.push({ name: 'admin-audit', query })
}

function clear () {
  router.push({ name: 'admin-audit', query: {} })
}

function toPage (wanted) {
  router.push({ name: 'admin-audit', query: { ...route.query, page: String(wanted) } })
}

// The count is the entire content of a collapsed entry (SEC-07): it is what
// separates an attacker with fifty thousand attempts from a colleague who
// mistyped five times.
function collapsedCount (entry) {
  try {
    return JSON.parse(entry.meta_json ?? '{}').count ?? 0
  } catch {
    return 0
  }
}
</script>

<template>
  <AppShell>
    <h1>{{ t('admin.title') }}</h1>
    <AdminTabs />

    <section class="panel" aria-labelledby="audit-heading">
      <h2 id="audit-heading">{{ t('admin.audit_heading') }}</h2>
      <p class="hint">{{ t('admin.audit_hint') }}</p>

      <form class="admin__filter" @submit.prevent="apply">
        <label class="field">
          <span>{{ t('admin.audit_actor') }}</span>
          <select v-model="draft.actor_id" data-test="audit-actor">
            <option value="">{{ t('admin.audit_anyone') }}</option>
            <option v-for="account in people" :key="account.id" :value="String(account.id)">
              {{ account.name }}
            </option>
          </select>
        </label>

        <label class="field">
          <span>{{ t('admin.audit_action') }}</span>
          <select v-model="draft.action" data-test="audit-action">
            <option value="">{{ t('admin.audit_anything') }}</option>
            <option v-for="action in actions" :key="action" :value="action">{{ action }}</option>
          </select>
        </label>

        <label class="field">
          <span>{{ t('admin.audit_from') }}</span>
          <input v-model="draft.from" type="date" data-test="audit-from">
        </label>

        <label class="field">
          <span>{{ t('admin.audit_to') }}</span>
          <input v-model="draft.to" type="date" data-test="audit-to">
        </label>

        <button type="submit" class="button" data-test="audit-filter">{{ t('admin.audit_apply') }}</button>
        <button type="button" class="button button--quiet" @click="clear">
          {{ t('admin.audit_clear') }}
        </button>
      </form>

      <ErrorState v-if="failure" :error="failure" :on-retry="load" />
      <LoadingState v-else-if="loading" :rows="6" />

      <template v-else>
        <!-- A page out of many must say so, or the filter looks as though it
             found everything there is. -->
        <p v-if="entries.length" class="hint" data-test="audit-count">
          {{ t('admin.audit_shown', { shown: entries.length, total: meta.total }) }}
        </p>

        <ul v-if="entries.length" class="entries">
          <li v-for="entry in entries" :key="entry.id" class="entry">
            <span class="entry__name">{{ entry.action }}</span>
            <span class="entry__detail">
              {{ t('admin.audit_entry', { actor: entry.actor_name ?? '—', action: entry.target_type ?? '—' }) }}
              · <span :title="exactTime(entry.created_at)">{{ formatTime(entry.created_at) }}</span>
              <template v-if="entry.action === 'login.failed.collapsed'">
                · {{ t('admin.audit_collapsed', { count: collapsedCount(entry) }) }}
              </template>
            </span>
          </li>
        </ul>
        <p v-else class="hint">{{ t('admin.audit_empty') }}</p>

        <nav v-if="pages > 1" class="admin__pages" :aria-label="t('admin.audit_pages')">
          <button type="button" class="button button--quiet" :disabled="page <= 1"
                  data-test="audit-previous" @click="toPage(page - 1)">
            {{ t('admin.audit_previous') }}
          </button>
          <span data-test="audit-page">{{ t('admin.audit_page', { page, pages }) }}</span>
          <button type="button" class="button button--quiet" :disabled="page >= pages"
                  data-test="audit-next" @click="toPage(page + 1)">
            {{ t('admin.audit_next') }}
          </button>
        </nav>
      </template>
    </section>
  </AppShell>
</template>

<style scoped>
.panel .hint {
  display: block;
  color: var(--muted);
  font-size: 0.875rem;
}

.admin__filter {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 0.75rem;
  margin-bottom: 0.75rem;
}

.admin__filter .field {
  flex: 1 1 10rem;
  margin-bottom: 0;
}

.admin__pages {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-top: 1rem;
}

select {
  padding: 0.375rem 0.5rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
}
</style>
