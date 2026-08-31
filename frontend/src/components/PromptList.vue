<script setup>
import { useTemplateRef } from 'vue'
import { t } from '@/i18n'
import { formatTime, exactTime } from '@/util/time'
import { segments } from '@/util/highlight'
import { originName } from '@/util/workspace'

// The list of hits (Requirements 11.3).
//
// Every line carries title, description, tags, the time of the last change,
// the author and the number of variables. The author is not decoration: in a
// team it is the signal that decides whether someone trusts a prompt enough
// to use it without reading all of it.

const props = defineProps({
  prompts: { type: Array, required: true },
  showOrigin: { type: Boolean, default: false },
  // FA-510. Off by default, so every screen that does not offer bulk actions
  // keeps the list it had — a checkbox column nobody can act on is furniture.
  selectable: { type: Boolean, default: false },
  // A predicate rather than a list: the caller owns the selection, and passing
  // it through as a Set would tie this component to how it is stored.
  isSelected: { type: Function, default: () => false }
})

const emit = defineEmits(['open', 'favorite', 'toggle-select'])

const container = useTemplateRef('container')

// The list is reachable from the search field, which is where the focus sits
// when the screen loads (11.3). Arrow down out of the field lands here.
function focusFirst () {
  focusRow(0)
}

// The buttons are looked up in the DOM at the moment of focusing, not held as
// a list of element references. A `ref` inside `v-for` collects such a list,
// but it keeps pointing at the nodes that were there when it was filled — and
// this list is rebuilt on every keystroke. Focusing a node that has since been
// replaced does nothing at all, silently. It went unnoticed in jsdom, where
// the old node stays focusable, and showed up in the browser.
function focusRow (index) {
  const items = container.value?.querySelectorAll('.hit__open') ?? []
  if (items.length === 0) return

  items[Math.max(0, Math.min(index, items.length - 1))]?.focus()
}

// Home and End are part of it, not a flourish: with fifty hits, holding the
// arrow key is not a way to get to the last one.
function onKey (event, index) {
  const moves = {
    ArrowDown: index + 1,
    ArrowUp: index - 1,
    Home: 0,
    End: props.prompts.length - 1
  }

  if (!(event.key in moves)) return

  event.preventDefault()
  focusRow(moves[event.key])
}

// `{{2}}` — the notation of the variables themselves (Requirements 8.2), so
// it is built from that syntax rather than translated. The words for a screen
// reader come from the text table.
function variableBadge (count) {
  return `{{${count}}}`
}

// FA-501: the found place is marked. The pieces come from the ranges the
// server sends, and each is rendered as text — never as markup (SEC-10).
function marked (text, ranges) {
  return segments(text, ranges ?? [])
}

function variableLabel (count) {
  return count === 1 ? t('library.variables_one') : t('library.variables_many', { count })
}

defineExpose({ focusFirst })
</script>

