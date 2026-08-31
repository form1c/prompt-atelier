<script setup>
import { computed, onMounted, onUnmounted, ref, watch, useTemplateRef } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { t } from '@/i18n'
import { put, del as remove, post } from '@/api/client'
import {
  detail, loadPrompt, forgetPrompt, toggleFavorite,
  rememberValues, recallValues,
  rememberWorkbench, recallWorkbench, forgetWorkbench
} from '@/state/prompt'
import { notify } from '@/state/notices'
import { render, renderMarked, measure } from '@/util/rendering'
import { pieces } from '@/util/preview'
import { VISIBILITIES, STATUSES } from '@/util/draft'
import { copyText } from '@/util/clipboard'
import { formatTime, exactTime } from '@/util/time'
import AppShell from '@/components/AppShell.vue'
import VariableForm from '@/components/VariableForm.vue'
import KeywordChips from '@/components/KeywordChips.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'
import Icon from '@/components/Icon.vue'

// S2 — the prompt in use (Requirements 11.4), and the most important screen
// in the application.
//
// Two columns: input on the left, result on the right. The connection between
// what one does and what one gets is then visible without being explained,
// and the preview — the thing people actually came for — is the larger half.
//
// The preview renders **here**, with the same pipeline the server uses
// (NFA-14, R-01). Asking the server on every keystroke would be a round trip
// per character; the two implementations are held together by the 34 vectors
// both of them are tested against.

// FA-304: the preview follows the last input within 150 ms.
//
// **The wait is 120, not 150, and the difference is the whole requirement.**
// It stood at 150 — the deadline itself — so the preview could never arrive
// before it: measured in a browser at 5.000 prompts (TF-703) the 95th
// percentile was 151.6 ms, with a distribution so tight around 151 that it
// could only be the timer plus about a millisecond of rendering. The promise
// was unmeetable by construction, and nothing had noticed, because until AP-17
// nothing had timed it.
//
// 120 ms leaves room for the rendering and still coalesces: somebody typing
// 500 characters a minute has 120 ms between keystrokes, so a burst is still
// one update rather than one per key.
const PREVIEW_DELAY = 120

const route = useRoute()
const router = useRouter()

const values = ref({})
const active = ref([])
// The text the browser refused to put into the clipboard, or null. It holds
// the text rather than a flag because there are two ways to copy from here and
// the field has to show the one that was actually tried (TF-416).
const manual = ref(null)
// Two results from the same input, and the split is deliberate.
//
// `preview` is the finished prompt: what gets copied, counted and blocked on.
// `display` is the same prompt laid out around the placeholders of the
// variables nobody has filled in yet (8.3.1) — the shape it will have. Only
// the right-hand column reads it, and nothing decides anything on it.
const preview = ref({ text: '', unknownKeys: [], missingRequired: [], complete: true })
const display = ref({ text: '', marks: [] })
const menuOpen = ref(false)
const manualField = useTemplateRef('manualField')

// FA-307 — the workbench.
//
// `copy_raw` hands over the prompt with its placeholders standing, and the
// reason somebody wants that is almost always the same: to work on the text
// before using it. Until now that meant copying out, opening an editor,
// changing two words and copying back. The field below is that editor, in
// place.
//
// **It is not the prompt editor.** Nothing here is saved to the prompt — this
// is one person adapting one use, and S3 remains the place where a change is
// meant to last. What keeps the two apart is that this text is never sent
// anywhere: `copy_raw` copies it, and that is all it does.
//
// It follows the source until somebody types in it. After that it is theirs,
// and the way back is a button rather than a surprise.
const workbench = ref('')
const workbenchTouched = ref(false)

let previewTimer = null

const prompt = computed(() => detail.prompt)
const may = computed(() => prompt.value?.permissions ?? {})

