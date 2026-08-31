<script setup>
import { onMounted, ref } from 'vue'
import { t, texts } from '@/i18n'
import { get, put, ApiError } from '@/api/client'
import { notify } from '@/state/notices'
import AppShell from '@/components/AppShell.vue'
import AdminTabs from '@/components/AdminTabs.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'

// S6, settings (FA-910).
//
// Only **product** values are here — who may register, how long things are
// kept, how many login attempts are allowed. Operating values (address, port,
// paths, the session secret, the trusted proxies) stay in config.yml, and the
// reason is not tidiness: a wrong one takes the instance off the network, and
// the screen on which the mistake was made is then unreachable. With the port
// that is literally so. Some of them are also a way to grant oneself rights.
//
// There is no restart button, and none is needed: the application reads its
// configuration on every request, so a change here is in force with the next
// one. A restart button would be worse than useless — in three of the four
// operating modes of E-14 nothing would start the application again, and
// nobody would be signed in to notice.

const settings = ref([])
const draft = ref({})
const problems = ref({})
const loading = ref(true)
const failure = ref(null)
const busy = ref(false)

onMounted(load)

async function load () {
  loading.value = true
  failure.value = null

  try {
    settings.value = (await get('/admin/settings')).settings ?? []
    draft.value = Object.fromEntries(settings.value.map((entry) => [entry.key, entry.value]))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    loading.value = false
  }
}

async function save () {
  if (busy.value) return

  busy.value = true
  problems.value = {}

  try {
    const payload = await put('/admin/settings', { body: { settings: draft.value } })
    settings.value = payload.settings ?? []
    draft.value = Object.fromEntries(settings.value.map((entry) => [entry.key, entry.value]))
    notify(t('admin.settings_saved'))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    // Not `fieldMessage` here: this screen's fields carry a `kind`, and the
    // sentence for a kind is the screen's own (`admin.kind_*`) — it says what
    // shape the value has to have, which the server has no word for.
    problems.value = problem.fields ?? {}
    if (Object.keys(problems.value).length === 0) failure.value = problem
  } finally {
    busy.value = false
  }
}

// The label and the explanation come from the text table under the key
// itself, so a new setting needs one entry there and nothing here.
// The server answers with the **kind** of value it expected, not with a
// sentence: its own descriptions are the console English of the scripts
// (I18n::BASE_LANGUAGE), and this form is German. The screen knows the kind
// anyway — it draws the control from it — so it writes the sentence itself.
function complaintFor (key) {
  const problem = problems.value[key]
  if (!problem) return null

  const kind = typeof problem === 'object' ? problem.kind : null
  // A kind the screen has no sentence for is possible — a new rule on the
  // server, an older interface. Saying "not permitted" is then still true,
  // and better than printing a key nobody can read.
  return kind && texts.admin?.[`kind_${kind}`]
    ? t(`admin.kind_${kind}`)
    : t('admin.kind_unknown')
}

const labelOf = (key) => t(`admin.setting_${key.replace('.', '_')}`)
const hintOf = (key) => t(`admin.setting_${key.replace('.', '_')}_hint`)
</script>

<template>
  <AppShell>
    <h1>{{ t('admin.title') }}</h1>
    <AdminTabs />

    <ErrorState v-if="failure" :error="failure" :on-retry="load" />
    <LoadingState v-else-if="loading" :rows="6" />

    <section v-else class="panel" aria-labelledby="settings-heading">
      <h2 id="settings-heading">{{ t('admin.settings_heading') }}</h2>
      <p class="hint">{{ t('admin.settings_hint') }}</p>

      <form @submit.prevent="save">
        <div v-for="entry in settings" :key="entry.key" class="field">
          <label>
            <span>{{ labelOf(entry.key) }}</span>

            <select v-if="entry.choices" v-model="draft[entry.key]"
                    :aria-describedby="`hint-${entry.key}`" :data-test="entry.key">
              <option v-for="choice in entry.choices" :key="choice" :value="choice">
                {{ t(`admin.choice_${choice}`) }}
              </option>
            </select>

            <input v-else v-model="draft[entry.key]" type="number" min="0"
                   :aria-describedby="`hint-${entry.key}`"
                   :aria-invalid="Boolean(problems[entry.key])" :data-test="entry.key">
          </label>

          <!-- Outside the label: everything inside one becomes part of the
               field's *name*, and a hint is a description (NFA-11). -->
          <span :id="`hint-${entry.key}`" class="hint">
            {{ hintOf(entry.key) }}
            <template v-if="entry.from_file"> · {{ t('admin.setting_from_file') }}</template>
          </span>
          <span v-if="problems[entry.key]" class="field-error">{{ complaintFor(entry.key) }}</span>
        </div>

        <button type="submit" class="button" :disabled="busy" data-test="save-settings">
          {{ t('admin.settings_save') }}
        </button>
      </form>
    </section>
  </AppShell>
</template>

<style scoped>
.panel .hint {
  display: block;
  color: var(--muted);
  font-size: 0.875rem;
}

.panel form {
  max-width: 34rem;
}

.field {
  margin-bottom: 1.25rem;
}

input[type="number"],
select {
  padding: 0.375rem 0.5rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
}
</style>
