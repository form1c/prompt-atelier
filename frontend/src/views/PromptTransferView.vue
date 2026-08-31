<script setup>
import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { t } from '@/i18n'
import { workspaceName } from '@/util/workspace'
import { get, post, ApiError } from '@/api/client'
import { session } from '@/state/session'
import { notify } from '@/state/notices'
import AppShell from '@/components/AppShell.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'
import Icon from '@/components/Icon.vue'

// Duplicating and moving (FA-204, FA-207, 11.4).
//
// One screen for both, because they are one question — "which workspace?" —
// with two answers to what happens afterwards. Requirements 11.4 says as much:
// both entries open the same chooser.
//
// The list offers only workspaces the caller may create in (TF-308). Which
// those are comes **from the server**, in the workspace payload; deriving it
// here from the role would be a second copy of the rules, and the copy is the
// one nobody tests (SEC-06). A target that can only end in a 403 is not a
// choice, it is a trap.

const route = useRoute()
const router = useRouter()

const prompt = ref(null)
const chosen = ref(null)
const loading = ref(true)
const working = ref(false)
const failure = ref(null)

const moving = computed(() => route.name === 'prompt-move')

const targets = computed(() => session.workspaces.filter((workspace) => {
  if (!workspace.permissions?.create) return false
  // Moving somewhere it already is does nothing and would still cost a
  // revision. Duplicating into the same workspace is a normal thing to do.
  return !moving.value || workspace.id !== prompt.value?.workspace_id
}))

onMounted(async () => {
  try {
    const payload = await get(`/prompts/${route.params.id}`)
    prompt.value = payload.prompt
    // The workspaces come from the session, loaded once at sign-in. Fetching
    // them again here would also reset the selected workspace — a side effect
    // this screen has no business having.
    chosen.value = targets.value[0]?.id ?? null
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    loading.value = false
  }
})

async function confirm () {
  if (working.value || chosen.value === null) return

  working.value = true
  failure.value = null

  try {
    const path = moving.value ? 'move' : 'duplicate'
    const payload = await post(`/prompts/${prompt.value.id}/${path}`, {
      body: { workspace_id: chosen.value }
    })

    announce(payload)
    await router.replace(destination(payload))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    working.value = false
  }
}

// What the server did that the screen would not otherwise show.
//
// Both messages are consequences nobody asked for and everybody has to know
// about: a moved prompt is private again (FA-207, TF-307), and a copy may have
// lost keywords the target workspace does not have (FA-204, TF-306). Finding
// that out later, in a prompt that renders differently than expected, is the
// outcome these two lines exist to prevent.
function announce (payload) {
  const dropped = payload.dropped_keywords ?? []

  if (payload.visibility_reset) notify(t('relocate.visibility_reset'))
  if (dropped.length) notify(t('relocate.dropped_keywords', { names: dropped.join(', ') }))

  notify(moving.value ? t('relocate.moved') : t('relocate.duplicated'))
}

// TF-352: a copy lands in the editor with its title selected — "… (Kopie)" is
// a placeholder, not a name. A move lands on the prompt itself, which is
// unchanged apart from where it lives.
function destination (payload) {
  if (moving.value) return { name: 'prompt', params: { id: payload.prompt.id } }

  return { name: 'prompt-edit', params: { id: payload.prompt.id }, query: { rename: '1' } }
}

function cancel () {
  return router.back()
}
</script>

<template>
  <AppShell>
    <ErrorState v-if="failure && !prompt" :error="failure" />
    <LoadingState v-else-if="loading" :rows="3" />

    <section v-else class="transfer">
      <h1>{{ moving ? t('relocate.title_move') : t('relocate.title_duplicate') }}</h1>
      <p class="transfer__subject">{{ prompt.title }}</p>

      <p v-if="failure" class="alert" role="alert">{{ failure.message }}</p>

      <p v-if="moving" class="transfer__warning">
        <Icon name="exclamation-triangle" /> {{ t('relocate.move_warning') }}
      </p>

      <fieldset v-if="targets.length" class="transfer__targets">
        <legend>{{ t('relocate.target') }}</legend>

        <label v-for="workspace in targets" :key="workspace.id" class="transfer__target">
          <input v-model="chosen" type="radio" name="target" :value="workspace.id">
          <span>{{ workspaceName(workspace) }}</span>
          <span v-if="workspace.is_personal" class="transfer__note">{{ t('shell.personal_marker') }}</span>
        </label>
      </fieldset>

      <!-- 11.6: never an empty area. A viewer everywhere has nowhere to put a
           copy, and the screen has to say so rather than show an empty list. -->
      <p v-else class="transfer__none">{{ t('relocate.no_target') }}</p>

      <div class="transfer__actions">
        <button type="button" class="button button--quiet" @click="cancel">
          {{ t('relocate.cancel') }}
        </button>
        <button
          type="button"
          class="button"
          :disabled="working || chosen === null"
          data-test="confirm"
          @click="confirm"
        >
          <Icon :name="moving ? 'folder-symlink' : 'files'" />
          {{ moving ? t('relocate.confirm_move') : t('relocate.confirm_duplicate') }}
        </button>
      </div>
    </section>
  </AppShell>
</template>

<style scoped>
.transfer {
  max-width: 34rem;
}

.transfer__subject {
  margin-bottom: 1rem;
  color: var(--muted);
}

.transfer__warning {
  display: flex;
  align-items: baseline;
  gap: 0.375rem;
  padding: 0.625rem 0.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface-sunken);
  font-size: 0.9375rem;
}

.transfer__targets {
  margin: 0 0 1rem;
  padding: 0.5rem 0.75rem 0.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
}

.transfer__targets legend {
  padding: 0 0.25rem;
  color: var(--muted);
  font-size: 0.75rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.transfer__target {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.375rem 0;
  cursor: pointer;
}

.transfer__note {
  color: var(--muted);
  font-size: 0.8125rem;
}

.transfer__none {
  padding: 0.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface-sunken);
  color: var(--muted);
}

.transfer__actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
}
</style>
