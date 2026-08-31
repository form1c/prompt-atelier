<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { t } from '@/i18n'
import { post, ApiError } from '@/api/client'
import { session, selectedWorkspace } from '@/state/session'
import { notify } from '@/state/notices'
import { jsonDocument, download } from '@/util/download'
import AppShell from '@/components/AppShell.vue'
import ErrorState from '@/components/ErrorState.vue'
import Icon from '@/components/Icon.vue'

// S10 — import and export (FA-801 to FA-804, W-8).
//
// The rule this screen is built around is one sentence of W-8: "Kein Import
// ohne vorherige Vorschau. Ein Import, der stillschweigend 200 Prompts
// überschreibt, ist ein Datenverlustereignis."
//
// So the writing button does not exist until a preview has been fetched, and
// the preview is not something this screen decides — it comes from the server,
// which runs the very same plan again when the import is executed and refuses
// a decision it did not offer. The screen cannot skip the step even by
// accident, because there is nothing to send before it.

const busy = ref(false)
const failure = ref(null)

const format = ref('json')
const preview = ref(null)
const report = ref(null)
const decisions = ref({})
const keywordDecisions = ref({})
const fileName = ref('')
const content = ref('')

const workspace = computed(() => selectedWorkspace())
const mayExport = computed(() => workspace.value?.permissions?.export === true)
const mayImport = computed(() => workspace.value?.permissions?.import === true)

// Written out rather than picked from a table by key. The check that every
// text in de.json is really used reads the sources for the literal shape
// `t('…')`, and a key assembled at runtime is a text it reports as unused
// (TF-713) — the same reason the preview's slot hints are spelled out.
function decisionLabel (choice) {
  if (choice === 'copy') return t('transfer.decision_copy')
  if (choice === 'overwrite') return t('transfer.decision_overwrite')

  return t('transfer.decision_skip')
}

// The two counts W-8 asks the preview to show. Read off the answer rather
// than counted here — the server decided them, and a second count in the
// browser could disagree with the one the import will use.
const collisions = computed(() => (preview.value?.prompts ?? []).filter((entry) => entry.state !== 'new'))

// A keyword whose name is taken here used to appear in neither of the two
// keyword lines: not among the new ones, because it exists, and not among the
// missing ones, because the file provides it. It fell between them, and the
// definition in the file was dropped without a word. These are those.
const keywordConflicts = computed(() => preview.value?.keywords?.conflicts ?? [])

// --- deciding all of them at once (FA-802) ---------------------------------
//
// **The tedium was never the safeguard.** W-8 asks that no import happens
// without a preview, because an import that silently overwrites 200 prompts is
// a data-loss event — and the word that carries that sentence is *silently*.
// Switching 180 dropdowns one at a time leads to mechanical clicking, and
// mechanical is exactly the state in which one overlooks the single entry one
// did not want to overwrite. The summary line below replaces the effort with a
// statement: it names the consequence instead of making it laborious.
//
// It **sets**, it does not lock: every entry stays changeable afterwards, and
// the default remains "überspringen".

// Not every collision offers every choice. A title that matches several
// prompts does not offer "overwrite" at all (FA-802), and a control that
// claimed to have set it would be lying about a third of the list.
function decideAll (choice) {
  let untouched = 0

  collisions.value.forEach((entry) => {
    if (entry.decisions.includes(choice)) {
      decisions.value[entry.index] = choice
    } else {
      untouched += 1
    }
  })

  if (untouched > 0) notify(t('transfer.decided_partly', { count: untouched }))
}

// What will happen, as four numbers. Counted from the decisions in hand rather
// than from the answer, because these are the decisions the import is about to
// be sent — the preview's own counts describe the file, not the plan.
const plan = computed(() => {
  const chosen = Object.values(decisions.value)

  return {
    added: preview.value?.new_count ?? 0,
    overwrite: chosen.filter((choice) => choice === 'overwrite').length,
    copy: chosen.filter((choice) => choice === 'copy').length,
    skip: chosen.filter((choice) => choice === 'skip').length
  }
})

