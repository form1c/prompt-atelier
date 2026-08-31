<script setup>
import { computed, onMounted, ref, watch, useTemplateRef } from 'vue'
import { t } from '@/i18n'
import { get, post, put, del as remove, ApiError } from '@/api/client'
import { session, selectedWorkspace } from '@/state/session'
import { notify } from '@/state/notices'
import { effectParts, POSITIONS } from '@/util/keyword'
import AppShell from '@/components/AppShell.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'
import EmptyState from '@/components/EmptyState.vue'
import ConfirmDialog from '@/components/ConfirmDialog.vue'
import Icon from '@/components/Icon.vue'

// S4 — the keywords of a workspace (FA-401 to FA-404, W-4).
//
// A keyword is a block of text that goes before or after a prompt (E-05).
// That is the whole of the idea, and it is also the part nobody can see from
// a form: `prepend` and `append` are two words in a select box, and the
// person choosing between them has no way to find out what they mean.
//
// So the form has a preview beside it, and it is the reason W-4 exists as a
// workflow at all: the example prompt with the text in place, updating while
// it is typed. What is drawn comes from the same pipeline the prompt screen
// renders with (`util/keyword.js`), so the example cannot show one thing and
// a real prompt do another.

const EMPTY = { name: '', description: '', text: '', position: 'prepend', sort_order: 0 }

const keywords = ref([])
const loading = ref(true)
const failure = ref(null)
const saveError = ref(null)
const working = ref(false)

// The keyword being written. `editing` holds its id when an existing one is
// open, and null while a new one is being made — the same form for both, as
// in the prompt editor.
const draft = ref({ ...EMPTY })
const editing = ref(null)
const doomed = ref(null)

const nameField = useTemplateRef('nameField')

const workspace = computed(() => selectedWorkspace())
const mayWrite = computed(() => workspace.value?.permissions?.keywords === true)

// The example the effect is shown on. A fixed sentence rather than a prompt
// from the workspace: the first keyword tends to be written in an empty
// workspace, where there would be nothing to show it on, and an example that
// changes with the contents makes the same keyword look different on two
// days.
const example = computed(() => t('keywords.example_body'))

const parts = computed(() => effectParts({ body: example.value, keyword: draft.value }))

// Whether there is anything to abandon. Without it the form would carry a
// "Abbrechen" next to an empty new keyword, which cancels nothing.
const changed = computed(() => (
  editing.value !== null || draft.value.name !== '' || draft.value.text !== ''
))

onMounted(load)

// The header can switch workspace while this screen is open, and keywords
// belong to exactly one (11.2).
watch(() => session.selectedWorkspaceId, load)

async function load () {
  if (!session.selectedWorkspaceId) return

  loading.value = true
  failure.value = null

  try {
    const payload = await get('/keywords', { params: { workspace_id: session.selectedWorkspaceId } })
    keywords.value = payload.keywords ?? []
    reset()
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    loading.value = false
  }
}

function reset () {
  draft.value = { ...EMPTY }
  editing.value = null
  saveError.value = null
}

function edit (keyword) {
  editing.value = keyword.id
  draft.value = {
    name: keyword.name ?? '',
    description: keyword.description ?? '',
    text: keyword.text ?? '',
    position: keyword.position ?? 'prepend',
    sort_order: keyword.sort_order ?? 0
  }
  saveError.value = null
  nameField.value?.focus()
}

async function save () {
  if (working.value) return

  working.value = true
  saveError.value = null

  try {
    const body = { ...draft.value, sort_order: Number(draft.value.sort_order) || 0 }
    if (editing.value === null) {
      await post('/keywords', { body: { ...body, workspace_id: session.selectedWorkspaceId } })
      notify(t('keywords.created'))
    } else {
      await put(`/keywords/${editing.value}`, { body })
      notify(t('keywords.updated'))
    }
    await load()
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    // The name is the one that collides (FA-401), so the message belongs at
    // the form and not over the list.
    saveError.value = problem
  } finally {
    working.value = false
  }
}

