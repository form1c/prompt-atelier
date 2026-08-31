<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { t } from '@/i18n'
import { get, post, put, del as remove, ApiError } from '@/api/client'
import { session, selectedWorkspace, refreshWorkspaces, selectWorkspace } from '@/state/session'
import { notify } from '@/state/notices'
import AppShell from '@/components/AppShell.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'
import ConfirmDialog from '@/components/ConfirmDialog.vue'
import Icon from '@/components/Icon.vue'

// S5 — the workspace and who is in it (FA-601, FA-603, FA-606, FA-608, W-5).
//
// Everything on this screen is decided by the server and only *shown* here.
// The workspace payload says whether renaming, managing members, handing out
// ownership and deleting are permitted (SEC-06); the two rules that cannot be
// read off a role — the last owner may not step down (FA-603) and a personal
// workspace is untouchable (FA-606) — reach the screen the same way, as a
// refusal with a sentence.
//
// The refusals are shown, not prevented. Counting owners in the browser to
// grey out a button would be a second implementation of the rule, and it
// would be the one that is wrong when two people click at once.

const ROLES = [
  { value: 'viewer', label: 'workspace.role_viewer' },
  { value: 'editor', label: 'workspace.role_editor' },
  { value: 'admin', label: 'workspace.role_admin' },
  { value: 'owner', label: 'workspace.role_owner' }
]

const router = useRouter()

const members = ref([])
const loading = ref(true)
const failure = ref(null)
const working = ref(false)

const name = ref('')
const nameError = ref(null)
const memberError = ref(null)
const invite = ref({ email: '', role: 'editor' })
const created = ref('')
const createError = ref(null)
const doomed = ref(null)
const confirmName = ref('')

const workspace = computed(() => selectedWorkspace())
const may = computed(() => workspace.value?.permissions ?? {})

// FA-603: only an owner hands out ownership, so an admin is offered the other
// three. Left out rather than greyed out — the same rule as the prompt menu.
const offeredRoles = computed(() => (
  may.value.grant_owner ? ROLES : ROLES.filter((role) => role.value !== 'owner')
))

const renamed = computed(() => name.value.trim() !== '' && name.value !== workspace.value?.name)

onMounted(load)

watch(() => session.selectedWorkspaceId, load)

async function load () {
  if (!session.selectedWorkspaceId) return

  loading.value = true
  failure.value = null
  name.value = workspace.value?.name ?? ''
  members.value = []

  try {
    // Only where the caller may see it. A viewer has a workspace screen too —
    // it shows the name and nothing about who else is in it (matrix row
    // "Mitglieder verwalten"), and asking anyway would answer 404 and turn
    // the whole screen into an error.
    if (may.value.members) {
      const payload = await get(`/workspaces/${session.selectedWorkspaceId}/members`)
      members.value = payload.members ?? []
    }
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    loading.value = false
  }
}

// FA-601. Anyone signed in may make one and becomes its owner.
//
// This is the only way to a team workspace, and until now there was none: the
// endpoint has existed since AP-05 and no screen called it, so an installation
// could be operated for a year without a second workspace ever coming into
// being. The personal one of FA-602 is created with the account and is not a
// place to share from.
//
// The new workspace is selected straight away. Making something and then
// having to find it in a menu is a step nobody wants, and the screen has to
// show *some* workspace — leaving the old one on display after the button
// said "angelegt" would read as if nothing had happened.
async function create () {
  if (working.value || created.value.trim() === '') return

  working.value = true
  createError.value = null

  try {
    const payload = await post('/workspaces', { body: { name: created.value.trim() } })
    await selectWorkspace(payload.workspace.id)
    await refreshWorkspaces()
    notify(t('workspace.created', { name: payload.workspace.name }))
    created.value = ''
    await load()
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    createError.value = problem
  } finally {
    working.value = false
  }
}

// FA-608. The name is what everyone else sees the workspace by, so the change
// has to reach the header too — hence the reload of the session's list.
async function rename () {
  if (working.value || !renamed.value) return

  working.value = true
  nameError.value = null

  try {
    await put(`/workspaces/${session.selectedWorkspaceId}`, { body: { name: name.value.trim() } })
    await refreshWorkspaces()
    notify(t('workspace.renamed'))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    nameError.value = problem
  } finally {
    working.value = false
  }
}

