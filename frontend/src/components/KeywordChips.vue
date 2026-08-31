<script setup>
import { t } from '@/i18n'

// Keywords as chips, not as a list of checkboxes (11.4). Switching one on is
// one click, and the state is visible without reading.

const props = defineProps({
  keywords: { type: Array, required: true },
  active: { type: Array, required: true },
  // Keywords that belong to the prompt but come from a workspace the reader
  // is not in (TF-426). They act, they are shown, and they cannot be switched
  // off — the server would refuse to render without them.
  locked: { type: Array, default: () => [] }
})

const emit = defineEmits(['toggle'])

const isActive = (keyword) => props.active.includes(keyword.id)
const isLocked = (keyword) => props.locked.includes(keyword.id)
</script>

<template>
  <div v-if="keywords.length" class="chips">
    <h2 class="chips__heading">{{ t('prompt.keywords') }}</h2>

    <ul class="chips__list">
      <li v-for="keyword in keywords" :key="keyword.id">
        <button
          type="button"
          class="chips__chip"
          :data-id="keyword.id"
          :aria-pressed="isActive(keyword)"
          :disabled="isLocked(keyword)"
          :title="keyword.text"
          @click="emit('toggle', keyword.id)"
        >
          {{ keyword.name }}
        </button>
      </li>
    </ul>

    <p v-if="locked.length" class="chips__note">{{ t('prompt.keywords_locked') }}</p>
  </div>
</template>

<style scoped>
.chips {
  margin-top: 1.5rem;
}

.chips__heading {
  margin: 0 0 0.5rem;
  color: var(--muted);
  font-size: 0.75rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.chips__list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
  margin: 0;
  padding: 0;
  list-style: none;
}

.chips__chip {
  padding: 0.25rem 0.625rem;
  border: 1px solid var(--border-strong);
  border-radius: 999px;
  background: var(--surface);
  cursor: pointer;
}

.chips__chip[aria-pressed="true"] {
  border-color: var(--accent);
  background: var(--accent);
  color: var(--accent-text);
}

.chips__chip:disabled {
  cursor: default;
  opacity: 0.75;
}

.chips__note {
  margin: 0.5rem 0 0;
  color: var(--muted);
  font-size: 0.8125rem;
}
</style>