// The keywords that can be switched: the catalogue of the workspace, plus
// any of the prompt's own that are not in it (TF-426).
const offered = computed(() => {
  const catalogue = detail.keywords
  const known = new Set(catalogue.map((keyword) => keyword.id))
  const attached = (prompt.value?.keywords ?? []).filter((keyword) => !known.has(keyword.id))

  return [...catalogue, ...attached]
})

// Those from a workspace the reader is not in cannot be switched off — the
// server renders them because they belong to the prompt, and dropping them
// here would make the preview disagree with what a copy would contain.
const locked = computed(() => {
  const known = new Set(detail.keywords.map((keyword) => keyword.id))
  return (prompt.value?.keywords ?? [])
    .filter((keyword) => !known.has(keyword.id))
    .map((keyword) => keyword.id)
})

const counts = computed(() => measure(preview.value.text))

// The preview, cut into what came from the text and what came from a variable
// (8.3.1). The placeholders among them are shown, never copied: `counts`
// above measures `preview.text`, and so does everything that copies.
const shown = computed(() => pieces(display.value.text, display.value.marks, preview.value.missingRequired))

const hasSlots = computed(() => shown.value.some((piece) => piece.kind !== 'plain' && piece.kind !== 'value'))

onMounted(async () => {
  window.addEventListener('keydown', onShortcut)
  await open(route.params.id)
})

onUnmounted(() => {
  clearTimeout(previewTimer)
  window.removeEventListener('keydown', onShortcut)
  forgetPrompt()
})

// The same screen can be reached again with another identifier — from the
// library, or by editing the address.
watch(() => route.params.id, (id) => { if (id) open(id) })

async function open (id) {
  await loadPrompt(id)
  if (!prompt.value) return

  // FA-306: what was typed last time, and the defaults for everything else.
  const remembered = recallValues(prompt.value.id)
  values.value = Object.fromEntries((prompt.value.variables ?? []).map((variable) => [
    variable.key,
    remembered[variable.key] ?? variable.default_value ?? ''
  ]))

  active.value = (prompt.value.keywords ?? []).map((keyword) => keyword.id)
  manual.value = null

  // Remembered per prompt, like the values above and for the same reason:
  // somebody who steps into the editor and comes back should not find their
  // adaptation gone.
  const kept = recallWorkbench(prompt.value.id)
  workbench.value = kept ?? ''
  workbenchTouched.value = kept !== null

  refreshPreview()
}

function updateValue (key, value) {
  values.value = { ...values.value, [key]: value }
  rememberValues(prompt.value.id, values.value)
  schedulePreview()
}

function toggleKeyword (id) {
  active.value = active.value.includes(id)
    ? active.value.filter((entry) => entry !== id)
    : [...active.value, id]
  schedulePreview()
}

function schedulePreview () {
  clearTimeout(previewTimer)
  previewTimer = setTimeout(refreshPreview, PREVIEW_DELAY)
}

function refreshPreview () {
  if (!prompt.value) return

  const input = {
    body: prompt.value.body,
    variables: (prompt.value.variables ?? []).map((variable) => ({
      ...variable,
      value: values.value[variable.key]
    })),
    keywords: activeKeywords()
  }

  preview.value = render(input)
  display.value = renderMarked({ ...input, showPlaceholders: true })
}

function activeKeywords () {
  return offered.value.filter((keyword) => active.value.includes(keyword.id))
}

// FA-305. Blocked while a required value is missing (8.3) — the preview is
// still shown, because seeing what is missing is what makes it obvious.
async function copy () {
  // The pause after the last keystroke may still be running, so the preview
  // is brought up to date **before** anything is decided on it. The other way
  // round, typing the last required value and pressing Strg+Enter straight
  // away did nothing at all: the check still saw the value as missing, and
  // the shortcut answered with silence. Found in the browser, where that is
  // exactly how the workflow is performed.
  clearTimeout(previewTimer)
  refreshPreview()

  if (!preview.value.complete) return

  await handOver(preview.value.text, t('prompt.copied'))
}

