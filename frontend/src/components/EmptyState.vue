<script setup>
import { t } from '@/i18n'

// Requirements 11.6: never an empty surface. A sentence that explains, and at
// least one thing to do — the empty library is the first thing a new
// installation shows, and "0 Treffer" would be a dead end (W-6).

defineProps({
  title: { type: String, required: true },
  description: { type: String, default: '' }
})
</script>

<template>
  <div class="empty">
    <h2>{{ title }}</h2>
    <p>{{ description || t('state.empty_hint') }}</p>
    <!-- The offers. A caller that has none leaves this empty, which is what
         the rule above forbids — so the slot has no fallback: an empty area
         here is meant to look wrong in review. -->
    <div class="empty__actions">
      <slot />
    </div>
  </div>
</template>

<style scoped>
.empty {
  padding: 2rem 1.5rem;
  border: 1px dashed var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  text-align: center;
}

.empty p {
  color: var(--muted);
}

.empty__actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  justify-content: center;
}
</style>