// FA-603. Named by e-mail address: a workspace owner has no account list to
// pick from — that belongs to the instance administrator (6.2) — and the
// address is what somebody adding a colleague knows.
async function addMember () {
  if (working.value || invite.value.email.trim() === '') return

  working.value = true
  memberError.value = null

  try {
    const payload = await post(`/workspaces/${session.selectedWorkspaceId}/members`, {
      body: { email: invite.value.email.trim(), role: invite.value.role }
    })
    members.value = payload.members ?? []
    notify(t('workspace.member_added'))
    invite.value = { email: '', role: 'editor' }
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    memberError.value = problem
  } finally {
    working.value = false
  }
}

// TF-206: the last owner may not step down, and the select has to end up
// showing the role that actually holds — not the one that was refused.
//
// Nothing here puts it back, and that is on purpose: the field is bound with
// `:value`, so the re-render caused by the error message below restores it.
// An explicit reset stood here first; a mutation probe showed it could be
// removed without a single test noticing, because there is no path on which
// the refusal fails to change reactive state. The test stays and checks the
// outcome — which is what has to be true however it comes about.
async function changeRole (member, event) {
  const role = event.target.value
  if (role === member.role) return

  memberError.value = null

  try {
    const payload = await put(
      `/workspaces/${session.selectedWorkspaceId}/members/${member.user_id}`,
      { body: { role } }
    )
    members.value = payload.members ?? []
    notify(t('workspace.role_changed', { name: member.name }))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    memberError.value = problem
  }
}

async function removeMember (member) {
  memberError.value = null

  try {
    const payload = await remove(`/workspaces/${session.selectedWorkspaceId}/members/${member.user_id}`)
    members.value = payload.members ?? []
    notify(t('workspace.member_removed', { name: member.name }))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    memberError.value = problem
  }
}

// FA-606: the contents go with it, so the name has to be typed out. Checked
// on the server as well — a dialogue in the browser is a reminder, not a
// safeguard.
function askDelete () {
  doomed.value = workspace.value
  confirmName.value = ''
}

async function confirmDelete () {
  if (working.value) return

  working.value = true

  try {
    await remove(`/workspaces/${doomed.value.id}`, { body: { confirm_name: confirmName.value } })
    notify(t('workspace.deleted', { name: doomed.value.name }))
    doomed.value = null
    // The workspace that was selected is gone; the session picks up the
    // fallback the server names (FA-605), and the library is where a screen
    // about a deleted workspace must not stay.
    await refreshWorkspaces()
    await router.push({ name: 'library' })
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
    doomed.value = null
  } finally {
    working.value = false
  }
}

const roleLabel = (value) => {
  if (value === 'owner') return t('workspace.role_owner')
  if (value === 'admin') return t('workspace.role_admin')
  if (value === 'editor') return t('workspace.role_editor')

  return t('workspace.role_viewer')
}
</script>