// FA-305, second way: **exactly the text of the preview**, with the
// placeholders of whatever is not filled in yet left standing. Never blocked —
// a missing mandatory value is the normal state for this one, not a reason to
// refuse.
//
// It copies `display`, not `preview`: the two differ in precisely the thing
// the label names. `preview` is the finished prompt and leaves an unfilled
// variable out; `display` puts its own `{{key}}` back in, which is what the
// right-hand column shows and what somebody wants who is going to finish the
// prompt somewhere else.
//
// **It used to copy the workbench**, and that was the wrong text under the
// wrong button: the field is further down the page, it is remembered per
// prompt, and somebody could be pasting an edit they made two days ago while
// looking at the preview. The workbench now has a button of its own, directly
// under it.
// **What it hands over is the prompt with every placeholder standing**, and
// not the preview.
//
// It used to copy the preview: entered values substituted, empty fields left
// as `{{key}}`. That is a defensible thing to want — get the text out even
// though a required field is empty — but it is not what the button says, and
// the label is what people go by. Reported from NT-7: somebody fills the
// fields in, presses "copy with placeholders", and gets a text with no
// placeholders in it.
//
// So the button now does what it is called. The other reading has not gone
// away — that text is one press further along, on the button beside the
// preview, which copies the finished prompt.
async function copyRaw () {
  await handOver(rawSource(), t('prompt.copied_raw'))
}

// The prompt with **every** placeholder standing, whatever is filled in — the
// starting point of the workbench below.
//
// The same pipeline, with no variable table: every {{key}} is then a reference
// to nothing and stays exactly as it is (8.2), and keywords and normalisation
// behave as they do everywhere else. Two ways of assembling the same prompt
// would be a second place for the two implementations to drift (R-01).
function rawSource () {
  return render({
    body: prompt.value?.body ?? '',
    variables: [],
    keywords: activeKeywords()
  }).text
}

// FA-307. Copies **what stands in the field**, and stands next to it — so
// there is no button on this screen that copies a text the eye is not on.
async function copyWorkbench () {
  await handOver(workbenchText(), t('prompt.copied_workbench'))
}

function workbenchText () {
  return workbenchTouched.value ? workbench.value : rawSource()
}

function editWorkbench (text) {
  workbench.value = text
  workbenchTouched.value = true
  if (prompt.value) rememberWorkbench(prompt.value.id, text)
}

// The way back. Shown only while there is something to go back from, so the
// screen does not carry a control that would do nothing.
function resetWorkbench () {
  workbench.value = ''
  workbenchTouched.value = false
  if (prompt.value) forgetWorkbench(prompt.value.id)
}

// The message comes in ready-made: both keys then stand in this file as
// `t('…')`, which is the shape TF-713 looks for when it checks that no text
// in the table is left unused.
async function handOver (text, message) {
  if (await copyText(text)) {
    manual.value = null
    notify(message)
    return
  }

  // TF-416: the browser refused. The text is put where it can be selected —
  // that is something no setting can take away.
  manual.value = text
  await new Promise((resolve) => setTimeout(resolve, 0))
  manualField.value?.select()
}

// 11.6: Strg+Enter copies, and it works anywhere on the screen — the hands
// are in the form, not on the button. With Umschalt it copies the other one,
// which is the same key for the same act and one modifier for the variant.
function onShortcut (event) {
  if (event.key !== 'Enter' || !(event.ctrlKey || event.metaKey)) return

  event.preventDefault()
  if (event.shiftKey) copyRaw()
  else copy()
}

async function star () {
  await toggleFavorite(prompt.value)
}

async function change (field, event) {
  const value = event.target.value
  if (value === prompt.value[field]) return

  await put(`/prompts/${prompt.value.id}`, { body: { [field]: value } })
  await loadPrompt(prompt.value.id)
  notify(t('prompt.saved'))
}

async function undo () {
  menuOpen.value = false
  await post(`/prompts/${prompt.value.id}/undo`)
  await open(prompt.value.id)
  notify(t('prompt.undone'))
}

