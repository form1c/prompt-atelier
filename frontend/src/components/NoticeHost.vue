<script setup>
import { notices } from '@/state/notices'

// The place the short confirmations from 11.6 appear. One host for the whole
// application, mounted next to the router view, so a notice survives the
// screen that caused it — "Gespeichert" would otherwise vanish with the
// dialogue that triggered it.
</script>

<template>
  <!-- polite, not assertive: the confirmation is not worth interrupting what
       a screen reader is currently saying. -->
  <div class="notices" role="status" aria-live="polite">
    <p v-for="notice in notices" :key="notice.id" class="notices__item">
      {{ notice.message }}
    </p>
  </div>
</template>

<style scoped>
.notices {
  position: fixed;
  right: 1rem;
  bottom: 1rem;
  z-index: 20;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  /* The area covers a corner of the screen even while empty; without this
     it would swallow clicks on whatever is underneath. */
  pointer-events: none;
}

.notices__item {
  margin: 0;
  padding: 0.5rem 0.875rem;
  border-radius: var(--radius);
  background: var(--text);
  color: var(--surface);
  box-shadow: var(--shadow);
}
</style>
