<script setup>
import { onMounted, onUnmounted, useTemplateRef } from 'vue'
import { t } from '@/i18n'

// The one shape a confirmation takes (Requirements 11.6).
//
// Asked for only where an action is irreversible or far-reaching: deleting a
// keyword that prompts depend on, deleting a workspace with its contents,
// purging from the trash, leaving unsaved work. Deleting *into* the trash is
// none of those and asks nothing.
//
// One component rather than one dialogue per screen. The four of them differ
// in their wording and in nothing else, and four copies of a modal would be
// four places to forget the focus, the Escape key or `aria-modal`.

defineProps({
  title: { type: String, required: true },
  description: { type: String, default: '' },
  confirmLabel: { type: String, required: true },
  // For the deletions, where the confirming button is the dangerous one.
  danger: { type: Boolean, default: false },
  // Off while the request is running, so a second click cannot send it twice.
  busy: { type: Boolean, default: false },
  // The confirming button stays out of reach until something else is right —
  // the workspace name in FA-606, typed out.
  ready: { type: Boolean, default: true }
})

const emit = defineEmits(['confirm', 'cancel'])

const box = useTemplateRef('box')

// The focus moves into the dialogue, or the keyboard stays behind on the
// screen underneath and Tab walks through controls nobody can see.
onMounted(() => {
  window.addEventListener('keydown', onKey)
  box.value?.querySelector('input, button')?.focus()
})

onUnmounted(() => window.removeEventListener('keydown', onKey))

// 11.6: Escape closes. A dialogue that can only be left by hitting the right
// button is one more thing to learn.
function onKey (event) {
  if (event.key !== 'Escape') return

  event.preventDefault()
  emit('cancel')
}
</script>

<template>
  <div class="confirm" role="dialog" aria-modal="true" :aria-label="title">
    <div ref="box" class="confirm__box">
      <h2>{{ title }}</h2>
      <p v-if="description">{{ description }}</p>

      <!-- What is at stake, named: the prompts a keyword is on, the contents
           of a workspace, the field that asks for its name. -->
      <slot />

      <div class="confirm__actions">
        <button type="button" class="button button--quiet" @click="emit('cancel')">
          {{ t('confirm.cancel') }}
        </button>
        <button
          type="button"
          class="button"
          :class="{ 'button--danger': danger }"
          :disabled="busy || !ready"
          data-test="confirm"
          @click="emit('confirm')"
        >
          {{ confirmLabel }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.confirm {
  position: fixed;
  inset: 0;
  z-index: 20;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1rem;
  background: rgb(31 35 40 / 45%);
}

.confirm__box {
  max-width: 30rem;
  max-height: 90vh;
  padding: 1.25rem;
  overflow-y: auto;
  border-radius: var(--radius);
  background: var(--surface);
  box-shadow: var(--shadow);
}

.confirm__actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  margin-top: 1rem;
}
</style>