async function trash () {
  menuOpen.value = false
  await remove(`/prompts/${prompt.value.id}`)
  notify(t('prompt.deleted'))
  await router.push({ name: 'library' })
}

// What a coloured piece of the preview is. On the placeholders this is the
// only place that says they are a drawing and not text — the accessible
// message about a missing value sits on the form field, where the correction
// is made (VariableForm, `prompt.required_missing`).
//
// Written out rather than picking the key by expression, so that each one
// stands in the file as `t('…')`. The check that every text in the table is
// really used reads the sources for exactly that shape, and a key assembled
// at runtime is a text it would report as unused (TF-713).
function slotHint (piece) {
  if (piece.kind === 'value') return t('prompt.slot_value', { key: piece.key })
  if (piece.kind === 'missing') return t('prompt.slot_missing', { key: piece.key })

  return t('prompt.slot_empty', { key: piece.key })
}

// A screen that does not exist yet is not offered — the same rule as in the
// navigation and in the empty states. AP-12 and AP-14 only have to register
// their route.
const has = (name) => router.hasRoute(name)
</script>

<template>
  <AppShell>
    <ErrorState v-if="detail.error" :error="detail.error" />
    <LoadingState v-else-if="detail.loading" :rows="6" />

    <article v-else-if="prompt" class="prompt">
      <header class="prompt__head">
        <RouterLink :to="{ name: 'library' }" class="prompt__back">
          <Icon name="arrow-left" /> {{ t('prompt.back') }}
        </RouterLink>

        <h1>{{ prompt.title }}</h1>

        <button
          type="button"
          class="prompt__star"
          :aria-pressed="prompt.favorite"
          :aria-label="prompt.favorite ? t('actions.favorite_remove') : t('actions.favorite_add')"
          @click="star"
        >
          <Icon :name="prompt.favorite ? 'star-fill' : 'star'" />
        </button>

        <div class="menu menu--end">
          <button
            type="button"
            class="button button--quiet"
            :aria-expanded="menuOpen"
            @click="menuOpen = !menuOpen"
          >
            <Icon name="three-dots" /> {{ t('prompt.menu') }}
          </button>

          <!-- 11.4: entries the reader is not allowed are left out, not
               greyed out. A permanently disabled control explains nothing. -->
          <ul v-if="menuOpen" class="menu__list menu__list--end">
            <li v-if="may.update && has('prompt-edit')">
              <RouterLink class="menu__item" :to="{ name: 'prompt-edit', params: { id: prompt.id } }">
                <Icon name="pencil" /> {{ t('prompt.edit') }}
              </RouterLink>
            </li>
            <li v-if="may.duplicate && has('prompt-duplicate')">
              <RouterLink class="menu__item" :to="{ name: 'prompt-duplicate', params: { id: prompt.id } }">
                <Icon name="files" /> {{ t('prompt.duplicate') }}
              </RouterLink>
            </li>
            <li v-if="may.move && has('prompt-move')">
              <RouterLink class="menu__item" :to="{ name: 'prompt-move', params: { id: prompt.id } }">
                <Icon name="folder-symlink" /> {{ t('prompt.move') }}
              </RouterLink>
            </li>
            <li v-if="may.update && prompt.revision_count > 0">
              <button type="button" class="menu__item" @click="undo">
                <Icon name="arrow-counterclockwise" /> {{ t('prompt.undo') }}
              </button>
            </li>
            <li v-if="may.delete">
              <button type="button" class="menu__item" @click="trash">
                <Icon name="trash" /> {{ t('prompt.delete') }}
              </button>
            </li>
          </ul>
        </div>
      </header>

      <p v-if="prompt.description" class="prompt__description">{{ prompt.description }}</p>

      <p class="prompt__meta">
        <span v-if="prompt.tags.length" class="prompt__tags">{{ prompt.tags.join(' · ') }}</span>

        <label v-if="may.visibility" class="prompt__select">
          <span class="visually-hidden">{{ t('prompt.visibility') }}</span>
          <select :value="prompt.visibility" @change="change('visibility', $event)">
            <option v-for="entry in VISIBILITIES" :key="entry.value" :value="entry.value">
              {{ t(entry.label) }}
            </option>
          </select>
        </label>

        <label v-if="may.update" class="prompt__select">
          <span class="visually-hidden">{{ t('prompt.status') }}</span>
          <select :value="prompt.status" @change="change('status', $event)">
            <option v-for="entry in STATUSES" :key="entry.value" :value="entry.value">
              {{ t(entry.label) }}
            </option>
          </select>
        </label>

        <span :title="exactTime(prompt.updated_at)">{{ formatTime(prompt.updated_at) }}</span>
      </p>

      <div class="prompt__columns">
        <section class="prompt__fill" aria-labelledby="fill-in">
          <h2 id="fill-in" class="prompt__column-heading">{{ t('prompt.fill_in') }}</h2>

          <VariableForm
            :variables="prompt.variables ?? []"
            :values="values"
            :missing="preview.missingRequired"
            @update="updateValue"
          />

          <KeywordChips
            :keywords="offered"
            :active="active"
            :locked="locked"
            @toggle="toggleKeyword"
          />
        </section>

        <section class="prompt__preview" aria-labelledby="preview">
          <h2 id="preview" class="prompt__column-heading">{{ t('prompt.preview') }}</h2>

          <!-- Text, never markup (SEC-10). A prompt is content, and this is
               where content is largest on the screen. Which is why the pieces
               are elements around plain text and never a string of HTML: a
               value someone typed must not be able to become a tag.

               Written on one line on purpose. Inside `pre` the compiler keeps
               template whitespace exactly as it stands, so a line break
               between these tags would be a line break in the preview. -->
          <pre class="prompt__text" data-test="preview"><template v-for="(piece, index) in shown" :key="index"><span v-if="piece.kind === 'plain'">{{ piece.text }}</span><span v-else :class="`slot slot--${piece.kind}`" :title="slotHint(piece)">{{ piece.text }}</span></template></pre>

          <p v-if="hasSlots" class="prompt__note">{{ t('prompt.slots_note') }}</p>

          <p v-if="preview.unknownKeys.length" class="prompt__warning">
            <Icon name="exclamation-triangle" />
            {{ t('prompt.unknown_keys', { keys: preview.unknownKeys.join(', ') }) }}
          </p>

          <!-- A placeholder that is not one. Distinct from the warning above:
               an unknown key is a variable nobody described, this one was
               never a variable at all — and before AP-23 it said nothing. -->
          <p v-if="preview.rejectedKeys?.length" class="prompt__warning" data-test="rejected-keys">
            <Icon name="exclamation-triangle" />
            {{ t('prompt.rejected_keys', { keys: preview.rejectedKeys.join(', ') }) }}
          </p>

          <div class="prompt__footer">
            <p class="prompt__counts">
              {{ t('prompt.counts', { characters: counts.characters, words: counts.words }) }}
            </p>

            <p v-if="!preview.complete" class="prompt__blocked">{{ t('prompt.copy_blocked') }}</p>

            <div class="prompt__actions">
              <!-- FA-305: never disabled. This is the way out for whoever
                   wants to finish the prompt somewhere else, and a missing
                   mandatory value is its normal starting point. -->
              <button
                type="button"
                class="button button--quiet"
                :title="t('prompt.copy_raw_hint')"
                data-test="copy-raw"
                @click="copyRaw"
              >
                <Icon name="braces" /> {{ t('prompt.copy_raw') }}
              </button>

              <button
                type="button"
                class="button"
                :disabled="!preview.complete"
                data-test="copy"
                @click="copy"
              >
                <Icon name="clipboard" /> {{ t('prompt.copy') }}
                <span class="prompt__shortcut" aria-hidden="true">{{ t('prompt.copy_shortcut') }}</span>
              </button>
            </div>
          </div>

          <!-- TF-416: the browser refused the clipboard. Selecting and
               copying is something no setting can take away. -->
          <div v-if="manual !== null" class="prompt__manual">
            <h3>{{ t('prompt.copy_manual_title') }}</h3>
            <p>{{ t('prompt.copy_manual_hint') }}</p>
            <textarea ref="manualField" readonly rows="6" :value="manual" />
          </div>
        </section>
      </div>

      <!-- FA-307. **Outside the two columns**, so it runs the full width of
           the content area up to the sidebar.

           It used to sit inside the preview column, where it inherited its
           three fifths — a field to work in, two thirds as wide as the text
           it holds. A long prompt wrapped twice as often there as it does in
           the editor it is standing in for, and a line that wraps is a line
           whose real breaks are no longer visible. Which is exactly what this
           field is for.

           Still below the preview, and that has not changed: the preview is
           the finished prompt and stays a preview — its placeholders are
           drawn, not text (8.3.1), and an editable field cannot show that. -->
      <section class="workbench" aria-labelledby="workbench-heading">
        <div class="workbench__head">
          <h3 id="workbench-heading">{{ t('prompt.workbench_title') }}</h3>
          <button
            v-if="workbenchTouched"
            type="button"
            class="button button--quiet"
            data-test="workbench-reset"
            @click="resetWorkbench"
          >
            <Icon name="arrow-counterclockwise" /> {{ t('prompt.workbench_reset') }}
          </button>
        </div>

        <p class="workbench__hint">{{ t('prompt.workbench_hint') }}</p>

        <textarea
          class="workbench__field"
          rows="30"
          spellcheck="false"
          :aria-label="t('prompt.workbench_title')"
          :value="workbenchText()"
          data-test="workbench"
          @input="editWorkbench($event.target.value)"
        />

        <!-- Under the field, not up in the footer with the other two. A button
             copies what stands next to it; anything else asks somebody to
             remember which of three texts a given button means. -->
        <div class="workbench__actions">
          <button
            type="button"
            class="button"
            data-test="workbench-copy"
            @click="copyWorkbench"
          >
            <Icon name="clipboard" /> {{ t('prompt.workbench_copy') }}
          </button>
        </div>
      </section>
    </article>
  </AppShell>