// FA-404 in two steps, and the server decides both. The first call carries no
// confirmation and is **meant** to be refused: the answer names the prompts
// the keyword is on, and that list is what the dialogue shows. Counting them
// here from a list the browser happens to hold would be a second answer to
// the same question.
//
// The refusal comes for every keyword, including one no prompt uses. That is
// deliberate on the server's side — deleting a keyword cannot be undone,
// there is no trash for it (11.6) — and it is why the dialogue has two
// wordings: "it is on these three prompts" and "no prompt uses it". The first
// draft here expected an unused keyword to go straight away, and its test
// passed because the stand-in server answered as the draft imagined rather
// than as the real one does. The browser test found it in the first run.
async function askDelete (keyword) {
  try {
    await remove(`/keywords/${keyword.id}`)
    await afterDelete(keyword)
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem
    if (problem.code !== 'confirmation_required') {
      failure.value = problem
      return
    }

    doomed.value = { keyword, affected: problem.details.affected_prompts ?? [] }
  }
}

async function confirmDelete () {
  if (working.value) return

  working.value = true
  const keyword = doomed.value.keyword

  try {
    await remove(`/keywords/${keyword.id}`, { body: { confirm: true } })
    await afterDelete(keyword)
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    working.value = false
    doomed.value = null
  }
}

async function afterDelete (keyword) {
  notify(t('keywords.deleted', { name: keyword.name }))
  if (editing.value === keyword.id) reset()
  await load()
}

const positionLabel = (value) => (
  value === 'append' ? t('keywords.position_append') : t('keywords.position_prepend')
)
</script>

<template>
  <AppShell>
    <h1>{{ t('keywords.title') }}</h1>
    <p class="keywords__intro">{{ t('keywords.intro') }}</p>

    <ErrorState v-if="failure" :error="failure" :on-retry="load" />
    <LoadingState v-else-if="loading" :rows="4" />

    <div v-else class="keywords">
      <section class="panel" aria-labelledby="keyword-list-heading">
        <h2 id="keyword-list-heading">
          {{ t('keywords.list_heading', { name: workspace?.name ?? '' }) }}
        </h2>

        <ul v-if="keywords.length" class="entries">
          <li v-for="keyword in keywords" :key="keyword.id" class="entry">
            <span class="entry__name">{{ keyword.name }}</span>
            <span class="entry__detail">
              {{ positionLabel(keyword.position) }} · {{ t('keywords.order', { order: keyword.sort_order }) }}
              <template v-if="keyword.description"> · {{ keyword.description }}</template>
            </span>

            <span v-if="mayWrite" class="entry__actions">
              <button
                type="button"
                class="button button--quiet"
                :aria-label="t('keywords.edit_one', { name: keyword.name })"
                @click="edit(keyword)"
              >
                <Icon name="pencil" /> {{ t('keywords.edit') }}
              </button>
              <button
                type="button"
                class="button button--quiet"
                :aria-label="t('keywords.delete_one', { name: keyword.name })"
                @click="askDelete(keyword)"
              >
                <Icon name="trash" /> {{ t('keywords.delete') }}
              </button>
            </span>
          </li>
        </ul>

        <EmptyState
          v-else
          :title="t('keywords.empty_title')"
          :description="t('keywords.empty_hint')"
        >
          <!-- 11.6: never an empty area. A viewer cannot write one, so the
               offer for them is the sentence, not a button that refuses. -->
          <button v-if="mayWrite" type="button" class="button" @click="nameField?.focus()">
            {{ t('keywords.empty_create') }}
          </button>
        </EmptyState>
      </section>

      <div v-if="mayWrite" class="keywords__editor">
        <section class="panel" aria-labelledby="keyword-form-heading">
          <h2 id="keyword-form-heading">
            {{ editing === null ? t('keywords.new_heading') : t('keywords.edit_heading') }}
          </h2>

          <p v-if="saveError" class="alert" role="alert">{{ saveError.message }}</p>

          <form @submit.prevent="save">
            <label class="field">
              <span>{{ t('keywords.field_name') }}</span>
              <input ref="nameField" v-model="draft.name" type="text" maxlength="40">
            </label>

            <label class="field">
              <span>{{ t('keywords.field_description') }}</span>
              <input v-model="draft.description" type="text">
            </label>

            <div class="field">
              <label>
                <span>{{ t('keywords.field_text') }}</span>
                <textarea v-model="draft.text" rows="4" aria-describedby="keyword-text-hint" />
              </label>
              <span id="keyword-text-hint" class="hint">{{ t('keywords.text_hint') }}</span>
            </div>

            <div class="keywords__row">
              <label class="field">
                <span>{{ t('keywords.field_position') }}</span>
                <select v-model="draft.position">
                  <option v-for="entry in POSITIONS" :key="entry.value" :value="entry.value">
                    {{ t(entry.label) }}
                  </option>
                </select>
              </label>

              <div class="field">
                <label>
                  <span>{{ t('keywords.field_order') }}</span>
                  <input v-model="draft.sort_order" type="number" aria-describedby="keyword-order-hint">
                </label>
                <span id="keyword-order-hint" class="hint">{{ t('keywords.order_hint') }}</span>
              </div>
            </div>

            <div class="keywords__actions">
              <button
                v-if="changed"
                type="button"
                class="button button--quiet"
                @click="reset"
              >
                {{ t('keywords.cancel') }}
              </button>
              <button type="submit" class="button" :disabled="working" data-test="save-keyword">
                <Icon name="check-lg" />
                {{ editing === null ? t('keywords.create') : t('keywords.update') }}
              </button>
            </div>
          </form>
        </section>

        <!-- W-4: the effect, on an example, while it is being written. The
             heading says which part is which, because the colours alone would
             leave a reader without them nothing (11.6). -->
        <section class="panel" aria-labelledby="keyword-effect-heading">
          <h2 id="keyword-effect-heading">{{ t('keywords.effect_heading') }}</h2>
          <p class="hint">{{ t('keywords.effect_hint') }}</p>

          <pre class="effect" data-test="effect"><span
            v-for="(part, index) in parts"
            :key="index"
            :class="part.kind === 'keyword' ? 'effect__keyword' : 'effect__prompt'"
          >{{ index === 0 ? part.text : '\n\n' + part.text }}</span></pre>

          <p class="effect__legend">
            <span class="effect__swatch effect__swatch--keyword" aria-hidden="true" />
            {{ t('keywords.effect_legend_keyword') }}
            <span class="effect__swatch effect__swatch--prompt" aria-hidden="true" />
            {{ t('keywords.effect_legend_prompt') }}
          </p>
        </section>
      </div>
    </div>

    <!-- FA-404: the prompts by name, not just their number. Whoever is about
         to delete a keyword has to be able to tell whether those are the ones
         they meant. -->
    <ConfirmDialog
      v-if="doomed"
      :title="t('keywords.delete_title', { name: doomed.keyword.name })"
      :description="doomed.affected.length
        ? t('keywords.delete_hint', { count: doomed.affected.length })
        : t('keywords.delete_hint_none')"
      :confirm-label="t('keywords.delete_confirm')"
      :danger="true"
      :busy="working"
      @confirm="confirmDelete"
      @cancel="doomed = null"
    >
      <ul v-if="doomed.affected.length" class="entries">
        <li v-for="entry in doomed.affected" :key="entry.id" class="entry">
          <span class="entry__name">{{ entry.title }}</span>
        </li>
      </ul>
    </ConfirmDialog>
  </AppShell>
