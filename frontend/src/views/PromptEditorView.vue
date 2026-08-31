<script setup>
import { computed, onMounted, onUnmounted, ref, watch, nextTick, useTemplateRef } from 'vue'
import { useRoute, useRouter, onBeforeRouteLeave } from 'vue-router'
import { t } from '@/i18n'
import { get, post, put, ApiError } from '@/api/client'
import { session } from '@/state/session'
import { notify } from '@/state/notices'
import { renderMarked } from '@/util/rendering'
import { pieces } from '@/util/preview'
import {
  emptyDraft, draftFrom, syncVariables, moveVariable, payloadOf, changed, withDefaults, addTag,
  VISIBILITIES, STATUSES
} from '@/util/draft'
import AppShell from '@/components/AppShell.vue'
import VariableEditor from '@/components/VariableEditor.vue'
import TagEditor from '@/components/TagEditor.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'
import Icon from '@/components/Icon.vue'

// S3 — the editor (Requirements 11.5).
//
// One screen for both cases: a new prompt and an existing one. They differ in
// where the draft comes from and which verb saves it, and in nothing else. Two
// screens would be two places to change every time a field is added, and the
// second one would be the one that gets forgotten.
//
// Variables are never added by hand. They follow from the text (FA-301), and
// what the editor offers is what each one *is* (FA-302) — the mechanics of
// that are in util/draft.js, where they can be decided without a browser.

const route = useRoute()
const router = useRouter()

const draft = ref(emptyDraft())
const original = ref(emptyDraft())
const loading = ref(false)
const saving = ref(false)
// Two of them, not one. A prompt that cannot be loaded takes the whole
// screen; a save the server refused leaves the draft where it is and puts the
// reason above it. Telling the two apart by `fields` would not work — an empty
// field list is the normal shape of an error, and `{}` is truthy.
const loadError = ref(null)
const saveError = ref(null)
// Per-field messages from the server (15.2). The browser does not repeat the
// server's validation — it would be a second set of rules, and the second one
// is the one nobody tests (SEC-06).
const problems = ref({})
const pending = ref(null)
const titleField = useTemplateRef('titleField')

let leaveConfirmed = false

const editing = computed(() => Boolean(route.params.id))
const dirty = computed(() => changed(draft.value, original.value))

// The preview of 11.5: the prompt with the default values standing in for what
// the reader will type later. Variables without one show their placeholder,
// exactly as on the reader's screen (8.3.1) — one convention for both, so
// nobody has to learn a second.
const preview = computed(() => renderMarked({
  body: draft.value.body,
  variables: withDefaults(draft.value),
  keywords: [],
  showPlaceholders: true
}))

const shown = computed(() => pieces(preview.value.text, preview.value.marks, preview.value.missingRequired))

const copy = (value) => JSON.parse(JSON.stringify(value))

onMounted(async () => {
  window.addEventListener('keydown', onShortcut)
  window.addEventListener('beforeunload', onUnload)
  await open()
})

onUnmounted(() => {
  window.removeEventListener('keydown', onShortcut)
  window.removeEventListener('beforeunload', onUnload)
})

watch(() => route.fullPath, () => open())

// The set of variables follows the text on every keystroke — there is no
// separate step to declare one (FA-301, TF-351).
watch(() => draft.value.body, (body) => {
  draft.value.variables = syncVariables(body, draft.value.variables)
})

async function open () {
  loadError.value = null
  saveError.value = null
  problems.value = {}
  leaveConfirmed = false

  if (!editing.value) {
    // The library offers "create «term» as a new prompt" when a search found
    // nothing; the term arrives here as the title.
    draft.value = emptyDraft({ title: String(route.query.title ?? '') })
    original.value = copy(draft.value)
    await focusTitle()
    return
  }

  loading.value = true
  try {
    const payload = await get(`/prompts/${route.params.id}`)
    draft.value = draftFrom(payload.prompt)
    original.value = copy(draft.value)
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    loadError.value = problem
  } finally {
    loading.value = false
  }

  // **After** the loading state is cleared, never inside the try above: the
  // form is `v-else` to it, so at that point there is no field to put the
  // focus on and the attempt goes nowhere quietly.
  if (!loadError.value) await focusTitle()
}

// TF-352: after duplicating, the copy arrives here with its title selected —
// "… (Kopie)" is a placeholder, not a name, and the first thing to do is
// replace it. Typing over a selection is one keystroke; clearing a field by
// hand is several.
async function focusTitle () {
  await nextTick()
  if (!titleField.value) return

  titleField.value.focus()
  if (route.query.rename || !editing.value) titleField.value.select()
}

function updateVariable (key, changes) {
  draft.value.variables = draft.value.variables.map(
    (variable) => (variable.key === key ? { ...variable, ...changes } : variable)
  )
}

function move (key, by) {
  draft.value.variables = moveVariable(draft.value.variables, key, by)
}