</template>

<style scoped>
.workbench {
  margin-top: 1.5rem;
  padding-top: 1rem;
  border-top: 1px solid var(--border);
}

.workbench__head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
}

.workbench__head h3 {
  margin: 0;
  font-size: 1rem;
}

.workbench__hint {
  margin: 0.25rem 0 0.5rem;
  color: var(--muted);
  font-size: 0.875rem;
}

.workbench__actions {
  display: flex;
  justify-content: flex-end;
  margin-top: 0.75rem;
}

/* Monospace and the full width of the content area: this is the text somebody
   is about to paste somewhere, and where its lines break matters.

   `rows="30"` sets how tall it starts. The cap next to it is not a
   contradiction but the reason the thirty rows are safe: thirty rows are
   roughly 800 px, more than the whole window on a laptop, and the field would
   then push the preview and the buttons above the fold on every prompt —
   including the ones nobody wants to edit. Capped at three quarters of the
   window it stays the largest thing on the screen without being the only
   thing, and `resize: vertical` gives the last word to whoever is working. */
.workbench__field {
  width: 100%;
  max-height: 75vh;
  padding: 0.625rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  color: var(--text);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.9375rem;
  line-height: 1.5;
  resize: vertical;
}

.prompt__head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
}

.prompt__head h1 {
  margin: 0;
  font-size: 1.375rem;
}