// **What the message used to say was not merely incomplete, it was wrong.**
// It named `created.length` alone, so a file of keywords reported "0 Prompts
// eingespielt" while a keyword had just been written, and an import that
// overwrote five prompts said the same. Both read as "nothing happened".
//
// Written out as four sentences rather than assembled from parts. The check
// that every text in the table is really used reads the sources for the
// literal shape `t('…')`, and a key put together at run time is a text it
// reports as unused (TF-713).
function importedMessage (report) {
  // Overwriting is writing. Counting only what was newly created was the
  // second half of the same mistake.
  const prompts = report.created.length + report.overwritten.length
  const keywords = report.keywords_created.length + report.keywords_overwritten.length

  if (prompts > 0 && keywords > 0) return t('transfer.imported_both', { prompts, keywords })
  if (keywords > 0) return t('transfer.imported_keywords', { count: keywords })
  if (prompts > 0) return t('transfer.imported', { count: prompts })

  // Reachable: every entry collided and every one of them was skipped. Saying
  // "0 eingespielt" there would read as a failure rather than as the outcome
  // that was asked for.
  return t('transfer.imported_nothing')
}

// Switching workspace mid-way would leave a preview belonging to a workspace
// nobody is looking at any more, and the import would write it somewhere else.
watch(() => session.selectedWorkspaceId, reset)

onMounted(reset)

function reset () {
  preview.value = null
  report.value = null
  decisions.value = {}
  keywordDecisions.value = {}
  failure.value = null
  fileName.value = ''
  content.value = ''
}

// --- export ---------------------------------------------------------------

async function runExport () {
  if (busy.value) return

  busy.value = true
  failure.value = null

  try {
    const payload = await post('/export', {
      body: { workspace_id: session.selectedWorkspaceId, format: format.value }
    })

    if (payload.format === 'markdown') handOverMarkdown(payload.files)
    else handOverJson(payload.filename, payload.package)
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    busy.value = false
  }
}

function handOverJson (name, payload) {
  download(name, jsonDocument(payload))
  notify(t('transfer.exported', { count: payload.prompts.length }))
}

// One file per prompt (17.2), so one download per prompt. Browsers ask before
// the second one, which is theirs to decide — what this screen must not do is
// pretend the format is something it is not by stuffing everything into one
// file.
function handOverMarkdown (files) {
  for (const file of files) download(file.name, file.content)
  notify(t('transfer.exported_markdown', { count: files.length }))
}

// --- import ---------------------------------------------------------------

async function chooseFile (event) {
  const file = event.target.files?.[0]
  if (!file) return

  reset()
  fileName.value = file.name
  content.value = await file.text()
  await loadPreview()
}

async function loadPreview () {
  busy.value = true
  failure.value = null

  try {
    const payload = await post('/import/preview', {
      body: { workspace_id: session.selectedWorkspaceId, content: content.value }
    })
    preview.value = payload.preview
    // Every collision starts on "überspringen". The safe answer is the
    // default, and it is the only one that cannot destroy something by
    // somebody clicking through without reading.
    decisions.value = Object.fromEntries(
      payload.preview.prompts.filter((entry) => entry.state !== 'new')
        .map((entry) => [entry.index, 'skip'])
    )
    // Same default, and here it carries more weight: a keyword has no
    // revisions behind it, so an overwrite cannot be taken back.
    keywordDecisions.value = Object.fromEntries(
      (payload.preview.keywords.conflicts ?? []).map((entry) => [entry.index, 'skip'])
    )
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    // Nothing is cleared here on purpose: `chooseFile` resets before it asks,
    // so a refused file cannot leave the previous one's preview standing. An
    // extra reset in this branch was in the first draft and a mutation probe
    // showed it could go without a single test noticing — it was guarding a
    // path that does not exist.
    failure.value = problem
  } finally {
    busy.value = false
  }
}