<template>
  <ul ref="container" class="hits">
    <li v-for="(prompt, index) in prompts" :key="prompt.id" class="hit">
      <!-- Before the star, because the tab order follows the reading order and
           the choice "does this one belong to my selection" comes before what
           is done with it. Its own label per row: "auswählen" alone would be
           thirty identical names in the accessibility tree (11.6). -->
      <label v-if="selectable" class="hit__select">
        <input
          type="checkbox"
          :checked="isSelected(prompt.id)"
          :aria-label="t('selection.for', { title: prompt.title })"
          @change="emit('toggle-select', prompt.id)"
        >
      </label>

      <button
        type="button"
        class="hit__star"
        :aria-pressed="prompt.favorite"
        :aria-label="prompt.favorite ? t('actions.favorite_remove') : t('actions.favorite_add')"
        @click="emit('favorite', prompt)"
      >
        <span aria-hidden="true">{{ prompt.favorite ? '★' : '☆' }}</span>
      </button>

      <button
        type="button"
        class="hit__open"
        :aria-label="t('library.open', { title: prompt.title })"
        @click="emit('open', prompt)"
        @keydown="onKey($event, index)"
      >
        <span class="hit__head">
          <!-- The name alone reads as part of the title to a screen reader.
               The label says what it is. -->
          <span
            v-if="showOrigin && prompt.workspace_name"
            class="hit__origin"
            :aria-label="t('library.origin', { workspace: originName(prompt) })"
          >
            {{ originName(prompt) }}
          </span>
          <span class="hit__title">
            <template v-for="(piece, at) in marked(prompt.title, prompt.highlights?.title)" :key="at">
              <mark v-if="piece.marked">{{ piece.text }}</mark>
              <template v-else>{{ piece.text }}</template>
            </template>
          </span>
          <span
            v-if="prompt.variable_count > 0"
            class="hit__variables"
            :title="variableLabel(prompt.variable_count)"
          >{{ variableBadge(prompt.variable_count) }}</span>
        </span>

        <span v-if="prompt.description" class="hit__description">
          <template
            v-for="(piece, at) in marked(prompt.description, prompt.highlights?.description)"
            :key="at"
          >
            <mark v-if="piece.marked">{{ piece.text }}</mark>
            <template v-else>{{ piece.text }}</template>
          </template>
        </span>

        <span class="hit__meta">
          <span class="hit__tags">{{ prompt.tags.join(' · ') }}</span>
          <span class="hit__when" :title="exactTime(prompt.updated_at)">
            {{ formatTime(prompt.updated_at) }}<template v-if="prompt.owner_name"> · {{ prompt.owner_name }}</template>
          </span>
        </span>
      </button>
    </li>
  </ul>
</template>

<style scoped>
.hits {
  margin: 0;
  padding: 0;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
  list-style: none;
  overflow: hidden;
}

.hit {
  display: flex;
  align-items: flex-start;
  gap: 0.25rem;
  border-bottom: 1px solid var(--border);
}

.hit__select {
  display: flex;
  align-items: center;
  /* Aligned with the first line of the title rather than the top of a box
     that may be three lines tall. */
  padding: 0.75rem 0.25rem 0 0.5rem;
}

.hit__select input {
  /* Bigger than the browser default: this is a target people hit repeatedly
     while working down a list, and at the default size they miss it. */
  width: 1.1rem;
  height: 1.1rem;
  cursor: pointer;
}

.hit:last-child { border-bottom: 0; }
.hit:hover { background: var(--surface-sunken); }

.hit__star {
  flex: 0 0 auto;
  padding: 0.75rem 0.25rem 0.75rem 0.75rem;
  border: 0;
  background: none;
  color: var(--muted);
  font-size: 1.125rem;
  line-height: 1.2;
  cursor: pointer;
}

.hit__star[aria-pressed="true"] { color: #b8860b; }

.hit__open {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: 0.25rem;
  padding: 0.75rem 0.75rem 0.75rem 0.25rem;
  border: 0;
  background: none;
  text-align: left;
  cursor: pointer;
}

.hit__head {
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
}

.hit__title { font-weight: 600; }

mark {
  padding: 0 0.0625rem;
  border-radius: 2px;
  background: #fff3b0;
  color: inherit;
}

.hit__origin {
  padding: 0.0625rem 0.375rem;
  border-radius: 999px;
  background: var(--surface-sunken);
  color: var(--muted);
  font-size: 0.75rem;
}

.hit__variables {
  margin-left: auto;
  color: var(--muted);
  font-size: 0.8125rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}

.hit__description {
  color: var(--muted);
  font-size: 0.9375rem;
}

.hit__meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem 1rem;
  color: var(--muted);
  font-size: 0.8125rem;
}

.hit__when { margin-left: auto; }

@media (max-width: 599px) {
  .hit__variables,
  .hit__when { margin-left: 0; }
}
</style>