.prompt__back {
  flex: 0 0 100%;
  margin-bottom: 0.25rem;
  color: var(--muted);
  font-size: 0.875rem;
}

.prompt__star {
  display: inline-flex;
  padding: 0.25rem;
  border: 0;
  background: none;
  color: var(--muted);
  font-size: 1.25rem;
  cursor: pointer;
}

.prompt__star[aria-pressed="true"] { color: #b8860b; }

.menu { position: relative; }
.menu--end { margin-left: auto; }

.menu__list {
  position: absolute;
  right: 0;
  z-index: 10;
  min-width: 14rem;
  margin: 0.25rem 0 0;
  padding: 0.25rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
  box-shadow: var(--shadow);
  list-style: none;
}

.menu__item {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: 100%;
  padding: 0.375rem 0.5rem;
  border: 0;
  border-radius: var(--radius);
  background: none;
  color: var(--text);
  text-align: left;
  text-decoration: none;
  cursor: pointer;
}

.menu__item:hover { background: var(--surface-sunken); }

.prompt__description {
  margin: 0.5rem 0 0.25rem;
  color: var(--muted);
}

.prompt__meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem 0.75rem;
  margin-bottom: 1.25rem;
  color: var(--muted);
  font-size: 0.875rem;
}

.prompt__select select {
  padding: 0.125rem 0.375rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
  font-size: 0.875rem;
}

