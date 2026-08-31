<script setup>
import { ref } from 'vue'
import { t } from '@/i18n'
import Icon from '@/components/Icon.vue'

// Tags as chips with a field to add one (11.5). Enter and comma both finish a
// tag: people type one or the other, and refusing the comma would leave it
// inside the name.

const props = defineProps({
  tags: { type: Array, required: true }
})

const emit = defineEmits(['add', 'remove'])

const typed = ref('')

function commit () {
  emit('add', typed.value)
  typed.value = ''
}

function onKey (event) {
  if (event.key === 'Enter' || event.key === ',') {
    // Enter inside a form would submit it, and a comma would land in the name.
    event.preventDefault()
    commit()
    return
  }

  // Backspace on an empty field takes the last chip — the usual way out of a
  // list of chips, and the only one that does not need the mouse.
  if (event.key === 'Backspace' && typed.value === '' && props.tags.length) {
    emit('remove', props.tags[props.tags.length - 1])
  }
}
</script>

<template>
  <div class="tags field">
    <span>{{ t('editor.tags') }}</span>

    <ul class="tags__list">
      <li v-for="tag in tags" :key="tag">
        <button
          type="button"
          class="tags__chip"
          :aria-label="t('editor.tag_remove', { name: tag })"
          @click="emit('remove', tag)"
        >
          {{ tag }} <Icon name="x-lg" class="tags__x" />
        </button>
      </li>
    </ul>

    <input
      v-model="typed"
      type="text"
      class="tags__input"
      :placeholder="t('editor.tag_placeholder')"
      @keydown="onKey"
      @blur="commit"
    >
  </div>
</template>

<style scoped>
.tags__list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
  margin: 0 0 0.375rem;
  padding: 0;
  list-style: none;
}

.tags__chip {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  padding: 0.125rem 0.5rem;
  border: 1px solid var(--border-strong);
  border-radius: 999px;
  background: var(--surface);
  font: inherit;
  cursor: pointer;
}

.tags__chip:hover {
  border-color: var(--danger);
  color: var(--danger);
}

.tags__x {
  font-size: 0.75em;
  opacity: 0.7;
}

.tags__input {
  width: 100%;
  padding: 0.5rem 0.625rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
}
</style>