async function runImport () {
  if (busy.value || !preview.value) return

  busy.value = true
  failure.value = null

  try {
    const payload = await post('/import', {
      body: {
        workspace_id: session.selectedWorkspaceId,
        content: content.value,
        decisions: decisions.value,
        keyword_decisions: keywordDecisions.value
      }
    })
    report.value = payload.report
    preview.value = null
    notify(importedMessage(payload.report))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <AppShell>
    <h1>{{ t('transfer.title') }}</h1>
    <p class="transfer__intro">{{ t('transfer.intro') }}</p>

    <ErrorState v-if="failure" :error="failure" />

    <section v-if="mayExport" class="panel" aria-labelledby="export-heading">
      <h2 id="export-heading">{{ t('transfer.export_heading', { name: workspace?.name ?? '' }) }}</h2>

      <fieldset class="transfer__formats">
        <legend>{{ t('transfer.format') }}</legend>

        <label class="transfer__format">
          <input v-model="format" type="radio" name="format" value="json">
          <span>
            <strong>{{ t('transfer.format_json') }}</strong>
            {{ t('transfer.format_json_hint') }}
          </span>
        </label>

        <!-- The limitation is written where the choice is made, not in a
             footnote afterwards: whoever picks Markdown for a move has to
             learn it here, not when the timestamps are gone (FA-803). -->
        <label class="transfer__format">
          <input v-model="format" type="radio" name="format" value="markdown">
          <span>
            <strong>{{ t('transfer.format_markdown') }}</strong>
            {{ t('transfer.format_markdown_hint') }}
          </span>
        </label>
      </fieldset>

      <button type="button" class="button" :disabled="busy" data-test="export" @click="runExport">
        <Icon name="download" /> {{ t('transfer.export') }}
      </button>
    </section>

    <section v-if="mayImport" class="panel" aria-labelledby="import-heading">
      <h2 id="import-heading">{{ t('transfer.import_heading') }}</h2>

      <div class="field">
        <label>
          <span>{{ t('transfer.file') }}</span>
          <input type="file" accept=".json,.md,application/json,text/markdown"
                 aria-describedby="file-hint" data-test="file" @change="chooseFile">
        </label>
        <span id="file-hint" class="hint">{{ t('transfer.file_hint') }}</span>
      </div>

      <!-- W-8: the preview, and nothing to press before it is here. -->
      <template v-if="preview">
        <p class="transfer__counts" aria-live="polite">
          {{ t('transfer.counts', { file: fileName, added: preview.new_count, collisions: preview.collision_count }) }}
        </p>

        <p v-if="preview.keywords.to_create.length" class="hint">
          {{ t('transfer.keywords_new', { names: preview.keywords.to_create.join(', ') }) }}
        </p>
        <p v-if="preview.keywords.missing.length" class="hint">
          {{ t('transfer.keywords_missing', { names: preview.keywords.missing.join(', ') }) }}
        </p>
        <p v-if="preview.unknown_fields.length" class="hint">
          {{ t('transfer.unknown_fields', { names: preview.unknown_fields.join(', ') }) }}
        </p>

        <!-- Both texts, not a count. A keyword has no revisions behind it, so
             an overwrite is final and the decision has to be made in sight of
             what it replaces. -->
        <template v-if="keywordConflicts.length">
          <p class="hint">{{ t('transfer.keywords_conflicts') }}</p>

          <ul class="entries" data-test="keyword-conflicts">
            <li v-for="entry in keywordConflicts" :key="entry.index" class="entry entry--keyword">
              <span class="entry__name">{{ entry.name }}</span>

              <span v-if="entry.identical" class="entry__detail">
                {{ t('transfer.keyword_identical') }}
              </span>
              <span v-else class="entry__texts">
                <span class="entry__text">
                  <span class="entry__label">{{ t('transfer.keyword_existing') }}</span>
                  {{ entry.existing.text }}
                </span>
                <span class="entry__text">
                  <span class="entry__label">{{ t('transfer.keyword_incoming') }}</span>
                  {{ entry.incoming.text }}
                </span>
              </span>

              <span class="entry__actions">
                <label class="transfer__decision">
                  <span class="visually-hidden">
                    {{ t('transfer.decision_for', { title: entry.name }) }}
                  </span>
                  <select v-model="keywordDecisions[entry.index]">
                    <option v-for="choice in entry.decisions" :key="choice" :value="choice">
                      {{ decisionLabel(choice) }}
                    </option>
                  </select>
                </label>
              </span>
            </li>
          </ul>
        </template>

        <!-- FA-802: one deliberate decision instead of 180 hurried ones. The
             default stays "überspringen"; this sets, it does not lock. -->
        <div v-if="collisions.length > 1" class="transfer__all">
          <span id="decide-all">{{ t('transfer.decide_all') }}</span>
          <button
            type="button"
            class="button button--quiet"
            data-test="decide-all-skip"
            @click="decideAll('skip')"
          >
            {{ t('transfer.decision_skip') }}
          </button>
          <button
            type="button"
            class="button button--quiet"
            data-test="decide-all-copy"
            @click="decideAll('copy')"
          >
            {{ t('transfer.decision_copy') }}
          </button>
          <button
            type="button"
            class="button button--quiet"
            data-test="decide-all-overwrite"
            @click="decideAll('overwrite')"
          >
            {{ t('transfer.decision_overwrite') }}
          </button>
        </div>

        <ul v-if="collisions.length" class="entries">
          <li v-for="entry in collisions" :key="entry.index" class="entry">
            <span class="entry__name">{{ entry.title }}</span>
            <span class="entry__detail">
              {{ entry.state === 'ambiguous'
                ? t('transfer.ambiguous', { count: entry.candidates.length })
                : t('transfer.exists') }}
            </span>

            <span class="entry__actions">
              <label class="transfer__decision">
                <span class="visually-hidden">{{ t('transfer.decision_for', { title: entry.title }) }}</span>
                <select v-model="decisions[entry.index]">
                  <option v-for="choice in entry.decisions" :key="choice" :value="choice">
                    {{ decisionLabel(choice) }}
                  </option>
                </select>
              </label>
            </span>
          </li>
        </ul>

        <!-- The safeguard that replaces the effort: what is about to happen,
             in four numbers, right above the button that does it. -->
        <p class="transfer__plan" data-test="import-plan" aria-live="polite">
          {{ t('transfer.plan', {
            added: plan.added, overwrite: plan.overwrite, copy: plan.copy, skip: plan.skip
          }) }}
        </p>

        <div class="transfer__actions">
          <button type="button" class="button button--quiet" @click="reset">
            {{ t('transfer.cancel') }}
          </button>
          <button type="button" class="button" :disabled="busy" data-test="import" @click="runImport">
            <Icon name="check-lg" /> {{ t('transfer.import') }}
          </button>
        </div>
      </template>

      <!-- The report. Named entries rather than a number, because "12
           übersprungen" is a figure and the twelve titles are an answer. -->
      <div v-if="report" class="transfer__report">
        <p><strong>{{ t('transfer.report', {
          created: report.created.length,
          overwritten: report.overwritten.length,
          skipped: report.skipped.length
        }) }}</strong></p>

        <p v-if="report.keywords_created.length" class="hint">
          {{ t('transfer.report_keywords', { names: report.keywords_created.join(', ') }) }}
        </p>
        <p v-if="report.keywords_overwritten.length" class="hint">
          {{ t('transfer.report_keywords_overwritten', { names: report.keywords_overwritten.join(', ') }) }}
        </p>
        <p v-if="report.keywords_skipped.length" class="hint">
          {{ t('transfer.report_keywords_skipped', { names: report.keywords_skipped.join(', ') }) }}
        </p>
        <p v-if="report.keywords_missing.length" class="hint">
          {{ t('transfer.keywords_missing', { names: report.keywords_missing.join(', ') }) }}
        </p>
        <p v-if="report.skipped.length" class="hint">
          {{ t('transfer.report_skipped', { names: report.skipped.join(', ') }) }}
        </p>
      </div>
    </section>

    <!-- 11.6: never an empty area. Someone with neither permission gets a
         sentence, not a screen with two headings and nothing under them. -->
    <p v-if="!mayExport && !mayImport" class="panel">{{ t('transfer.nothing_allowed') }}</p>
  </AppShell>
</template>

<style scoped>
.entry--keyword {
  align-items: start;
}

.entry__texts {
  display: grid;
  gap: 0.2rem;
  min-width: 0;
}

.entry__text {
  color: var(--muted);
  font-size: 0.85rem;
  overflow-wrap: anywhere;
}

.entry__label {
  margin-right: 0.4rem;
  color: var(--muted);
  font-size: 0.7rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.transfer__intro {
  max-width: 46rem;
  color: var(--muted);
}

.transfer__formats {
  margin: 0 0 1rem;
  padding: 0.5rem 0.75rem 0.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.transfer__formats legend {
  padding: 0 0.25rem;
  color: var(--muted);
  font-size: 0.75rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.transfer__format {
  display: flex;
  align-items: flex-start;
  gap: 0.5rem;
  padding: 0.375rem 0;
  cursor: pointer;
}

.transfer__format strong {
  display: block;
}

.transfer__format span {
  color: var(--muted);
  font-size: 0.875rem;
}

.transfer__format strong {
  color: var(--text);
  font-size: 1rem;
}

.transfer__counts {
  padding: 0.625rem 0.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface-sunken);
}

.transfer__decision select {
  padding: 0.375rem 0.5rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
}

.transfer__actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  margin-top: 1rem;
}

.transfer__report {
  margin-top: 1rem;
  padding: 0.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface-sunken);
}

.panel .hint {
  display: block;
  margin-top: 0.25rem;
  color: var(--muted);
  font-size: 0.875rem;
}
</style>