async function save () {
  if (saving.value) return

  saving.value = true
  problems.value = {}
  saveError.value = null

  try {
    const body = payloadOf(draft.value)
    const payload = editing.value
      ? await put(`/prompts/${route.params.id}`, { body })
      : await post('/prompts', { body: { ...body, workspace_id: session.selectedWorkspaceId } })

    // Marked as saved **before** navigating, or the guard below would ask
    // about changes that are safely on the server.
    original.value = copy(draft.value)
    leaveConfirmed = true
    notify(t('editor.saved'))
    await router.replace({ name: 'prompt', params: { id: payload.prompt.id } })
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    saveError.value = problem
    problems.value = Object.fromEntries(
      Object.keys(problem.fields ?? {}).map((field) => [field, problem.fieldMessage(field)])
    )
  } finally {
    saving.value = false
  }
}

function leave () {
  if (editing.value) return router.push({ name: 'prompt', params: { id: route.params.id } })

  return router.push({ name: 'library' })
}

// 11.5: unsaved changes ask before the screen is left. Held here rather than
// left to the browser's own dialog, which cannot be worded and appears for
// tab-closing only.
onBeforeRouteLeave((to) => {
  if (leaveConfirmed || !dirty.value) return true

  pending.value = to.fullPath
  return false
})

async function discard () {
  const target = pending.value
  pending.value = null
  leaveConfirmed = true
  await router.push(target)
}

// What the router cannot see: closing the tab or the window. Only the
// browser's own dialog exists there, and it takes no wording of ours.
function onUnload (event) {
  if (!dirty.value) return

  event.preventDefault()
  event.returnValue = ''
}

function onShortcut (event) {
  if (event.key.toLowerCase() === 's' && (event.ctrlKey || event.metaKey)) {
    event.preventDefault()
    save()
  }
}
</script>

<template>
  <AppShell>
    <ErrorState v-if="loadError" :error="loadError" />
    <LoadingState v-else-if="loading" :rows="6" />

    <form v-else class="editor" @submit.prevent="save">
      <header class="editor__head">
        <button type="button" class="button button--quiet" @click="leave">
          <Icon name="arrow-left" /> {{ t('editor.cancel') }}
        </button>

        <h1>{{ editing ? t('editor.title_edit') : t('editor.title_new') }}</h1>

        <span v-if="dirty" class="editor__dirty">{{ t('editor.unsaved') }}</span>

        <button type="submit" class="button editor__save" :disabled="saving">
          <Icon name="check-lg" /> {{ saving ? t('editor.saving') : t('editor.save') }}
          <span class="editor__shortcut" aria-hidden="true">{{ t('editor.save_shortcut') }}</span>
        </button>
      </header>

      <p v-if="saveError" class="alert" role="alert">{{ saveError.message }}</p>

      <div class="editor__columns">
        <section class="editor__form">
          <div class="field">
            <label>
              <span>{{ t('editor.field_title') }}</span>
              <input
                ref="titleField"
                v-model="draft.title"
                type="text"
                :aria-invalid="Boolean(problems.title)"
                maxlength="200"
              >
            </label>
            <span v-if="problems.title" class="field-error">{{ t('editor.title_required') }}</span>
          </div>

          <label class="field">
            <span>{{ t('editor.field_description') }}</span>
            <input v-model="draft.description" type="text" maxlength="1000">
          </label>

          <!-- Hint and error live beside the label, never inside it: a label's
               whole content becomes the field's accessible name (NFA-11). -->
          <div class="field">
            <label>
              <span>{{ t('editor.field_body') }}</span>
              <textarea
                v-model="draft.body"
                class="editor__body"
                rows="12"
                :aria-invalid="Boolean(problems.body)"
                aria-describedby="editor-body-hint"
                data-test="body"
              />
            </label>
            <span id="editor-body-hint" class="hint">{{ t('editor.body_hint') }}</span>
            <span v-if="problems.body" class="field-error">{{ t('editor.body_required') }}</span>
          </div>

          <VariableEditor
            :variables="draft.variables"
            :errors="problems"
            @update="updateVariable"
            @move="move"
          />

          <TagEditor
            :tags="draft.tags"
            @add="(name) => (draft.tags = addTag(draft.tags, name))"
            @remove="(name) => (draft.tags = draft.tags.filter((entry) => entry !== name))"
          />

          <div class="editor__pair">
            <label class="field">
              <span>{{ t('prompt.visibility') }}</span>
              <select v-model="draft.visibility">
                <option v-for="entry in VISIBILITIES" :key="entry.value" :value="entry.value">
                  {{ t(entry.label) }}
                </option>
              </select>
            </label>

            <label class="field">
              <span>{{ t('prompt.status') }}</span>
              <select v-model="draft.status">
                <option v-for="entry in STATUSES" :key="entry.value" :value="entry.value">
                  {{ t(entry.label) }}
                </option>
              </select>
            </label>
          </div>

          <div class="field">
            <label>
              <span>{{ t('editor.field_model_hint') }}</span>
              <input
                v-model="draft.model_hint"
                type="text"
                maxlength="200"
                aria-describedby="editor-model-hint"
              >
            </label>
            <span id="editor-model-hint" class="hint">{{ t('editor.model_hint_hint') }}</span>
          </div>
        </section>

        <section class="editor__preview" aria-labelledby="editor-preview">
          <h2 id="editor-preview" class="editor__column-heading">{{ t('editor.preview') }}</h2>

          <!-- Same rendering as the reader's screen, on one line for the same
               reason: inside `pre` the compiler keeps template whitespace. -->
          <pre class="editor__text" data-test="preview"><template v-for="(piece, index) in shown" :key="index"><span v-if="piece.kind === 'plain'">{{ piece.text }}</span><span v-else :class="`slot slot--${piece.kind}`">{{ piece.text }}</span></template></pre>

          <!-- The screen where this belongs most: somebody is writing the
               prompt right now. `{{2fa}}` and `{{mi variable}}` are not
               variables, get no field, and before AP-23 said nothing at all —
               the author found out when they pasted the result into a model. -->
          <p v-if="preview.rejectedKeys.length" class="editor__warning" data-test="rejected-keys">
            <Icon name="exclamation-triangle" />
            {{ t('editor.rejected_keys', { keys: preview.rejectedKeys.join(', ') }) }}
          </p>

          <p class="editor__note">{{ t('editor.preview_hint') }}</p>
        </section>
      </div>
    </form>

    <!-- 11.5: the way out of a screen with unsaved work. Worded here rather
         than left to the browser, which offers a sentence nobody chose. -->
    <div v-if="pending" class="leave" role="dialog" aria-modal="true" aria-labelledby="leave-title">
      <div class="leave__box">
        <h2 id="leave-title">{{ t('editor.leave_title') }}</h2>
        <p>{{ t('editor.leave_hint') }}</p>
        <div class="leave__actions">
          <button type="button" class="button button--quiet" @click="discard">
            {{ t('editor.leave_discard') }}
          </button>
          <button type="button" class="button" @click="pending = null">
            {{ t('editor.leave_stay') }}
          </button>
        </div>
      </div>
    </div>
  </AppShell>