</template>

<style scoped>
.keywords__intro {
  max-width: 46rem;
  color: var(--muted);
}

.keywords {
  display: grid;
  gap: var(--gap);
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  align-items: start;
}

/* The form and its preview belong together and stay together: the preview is
   the answer to what the form asks, and putting a column between them would
   make it a separate thing to look up. */
.keywords__editor {
  display: contents;
}

.keywords__row {
  display: grid;
  gap: 0 0.75rem;
  grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr));
}

.keywords__actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
}

.keywords select,
.keywords textarea,
.keywords input[type="number"] {
  width: 100%;
  padding: 0.5rem 0.625rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
}

.effect {
  margin: 0 0 0.5rem;
  padding: 0.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface-sunken);
  font: inherit;
  white-space: pre-wrap;
  overflow-wrap: break-word;
}

/* Two carriers, not one: the keyword's own text is on a tinted ground **and**
   underlined, so the difference survives a screen without colour (11.6). */
.effect__keyword {
  background: var(--accent-surface);
  color: var(--accent);
  text-decoration: underline;
  text-decoration-style: dotted;
}

.effect__prompt { color: var(--text); }

.effect__legend {
  display: flex;
  align-items: center;
  gap: 0.375rem;
  margin: 0;
  color: var(--muted);
  font-size: 0.8125rem;
}

.effect__swatch {
  display: inline-block;
  width: 0.75rem;
  height: 0.75rem;
  border: 1px solid var(--border-strong);
  border-radius: 2px;
}

.effect__swatch--keyword { background: var(--accent-surface); }
.effect__swatch--prompt { background: var(--surface); }

.effect__legend .effect__swatch:not(:first-child) { margin-left: 0.75rem; }

@media (max-width: 899px) {
  .keywords { grid-template-columns: minmax(0, 1fr); }
}
</style>
