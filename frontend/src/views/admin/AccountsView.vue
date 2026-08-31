<script setup>
import { computed, onMounted, ref } from 'vue'
import { t } from '@/i18n'
import { get, post, del as remove, ApiError } from '@/api/client'
import { notify } from '@/state/notices'
import { formatTime, exactTime } from '@/util/time'
import AppShell from '@/components/AppShell.vue'
import AdminTabs from '@/components/AdminTabs.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'
import ConfirmDialog from '@/components/ConfirmDialog.vue'
import Icon from '@/components/Icon.vue'

// S6, accounts (FA-901 to FA-906, FA-107a, W-7).
//
// The one-time password of FA-901 and FA-903 is shown **once**, in a dialogue
// that has to be dismissed by hand. It is stored nowhere in readable form, so
// a screen that let it scroll away would lose it for good.

const accounts = ref([])
const loading = ref(true)
const failure = ref(null)
const busy = ref(false)

const term = ref('')
const draft = ref({ name: '', email: '' })
const createError = ref(null)

// What is on display in a dialogue, and only ever one of them.
const shown = ref(null)
const resetting = ref(null)
const doomed = ref(null)
const successor = ref(null)
const promptsAction = ref('delete')

const successors = computed(() => accounts.value.filter((entry) => entry.id !== doomed.value?.id))

// FA-107a. The application cannot call the administrator — it sends no e-mail
// (E-13) — so a registration nobody looks at is a person who concludes the
// tool is broken. The count sits in the heading, where he is already looking,
// and the server sorts the waiting ones to the top.
const pendingCount = computed(() => accounts.value.filter((entry) => entry.pending_since).length)

onMounted(load)

async function load () {
  loading.value = true
  failure.value = null

  try {
    accounts.value = (await get('/admin/users', { params: { q: term.value || null } })).users ?? []
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    loading.value = false
  }
}

async function search () {
  accounts.value = (await get('/admin/users', { params: { q: term.value || null } })).users ?? []
}

// FA-901. The answer carries the one-time password, and this is the only
// moment it exists in readable form anywhere.
async function create () {
  if (busy.value) return

  busy.value = true
  createError.value = null

  try {
    const payload = await post('/admin/users', { body: { ...draft.value } })
    shown.value = { name: payload.user.name, password: payload.initial_password }
    draft.value = { name: '', email: '' }
    notify(t('admin.created'))
    await load()
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    createError.value = problem
  } finally {
    busy.value = false
  }
}

async function lock (account) {
  await act(() => post(`/admin/users/${account.id}/lock`), t('admin.locked', { name: account.name }))
}

async function unlock (account) {
  await act(() => post(`/admin/users/${account.id}/unlock`), t('admin.unlocked', { name: account.name }))
}

// FA-107a. A button of its own beside "unlock", although the row change is
// the same: letting somebody in for the first time and lifting a lock one
// imposed oneself are decided on different grounds and land in the log under
// different names.
async function approve (account) {
  await act(() => post(`/admin/users/${account.id}/approve`), t('admin.approved', { name: account.name }))
}

// FA-903 asks before it acts: the sessions of that account end at once, and
// the person is locked out of their own work until somebody hands them the
// new password.
async function confirmReset () {
  const account = resetting.value

  await act(async () => {
    const payload = await post(`/admin/users/${account.id}/reset-password`)
    shown.value = { name: account.name, password: payload.initial_password }
  })
  resetting.value = null
}

// FA-904. The question is asked because the two answers are not the same kind
// of decision: removing an account is administrative, removing their work is
// about content.
function askDelete (account) {
  doomed.value = account
  promptsAction.value = 'delete'
  successor.value = successors.value[0]?.id ?? null
}

async function confirmDelete () {
  const account = doomed.value

  await act(
    () => remove(`/admin/users/${account.id}`, {
      body: { prompts_action: promptsAction.value, successor_id: successor.value }
    }),
    t('admin.deleted', { name: account.name })
  )
  doomed.value = null
}

// One shape for every operation on the list: do it, say what happened, load
// the list again. Without the reload the screen would show a status the
// server no longer holds.
async function act (operation, message = null) {
  if (busy.value) return

  busy.value = true
  failure.value = null

  try {
    await operation()
    if (message) notify(message)
    await load()
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    busy.value = false
  }
}

// Waiting and locked are the same row in the database and two different
// things to a person. Whoever registered a minute ago must not read that they
// were locked out, and the administrator has to be able to tell a newcomer
// from somebody he shut out himself.
function statusLabel (account) {
  if (account.pending_since) return t('admin.status_pending')

  return account.status === 'locked' ? t('admin.status_locked') : t('admin.status_active')
}
</script>

