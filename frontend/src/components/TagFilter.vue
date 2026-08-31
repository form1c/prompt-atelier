<script setup>
import { t } from '@/i18n'

// The tag list in the sidebar (11.3): every tag of the workspace with the
// number of prompts carrying it.
//
// The count is what makes the list useful. A tag with 12 prompts behind it is
// a way into the library; one with none is a leftover, and seeing that is the
// first step to tidying it up.
//
// Several selected tags are combined with AND (FA-504) — the list narrows
// down, it does not grow. That is the behaviour people expect from a filter,
// and the opposite of what a search with several terms does in some other
// tools.

defineProps({
  tags: { type: Array, required: true },
  selected: { type: Array, required: true }
})

const emit = defineEmits(['toggle'])
</script>

<template>
  <div v-if="tags.length" class="tags">
    <h2 class="tags__heading">{{ t('shell.sections.tags') }}</h2>
    <ul class="tags__list">
      <li v-for="tag in tags" :key="tag.id">
        <button
          type="button"
          class="tags__item"
          :aria-pressed="selected.includes(tag.id)"
          @click="emit('toggle', tag.id)"
        >
          <span class="tags__name">{{ tag.name }}</span>
          <span class="tags__count">{{ tag.usage_count }}</span>
        </button>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.tags { margin-bottom: 1rem; }

.tags__heading {
  margin: 0 0 0.375rem;
  color: var(--muted);
  font-size: 0.75rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.tags__list {
  margin: 0;
  padding: 0;
  list-style: none;
}

.tags__item {
  display: flex;
  justify-content: space-between;
  gap: 0.5rem;
  width: 100%;
  padding: 0.25rem 0.5rem;
  border: 0;
  border-radius: var(--radius);
  background: none;
  text-align: left;
  cursor: pointer;
}

.tags__item:hover { background: var(--surface-sunken); }

.tags__item[aria-pressed="true"] {
  background: var(--accent);
  color: var(--accent-text);
}

.tags__count { color: inherit; opacity: 0.75; font-variant-numeric: tabular-nums; }
</style>
