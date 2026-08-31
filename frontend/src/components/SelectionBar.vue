<script setup>
import { t } from '@/i18n'
import Icon from '@/components/Icon.vue'

// The bar that appears once something is selected (FA-510).
//
// **It is not there when nothing is selected.** A permanently visible bar
// reading "0 ausgewählt" with greyed-out buttons explains nothing and takes up
// the room the list needs — the same reasoning as for a disabled control in
// 11.6: a button that cannot be pressed says less than a button that is not
// there.
//
// The actions themselves come from the screen through a slot. This component
// knows how many are selected and how to let go of them; what may be done with
// a selection is a question about the screen, and the library and the trash
// answer it differently.

defineProps({
  count: { type: Number, required: true },
  // The whole result list, when it is bigger than what has been loaded and
  // small enough for one call (15.3). Null means the offer does not apply.
  total: { type: Number, default: null },
  // Above the limit of a bulk call the offer turns into a sentence. A button
  // the server would refuse is a promise the interface cannot keep.
  tooMany: { type: Boolean, default: false }
})

const emit = defineEmits(['clear', 'select-all'])
</script>

<template>
  <div class="selection" role="region" :aria-label="t('selection.title')">
    <p class="selection__count" aria-live="polite">
      {{ count === 1 ? t('selection.one') : t('selection.many', { count }) }}
    </p>

    <p v-if="tooMany" class="selection__note">
      {{ t('selection.too_many', { count: total }) }}
    </p>
    <button
      v-else-if="total && total > count"
      type="button"
      class="button button--quiet selection__all"
      data-test="select-all"
      @click="emit('select-all')"
    >
      {{ t('selection.select_all', { count: total }) }}
    </button>

    <span class="selection__actions">
      <slot />
    </span>

    <button
      type="button"
      class="button button--quiet"
      data-test="selection-clear"
      @click="emit('clear')"
    >
      <Icon name="x-lg" /> {{ t('selection.clear') }}
    </button>
  </div>
</template>

<style scoped>
.selection {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--space-2);
  padding: var(--space-2) var(--space-3);
  margin-bottom: var(--space-3);
  background: var(--accent-surface);
  border: 1px solid var(--accent);
  border-radius: var(--radius);
}

.selection__count {
  margin: 0;
  font-weight: 600;
}

.selection__note {
  margin: 0;
  color: var(--muted);
}

.selection__actions {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space-2);
  margin-left: auto;
}
</style>