<template>
  <AppShell>
    <h1>{{ t('admin.title') }}</h1>
    <AdminTabs />

    <ErrorState v-if="failure" :error="failure" :on-retry="load" />
    <LoadingState v-else-if="loading" :rows="5" />

    <section v-else class="panel" aria-labelledby="accounts-heading">
      <h2 id="accounts-heading">
        {{ t('admin.accounts_heading', { count: accounts.length }) }}
        <span v-if="pendingCount" class="admin__badge" data-test="pending-count">
          {{ t('admin.pending_badge', { count: pendingCount }) }}
        </span>
      </h2>

      <label class="field">
        <span>{{ t('admin.search') }}</span>
        <input v-model="term" type="search" :placeholder="t('admin.search_placeholder')"
               data-test="search" @input="search">
      </label>

      <ul class="entries">
        <li v-for="account in accounts" :key="account.id" class="entry"
            :class="{ 'entry--pending': account.pending_since }">
          <span class="entry__name">{{ account.name }}</span>
          <span class="entry__detail">
            {{ account.email }} · {{ statusLabel(account) }}
            <template v-if="account.is_instance_admin"> · {{ t('admin.instance_admin') }}</template>
            · {{ t('admin.counts', { workspaces: account.workspace_count, prompts: account.prompt_count }) }}
            · <span :title="exactTime(account.last_login_at)">{{
              account.last_login_at
                ? t('admin.last_login', { when: formatTime(account.last_login_at) })
                : t('admin.never_signed_in')
            }}</span>
          </span>

          <span class="entry__actions">
            <button v-if="account.pending_since" type="button" class="button"
                    :aria-label="t('admin.approve_one', { name: account.name })"
                    data-test="approve" @click="approve(account)">
              <Icon name="check-lg" /> {{ t('admin.approve') }}
            </button>
            <button v-else-if="account.status === 'active'" type="button" class="button button--quiet"
                    :aria-label="t('admin.lock_one', { name: account.name })" @click="lock(account)">
              <Icon name="lock" /> {{ t('admin.lock') }}
            </button>
            <button v-else type="button" class="button button--quiet"
                    :aria-label="t('admin.unlock_one', { name: account.name })" @click="unlock(account)">
              <Icon name="lock" /> {{ t('admin.unlock') }}
            </button>

            <button type="button" class="button button--quiet"
                    :aria-label="t('admin.reset_one', { name: account.name })"
                    @click="resetting = account">
              <Icon name="arrow-counterclockwise" /> {{ t('admin.reset') }}
            </button>

            <button type="button" class="button button--quiet"
                    :aria-label="t('admin.delete_one', { name: account.name })"
                    @click="askDelete(account)">
              <Icon name="trash" /> {{ t('admin.delete') }}
            </button>
          </span>
        </li>
      </ul>

      <form class="admin__new" @submit.prevent="create">
        <h3>{{ t('admin.new_heading') }}</h3>

        <p v-if="createError" class="alert" role="alert">{{ createError.message }}</p>

        <div class="admin__row">
          <label class="field">
            <span>{{ t('admin.field_name') }}</span>
            <input v-model="draft.name" type="text">
          </label>
          <label class="field">
            <span>{{ t('admin.field_email') }}</span>
            <input v-model="draft.email" type="email">
          </label>
          <button type="submit" class="button" :disabled="busy" data-test="create-account">
            <Icon name="plus-lg" /> {{ t('admin.create') }}
          </button>
        </div>
      </form>
    </section>

    <!-- Shown once and dismissed by hand. It exists nowhere else in readable
         form, so a message that fades after two seconds would lose it. -->
    <ConfirmDialog
      v-if="shown"
      :title="t('admin.initial_password_title', { name: shown.name })"
      :description="t('admin.initial_password_hint')"
      :confirm-label="t('admin.initial_password_done')"
      @confirm="shown = null"
      @cancel="shown = null"
    >
      <p class="admin__password" data-test="initial-password">{{ shown.password }}</p>
    </ConfirmDialog>

    <ConfirmDialog
      v-if="resetting"
      :title="t('admin.reset_title', { name: resetting.name })"
      :description="t('admin.reset_hint')"
      :confirm-label="t('admin.reset_confirm')"
      :danger="true"
      :busy="busy"
      @confirm="confirmReset"
      @cancel="resetting = null"
    />

    <ConfirmDialog
      v-if="doomed"
      :title="t('admin.delete_title', { name: doomed.name })"
      :description="t('admin.delete_hint', { count: doomed.prompt_count })"
      :confirm-label="t('admin.delete_confirm')"
      :danger="true"
      :busy="busy"
      :ready="promptsAction === 'delete' || successor !== null"
      @confirm="confirmDelete"
      @cancel="doomed = null"
    >
      <label class="admin__choice">
        <input v-model="promptsAction" type="radio" name="prompts-action" value="delete">
        <span>{{ t('admin.delete_prompts') }}</span>
      </label>

      <label class="admin__choice">
        <input v-model="promptsAction" type="radio" name="prompts-action" value="transfer">
        <span>{{ t('admin.transfer_prompts') }}</span>
      </label>

      <label v-if="promptsAction === 'transfer'" class="field">
        <span class="visually-hidden">{{ t('admin.transfer_prompts') }}</span>
        <select v-model="successor" data-test="successor">
          <option v-for="entry in successors" :key="entry.id" :value="entry.id">
            {{ entry.name }}
          </option>
        </select>
      </label>
    </ConfirmDialog>
  </AppShell>
</template>

<style scoped>
.admin__new {
  margin-top: 1rem;
  padding-top: 1rem;
  border-top: 1px solid var(--border);
}

.admin__new h3 {
  margin-bottom: 0.5rem;
  font-size: 1rem;
}

.admin__row {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 0.75rem;
}

.admin__row .field {
  flex: 1 1 14rem;
  margin-bottom: 0;
}

/* Monospace and large: it is read out or copied, once, and a transposed
   character means the person cannot get in. */
.admin__password {
  padding: 0.75rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface-sunken);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 1.125rem;
  overflow-wrap: anywhere;
  user-select: all;
}

.admin__badge {
  margin-left: 0.5rem;
  padding: 0.125rem 0.5rem;
  border-radius: 999px;
  background: var(--accent);
  color: var(--accent-text);
  font-size: 0.8125rem;
  font-weight: 600;
  vertical-align: middle;
}

.entry--pending {
  border-left: 3px solid var(--accent);
  padding-left: calc(0.75rem - 3px);
}

.admin__choice {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.25rem 0;
}

select {
  padding: 0.375rem 0.5rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
}
</style>