</template>

<style scoped>
.editor__head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 1rem;
}

.editor__head h1 {
  margin: 0;
  font-size: 1.375rem;
}

.editor__dirty {
  color: var(--muted);
  font-size: 0.875rem;
}

.editor__save {
  margin-left: auto;
}

.editor__shortcut {
  margin-left: 0.5rem;
  opacity: 0.8;
  font-size: 0.8125rem;
  font-weight: 400;
}

.editor__columns {
  display: grid;
  gap: 1.5rem;
  /* The mirror image of the reader's screen (11.4): there the result is the
     larger half, here the text being written is. */
  grid-template-columns: minmax(0, 3fr) minmax(0, 2fr);
}

.editor__column-heading {
  margin-bottom: 0.75rem;
  color: var(--muted);
  font-size: 0.75rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.editor__form input,
.editor__form select,
.editor__form textarea {
  width: 100%;
  padding: 0.5rem 0.625rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
}

.editor__body {
  font-family: ui-monospace, "Cascadia Code", "Source Code Pro", Menlo, Consolas, monospace;
  resize: vertical;
}

.editor__pair {
  display: grid;
  gap: 0.75rem;
  grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr));
}

.editor__preview {
  position: sticky;
  top: 1rem;
  align-self: start;
}

.editor__text {
  margin: 0;
  padding: 1rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
  white-space: pre-wrap;
  word-break: break-word;
}

.editor__note {
  margin: 0.5rem 0 0;
  color: var(--muted);
  font-size: 0.8125rem;
}

.editor__warning {
  display: flex;
  align-items: baseline;
  gap: 0.375rem;
  margin: 0.5rem 0 0;
  color: var(--danger);
  font-size: 0.875rem;
}

/* The same three states as on the reader's screen (8.3.1). Repeated rather
   than shared because both are scoped styles; the values come from the same
   custom properties, so they cannot drift apart in colour. */
.slot {
  padding: 0 0.125rem;
  border-radius: 3px;
}

.slot--value {
  background: var(--accent-surface);
  box-shadow: inset 0 -1px 0 var(--accent);
}

.slot--empty,
.slot--missing {
  padding: 0 0.1875rem;
  border: 1px dashed;
  font-size: 0.9375em;
}

.slot--empty {
  border-color: var(--border-strong);
  background: var(--surface-sunken);
  color: var(--muted);
}

.slot--missing {
  border-color: var(--danger);
  background: var(--danger-surface);
  color: var(--danger);
  font-weight: 600;
}

.leave {
  position: fixed;
  inset: 0;
  z-index: 20;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1rem;
  background: rgb(31 35 40 / 45%);
}

.leave__box {
  max-width: 26rem;
  padding: 1.25rem;
  border-radius: var(--radius);
  background: var(--surface);
  box-shadow: var(--shadow);
}

.leave__actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
}

@media (max-width: 899px) {
  .editor__columns { grid-template-columns: minmax(0, 1fr); }

  .editor__preview { position: static; }
}
</style>