.prompt__columns {
  display: grid;
  gap: 1.5rem;
  /* 11.4: the preview is the visually dominant half — it is the product. */
  grid-template-columns: minmax(0, 2fr) minmax(0, 3fr);
}

.prompt__column-heading {
  margin-bottom: 0.75rem;
  color: var(--muted);
  font-size: 0.75rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.prompt__text {
  margin: 0;
  padding: 1rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
  white-space: pre-wrap;
  word-break: break-word;
}

/* 8.3: where a variable went. The value keeps the reading flow and is only
   tinted; a gap has to be drawn, because a variable nobody filled in occupies
   no characters and there would be nothing to point at.

   Colour is not the only difference between the three (Requirements 11.6):
   filled is tinted and underlined, empty is dashed, missing is dashed and
   bold. */
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

/* The one line on the screen that says a drawn placeholder is not text. The
   tooltips on the placeholders repeat it, but a tooltip is not something one
   finds — it is something one confirms. */
.prompt__note {
  margin: 0.5rem 0 0;
  color: var(--muted);
  font-size: 0.8125rem;
}

.prompt__warning {
  display: flex;
  align-items: baseline;
  gap: 0.375rem;
  margin: 0.5rem 0 0;
  color: var(--danger);
  font-size: 0.875rem;
}

.prompt__footer {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.75rem;
  margin-top: 0.75rem;
  padding-top: 0.75rem;
  border-top: 1px solid var(--border);
}

.prompt__counts {
  margin: 0;
  color: var(--muted);
  font-size: 0.875rem;
  font-variant-numeric: tabular-nums;
}

.prompt__blocked {
  margin: 0;
  color: var(--danger);
  font-size: 0.875rem;
}

.prompt__actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  margin-left: auto;
}

.prompt__shortcut {
  margin-left: 0.5rem;
  opacity: 0.8;
  font-size: 0.8125rem;
  font-weight: 400;
}

.prompt__manual {
  margin-top: 1rem;
  padding: 0.75rem;
  border: 1px solid var(--danger);
  border-radius: var(--radius);
  background: var(--danger-surface);
}

.prompt__manual h3 { font-size: 1rem; }

.prompt__manual textarea {
  width: 100%;
  padding: 0.5rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  font: inherit;
}

/* 11.4: below the two-column threshold the columns stack, and the copy bar
   stays reachable at the bottom of the screen. */
@media (max-width: 899px) {
  .prompt__columns { grid-template-columns: minmax(0, 1fr); }

  .prompt__footer {
    position: sticky;
    bottom: 0;
    margin: 0 -1rem;
    padding: 0.75rem 1rem;
    background: var(--surface);
    box-shadow: 0 -2px 8px rgb(31 35 40 / 10%);
  }
}
</style>