<template>
  <AppShell>
    <h1>{{ t('workspace.title') }}</h1>

    <ErrorState v-if="failure" :error="failure" :on-retry="load" />
    <LoadingState v-else-if="loading" :rows="4" />

    <template v-else>
      <section class="panel" aria-labelledby="workspace-name-heading">
        <h2 id="workspace-name-heading">{{ t('workspace.name_heading') }}</h2>

        <p v-if="nameError" class="alert" role="alert">{{ nameError.message }}</p>

        <form class="workspace__rename" @submit.prevent="rename">
          <label class="field">
            <span>{{ t('workspace.field_name') }}</span>
            <input v-model="name" type="text" maxlength="100" :disabled="!may.rename">
          </label>

          <button
            v-if="may.rename"
            type="submit"
            class="button"
            :disabled="working || !renamed"
            data-test="rename"
          >
            {{ t('workspace.rename') }}
          </button>
        </form>

        <p v-if="workspace?.is_personal" class="hint">{{ t('workspace.personal_note') }}</p>
      </section>

      <!-- FA-601: the only way to a workspace that can be shared. Open to
           everyone signed in — the creator becomes its owner. -->
      <section class="panel" aria-labelledby="workspace-new-heading">
        <h2 id="workspace-new-heading">{{ t('workspace.new_heading') }}</h2>

        <p v-if="createError" class="alert" role="alert">{{ createError.message }}</p>

        <form class="workspace__rename" @submit.prevent="create">
          <div class="field">
            <label>
              <span>{{ t('workspace.field_new_name') }}</span>
              <input v-model="created" type="text" maxlength="100" aria-describedby="new-hint">
            </label>
            <span id="new-hint" class="hint">{{ t('workspace.new_hint') }}</span>
          </div>

          <button type="submit" class="button" :disabled="working" data-test="create">
            <Icon name="plus-lg" /> {{ t('workspace.create') }}
          </button>
        </form>
      </section>

      <!-- Only for whoever manages members. A viewer's screen ends above —
           the matrix gives them no view of the membership, and an empty
           panel would suggest there is nobody in it. -->
      <section v-if="may.members" class="panel" aria-labelledby="workspace-members-heading">
        <h2 id="workspace-members-heading">
          {{ t('workspace.members_heading', { count: members.length }) }}
        </h2>

        <p v-if="memberError" class="alert" role="alert">{{ memberError.message }}</p>

        <ul class="entries">
          <li v-for="member in members" :key="member.user_id" class="entry">
            <span class="entry__name">{{ member.name }}</span>
            <span class="entry__detail">{{ member.email }}</span>

            <span class="entry__actions">
              <label class="workspace__role">
                <span class="visually-hidden">
                  {{ t('workspace.role_of', { name: member.name }) }}
                </span>
                <select :value="member.role" @change="changeRole(member, $event)">
                  <!-- The current role is always in the list, even when it is
                       one this user may not hand out: an admin looking at the
                       owner would otherwise see a select box claiming they are
                       something else. -->
                  <option v-if="member.role === 'owner' && !may.grant_owner" value="owner">
                    {{ roleLabel('owner') }}
                  </option>
                  <option v-for="role in offeredRoles" :key="role.value" :value="role.value">
                    {{ t(role.label) }}
                  </option>
                </select>
              </label>

              <button
                type="button"
                class="button button--quiet"
                :aria-label="t('workspace.remove_one', { name: member.name })"
                @click="removeMember(member)"
              >
                <Icon name="x-lg" /> {{ t('workspace.remove') }}
              </button>
            </span>
          </li>
        </ul>

        <form class="workspace__invite" @submit.prevent="addMember">
          <div class="field">
            <label>
              <span>{{ t('workspace.field_email') }}</span>
              <input v-model="invite.email" type="email" aria-describedby="invite-hint">
            </label>
            <span id="invite-hint" class="hint">{{ t('workspace.email_hint') }}</span>
          </div>

          <label class="field">
            <span>{{ t('workspace.field_role') }}</span>
            <select v-model="invite.role">
              <option v-for="role in offeredRoles" :key="role.value" :value="role.value">
                {{ t(role.label) }}
              </option>
            </select>
          </label>

          <button type="submit" class="button" :disabled="working" data-test="add-member">
            <Icon name="plus-lg" /> {{ t('workspace.add_member') }}
          </button>
        </form>
      </section>

      <!-- FA-606 and TF-425: for a personal workspace this is absent, not
           disabled. The requirement says the action is not to be offered. -->
      <section v-if="may.delete" class="panel" aria-labelledby="workspace-danger-heading">
        <h2 id="workspace-danger-heading">{{ t('workspace.delete_heading') }}</h2>
        <p class="hint">{{ t('workspace.delete_hint') }}</p>

        <button type="button" class="button button--danger" data-test="delete" @click="askDelete">
          <Icon name="trash" /> {{ t('workspace.delete') }}
        </button>
      </section>
    </template>

    <ConfirmDialog
      v-if="doomed"
      :title="t('workspace.delete_title', { name: doomed.name })"
      :description="t('workspace.delete_confirm_hint', { name: doomed.name })"
      :confirm-label="t('workspace.delete_confirm')"
      :danger="true"
      :busy="working"
      :ready="confirmName === doomed.name"
      @confirm="confirmDelete"
      @cancel="doomed = null"
    >
      <label class="field">
        <span>{{ t('workspace.delete_name_label') }}</span>
        <input v-model="confirmName" type="text">
      </label>
    </ConfirmDialog>
  </AppShell>
</template>

<style scoped>
.workspace__rename,
.workspace__invite {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 0.75rem;
}

.workspace__rename .field,
.workspace__invite .field {
  flex: 1 1 14rem;
  margin-bottom: 0;
}

.workspace__invite {
  margin-top: 1rem;
  padding-top: 1rem;
  border-top: 1px solid var(--border);
}

.workspace__role {
  display: inline-flex;
  align-items: center;
}

select {
  padding: 0.5rem 0.625rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
}

.panel .hint {
  display: block;
  color: var(--muted);
  font-size: 0.875rem;
}
</style>
